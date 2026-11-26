#!/usr/bin/env bash
# dreamdns - keep a DreamHost DNS record pointed at this host's public IP.
#
# Runs once and exits; schedule it with the bundled systemd timer (or cron).
# Each run handles one record; run one instance per record (dreamdns@.timer).
# Uses the DreamHost API v1 (https://developers.dreamhost.com):
#   GET  /v1/dns/{zone}?name=&type=   find the current record
#   PUT  /v1/dns/{zone}               change its IP (no delete/re-add gap)
#   POST /v1/dns/{zone}               create it when missing
#   GET  /v1/tasks/{id}               writes are async; check the result
#
# The last published IP is cached in STATE_DIR so the API is only called
# when the public IP changes, plus once per RECHECK_SECS to repair drift
# (e.g. someone edited the record in the panel).
#
# DNS writes are asynchronous tasks that took ~3 minutes to complete in
# testing, although the API lists the new value right away. Rather than
# block on them, the task IDs are saved with the cached IP and checked on
# the next run: a task that ended in anything but success clears the cache,
# so that same run re-reads the record and writes it again.
#
# Config (environment, or KEY=value lines in --env files):
#   DH_API_KEY    API key with dns:read + dns:write          (required)
#   DNS_ZONE      zone the record lives in, e.g. example.com  (required)
#   DNS_NAME      record name relative to the zone, e.g. home (required)
#   DNS_TYPES     "A", "AAAA" or "A AAAA"                     (default: A)
#   RECHECK_SECS  verify against the API at least this often  (default: 14400)
#   STATE_DIR     IP cache dir (default: $STATE_DIRECTORY, else ~/.local/state/dreamdns)

set -euo pipefail

readonly API_BASE="https://api.dreamhost.com/v1"
readonly IPV4_URLS=("https://api.ipify.org" "https://ipv4.icanhazip.com")
readonly IPV6_URLS=("https://api6.ipify.org" "https://ipv6.icanhazip.com")

usage() {
	cat >&2 <<-EOF
	Usage: $0 [--env FILE]... [--ip ADDR] [--force]
	  --env FILE  load KEY=value config from FILE; repeatable, later files win
	              (e.g. --env /etc/dreamdns/common.env --env /etc/dreamdns/home.env)
	  --ip ADDR   publish ADDR instead of detecting the public IP (one type only)
	  --force     ignore the local IP cache and always check the API
	EOF
	exit 2
}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

env_files=()
ip_override=""
force=0
while (($#)); do
	case "$1" in
		--env) env_files+=("${2:?--env needs a file}"); shift 2 ;;
		--ip) ip_override="${2:?--ip needs an address}"; shift 2 ;;
		--force) force=1; shift ;;
		-h | --help) usage ;;
		*) log "unknown option: $1"; usage ;;
	esac
done

for env_file in "${env_files[@]}"; do
	[[ -r "$env_file" ]] || die "cannot read $env_file"
	set -a
	# shellcheck disable=SC1090
	source "$env_file"
	set +a
done

: "${DH_API_KEY:?DH_API_KEY is not set}"
: "${DNS_ZONE:?DNS_ZONE is not set}"
: "${DNS_NAME:?DNS_NAME is not set}"
DNS_TYPES="${DNS_TYPES:-A}"
RECHECK_SECS="${RECHECK_SECS:-14400}"
STATE_DIR="${STATE_DIR:-${STATE_DIRECTORY:-${XDG_STATE_HOME:-$HOME/.local/state}/dreamdns}}"
command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required"

if [[ -n "$ip_override" && "$DNS_TYPES" == *" "* ]]; then
	die "--ip can only be used when DNS_TYPES has a single type"
fi

fqdn="$DNS_NAME.$DNS_ZONE"
[[ "$DNS_NAME" == "@" ]] && fqdn="$DNS_ZONE"

# Calls the API and prints the response body. The key is fed to curl as a
# config file on stdin so it never shows up in `ps` output. curl retries
# 429/5xx itself, honoring Retry-After; writes carry an Idempotency-Key so
# those retries cannot apply a change twice.
api() {
	local method="$1" path="$2" body="${3:-}"
	local args=(-sS --max-time 30 --retry 3 --retry-max-time 90 -X "$method"
		-H "Accept: application/json" -w '\n%{http_code}' -K -)
	if [[ -n "$body" ]]; then
		args+=(-H "Content-Type: application/json"
			-H "Idempotency-Key: $(cat /proc/sys/kernel/random/uuid)"
			--data-binary "$body")
	fi
	local response status
	response="$(curl "${args[@]}" "$API_BASE$path" \
		<<<"header = \"Authorization: Bearer $DH_API_KEY\"")" ||
		die "$method $path: request failed"
	status="${response##*$'\n'}"
	response="${response%$'\n'*}"
	if ((status < 200 || status > 299)); then
		local message
		message="$(jq -r 'select(.message) | "\(.message) (correlationId \(.correlationId))"' \
			<<<"$response" 2>/dev/null || true)"
		die "$method $path: HTTP $status ${message:-$response}"
	fi
	printf '%s' "$response"
}

# Records the ID of a write task (from a 202 response) in submitted_tasks.
track_task() {
	local task_id
	task_id="$(jq -r '.taskId // empty' <<<"$1")"
	[[ "$task_id" =~ ^[0-9]+$ ]] || die "write accepted without a task ID: $1"
	log "$fqdn: submitted task $task_id"
	submitted_tasks+=("$task_id")
}

# Checks tasks saved by an earlier run. Prints the IDs still scheduled and
# returns 1 if any ended in another state (failure, died, killed, canceled)
# or could not be looked up, meaning the cached IP cannot be trusted.
check_pending_tasks() {
	local task_id status ok=0
	for task_id in "$@"; do
		status="$(api GET "/tasks/$task_id" | jq -r '.status')" || status="unknown"
		case "$status" in
			success) ;;
			scheduled) printf '%s ' "$task_id" ;;
			*) log "warning: task $task_id ended with status '$status'"; ok=1 ;;
		esac
	done
	return "$ok"
}

detect_ip() {
	local type="$1" url ip curl_family pattern
	if [[ "$type" == "A" ]]; then
		curl_family=-4 pattern='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
		set -- "${IPV4_URLS[@]}"
	else
		curl_family=-6 pattern='^[0-9a-fA-F:]+:[0-9a-fA-F:.]*$'
		set -- "${IPV6_URLS[@]}"
	fi
	for url in "$@"; do
		ip="$(curl "$curl_family" -fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
		if [[ "$ip" =~ $pattern ]]; then
			printf '%s' "$ip"
			return 0
		fi
		log "warning: $url returned unexpected data"
	done
	return 1
}

# Makes DNS_NAME's record of the given type hold exactly one value: ip.
publish() {
	local type="$1" ip="$2" records count current task
	local name_q
	name_q="$(jq -rn --arg n "$DNS_NAME" '$n|@uri')"
	records="$(api GET "/dns/$DNS_ZONE?name=$name_q&type=$type" | jq -c '.data')"
	count="$(jq 'length' <<<"$records")"

	if jq -e 'any(.[]; .isProtected)' <<<"$records" >/dev/null; then
		die "$fqdn $type is a protected record and cannot be changed via the API"
	fi

	if ((count == 0)); then
		log "$fqdn $type: creating -> $ip"
		task="$(api POST "/dns/$DNS_ZONE" "$(jq -cn \
			--arg n "$DNS_NAME" --arg t "$type" --arg ip "$ip" \
			'{records: [{name: $n, type: $t, fields: {ip: $ip}}]}')")"
		track_task "$task"
		return
	fi

	# Keep the record that already holds the right IP if there is one,
	# otherwise repoint the first; a dynamic name should have one value,
	# so any extras (left over from manual edits) are removed.
	current="$(jq -c --arg ip "$ip" '(map(select(.value == $ip)) + .)[0]' <<<"$records")"
	if [[ "$(jq -r '.value' <<<"$current")" == "$ip" ]]; then
		log "$fqdn $type: already $ip"
	else
		log "$fqdn $type: updating $(jq -r '.value' <<<"$current") -> $ip"
		task="$(api PUT "/dns/$DNS_ZONE" "$(jq -cn \
			--argjson cur "$current" --arg ip "$ip" \
			'{currentRecord: {name: $cur.name, type: $cur.type, value: $cur.value},
			  newRecord: {name: $cur.name, type: $cur.type, fields: {ip: $ip}}}')")"
		track_task "$task"
	fi

	local extra
	while IFS= read -r extra; do
		[[ -n "$extra" ]] || continue
		log "$fqdn $type: removing extra value $(jq -r '.value' <<<"$extra")"
		task="$(api DELETE "/dns/$DNS_ZONE" "$(jq -cn --argjson r "$extra" \
			'{record: {name: $r.name, type: $r.type, value: $r.value}}')")"
		track_task "$task"
	done < <(jq -c --argjson cur "$current" '.[] | select(.value != $cur.value)' <<<"$records")
}

mkdir -p "$STATE_DIR"
for type in $DNS_TYPES; do
	[[ "$type" == "A" || "$type" == "AAAA" ]] || die "unsupported DNS type '$type'"

	if [[ -n "$ip_override" ]]; then
		ip="$ip_override"
	else
		ip="$(detect_ip "$type")" || die "could not detect public $type address"
	fi

	# State file: "<ip> <epoch of last API check> [<pending task id>...]"
	state_file="$STATE_DIR/$DNS_ZONE-$DNS_NAME-$type"
	cached_ip="" cached_at=0 pending_tasks_line="" pending_tasks=()
	if [[ -r "$state_file" ]]; then
		read -r cached_ip cached_at pending_tasks_line <"$state_file" || true
		read -ra pending_tasks <<<"${pending_tasks_line:-}"
	fi
	if ((${#pending_tasks[@]})); then
		task_failed=0
		still_pending="$(check_pending_tasks "${pending_tasks[@]}")" || task_failed=1
		read -ra pending_tasks <<<"$still_pending"
		if ((task_failed)); then
			log "$fqdn $type: an earlier write failed; re-checking the record"
			cached_at=0
		fi
	fi

	now="$(date +%s)"
	if ((!force)) && [[ "$ip" == "$cached_ip" ]] && ((now - cached_at < RECHECK_SECS)); then
		log "$fqdn $type: $ip unchanged since last check${pending_tasks[*]:+ (tasks pending: ${pending_tasks[*]})}"
		printf '%s %s %s\n' "$cached_ip" "$cached_at" "${pending_tasks[*]}" >"$state_file"
		continue
	fi

	submitted_tasks=()
	publish "$type" "$ip"
	printf '%s %s %s\n' "$ip" "$now" "${pending_tasks[*]} ${submitted_tasks[*]}" >"$state_file"
done

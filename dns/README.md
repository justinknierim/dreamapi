# dreamdns

Keeps DreamHost DNS records (e.g. `subdomain.mydomain.com`) pointed at the
host's public IP, using the DreamHost API v1.

- `dreamdns.sh` - updates one record, runs once and exits; systemd schedules it
- `dreamdns@.service` / `dreamdns@.timer` - one instance per record, every 5 minutes, sandboxed, with `DynamicUser`
- `dreamdns.env.example` - per-record config

## Config layout

One systemd instance per record. The instance name is any label; using the
FQDN keeps it obvious:

| Path | Contents |
|---|---|
| `/etc/dreamdns/common.env` | Optional. Settings shared by every instance, typically `DH_API_KEY`. |
| `/etc/dreamdns/<instance>.env` | Required. `DNS_ZONE`, `DNS_NAME`, optional `DNS_TYPES`; overrides `common.env`. |

Records can be in different zones, and in different DreamHost accounts by
putting each account's `DH_API_KEY` in the instance file instead of
`common.env`. Each instance keeps its cache in `/var/lib/dreamdns/<instance>/`.

## Behavior

1. Detect the public IP (`api.ipify.org`, falling back to `icanhazip.com`).
2. If it matches the cached IP and the last API check was less than `RECHECK_SECS` (default 4 hours) ago, exit without calling the API.
3. Otherwise `GET /v1/dns/{zone}?name=&type=`, then `PUT` to change the IP, or `POST` if the record is missing. Extra values for the same name and type are deleted.
4. Save the IP and the write's task ID (`/v1/tasks/{id}`) to the cache and exit without waiting.
5. On the next run, check saved tasks. If one ended in anything other than `success`, clear the cache so that run re-reads the record and fixes it.

DNS write tasks show the new value immediately in the API.  DreamHost's
nameservers serve it once the backend DNS task completes; resolvers then
follow the zone's TTL (DreamHost's default is 4 hours unless change requested).

`RECHECK_SECS` is how often the record is re-read from the API even when the
IP has not changed, to repair manual edits. It is unrelated to the TTL, and
lookups are cheap (500 GETs per minute per account), so lower it freely.

## Requirements

- `bash`, `curl`, `jq`, systemd
- An API key per host, from Panel > API (`https://panel.dreamhost.com/?tree=api.dashboard`), with only `dns:read` and `dns:write`. The key must be created in the DreamHost account that owns the zone; otherwise the API returns `404 domain_not_found`.

## Install (per host)

```sh
sudo install -m 755 dreamdns.sh /usr/local/bin/dreamdns
sudo install -m 644 dreamdns@.service dreamdns@.timer /etc/systemd/system/
sudo install -d -m 700 /etc/dreamdns
sudo systemctl daemon-reload
```

Per record (repeat for each):

```sh
sudo install -m 600 dreamdns.env.example /etc/dreamdns/subdomain.mydomain.com.env
sudoedit /etc/dreamdns/subdomain.mydomain.com.env   # set DH_API_KEY, DNS_ZONE, DNS_NAME
sudo systemctl enable --now dreamdns@subdomain.mydomain.com.timer
```

To share one key across records, put `DH_API_KEY=...` in
`/etc/dreamdns/common.env` (mode 600) and leave it out of the instance files.

Check it:

```sh
sudo systemctl start dreamdns@subdomain.mydomain.com.service
journalctl -u 'dreamdns@*' -n 20
# subdomain.mydomain.com A: updating 203.0.113.4 -> 198.51.100.7
systemctl list-timers 'dreamdns@*'
dig +short subdomain.mydomain.com
```

## Upgrading from the single-record units

Earlier versions used `dreamdns.service` / `dreamdns.timer` and `/etc/dreamdns.env`:

```sh
sudo systemctl disable --now dreamdns.timer
sudo rm /etc/systemd/system/dreamdns.service /etc/systemd/system/dreamdns.timer
sudo install -d -m 700 /etc/dreamdns
sudo mv /etc/dreamdns.env /etc/dreamdns/subdomain.mydomain.com.env
# then install the script and @ units as above, and enable the instance timer
```

The first run of the new instance re-reads the record from the API (no cache
yet) and only writes if it differs.

## Manual runs

```sh
./dreamdns.sh --env ./my.env            # normal run
./dreamdns.sh --env ./my.env --force    # ignore the local IP cache
./dreamdns.sh --env ./my.env --ip 192.0.2.55   # publish a specific IP
./dreamdns.sh --env ./common.env --env ./home.env   # layered, like systemd
```

Outside systemd, the cache lives in `~/.local/state/dreamdns` (override with `STATE_DIR`).

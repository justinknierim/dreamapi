# dreamdns

Keeps a DreamHost DNS record (e.g. `subdomain.mydomain.com`) pointed at the
host's public IP, using the DreamHost API v1.

- `dreamdns.sh` - runs once and exits; systemd schedules it
- `dreamdns.service` / `dreamdns.timer` - run every 5 minutes, sandboxed, with `DynamicUser`
- `dreamdns.env.example` - per-host config

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
sudo install -m 600 dreamdns.env.example /etc/dreamdns.env
sudoedit /etc/dreamdns.env        # set DH_API_KEY and DNS_NAME
sudo install -m 644 dreamdns.service dreamdns.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dreamdns.timer
```

Check it:

```sh
sudo systemctl start dreamdns.service && journalctl -u dreamdns -n 20
# subdomain.mydomain.com A: updating 203.0.113.4 -> 198.51.100.7
dig +short subdomain.mydomain.com
```

## Manual runs

```sh
./dreamdns.sh --env ./my.env            # normal run
./dreamdns.sh --env ./my.env --force    # ignore the local IP cache
./dreamdns.sh --env ./my.env --ip 192.0.2.55   # publish a specific IP
```

Outside systemd, the cache lives in `~/.local/state/dreamdns` (override with `STATE_DIR`).

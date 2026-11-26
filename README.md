# dreamapi

Small tools built on the [DreamHost API v1](https://developers.dreamhost.com/)
(`https://api.dreamhost.com/v1`), which replaces the retired legacy API.

| Directory | What it does |
|---|---|
| [`dns/`](dns/) | Dynamic DNS: keeps A/AAAA records pointed at a host's public IP. Bash + curl + jq, one systemd timer instance per record. |

## API keys

Create keys at Panel > API (`https://panel.dreamhost.com/?tree=api.dashboard`).

- Grant only the permissions a tool needs (each tool's README lists them).
- Create the key in the DreamHost account that owns the resource; otherwise the API returns `404` (for example `domain_not_found`).
- Legacy API keys do not work with the v1 API.
- Keep keys in env files outside the repo (for example `/etc/dreamdns/`); `.env*` files are git-ignored here.

## License

GPL-3.0, see [LICENSE](LICENSE).

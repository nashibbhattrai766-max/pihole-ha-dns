# Highly-available Pi-hole DNS

Two Pi-hole v6 instances so ad-blocking DNS keeps working when one host is down for maintenance:

| | Primary | Secondary |
|---|---|---|
| Runs on | LXC container on the Proxmox cluster | Docker on the backup server |
| IP | `10.0.0.2` | `10.0.0.20` |
| Upstream | Unbound (recursive, DNSSEC) | Unbound (recursive, DNSSEC) |
| Config | edited here | **copied from primary hourly by nebula-sync** |

The router's DHCP hands out **both** addresses, so clients fail over by themselves.

```
clients ──► DNS 1 (Pi-hole) ──► Unbound ──► root servers
        └─► DNS 2 (Pi-hole) ──► Unbound ──► root servers
                 ▲
                 └── nebula-sync (hourly): blocklists, allow/deny lists, groups, local DNS records
```

## Files

| File | Purpose |
|---|---|
| [`docker-compose.yml`](docker-compose.yml) | Secondary Pi-hole + nebula-sync |
| [`.env.example`](.env.example), [`nebula.env.example`](nebula.env.example) | Passwords and sync settings (copy to `.env` / `nebula.env`, never commit them) |
| [`unbound/pi-hole.conf`](unbound/pi-hole.conf) | Unbound as a local recursive resolver on `127.0.0.1:5335` |
| [`test-dns.sh`](test-dns.sh) | Checks both servers resolve, block and validate DNSSEC |

## Setup (secondary)

```bash
apt install docker.io docker-compose unbound
cp unbound/pi-hole.conf /etc/unbound/unbound.conf.d/
systemctl restart unbound
dig @127.0.0.1 -p 5335 example.com          # must answer

cp .env.example .env && cp nebula.env.example nebula.env   # fill in passwords
docker compose up -d
docker logs -f nebula-sync                    # look for "Sync completed"
```

Then add the second IP to your router's DHCP DNS servers.

**Test failover:** stop the primary and browse; everything should keep resolving through the secondary.

## Troubleshooting notes

- **Unbound on Proxmox/PBS hosts.** Debian's Unbound AppArmor profile and `remote-control` config clashed on the Proxmox kernel. Disabling the profile (`ln -s /etc/apparmor.d/usr.sbin.unbound /etc/apparmor.d/disable/`, then `apparmor_parser -R`) and removing `remote-control.conf` fixed startup.
- **Unbound answered `SERVFAIL` for everything.** The cause wasn't Unbound at all: the router's **content-filter "ad block" feature intercepts all port-53 traffic** and answers it itself, which breaks recursion and DNSSEC. Telling sign: `dig +norec @127.0.0.1 -p 5335 . NS` returns `ra` from an unexpected server instead of `qr aa` from a root server. Turning the router feature off fixed it — and showed that the "working" primary had only been answering from cache for weeks.
- **nebula-sync returns 401.** It needs the Pi-hole *web password*. If you set it through a shell variable, make sure the variable isn't empty in a new shell.
- **Chrome bypasses Pi-hole** on machines that list a public resolver (e.g. `8.8.8.8`) as a fallback DNS server: Chrome upgrades to encrypted DNS with that provider. Give devices only your Pi-holes.
- **Pi-hole can't block ads served from the same domain as the content** (e.g. YouTube). That needs a browser-level blocker.

## License

MIT

# Highly-Available Pi-hole DNS with Unbound

Network-wide ad and tracker blocking that **keeps working when a server is down**. There are two Pi-hole v6 servers on different hardware, each with its own **Unbound** recursive resolver, and the primary's configuration is copied to the secondary automatically every hour.

**Result:** every device on the network gets ad-blocked, privacy-friendly DNS. When I stop the primary for maintenance, nobody notices.

---

## Contents
1. [Why](#1-why)
2. [Design](#2-design)
3. [What you need](#3-what-you-need)
4. [Build: primary Pi-hole](#4-build-primary-pi-hole)
5. [Build: Unbound (on both servers)](#5-build-unbound-on-both-servers)
6. [Build: secondary Pi-hole in Docker](#6-build-secondary-pi-hole-in-docker)
7. [Build: keep them in sync with nebula-sync](#7-build-keep-them-in-sync-with-nebula-sync)
8. [Build: hand both servers to clients](#8-build-hand-both-servers-to-clients)
9. [Build: monitoring](#9-build-monitoring)
10. [Verify it works](#10-verify-it-works)
11. [Running it day to day](#11-running-it-day-to-day)
12. [Troubleshooting: when DNS "worked" but didn't](#12-troubleshooting-when-dns-worked-but-didnt)
13. [Other lessons](#13-other-lessons)

---

## 1. Why

With a **single Pi-hole**, DNS is a single point of failure for the whole house: reboot that container for an update and every phone, TV and laptop loses the internet until it's back. A household notices that immediately.

Goals:
- **Two DNS servers on different physical machines**, so one can be down.
- **Identical blocking on both**, without editing two web UIs.
- **No third-party DNS provider** (Google, Cloudflare) sees the queries. Each server resolves recursively from the root servers itself, with DNSSEC validation.
- Monitored, with alerts if either one stops answering.

## 2. Design

```
                      ┌─────────────── DHCP: DNS = 10.0.0.2, 10.0.0.20 ───────────────┐
                      ▼                                                               ▼
     ┌─ DNS 1 · Pi-hole (LXC on the Proxmox cluster) ─┐     ┌─ DNS 2 · Pi-hole (Docker on the backup server) ─┐
     │  10.0.0.2                                       │     │  10.0.0.20                                       │
     │  upstream: Unbound 127.0.0.1#5335               │     │  upstream: Unbound 127.0.0.1#5335                │
     └─────────────────────────────────────────────────┘     └──────────────────────────────────────────────────┘
                      │            ▲ nebula-sync (hourly): adlists, allow/deny lists,          │
                      │            └─ groups, clients, local DNS records ──────────────────────┤
                      ▼                                                                         ▼
               root servers → TLD → authoritative            (each Unbound resolves on its own, DNSSEC-validated)
```

| Decision | Why |
|---|---|
| **Secondary on a different machine** (the backup server) | The primary is on the cluster. If the cluster has a bad day, DNS still works. |
| **Docker for the secondary** | The backup server is a dedicated appliance; Docker keeps Pi-hole isolated and easy to update or remove. |
| **Unbound on each host** | Recursive resolution means no upstream provider sees your browsing, and DNSSEC is validated locally. Each server is independent. |
| **nebula-sync, selective mode** | Pi-hole v6 has no built-in HA. nebula-sync copies lists, groups and local DNS records through the API, but *not* host-specific settings (interfaces, upstreams) that must differ. |
| **Both IPs via DHCP** | Clients fail over by themselves; no virtual IP or keepalived needed. |

## 3. What you need

- Two always-on Linux hosts (here: a Debian 13 LXC on Proxmox, and the Debian 13-based Proxmox Backup Server).
- Static IPs for both.
- Access to the router's DHCP settings.
- On the Docker host: `docker.io` and `docker-compose`.

## 4. Build: primary Pi-hole

1. **Container:** Proxmox → *Create CT* → Debian 13 template, 1 vCPU, 512 MB–1 GB RAM, 8 GB disk, **static IP** `10.0.0.2/24`, *Start at boot* ✓.
2. **Install Pi-hole** inside it (or use the Proxmox community helper script for Pi-hole):
   ```bash
   apt update && apt install -y curl
   curl -sSL https://install.pi-hole.net | bash
   ```
   Pick any upstream for now; it gets switched to Unbound in step 5.
3. Set the web password: `pihole setpassword`.
4. **Blocklists:** *Lists*. Start with the default list and add a few well-maintained ones (e.g. OISD, Hagezi). Then *Tools → Update Gravity*.

## 5. Build: Unbound (on both servers)

Do this on the primary **and** on the Docker host for the secondary.

```bash
apt install -y unbound
cp unbound/pi-hole.conf /etc/unbound/unbound.conf.d/pi-hole.conf   # from this repo
systemctl restart unbound
dig @127.0.0.1 -p 5335 example.com            # must return an address
dig @127.0.0.1 -p 5335 dnssec-failed.org      # must return SERVFAIL (DNSSEC working)
```

The config ([`unbound/pi-hole.conf`](unbound/pi-hole.conf)) listens only on `127.0.0.1:5335`, hardens against DNS spoofing and cache poisoning, and refuses to return private IPs for public names (DNS-rebinding protection).

Then point Pi-hole at it: *Settings → DNS*. Untick every upstream and add the custom upstream **`127.0.0.1#5335`**.

## 6. Build: secondary Pi-hole in Docker

On the second host:

```bash
git clone https://github.com/nashibbhattrai766-max/pihole-ha-dns && cd pihole-ha-dns
cp .env.example .env              # set PIHOLE_PASSWORD
docker compose up -d pihole
docker logs -f pihole2            # wait for "FTL started"
```

What the compose file sets up ([`docker-compose.yml`](docker-compose.yml)):
- **Host networking**, so Pi-hole answers on the host's own IP on port 53.
- **`FTLCONF_dns_upstreams: 127.0.0.1#5335`**: the host's Unbound from step 5.
- **`FTLCONF_dns_listeningMode: ALL`**, so it answers clients on the LAN.
- **`apparmor=unconfined`**, needed on Proxmox kernels (otherwise `setpriv: initgroups failed`).

Open `http://10.0.0.20/admin` and log in.

## 7. Build: keep them in sync with nebula-sync

```bash
cp nebula.env.example nebula.env  # primary + replica URLs and web passwords
docker compose up -d nebula-sync
docker logs -f nebula-sync        # look for "Sync completed"
```

The sync runs **hourly** (`CRON=0 * * * *`) and copies:

| Synced ✓ | Not synced ✗ (host-specific) |
|---|---|
| Adlists, allow/deny domains, regex | Upstream DNS servers |
| Groups and client assignments | Network interfaces / listening mode |
| Local DNS and CNAME records | DHCP, NTP, misc settings |

It also runs **gravity** on the replica after each sync, so new adlists download there too.

From now on, **make all changes on the primary only**. The secondary catches up within the hour.

## 8. Build: hand both servers to clients

In the router's LAN/DHCP settings, set **DNS server 1 = 10.0.0.2** and **DNS server 2 = 10.0.0.20**. Clients pick up the change when they renew their lease; reconnecting Wi-Fi forces it.

Also set **Proxmox nodes and other servers** to use only these two (*node → System → DNS*). Don't add `8.8.8.8` "as a fallback"; see the lessons below.

## 9. Build: monitoring

- **Zabbix** asks each Pi-hole to resolve a name every minute (`net.dns[10.0.0.20,google.com,A,2,2]`). If either fails to answer for 3 minutes, a **High** alert goes to my phone ([zabbix-monitoring](https://github.com/nashibbhattrai766-max/zabbix-monitoring)).
- On the backup server, a collector also reports whether **Unbound**, the **Pi-hole container** and **nebula-sync** are running, and when the last successful sync happened. An alert fires if there has been no sync for 3 hours.
- The Grafana rack screen has **DNS 1 / DNS 2** status tiles and a Pi-hole screen with queries, block rate and top blocked domains ([grafana-rack-dashboards](https://github.com/nashibbhattrai766-max/grafana-rack-dashboards)).

## 10. Verify it works

```bash
./test-dns.sh 10.0.0.2 10.0.0.20
# 10.0.0.2   resolve:93.184.215.14  block:0.0.0.0  dnssec-broken-domain:SERVFAIL (want SERVFAIL)
# 10.0.0.20  resolve:93.184.215.14  block:0.0.0.0  dnssec-broken-domain:SERVFAIL (want SERVFAIL)
```

| Test | Expected |
|---|---|
| Normal domain resolves on both | an IP address |
| Ad domain on both | `0.0.0.0` |
| `dnssec-failed.org` | `SERVFAIL` (bad signatures rejected) |
| **Failover:** stop the primary (`pct shutdown <id>`) and browse on a phone/PC | everything keeps working; queries appear in Pi-hole 2's log |
| Sync: add a test domain to the primary's deny list, wait for the next hour | it appears on the secondary |

## 11. Running it day to day

- **Change settings on the primary only.**
- **If you change the primary's web password**, update `nebula.env` too and run `docker compose up -d nebula-sync`, or syncing stops with HTTP 401.
- **Updates:** `pihole -up` on the primary; on the secondary, `docker compose pull && docker compose up -d`.
- Patch one server at a time. That's the whole point of having two.

## 12. Troubleshooting: when DNS "worked" but didn't

The most useful lesson in this build.

**Symptom:** the new secondary's Unbound returned **`SERVFAIL` for every domain**, while the primary seemed fine.

**What I tried first** (none of it was the problem): AppArmor fixes, re-downloading the DNSSEC root trust anchor (`unbound-anchor`), copying the primary's root key, debug logging.

**How it was found:** asking a root server directly *without recursion*:
```bash
dig +norec @127.0.0.1 -p 5335 . NS     # through Unbound
dig +norec @198.41.0.4 . NS            # straight to a.root-servers.net
```
A real root server answers with the flags **`qr aa`** (authoritative). Instead, the answers came back as **`qr ra`** from an unexpected address: something on the network was **intercepting every port-53 query** and answering it itself.

**Cause:** the router's *Content Filtering → Ad Block* feature transparently hijacks all DNS traffic leaving the LAN. A recursive resolver can't work behind that, and DNSSEC validation fails.

**The surprise:** running the same test on the "working" primary showed that it was intercepted too. It had only been answering from its **cache**, so it would have failed as soon as the cache expired.

**Fix:** turn off the router's DNS ad-block / content filter (Pi-hole does that job now). Straight after, `dig +norec` returned `qr aa` from the real root server on both hosts, and Unbound worked everywhere.

> **Lesson:** if a recursive resolver fails in weird ways, check whether your router or ISP is intercepting port 53 before debugging the resolver.

## 13. Other lessons

- **A public "fallback" DNS server lets Chrome bypass Pi-hole.** On a machine whose DNS list included `8.8.8.8`, Chrome quietly switched to **encrypted DNS to Google**, and ads appeared only on that machine. Give devices only your own DNS servers.
- **Pi-hole can't block ads served from the same domain as the content** (YouTube, some streaming sites). That needs a browser extension.
- **nebula-sync 401 errors** mean the password in `nebula.env` is wrong or empty. Check that the variable wasn't empty when you created the container in a new shell.
- **Unbound on the Proxmox kernel:** Debian's Unbound AppArmor profile blocked its control socket. Disabling that profile (`ln -s /etc/apparmor.d/usr.sbin.unbound /etc/apparmor.d/disable/ && apparmor_parser -R /etc/apparmor.d/usr.sbin.unbound`) and removing `remote-control.conf` fixed startup.

## Files in this repo

| File | Purpose |
|---|---|
| [`docker-compose.yml`](docker-compose.yml) | Secondary Pi-hole + nebula-sync |
| [`.env.example`](.env.example) / [`nebula.env.example`](nebula.env.example) | Settings templates (the real files are git-ignored) |
| [`unbound/pi-hole.conf`](unbound/pi-hole.conf) | Unbound recursive resolver config |
| [`test-dns.sh`](test-dns.sh) | Resolve / block / DNSSEC test for both servers |

## License

MIT

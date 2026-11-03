# OpenWrt + AdGuardHome + PassWall2 — conflict-free installer

One-shot script that wires **AdGuardHome** and **PassWall2** together on OpenWrt
so they stop fighting over DNS and ports, with a tested rollback path.

> **Settings only.** No proxy nodes are added. You still add and choose your
> nodes in LuCI → Services → PassWall2.

---

## Chain

```
LAN client ──▶ router:53              AdGuardHome (filter, cache, query log)
                   │
                   ▼
           127.0.0.1:15353            PassWall2 local DNS (CN-direct / foreign-proxy)
                   │
                   └─ .lan / .local / .home.arpa
                        └─▶ 127.0.0.1:54   dnsmasq (DHCP + local names)
```

dnsmasq hand-off note: OpenWrt keeps advertising the router address as the DNS
server, so clients always talk to `:53`. AdGuardHome binds `:53` (IPv4, plus
`::` when IPv6 is present) and forwards everything except local names to
PassWall2.

---

## Safety model

* Every file touched is backed up next to itself
  (`<file>.agh-pw.bak.<timestamp>`) and recorded in
  `/etc/agh-pw-backup/manifest.txt`, so `--uninstall` can restore it later.
* The new AdGuardHome YAML is validated with `AdGuardHome --check-config`
  **before** dnsmasq gives up port 53.
* If AdGuardHome does not answer on `:53` after the restart, the script rolls
  back automatically: original configs restored, dnsmasq restarted on `:53`.
* Re-running is idempotent: no duplicated YAML keys, no duplicate firewall
  rules, no duplicate cron entries.
* `--dry-run` shows every action and changes nothing.
* A 2-minute watchdog (cron) restarts AdGuardHome if it stops answering. It
  only restarts services — it never rewrites config, firewall, or ports.

---

## Requirements

* OpenWrt 23.05 / 24.10 or newer (opkg **or** apk), root access
* `adguardhome` from the packages feed (the script installs it if missing)
* PassWall2 core (`passwall2` / `luci-app-passwall2`) from a third-party feed —
  it is **not** in the official feeds. The script refuses to continue and prints
  the exact steps when it is missing.
* ≥ 20 MiB free on `/overlay` for a fresh AdGuardHome install

Feed for opkg-based releases:
<https://github.com/xiaorouji/openwrt-passwall-build>
(apk-based releases: the matching apk repository). Then:

```sh
opkg update && opkg install luci-app-passwall2
```

---

## Usage

On the router (SSH as root):

```sh
wget -O /tmp/agh-pw.sh https://raw.githubusercontent.com/Ace1337z/openwrt-agh-passwall2/main/install.sh
sh /tmp/agh-pw.sh --dry-run     # inspect, change nothing
sh /tmp/agh-pw.sh               # apply
```

Options:

| flag | effect |
|---|---|
| `--dry-run` | print planned actions, change nothing |
| `--uninstall` | stop AdGuardHome, restore every backed-up file, remove the firewall rule and watchdog |
| `-y`, `--yes` | no confirmation prompt for `--uninstall` |
| `--dnsmasq-forward` | additionally set `dhcp.@dnsmasq[0].server=127.0.0.1#15353` (persistent UCI, off by default; AdGuardHome already forwards) |
| `--no-watchdog` | do not install the health cron |

After it finishes:

1. Open `http://<router-ip>:3000` and **create the admin login immediately**
   (until you do, anyone on the LAN can claim the UI).
2. Add / choose proxy nodes in **LuCI → Services → PassWall2**.
3. Verify: `nslookup openwrt.org 127.0.0.1`.

### Tunables (environment)

| variable | default | meaning |
|---|---|---|
| `AGH_PORT` | `53` | AdGuardHome DNS port |
| `DNSMASQ_PORT` | `54` | dnsmasq port |
| `PW_DNS_PORT` | `15353` | PassWall2 local DNS port |
| `AGH_CACHE` | `16777216` | DNS cache bytes (16 MiB). The old 64 MiB default is a common OOM cause on 128–256 MB routers |
| `AGH_RATELIMIT` | `0` | per-client qps limit, `0` = unlimited |
| `AGH_FALLBACK` | *(empty)* | optional `fallback_dns`; empty means PassWall2 DNS is authoritative. Setting it makes AGH answer from plaintext DNS when PassWall2 DNS fails → **queries leak outside the tunnel** |
| `IPV6_ENABLE` | `auto` | bind `::` when `/proc/net/inet6` exists |
| `BOOT1`, `BOOT2` | `223.5.5.5`, `119.29.29.29` | bootstrap resolvers (plain IPv4, no IPv6) |

---

## What actually changes

1. **Packages** — installs `adguardhome`, tries `luci-app-adguardhome`, and
   refuses to continue if PassWall2 core is unavailable (instead of silently
   skipping half the setup).
2. **AdGuardHome config** — rewrites only the managed keys of the top-level
   `dns:` block; old list items (including the section-indented `- ::1` style
   AdGuardHome itself writes) are removed, so re-runs do not accumulate stale
   upstreams:
   * `upstream_dns`: `127.0.0.1:15353` (**UDP**; `tcp://` breaks with
     dns2socks-backed local DNS and churns conntrack entries), plus
     `/lan/`, `/local/`, `/home.arpa/` → `127.0.0.1:54`
   * `bootstrap_dns`: `223.5.5.5`, `119.29.29.29` (IPv4 only)
   * `cache_size`: 16 MiB, `cache_optimistic: true`
   * `ratelimit: 0` (a low limit makes bursts look like "DNS is down")
   * private PTR: `use_private_ptr_resolvers: true` with RFC1918/ULA networks
     pointed at dnsmasq, so reverse lookups stay local
   * SafeSearch/parental OFF, DNSSEC off (it breaks through split DNS)
   * if no config exists: writes a complete default, then patches it through
     the same path, so a fresh install and a later re-run are byte-identical
3. **dnsmasq** — `port=54`, `authoritative=1`; deletes the bogus
   `dns_redirect` option older versions of this script wrote; removes an old
   `/tmp/dnsmasq.d/dnsmasq-passwall2.conf` **only if** it carries this
   project's marker.
4. **PassWall2** — `dns_redirect=0`, `localhost_proxy=1`. `remote_dns` /
   protocol / detour are only set when empty — an existing DoH/DoT choice is
   never overwritten.
5. **Firewall** — one idempotent LAN-only rule (`Allow-AdGuardHome-LAN`,
   tcp+udp 53 and 3000). Protect the admin UI on interfaces where `wan` input
   is not dropped.
6. **Services** — restart order dnsmasq → passwall2 → adguardhome, then verify
   `:53`, `:54` and a real lookup; rollback if AdGuardHome is not listening.
7. **Watchdog** — `/usr/sbin/agh-pw-watchdog` via `/etc/crontabs/root`, every
   2 minutes, 5-minute cooldown, logs to `logread -t agh-pw-wd`.

---

## Verify

```sh
ss -lnup | grep -E ':53 |:54 |:15353 '   # listeners
uci get dhcp.@dnsmasq[0].port           # 54
uci get passwall2.@global[0].dns_redirect   # 0
nslookup openwrt.org 127.0.0.1          # through AGH -> PassWall2
nslookup openwrt.lan 127.0.0.1          # through AGH -> dnsmasq
logread -e AdGuardHome | tail
```

Full health report (read-only, safe to run when things are broken):

```sh
wget -O /tmp/diagnose.sh https://raw.githubusercontent.com/Ace1337z/openwrt-agh-passwall2/main/diagnose.sh
sh /tmp/diagnose.sh
```

It prints memory/OOM evidence, listeners, conntrack usage, effective UCI values,
the managed AGH keys, functional lookups, and a ranked verdict.

---

## "It works, then the internet dies while the node is still connected"

This is almost never the proxy itself. In order of likelihood:

1. **OOM kill.** AdGuardHome 64 MiB cache + querylog/statistics in `/var`
   (tmpfs) + Xray/Sing-Box on a 128–256 MB router. Check `dmesg | grep -i oom`.
   This installer uses a 16 MiB cache and `ratelimit: 0`; lower `AGH_CACHE`
   further on small devices.
2. **PassWall2 local DNS on `:15353` stopped.** dns2socks/chinadns-ng/Xray DNS
   is restarted by PassWall2 on node switch and watchdog events and can stay
   down. AdGuardHome has no second upstream by design (to avoid leaks), so DNS
   dies while the node list still shows "connected". Check
   `ss -lnu | grep 15353` and `logread | grep -i passwall`.
3. **conntrack table full.** DNS-through-proxy with `tcp://` upstream churns
   connections. Check `nf_conntrack_count` vs `nf_conntrack_max` in the report.
4. **Config drift after a PassWall2 upgrade** re-enables DNS hijack, or
   dnsmasq's port is reset to 53. The watchdog restarts services; re-run
   `install.sh` to re-apply settings.

---

## Uninstall / revert

```sh
sh /tmp/agh-pw.sh --uninstall        # asks for confirmation
sh /tmp/agh-pw.sh --uninstall --yes  # unattended
```

It restores the newest backup of every file the installer touched (from
`/etc/agh-pw-backup/manifest.txt`), removes the firewall rule, the watchdog and
its cron line, stops/disables AdGuardHome, and puts dnsmasq back on `:53`.

Manual equivalent:

```sh
ls /etc/agh-pw-backup
ls /etc/adguardhome/adguardhome.yaml.agh-pw.bak.*
cat /etc/agh-pw-backup/manifest.txt
```

Packages are **not** removed: `opkg remove adguardhome luci-app-adguardhome`.

---

## Known limitations

* **IPv6:** AdGuardHome binds `::` when the IPv6 stack is present, otherwise
  IPv6 clients (which get the router's link-local via RA) would have no
  resolver. If you disable IPv6 later, re-run the installer so the config
  matches, or AdGuardHome fails to bind.
* **No upstream redundancy by default.** Everything goes to PassWall2 DNS.
  `AGH_FALLBACK` trades leak-freedom for resilience; decide explicitly.
* **`/var/lib/adguardhome` is tmpfs** on OpenWrt: statistics and query log are
  lost on reboot and consume RAM. Persisting them means flash writes; the
  default keeps them ephemeral on purpose.
* **Third-party feed required** for PassWall2; package names/feeds change
  between releases, so feed errors are surfaced instead of swallowed.
* **Admin UI**: AdGuardHome serves `0.0.0.0:3000`; the LAN-only firewall rule is
  the protection. Complete the setup wizard right away.
* The watchdog only restarts services. It deliberately never rewrites
  config/ports, so a wrong config cannot be "fixed" into a worse one.

---

## Tested

* `shellcheck -s sh` clean; `busybox sh -n` clean
* install / re-run / dry-run / rollback-on-bad-config / uninstall / watchdog
  covered by the harness in `test/run_tests.sh` (fake uci/opkg/services, real
  YAML + duplicate-key validation)
* Router targets: ipq807x (`qualcommax`), x86_64 in QEMU before touching
  production hardware. Always keep serial/TFTP recovery available.

## License

MIT

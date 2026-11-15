# OpenWrt + AdGuardHome + PassWall2 — conflict-free installer

One-shot script that wires **AdGuardHome** and **PassWall2** together on OpenWrt
so they stop fighting over DNS and ports, with a tested rollback path.

> **Settings only.** No proxy nodes are added. You still add and choose your
> nodes in LuCI → Services → PassWall2.

---

## Chain

```
LAN client ──▶ router:53              AdGuardHome (filter, cache, query log)
router proc ──▶  (nftables redirect)        │
                                            ├─▶ Quad9 DoH      (dns10.quad9.net)
                                            ├─▶ Cloudflare DoH (cloudflare-dns.com)
                                            └─ .lan / .local
                                                 └─▶ 127.0.0.1:5335
                                                      dnsmasq (DHCP + local names)
```

AdGuardHome is the **only** resolver LAN clients and router processes use.
External names go out over **encrypted DNS (DoH)**, independent of PassWall2's
own DNS stack, so a PassWall2 node restart no longer kills resolution. Local
names are answered by dnsmasq, which is moved out of the way to `:5335`.

An nftables chain (`/etc/nftables.d/20-agh-dns-hijack.nft`) redirects every
plaintext DNS query from the LAN — and from router processes — to AdGuardHome on
`:53`. It is hooked at priority `-150`, i.e. **before** PassWall2's `PSW2_NAT`
(`dstnat - 1`) and fw4's `dstnat`, so a client with a hard-coded resolver
(`8.8.8.8`, ISP DNS) never bypasses filtering. AdGuardHome's own UID is exempted
in the output chain: it has to reach the DoH bootstrap resolvers directly, or it
would query itself and return `SERVFAIL`.

Hand-off note: OpenWrt keeps advertising the router address as the DNS server, so
clients always talk to `:53`. AdGuardHome binds `:53` (LAN IPv4 + `127.0.0.1`,
or `0.0.0.0` + `::` when IPv6 is enabled). With `IPV6_ENABLE=0` the web UI is
pinned to `<lan-ip>:3000` for the same reason: AdGuardHome turns a plain
`0.0.0.0` into a dual-stack `[::]` socket.

---

## Safety model

* Every file touched is backed up next to itself
  (`<file>.agh-pw.bak.<timestamp>`) and recorded in
  `/etc/agh-pw-backup/manifest.txt`, so `--uninstall` can restore it later.
* The new AdGuardHome YAML is validated with `AdGuardHome --check-config`
  **before** dnsmasq gives up port 53.
* If AdGuardHome does not answer on `:53` after the restart, the script rolls
  back automatically: original configs restored, the nft chain removed,
  dnsmasq restarted on `:53`.
* Re-running is idempotent: no duplicated YAML keys, no duplicate firewall
  rules, no duplicate cron entries, no duplicated nft file.
* An existing `20-agh-dns-hijack.nft` that was **not** written by this installer
  is never overwritten — the run stops with an error instead.
* `--dry-run` shows every action and changes nothing.
* A 2-minute watchdog (cron) restarts AdGuardHome if it stops answering. It
  only restarts services — it never rewrites config, firewall, or ports.

---

## Requirements

* OpenWrt 23.05 / 24.10 or newer (opkg **or** apk), root access, `nft` (fw4)
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
| `--uninstall` | stop AdGuardHome, restore every backed-up file, remove the nft chain, the firewall rule and the watchdog |
| `-y`, `--yes` | no confirmation prompt for `--uninstall` |
| `--no-dns-hijack` | do not install/replace the nftables DNS redirect chain |
| `--no-watchdog` | do not install the health cron |

After it finishes:

1. Open `http://<router-ip>:3000` and **create the admin login immediately**
   (until you do, anyone on the LAN can claim the UI).
2. Add / choose proxy nodes in **LuCI → Services → PassWall2**. Not required for
   DNS: AdGuardHome resolves over its own DoH upstreams.
3. Verify: `nslookup openwrt.org 127.0.0.1` and
   `nslookup openwrt.lan 127.0.0.1`.

### Tunables (environment)

| variable | default | meaning |
|---|---|---|
| `AGH_PORT` | `53` | AdGuardHome DNS port |
| `DNSMASQ_PORT` | `5335` | dnsmasq port (must differ from `AGH_PORT`) |
| `AGH_UPSTREAM1` | `https://dns10.quad9.net/dns-query` | primary DoH upstream |
| `AGH_UPSTREAM2` | `https://cloudflare-dns.com/dns-query` | second DoH upstream |
| `BOOT1`, `BOOT2`, `BOOT3` | `9.9.9.10`, `149.112.112.10`, `1.1.1.1` | bootstrap resolvers for DoH hostname lookup only |
| `AGH_CACHE` | `4194304` | DNS cache bytes (4 MiB) |
| `AGH_RATELIMIT` | `0` | per-client qps limit, `0` = unlimited |
| `AGH_DISABLE_AAAA` | `true` | drop AAAA answers |
| `AGH_DNSSEC` | `true` | validate DNSSEC at AdGuardHome |
| `AGH_FALLBACK` | *(empty)* | optional `fallback_dns`; empty means DoH only. Setting it makes AGH answer from plaintext DNS when both DoH upstreams fail → **queries leave the encrypted path** |
| `IPV6_ENABLE` | `auto` | bind `::` when the IPv6 stack exists |
| `DNS_HIJACK` | `1` | install the nftables redirect chain |
| `HIJACK_NFT` | `/etc/nftables.d/20-agh-dns-hijack.nft` | path of the redirect chain file |
| `AGH_UID`, `LAN_IF` | autodetected | AdGuardHome UID and LAN bridge used by the redirect chain |

---

## What actually changes

1. **Packages** — installs `adguardhome`, tries `luci-app-adguardhome`, and
   refuses to continue if PassWall2 core is unavailable (instead of silently
   skipping half the setup).
2. **AdGuardHome config** — rewrites only the managed keys of the top-level
   `dns:` block; old list items (including the section-indented `- ::1` style
   AdGuardHome itself writes) are removed, so re-runs do not accumulate stale
   upstreams:
   * `upstream_dns`: Quad9 DoH, Cloudflare DoH, and `/lan/`, `/local/` →
     `127.0.0.1:5335`
   * `bootstrap_dns`: `9.9.9.10`, `149.112.112.10`, `1.1.1.1` (used only to
     resolve the DoH hostnames)
   * `cache_size`: 4 MiB, `cache_optimistic: false`
   * `ratelimit: 0` (a low limit makes bursts look like "DNS is down")
   * `aaaa_disabled: true`, `enable_dnssec: true`
   * private PTR: `use_private_ptr_resolvers: true`, `private_networks: []`,
     `local_ptr_upstreams` → dnsmasq
   * SafeSearch/parental OFF
   * if no config exists: writes a complete default, then patches it through
     the same path, so a fresh install and a later re-run are byte-identical
3. **dnsmasq** — `port=5335`, `authoritative=1`; deletes the invalid
   `dns_redirect` option older versions of this script wrote.
4. **PassWall2** — `dns_redirect=0`, `localhost_proxy=1`. PassWall2's own DNS
   stack is left untouched: AdGuardHome does not depend on it.
5. **nftables redirect** — writes `20-agh-dns-hijack.nft` (prerouting + output
   chains, priority `-150`) so LAN and router plaintext DNS land on `:53`.
6. **Firewall** — one idempotent rule `Block-LAN-DNS-Bypass-5335` refuses
   LAN → dnsmasq `:5335`, so clients cannot skip AdGuardHome's filtering.
7. **Services** — restart order dnsmasq → passwall2 → adguardhome, then reload
   the firewall (to load the nft chain) and verify `:53`, `:5335` and a real
   lookup; rollback if AdGuardHome is not listening.
8. **Watchdog** — `/usr/sbin/agh-pw-watchdog` via `/etc/crontabs/root`, every
   2 minutes, 5-minute cooldown, logs to `logread -t agh-pw-wd`.

---

## Verify

```sh
ss -lnup | grep -E ':53 |:5335 '              # listeners
nft list chain inet fw4 agh_dns_hijack        # redirect rule
uci get dhcp.@dnsmasq[0].port                 # 5335
uci get passwall2.@global[0].dns_redirect     # 0
nslookup openwrt.org 127.0.0.1                # through AGH -> DoH
nslookup openwrt.lan 127.0.0.1                # through AGH -> dnsmasq
logread -e AdGuardHome | tail
```

Full health report (read-only, safe to run when things are broken):

```sh
wget -O /tmp/diagnose.sh https://raw.githubusercontent.com/Ace1337z/openwrt-agh-passwall2/main/diagnose.sh
sh /tmp/diagnose.sh
```

It prints memory/OOM evidence, listeners, conntrack usage, effective UCI values,
the managed AGH keys, the nft chain state, functional lookups, and a ranked
verdict.

---

## "It works, then DNS stops answering"

In order of likelihood:

1. **dnsmasq moved off `:5335`** (config drift, PassWall2 upgrade). Local names
   and DHCP break, and AdGuardHome's `/lan/` upstream points at nothing. Re-run
   `install.sh`; the report shows the effective port.
2. **AdGuardHome stopped or lost `:53`** — OOM kill, config drift, or another
   resolver grabbing the port. Check `dmesg | grep -i oom` and
   `logread -e AdGuardHome`. The watchdog restarts the service every 2 minutes.
3. **nft chains gone after a firewall reload** — LAN clients then bypass
   AdGuardHome with their own resolver. `nft list chain inet fw4
   agh_dns_hijack` shows whether they are loaded; re-run `install.sh` to rewrite
   the file and reload the firewall.
4. **Both DoH upstreams unreachable** — bootstrap DNS is only resolved through
   `BOOT1..3`; if a proxy rule swallows port 53 for those addresses, DoH cannot
   start. Check `logread -e AdGuardHome | grep -i upstream`.
5. **OOM kill in general.** AdGuardHome cache + querylog/statistics in `/var`
   (tmpfs) + Xray/Sing-Box on a 128–256 MB router. This installer uses a 4 MiB
   cache and `ratelimit: 0`; lower `AGH_CACHE` further on small devices.

Deliberately **not** installed: no DoT/DoH blocking of LAN clients and no
`fallback_dns`. Clients that speak DoH to a third party are not stopped by this
script; add a forwarding rule if you need that.

---

## Uninstall / revert

```sh
sh /tmp/agh-pw.sh --uninstall        # asks for confirmation
sh /tmp/agh-pw.sh --uninstall --yes  # unattended
```

It restores the newest backup of every file the installer touched (from
`/etc/agh-pw-backup/manifest.txt`), removes the nft chain file (only if it
carries this project's marker), the firewall rule, the watchdog and its cron
line, stops/disables AdGuardHome, and puts dnsmasq back on `:53`.

Manual equivalent:

```sh
ls /etc/agh-pw-backup
ls /etc/adguardhome/adguardhome.yaml.agh-pw.bak.*
cat /etc/agh-pw-backup/manifest.txt
```

Packages are **not** removed: `opkg remove adguardhome luci-app-adguardhome`.

---

## Known limitations

* **IPv6:** AdGuardHome binds `::` (DNS and web UI) when the IPv6 stack is
  present, otherwise IPv6 clients (which get the router's link-local via RA)
  would have no resolver. If you disable IPv6 later, re-run the installer so the
  config matches, or AdGuardHome fails to bind.
* **DoH only.** If both DoH endpoints are blocked on the ISP path, resolution
  stops. `AGH_FALLBACK` trades encryption for resilience; decide explicitly.
* **`/var/lib/adguardhome` is tmpfs** on OpenWrt: statistics and query log are
  lost on reboot and consume RAM. Persisting them means flash writes; the
  default keeps them ephemeral on purpose.
* **`--no-dns-hijack`** leaves clients free to use their own resolver (and to
  reach dnsmasq directly unless the firewall rule is present). Only useful if
  you already redirect DNS some other way.
* **Third-party feed required** for PassWall2; package names/feeds change
  between releases, so feed errors are surfaced instead of swallowed.
* **Admin UI**: with IPv6 disabled AdGuardHome serves the UI on the LAN IPv4 only
  (e.g. `192.168.1.1:3000`), not on `127.0.0.1`, so a local `curl` from the
  router must use the LAN address. The first-run admin user is created through
  AdGuardHome's own install API; the generated password is written to
  `/etc/agh-pw-backup/agh-admin.txt` (0600).
* The watchdog only restarts services. It deliberately never rewrites
  config/ports, so a wrong config cannot be "fixed" into a worse one.

---

## Tested

* `sh -n` / `busybox sh -n` / `bash -n` clean
* install / re-run / dry-run / rollback-on-bad-config / uninstall / watchdog /
  `--no-dns-hijack` / unmanaged-nft-file refusal covered by the harness in
  `test/run_tests.sh` (fake uci/opkg/services, real YAML + duplicate-key
  validation)
* Router targets: ipq807x (`qualcommax`), x86_64 in QEMU before touching
  production hardware. Always keep serial/TFTP recovery available.

## License

MIT

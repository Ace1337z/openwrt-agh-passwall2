# OpenWrt + AdGuardHome + PassWall2 — conflict-free installer

One-shot script that installs and wires **AdGuardHome** together with **PassWall2**
on OpenWrt so they never fight over DNS/ports — no more "problem detected" from
DNS hijack conflicts, and no `www.google.com -> forcesafesearch` surprises.

> **Settings only.** This script does **not** add any proxy nodes. You still add
> and choose your nodes in LuCI → Services → PassWall2.

---

## What it sets up

```
LAN client ──▶ router:53  (AdGuardHome: ad-block / filtering)
                    │
                    ▼
            PassWall2 DNS  127.0.0.1:15353   (China-direct / foreign-proxy split)
                    │
                    └─ .lan / .local / .home.arpa ──▶ dnsmasq 127.0.0.1:54
```

### Concrete changes

1. Installs (if missing): `adguardhome`, `luci-app-adguardhome`, `luci-app-passwall2`
2. Moves **dnsmasq → port 54** so AdGuardHome can own **port 53**
3. Configures AdGuardHome:
   - upstream → `tcp://127.0.0.1:15353` (PassWall2's DNS)
   - `.lan` / `.local` / `.home.arpa` → `127.0.0.1:54` (dnsmasq)
   - bootstrap / fallback → reachable IPv4 resolvers (no IPv6)
   - **SafeSearch / parental OFF** (prevents google→forcesafesearch)
   - if no config exists yet, writes a complete sane default (validated against AdGuardHome 0.107.x)
4. Configures PassWall2:
   - `dns_redirect = 0` (do **not** hijack port 53)
   - `localhost_proxy = 1` (keep local DNS/proxy on loopback for AdGuard)
   - ⚠️ Does **not** touch `dnsmasq_dns_redirect` (PassWall manages it internally)
5. Adds a dnsmasq drop-in forwarding `dnsmasq → 127.0.0.1#15353`
6. Enables + restarts services in order: dnsmasq → passwall2 → adguardhome

Existing configs are backed up to `*.agh-pw.bak.<timestamp>`. Re-running is safe
(idempotent — it replaces the managed DNS block, never duplicates it).

---

## Usage

On the router (SSH as root):

```sh
wget -O - https://raw.githubusercontent.com/Ace1337z/openwrt-agh-passwall2/main/install.sh | sh
```

or download and inspect first:

```sh
wget -O install.sh https://raw.githubusercontent.com/Ace1337z/openwrt-agh-passwall2/main/install.sh
sh install.sh
```

After it finishes:

1. Open **http://<router-ip>:3000** and complete the AdGuardHome first-run wizard
   (create admin user/password). It then serves DNS on port 53.
2. Add / choose your proxy nodes in **LuCI → Services → PassWall2**.

---

## Requirements

- OpenWrt 23.05+ / 24.10+ (tested on 25.12, `qualcommax/ipq807x`), `opkg` or `apk`
- `luci-app-passwall2` (PassWall2 core) — if not installed via the script, install it first
- Root access

## Verify

```sh
# AdGuardHome should listen on :53
netstat -ln | grep ':53'

# dnsmasq moved to :54
uci get dhcp.@dnsmasq[0].port        # -> 54

# PassWall2 no longer hijacks DNS
uci get passwall2.@global[0].dns_redirect   # -> 0

# resolution works through the chain
nslookup www.google.com 127.0.0.1
```

## Uninstall / revert

Backups are kept next to each file:

```sh
ls /etc/adguardhome/adguardhome.yaml.agh-pw.bak.*
ls /etc/config/{dhcp,passwall2,adguardhome}.agh-pw.bak.*
rm -f /tmp/dnsmasq.d/dnsmasq-passwall2.conf
```

Then restore the desired backup, and set dnsmasq back to port 53 if you remove AdGuardHome:

```sh
uci set dhcp.@dnsmasq[0].port='53'; uci commit dhcp; /etc/init.d/dnsmasq restart
```

## Notes / known caveats

- PassWall2's own DNS (`127.0.0.1:15353`) occasionally logs `i/o timeout` for
  unsupported record types (e.g. `HTTPS`/SVCB) — harmless; clients fall back to A/AAAA.
- If you have no IPv6 upstream, IPv6 bootstrap servers are intentionally not used.
- This only manages DNS/settings; routing, firewall, and nodes are left to PassWall2.

## License

MIT

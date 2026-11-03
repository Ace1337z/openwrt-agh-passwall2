#!/bin/bash
# Test harness for install.sh: fake uci/opkg/services, real YAML validation.
set -u
SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)/install.sh}"
T="${T:-${TMPDIR:-/tmp}/agh-pw-test}"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [$2]"; fi; }

mocks() {
    mkdir -p "$T/bin" "$T/init.d"
    cat > "$T/bin/uci" <<'EOS'
#!/usr/bin/env python3
import os, sys, re
db = os.environ["UCI_DB"]
args = sys.argv[1:]
if args and args[0] == "-q":
    args = args[1:]
def path(p): return os.path.join(db, p)
def read(p):
    d = {}
    fp = path(p)
    if os.path.exists(fp):
        for line in open(fp):
            line = line.rstrip("\n")
            if line and "=" in line:
                k, v = line.split("=", 1); d[k] = v
    return d
def write(p, d):
    os.makedirs(db, exist_ok=True)
    with open(path(p), "w") as f:
        for k, v in d.items(): f.write("%s=%s\n" % (k, v))
def split(k):
    return k.split(".", 1) if "." in k else (k, "")
if not args: sys.exit(1)
c = args[0]
if c == "get":
    pkg, rest = split(args[1]); d = read(pkg)
    if rest in d: print(d[rest])
    else: sys.exit(1)
elif c == "set":
    k, v = args[1].split("=", 1); pkg, rest = split(k)
    if not rest: sys.exit(1)
    d = read(pkg); d[rest] = v; write(pkg, d)
elif c == "add_list":
    k, v = args[1].split("=", 1); pkg, rest = split(k)
    d = read(pkg); old = d.get(rest, "").strip()
    d[rest] = (old + " " + v).strip() if old else v; write(pkg, d)
elif c == "del_list":
    k, v = args[1].split("=", 1); pkg, rest = split(k)
    d = read(pkg); d[rest] = " ".join(x for x in d.get(rest, "").split() if x != v)
    write(pkg, d)
elif c == "delete":
    pkg, rest = split(args[1]); d = read(pkg)
    if rest in d: del d[rest]
    else:
        for kk in [x for x in d if x.startswith(rest + ".")]: del d[kk]
    write(pkg, d)
elif c == "show":
    if len(args) > 1:
        for k, v in read(args[1]).items(): print("%s.%s='%s'" % (args[1], k, v))
    else:
        for f in sorted(os.listdir(db)):
            for k, v in read(f).items(): print("%s.%s='%s'" % (f, k, v))
elif c == "commit":
    pass
elif c == "add":
    pkg = args[1]; d = read(pkg)
    n = len([k for k in d if re.match(r"^cfg\d+$", k)]) + 1
    sec = "cfg%04d" % n
    d[sec] = args[2] if len(args) > 2 else "section"; write(pkg, d); print(sec)
else:
    sys.exit(1)
EOS
    cat > "$T/bin/opkg" <<'EOS'
#!/bin/sh
case "$1" in
  list-installed) while read -r p; do [ -n "$p" ] && echo "$p - 1.0"; done < "$PKG_DB" ;;
  update) exit 0 ;;
  install)
    if [ -f "${PKG_FAIL:-/nonexistent}" ] && grep -qx "$2" "$PKG_FAIL"; then exit 1; fi
    grep -qx "$2" "$PKG_DB" || echo "$2" >> "$PKG_DB" ;;
  *) exit 0 ;;
esac
EOS
    cat > "$T/bin/ss" <<'EOS'
#!/bin/sh
[ -f "$SS_FILE" ] && cat "$SS_FILE"
exit 0
EOS
    cat > "$T/bin/pidof" <<'EOS'
#!/bin/sh
case "$1" in
  AdGuardHome) [ -f "$AGH_UP" ] && { echo 100; exit 0; } ;;
  dnsmasq)     [ -f "$DNSMASQ_UP" ] && { echo 200; exit 0; } ;;
esac
exit 1
EOS
    cat > "$T/bin/nslookup" <<'EOS'
#!/bin/sh
[ "${NS_OK:-0}" = 1 ] && exit 0
exit 1
EOS
    cat > "$T/bin/logread" <<'EOS'
#!/bin/sh
cat "${LOGREAD_FILE:-/dev/null}" 2>/dev/null
EOS
    cat > "$T/bin/AdGuardHome" <<'EOS'
#!/bin/sh
cfg=""; check=0; prev=""
for a in "$@"; do
  [ "$prev" = "--config" ] && cfg="$a"
  [ "$a" = "--check-config" ] && check=1
  prev="$a"
done
[ "$check" = 1 ] || exit 0
[ -n "$cfg" ] && [ -f "$cfg" ] || exit 1
[ "${AGH_CHECK_FAIL:-0}" = 1 ] && exit 1
grep -q BROKEN "$cfg" && exit 1
python3 - "$cfg" <<'PY'
import sys, yaml
class L(yaml.SafeLoader): pass
def cm(loader, node, deep=False):
    seen = []
    for k, _ in node.value:
        kk = loader.construct_object(k, deep=deep)
        if kk in seen: raise yaml.YAMLError("duplicate key %r" % (kk,))
        seen.append(kk)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)
L.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, cm)
d = yaml.load(open(sys.argv[1]), Loader=L)
assert isinstance(d, dict), "root not a mapping"
dns = d.get("dns") or {}
assert isinstance(dns.get("port"), int), "dns.port not int"
bh = dns.get("bind_hosts"); assert isinstance(bh, list) and bh, "dns.bind_hosts empty"
assert len(bh) == len(set(bh)), "duplicate bind_hosts entries"
up = dns.get("upstream_dns"); assert isinstance(up, list) and up, "upstream_dns empty"
assert len(up) == len(set(up)), "duplicate upstream_dns entries"
assert dns.get("port") == 53, "dns.port != 53"
assert any("127.0.0.1:15353" in u for u in up), "no PassWall2 upstream"
PY
EOS
    for n in dnsmasq passwall2 adguardhome; do :; done
    cat > "$T/init.d/dnsmasq" <<'EOS'
#!/bin/sh
echo "dnsmasq $1" >> "$SERVICE_LOG"
port=$(uci -q get dhcp.@dnsmasq[0].port); [ -n "$port" ] || port=53
touch "$SS_FILE"
grep -v ':53$' "$SS_FILE" > "$SS_FILE.t" 2>/dev/null || true
mv "$SS_FILE.t" "$SS_FILE" 2>/dev/null || true
printf 'udp UNCONN 0 0 0.0.0.0:%s 0.0.0.0:*\n' "$port" >> "$SS_FILE"
touch "$DNSMASQ_UP"
EOS
    cat > "$T/init.d/adguardhome" <<'EOS'
#!/bin/sh
echo "adguardhome $1" >> "$SERVICE_LOG"
case "$1" in
  start|restart)
     touch "$AGH_UP"; touch "$SS_FILE"
     grep -v ':53$' "$SS_FILE" > "$SS_FILE.t" 2>/dev/null || true
     mv "$SS_FILE.t" "$SS_FILE" 2>/dev/null || true
     printf 'udp UNCONN 0 0 0.0.0.0:53 0.0.0.0:*\nudp UNCONN 0 0 [::]:53 [::]:*\n' >> "$SS_FILE" ;;
  stop)
     rm -f "$AGH_UP"; touch "$SS_FILE"
     grep -v ':53$' "$SS_FILE" > "$SS_FILE.t" 2>/dev/null || true
     mv "$SS_FILE.t" "$SS_FILE" 2>/dev/null || true ;;
esac
EOS
    cat > "$T/init.d/passwall2" <<'EOS'
#!/bin/sh
echo "passwall2 $1" >> "$SERVICE_LOG"
EOS
    chmod +x "$T/bin/"* "$T/init.d/"*
}

setup() {
    rm -rf "$T/root" "$T/run"; mkdir -p "$T/root/etc/config" "$T/root/etc/adguardhome" "$T/root/var/lib/adguardhome" "$T/run"
    : > "$T/run/pkg.db"; printf 'adguardhome\npasswall2\nluci-app-passwall2\nluci-app-adguardhome\n' > "$T/run/pkg.db"; : > "$T/run/pkg.fail"
    : > "$T/run/services.log"; : > "$T/run/ss"; : > "$T/run/agh.yaml"
    cat > "$T/root/etc/config/dhcp" <<'EOS'
@dnsmasq[0].domainneeded=1
@dnsmasq[0].localise_queries=1
@dnsmasq[0].local=/lan/
@dnsmasq[0].domain=lan
@dnsmasq[0].authoritative=0
@dnsmasq[0].port=53
EOS
    cat > "$T/root/etc/config/passwall2" <<'EOS'
@global[0].dns_redirect=1
@global[0].localhost_proxy=0
EOS
    cat > "$T/root/etc/config/firewall" <<'EOS'
@defaults[0].input=ACCEPT
cfg0001.name=Allow-DHCP-Renew
cfg0001.target=ACCEPT
EOS
    : > "$T/root/etc/config/adguardhome"
}

envrun() {
    UCI_DB="$T/root/etc/config" PKG_DB="$T/run/pkg.db" \
    SS_FILE="$T/run/ss" SERVICE_LOG="$T/run/services.log" \
    AGH_UP="$T/run/agh.up" DNSMASQ_UP="$T/run/dnsmasq.up" \
    AGH_BIN="$T/bin/AdGuardHome" \
    AGH_DIR="$T/root/etc/adguardhome" AGH_YAML="$T/root/etc/adguardhome/adguardhome.yaml" \
    AGH_UCI="$T/root/etc/config/adguardhome" DHCP_CFG="$T/root/etc/config/dhcp" \
    PW_CFG="$T/root/etc/config/passwall2" FW_CFG="$T/root/etc/config/firewall" \
    INIT_D="$T/init.d" AGH_WORKDIR="$T/root/var/lib/adguardhome" \
    STATE_DIR="$T/root/etc/agh-pw-backup" OVERLAY="$T/root" \
    WD_BIN="$T/root/usr/sbin/agh-pw-watchdog" CRON_FILE="$T/root/etc/crontabs/root" \
    AGH_PW_INITD="$T/init.d" \
    AGH_PW_SKIP_ROOT=1 AGH_PW_WAIT=2 PKG_FAIL="$T/run/pkg.fail" PATH="$T/bin:$PATH" \
    sh "$SRC" "$@"
}

legacy_yaml() {
    cat > "$1" <<'EOS'
http:
  address: 0.0.0.0:3000
  session_ttl: 30d
users: []
auth_attempts: 5
dns:
  bind_hosts:
  - 0.0.0.0
  - ::1
  port: 53
  upstream_dns:
  - tcp://1.1.1.1
  - https://dns.example/dns-query
  upstream_dns_file: ''
  bootstrap_dns:
  - 2001:4860:4860::8888
  - 8.8.8.8
  fallback_dns:
  - 2606:4700:4700::1111
  cache_size: 4194304
  cache_enabled: true
  enable_dnssec: true
  use_private_ptr_resolvers: false
  private_networks: []
  local_ptr_upstreams: []
filters: []
schema_version: 34
EOS
}

mocks
echo "== T1 fresh install"
setup
envrun > "$T/run/t1.log" 2>&1; rc=$?
check "rc=0" "[ $rc -eq 0 ]"
check "yaml created" "[ -s $T/root/etc/adguardhome/adguardhome.yaml ]"
check "dnsmasq port 54" '[ "$(UCI_DB=$T/root/etc/config python3 $T/bin/uci -q get dhcp.@dnsmasq[0].port)" = 54 ]'
check "passwall dns_redirect=0" '[ "$(UCI_DB=$T/root/etc/config python3 $T/bin/uci -q get passwall2.@global[0].dns_redirect)" = 0 ]'
check "firewall rule added" 'UCI_DB=$T/root/etc/config python3 $T/bin/uci -q show firewall | grep -q "Allow-AdGuardHome-LAN"'
check "manifest written" "[ -s $T/root/etc/agh-pw-backup/manifest.txt ]"
check "dnsmasq restarted before adguardhome" 'awk "/dnsmasq restart/{d=NR} /adguardhome restart/{a=NR} END{exit !(d<a)}" "$T/run/services.log"'
check "no ipv6 fallback leak" '! grep -q "2606:4700" "$T/root/etc/adguardhome/adguardhome.yaml"'
check "no fallback_dns by default" '! grep -q "fallback_dns" "$T/root/etc/adguardhome/adguardhome.yaml"'
check "private ptr on" 'grep -q "use_private_ptr_resolvers: true" "$T/root/etc/adguardhome/adguardhome.yaml"'
check "cache 16MiB" 'grep -q "cache_size: 16777216" "$T/root/etc/adguardhome/adguardhome.yaml"'

echo "== T2 re-run idempotent"
cp "$T/root/etc/adguardhome/adguardhome.yaml" "$T/run/yaml.after1"
envrun > "$T/run/t2.log" 2>&1; rc=$?
check "rc=0" "[ $rc -eq 0 ]"
check "yaml unchanged" "cmp -s $T/run/yaml.after1 $T/root/etc/adguardhome/adguardhome.yaml"
check "single bind_hosts key" '[ "$(grep -c "^  bind_hosts:" $T/root/etc/adguardhome/adguardhome.yaml)" = 1 ]'
check "single port key in dns" '[ "$(grep -c "^  port: 53$" $T/root/etc/adguardhome/adguardhome.yaml)" = 1 ]'
check "single firewall rule" '[ "$(UCI_DB=$T/root/etc/config python3 $T/bin/uci -q show firewall | grep -c "Allow-AdGuardHome-LAN")" = 1 ]'
check "no dnsmasq server list" '! UCI_DB=$T/root/etc/config python3 $T/bin/uci -q get dhcp.@dnsmasq[0].server >/dev/null 2>&1'

echo "== T3 legacy yaml patch"
setup
legacy_yaml "$T/root/etc/adguardhome/adguardhome.yaml"
cp "$T/root/etc/adguardhome/adguardhome.yaml" "$T/run/yaml.legacy"
envrun > "$T/run/t3.log" 2>&1; rc=$?
check "rc=0" "[ $rc -eq 0 ]"
y="$T/root/etc/adguardhome/adguardhome.yaml"
check "no stale ::1 bind" '! grep -q "^  - ::1$" "$y"'
check "no stale IPv6 bootstrap" '! grep -q "2001:4860" "$y"'
check "old doh upstream gone" '! grep -q "https://dns.example" "$y"'
check "single upstream_dns key" '[ "$(grep -c "^  upstream_dns:" "$y")" = 1 ]'
check "single [/lan/] entry" '[ "$(grep -c "\[/lan/\]" "$y")" = 1 ]'
check "dnssec preserved" 'grep -q "enable_dnssec: true" "$y"'
check "filters section preserved" 'grep -q "^filters: \[\]" "$y"'
check "backup of legacy yaml kept" 'ls $T/root/etc/adguardhome/*.agh-pw.bak.* >/dev/null 2>&1'
check "backup identical to original" 'cmp -s $(ls -1 $T/root/etc/adguardhome/*.agh-pw.bak.* | head -1) $T/run/yaml.legacy'

echo "== T4 IPv6 disabled"
setup
IPV6_ENABLE=0 envrun > "$T/run/t4.log" 2>&1; rc=$?
check "rc=0" "[ $rc -eq 0 ]"
check "no :: bind" '! grep -q "^  - ::$" $T/root/etc/adguardhome/adguardhome.yaml'

echo "== T5 failed config -> rollback"
setup
legacy_yaml "$T/root/etc/adguardhome/adguardhome.yaml"
cp "$T/root/etc/adguardhome/adguardhome.yaml" "$T/run/yaml.pre"
cp "$T/root/etc/config/dhcp" "$T/run/dhcp.pre"
AGH_CHECK_FAIL=1 envrun > "$T/run/t5.log" 2>&1; rc=$?
check "non-zero exit" "[ $rc -ne 0 ]"
check "rollback logged" 'grep -q "rolling back" "$T/run/t5.log"'
check "yaml restored" "cmp -s $T/run/yaml.pre $T/root/etc/adguardhome/adguardhome.yaml"
check "dnsmasq back to 53" '[ "$(UCI_DB=$T/root/etc/config python3 $T/bin/uci -q get dhcp.@dnsmasq[0].port)" = 53 ]'
check "dhcp config restored" "cmp -s $T/run/dhcp.pre $T/root/etc/config/dhcp"
check "adguardhome not left enabled" "[ ! -f $T/run/agh.up ]"
check "dnsmasq restarted on rollback" '[ "$(grep -c "dnsmasq restart" "$T/run/services.log")" -ge 1 ]'

echo "== T6 uninstall restores"
setup
legacy_yaml "$T/root/etc/adguardhome/adguardhome.yaml"
cp "$T/root/etc/adguardhome/adguardhome.yaml" "$T/run/yaml.orig"
cp "$T/root/etc/config/dhcp" "$T/run/dhcp.orig"
cp "$T/root/etc/config/passwall2" "$T/run/pw.orig"
envrun >/dev/null 2>&1
envrun --uninstall --yes > "$T/run/t6.log" 2>&1; rc=$?
check "rc=0" "[ $rc -eq 0 ]"
check "yaml restored" "cmp -s $T/run/yaml.orig $T/root/etc/adguardhome/adguardhome.yaml"
check "dnsmasq restored to 53" "cmp -s $T/run/dhcp.orig $T/root/etc/config/dhcp"
check "passwall restored" "cmp -s $T/run/pw.orig $T/root/etc/config/passwall2"
check "firewall rule removed" '! UCI_DB=$T/root/etc/config python3 $T/bin/uci -q show firewall | grep -q "Allow-AdGuardHome-LAN"'
check "agh stopped" "[ ! -f $T/run/agh.up ]"
check "uninstall without --yes refuses" 'envrun --uninstall >/dev/null 2>&1 </dev/null; [ $? -eq 1 ]'

echo "== T7 dry run changes nothing"
setup
legacy_yaml "$T/root/etc/adguardhome/adguardhome.yaml"
cp "$T/root/etc/adguardhome/adguardhome.yaml" "$T/run/yaml.pre"
cp "$T/root/etc/config/dhcp" "$T/run/dhcp.pre"
cp "$T/root/etc/config/firewall" "$T/run/fw.pre"
envrun --dry-run > "$T/run/t7.log" 2>&1; rc=$?
check "rc=0" "[ $rc -eq 0 ]"
check "yaml untouched" "cmp -s $T/run/yaml.pre $T/root/etc/adguardhome/adguardhome.yaml"
check "dhcp untouched" "cmp -s $T/run/dhcp.pre $T/root/etc/config/dhcp"
check "firewall untouched" "cmp -s $T/run/fw.pre $T/root/etc/config/firewall"
check "no manifest" "[ ! -s $T/root/etc/agh-pw-backup/manifest.txt ]"
check "dry-run summary" 'grep -q "dry-run" "$T/run/t7.log"'

echo "== T8 foreign :53 listener refused"
setup
printf 'udp UNCONN 0 0 127.0.0.1:53 0.0.0.0:*\n' > "$T/run/ss"
cp "$T/root/etc/config/dhcp" "$T/run/dhcp.pre"
envrun > "$T/run/t8.log" 2>&1; rc=$?
check "non-zero exit" "[ $rc -ne 0 ]"
check "refused with message" 'grep -q "free port 53 first" "$T/run/t8.log"'
check "nothing changed" "cmp -s $T/run/dhcp.pre $T/root/etc/config/dhcp"

echo "== T9 --dnsmasq-forward persistent + no dup"
setup
envrun --dnsmasq-forward >/dev/null 2>&1
envrun --dnsmasq-forward >/dev/null 2>&1
check "one server entry" '[ "$(UCI_DB=$T/root/etc/config python3 $T/bin/uci -q get dhcp.@dnsmasq[0].server)" = "127.0.0.1#15353" ]'
check "allservers set" '[ "$(UCI_DB=$T/root/etc/config python3 $T/bin/uci -q get dhcp.@dnsmasq[0].allservers)" = 1 ]'
check "no /tmp drop-in written" '[ ! -f /tmp/dnsmasq.d/dnsmasq-passwall2.conf ] || ! grep -q "Managed by agh-pw" /tmp/dnsmasq.d/dnsmasq-passwall2.conf'

echo "== T10 missing PassWall2 feed"
setup
printf 'adguardhome\n' > "$T/run/pkg.db"; echo luci-app-passwall2 > "$T/run/pkg.fail"
envrun > "$T/run/t10.log" 2>&1; rc=$?
check "non-zero exit" "[ $rc -ne 0 ]"
check "actionable message" 'grep -q "not in the configured feeds" "$T/run/t10.log"'
check "no config touched" "[ ! -s $T/root/etc/adguardhome/adguardhome.yaml ]"

echo "== T11 watchdog installed and functional"
setup
envrun >/dev/null 2>&1
W="$T/root/usr/sbin/agh-pw-watchdog"
check "watchdog installed executable" "[ -x $W ]"
check "watchdog syntax ok" "sh -n $W"
check "cron entry present once" '[ "$(grep -c agh-pw-watchdog $T/root/etc/crontabs/root)" = 1 ]'
envrun >/dev/null 2>&1
check "cron entry not duplicated" '[ "$(grep -c agh-pw-watchdog $T/root/etc/crontabs/root)" = 1 ]'
rm -f "$T/run/agh.up" "$T/run/wd.stamp"
sed -i "s#/tmp/agh-pw-watchdog.stamp#$T/run/wd.stamp#" "$W"
before=$(grep -c "adguardhome restart" "$T/run/services.log")
SS_FILE="$T/run/ss" SERVICE_LOG="$T/run/services.log" AGH_UP="$T/run/agh.up" \
  DNSMASQ_UP="$T/run/dnsmasq.up" AGH_PW_INITD="$T/init.d" PATH="$T/bin:$PATH" \
  sh "$W"
after=$(grep -c "adguardhome restart" "$T/run/services.log")
check "watchdog restarted adguardhome" "[ $after -gt $before ]"
rm -f "$T/run/agh.up"
before=$(grep -c "adguardhome restart" "$T/run/services.log")
SS_FILE="$T/run/ss" SERVICE_LOG="$T/run/services.log" AGH_UP="$T/run/agh.up" \
  DNSMASQ_UP="$T/run/dnsmasq.up" AGH_PW_INITD="$T/init.d" PATH="$T/bin:$PATH" \
  sh "$W"
after=$(grep -c "adguardhome restart" "$T/run/services.log")
check "cooldown prevents restart storm" "[ $after -eq $before ]"
check "--no-watchdog skips install" 'setup; envrun --no-watchdog >/dev/null 2>&1; [ ! -f $T/root/usr/sbin/agh-pw-watchdog ] || [ ! -x $T/root/usr/sbin/agh-pw-watchdog ]'
check "uninstall removes watchdog" 'setup; envrun >/dev/null 2>&1; envrun --uninstall --yes >/dev/null 2>&1; [ ! -f $T/root/usr/sbin/agh-pw-watchdog ] && ! grep -q agh-pw-watchdog $T/root/etc/crontabs/root'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

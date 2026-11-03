#!/bin/sh
# ==============================================================================
#  OpenWrt + AdGuardHome + PassWall2 - conflict-free one-shot installer
#  Repo: https://github.com/Ace1337z/openwrt-agh-passwall2
# ------------------------------------------------------------------------------
#  SETTINGS ONLY. No proxy nodes are added. Add/choose them in LuCI afterwards.
#
#  Resulting chain:
#    LAN client -> router:53                      AdGuardHome (filter, cache)
#               -> tcp://127.0.0.1:15353          PassWall2 DNS (CN/proxy split)
#               -> .lan/.local/.home.arpa
#                  -> 127.0.0.1:54                dnsmasq (DHCP + local names)
#
#  Safety model:
#    * every file touched is backed up next to itself (*.agh-pw.bak.<ts>) and
#      recorded in a manifest, so --uninstall can restore it later
#    * the new AdGuardHome YAML is validated with `AdGuardHome --check-config`
#      before dnsmasq gives up port 53
#    * if AdGuardHome does not come up on :53 the script rolls DNS back
#      automatically (dnsmasq returns to :53, original configs restored)
#    * re-running is idempotent, no duplicate keys or duplicate firewall rules
#
#  Usage (as root on the router):
#    wget -O /tmp/agh-pw.sh \
#      https://raw.githubusercontent.com/Ace1337z/openwrt-agh-passwall2/main/install.sh
#    sh /tmp/agh-pw.sh --dry-run     # show what would change, change nothing
#    sh /tmp/agh-pw.sh               # apply
#    sh /tmp/agh-pw.sh --uninstall   # revert everything this script changed
# ==============================================================================

set -u
umask 077

# ------------------------------ tunables --------------------------------------
AGH_PORT="${AGH_PORT:-53}"             # AdGuardHome DNS listen port (LAN DNS)
DNSMASQ_PORT="${DNSMASQ_PORT:-54}"     # dnsmasq port (must differ from AGH_PORT)
PW_DNS_PORT="${PW_DNS_PORT:-15353}"    # PassWall2 local DNS port
AGH_DIR="${AGH_DIR:-/etc/adguardhome}"
AGH_YAML="${AGH_YAML:-${AGH_DIR}/adguardhome.yaml}"
AGH_UCI="${AGH_UCI:-/etc/config/adguardhome}"
DHCP_CFG="${DHCP_CFG:-/etc/config/dhcp}"
PW_CFG="${PW_CFG:-/etc/config/passwall2}"
FW_CFG="${FW_CFG:-/etc/config/firewall}"
INIT_D="${INIT_D:-/etc/init.d}"
AGH_WORKDIR="${AGH_WORKDIR:-/var/lib/adguardhome}"
AGH_BIN="${AGH_BIN:-/usr/bin/AdGuardHome}"
STATE_DIR="${STATE_DIR:-/etc/agh-pw-backup}"
OVERLAY="${OVERLAY:-/overlay}"
BOOT1="${BOOT1:-223.5.5.5}"            # bootstrap resolvers (plain IPv4, v4-only)
BOOT2="${BOOT2:-119.29.29.29}"
# Fallback resolvers are opt-in: with them set, AGH answers directly from
# plaintext DNS when PassWall2 DNS fails, which leaks queries outside the
# tunnel. Empty by default (PassWall2 DNS is authoritative).
AGH_FALLBACK="${AGH_FALLBACK:-}"
AGH_CACHE="${AGH_CACHE:-16777216}"     # 16 MiB DNS cache (65536 entries)
IPV6_ENABLE="${IPV6_ENABLE:-auto}"     # auto|1|0 - bind AdGuardHome on ::
AGH_RATELIMIT="${AGH_RATELIMIT:-0}"    # per-client qps limit, 0 = unlimited
WD_BIN="${WD_BIN:-/usr/sbin/agh-pw-watchdog}"
CRON_FILE="${CRON_FILE:-/etc/crontabs/root}"

DRY=0
UNINSTALL=0
ASSUME=0
DNSMASQ_FORWARD=0
WATCHDOG=1

TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${TMPDIR:-/tmp}/agh-pw.$$"
ROLLBACK_ARMED=0
FW_ADDED=""
AGH_PREV_RUNNING=0
IPV6=0

# ---------------------------------------------------------------- helpers -----
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    C_BOLD="$(printf '\033[1m')"; C_CYAN="$(printf '\033[36m')"
    C_YEL="$(printf '\033[33m')"; C_RED="$(printf '\033[31m')"
    C_OFF="$(printf '\033[0m')"
else
    C_BOLD=""; C_CYAN=""; C_YEL=""; C_RED=""; C_OFF=""
fi

log()  { printf '%s[agh-pw]%s %s\n' "$C_CYAN" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
die()  { printf '%s[error]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Options:
  --dry-run             show what would change, change nothing
  --uninstall           stop AdGuardHome and restore the previous DNS setup
  --dnsmasq-forward     also make dnsmasq forward to PassWall2 DNS (UCI,
                        persistent; off by default - AdGuardHome already does)
  --no-watchdog         do not install the 2-minute AdGuardHome health cron
  -y, --yes             do not ask for confirmation (uninstall)
  -h, --help            this help

Environment overrides:
  AGH_PORT=53 DNSMASQ_PORT=54 PW_DNS_PORT=15353
  BOOT1=223.5.5.5 BOOT2=119.29.29.29 AGH_FALLBACK=
  AGH_CACHE=16777216 AGH_RATELIMIT=0 IPV6_ENABLE=auto|1|0
  WD_BIN CRON_FILE
  AGH_DIR AGH_YAML AGH_UCI DHCP_CFG PW_CFG FW_CFG INIT_D AGH_WORKDIR
  AGH_BIN STATE_DIR OVERLAY
  AGH_PW_SKIP_ROOT=1 (tests only)

Exit status: 0 ok, 1 error and rolled back, 2 aborted/no change.
EOF
}

# Run or simulate. Never use for reads.
cmd() {
    if [ "$DRY" = 1 ]; then
        log "  [dry] $*"
        return 0
    fi
    "$@"
}

need_root() {
    [ -n "${AGH_PW_SKIP_ROOT:-}" ] && return 0
    [ "$(id -u)" = "0" ] || die "run as root on the OpenWrt router"
}

cget() { uci -q get "$1" 2>/dev/null || true; }

sockets() {
    if command -v ss >/dev/null 2>&1 && ss -lntu >/dev/null 2>&1; then
        ss -lntu 2>/dev/null
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntu 2>/dev/null
    else
        return 1
    fi
}

port_busy() {
    sockets | grep -qE "[:.]$1([[:space:]]|$)"
}

agh_running() {
    command -v pidof >/dev/null 2>&1 && pidof AdGuardHome >/dev/null 2>&1
}

dnsmasq_running() {
    command -v pidof >/dev/null 2>&1 && pidof dnsmasq >/dev/null 2>&1
}

dnsmasq_port() {
    p="$(cget dhcp.@dnsmasq[0].port)"
    [ -n "${p:-}" ] || p=53
    printf '%s' "$p"
}

agh_listening() {
    port_busy "$AGH_PORT" || return 1
    agh_running && return 0
    # Some builds expose the process name differently; a busy :53 with
    # dnsmasq already moved off it is good enough.
    ! port_busy "$DNSMASQ_PORT" 2>/dev/null && return 0
    port_busy "$AGH_PORT"
}

detect_ipv6() {
    case "$IPV6_ENABLE" in
        1) IPV6=1; return 0 ;;
        0) IPV6=0; return 0 ;;
    esac
    if [ -s /proc/net/if_inet6 ]; then IPV6=1; else IPV6=0; fi
}

initctl() {
    if [ ! -x "${INIT_D}/$1" ]; then
        warn "init script ${INIT_D}/$1 missing - skipping $2"
        return 1
    fi
    cmd "${INIT_D}/$1" "$2"
}

# ------------------------------- backup ---------------------------------------
mkdir -p "$RUN_DIR" 2>/dev/null || die "cannot create $RUN_DIR"

backups_of() {
    bdir="${1%/*}"; bname="${1##*/}"
    [ -d "$bdir" ] || return 0
    find "$bdir" -maxdepth 1 -type f -name "${bname}.agh-pw.bak.*" 2>/dev/null | sort -r
}

backup() {
    bf="$1"
    [ -f "$bf" ] || return 0
    newest="$(backups_of "$bf" | head -n 1)"
    if [ -n "$newest" ] && cmp -s "$bf" "$newest"; then
        log "  - $bf unchanged since last run"
        return 0
    fi
    bak="$bf.agh-pw.bak.$TS"
    if [ "$DRY" = 1 ]; then
        log "  [dry] backup $bf -> $bak"
        return 0
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null || { warn "cannot create $STATE_DIR - no rollback manifest"; return 1; }
    cp -p "$bf" "$bak" || { warn "cannot back up $bf"; return 1; }
    printf '%s\t%s\n' "$bf" "$bak" >> "$STATE_DIR/manifest.txt"
    printf '%s\t%s\n' "$bf" "$bak" >> "$RUN_DIR/files"
    # keep the five newest backups per file
    backups_of "$bf" | sed -n '6,999p' | while read -r old; do
        rm -f "$old"
    done
}

# --------------------------- packages -----------------------------------------
pkg_installed() {
    if command -v opkg >/dev/null 2>&1; then
        opkg list-installed 2>/dev/null | awk -v p="$1" '$1==p{f=1} END{exit f?0:1}'
    elif command -v apk >/dev/null 2>&1; then
        apk info -e "$1" >/dev/null 2>&1
    else
        return 1
    fi
}

pkg_install() {
    p="$1"
    if pkg_installed "$p"; then
        log "  - $p: installed"
        return 0
    fi
    log "  - $p: installing"
    if command -v opkg >/dev/null 2>&1; then
        cmd opkg update || warn "opkg update failed (feed unreachable?)"
        cmd opkg install "$p"
        return $?
    fi
    if command -v apk >/dev/null 2>&1; then
        cmd apk update || warn "apk update failed (feed unreachable?)"
        cmd apk add "$p"
        return $?
    fi
    warn "neither opkg nor apk found"
    return 1
}

# ------------------------- AdGuardHome YAML -----------------------------------
# Rewrites only the managed keys of the top-level dns: section and removes
# their old values (including list items written at section indentation,
# which is what AdGuardHome itself emits). Everything else is preserved.
patch_agh_dns() {
    in_file="$1"
    out_file="$2"
    awk -v port="$AGH_PORT" -v pwdns="127.0.0.1:${PW_DNS_PORT}" \
        -v dm="$DNSMASQ_PORT" -v b1="$BOOT1" -v b2="$BOOT2" \
        -v fb="$AGH_FALLBACK" -v cache="$AGH_CACHE" -v rl="$AGH_RATELIMIT" -v v6="$IPV6" \
        -v keys="bind_hosts port upstream_dns upstream_dns_file bootstrap_dns fallback_dns upstream_mode fastest_timeout cache_size ratelimit use_private_ptr_resolvers private_networks local_ptr_upstreams" '
    function emit(   ) {
        print "  bind_hosts:"
        print "  - 0.0.0.0"
        if (v6 == 1) print "  - ::"
        print "  port: " port
        print "  upstream_dns:"
        print "  - " pwdns
        print "  - \"[/lan/]127.0.0.1:" dm "\""
        print "  - \"[/local/]127.0.0.1:" dm "\""
        print "  - \"[/home.arpa/]127.0.0.1:" dm "\""
        print "  upstream_dns_file: \"\""
        print "  bootstrap_dns:"
        print "  - " b1
        print "  - " b2
        if (fb != "") {
            print "  fallback_dns:"
            print "  - " fb
        }
        print "  upstream_mode: parallel"
        print "  fastest_timeout: 1s"
        print "  cache_size: " cache
        print "  ratelimit: " rl
        print "  use_private_ptr_resolvers: true"
        print "  private_networks:"
        print "  - 192.168.0.0/16"
        print "  - 10.0.0.0/8"
        print "  - 172.16.0.0/12"
        print "  - fd00::/8"
        print "  local_ptr_upstreams:"
        print "  - 127.0.0.1:" dm
    }
    BEGIN {
        n = split(keys, k, " ")
        for (i = 1; i <= n; i++) managed[k[i]] = 1
        found = 0; in_dns = 0; skip = 0
    }
    {
        if (found == 0 && $0 ~ /^dns:[[:space:]]*$/) {
            found = 1; print; emit(); in_dns = 1; skip = 0; next
        }
        if (in_dns == 1 && $0 ~ /^[^[:space:]#]/) { in_dns = 0; skip = 0 }
        if (in_dns == 1) {
            if (match($0, /^  [A-Za-z_][A-Za-z0-9_]*:/)) {
                key = $0
                sub(/^  /, "", key)
                sub(/:.*$/, "", key)
                if (key in managed) { skip = 1; next }
                skip = 0
            } else if (skip == 1 && ($0 ~ /^  - / || $0 ~ /^    /)) {
                next
            } else if ($0 ~ /^  [^[:space:]]/) {
                skip = 0
            }
        }
        print
    }
    END { if (found == 0) { print "dns:"; emit() } }
    ' "$in_file" > "$out_file"
}

write_default_agh_yaml() {
    outf="${1:-$AGH_YAML}"
    {
        cat <<YAML
http:
  pprof:
    port: 6060
    enabled: false
  doh:
    routes:
    - GET /dns-query
    - POST /dns-query
    insecure_enabled: false
  address: 0.0.0.0:3000
  session_ttl: 30d
users: []
auth_attempts: 5
block_auth_min: 15
http_proxy: ''
language: ''
theme: auto
dns:
  bind_hosts:
  - 0.0.0.0
YAML
        [ "$IPV6" = 1 ] && printf '  - ::\n'
        cat <<YAML
  port: ${AGH_PORT}
  anonymize_client_ip: false
  ratelimit: ${AGH_RATELIMIT}
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
  - 127.0.0.1:${PW_DNS_PORT}
  - "[/lan/]127.0.0.1:${DNSMASQ_PORT}"
  - "[/local/]127.0.0.1:${DNSMASQ_PORT}"
  - "[/home.arpa/]127.0.0.1:${DNSMASQ_PORT}"
  upstream_dns_file: ''
  bootstrap_dns:
  - ${BOOT1}
  - ${BOOT2}
  upstream_mode: parallel
  fastest_timeout: 1s
  cache_size: ${AGH_CACHE}
  cache_enabled: true
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: true
  cache_optimistic_answer_ttl: 30s
  cache_optimistic_max_age: 12h
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ''
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ''
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  use_private_ptr_resolvers: true
  private_networks:
  - 192.168.0.0/16
  - 10.0.0.0/8
  - 172.16.0.0/12
  - fd00::/8
  local_ptr_upstreams:
  - 127.0.0.1:${DNSMASQ_PORT}
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
  pending_requests:
    enabled: true
YAML
        cat <<'YAML'
tls:
  enabled: false
  server_name: ''
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ''
  certificate_chain: ''
  private_key: ''
  certificate_path: ''
  private_key_path: ''
  strict_sni_check: false
querylog:
  dir_path: ''
  ignored: []
  interval: 90d
  size_memory: 1000
  enabled: true
  ignored_enabled: false
  file_enabled: true
statistics:
  dir_path: ''
  ignored: []
  interval: 1d
  enabled: true
  ignored_enabled: false
filters:
- enabled: true
  url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
  name: AdGuard DNS filter
  id: 1
whitelist_filters: []
user_rules: []
dhcp:
  enabled: false
  interface_name: ''
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ''
    subnet_mask: ''
    range_start: ''
    range_end: ''
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ''
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
filtering:
  blocking_ipv4: ''
  blocking_ipv6: ''
  blocked_services:
    schedule:
      time_zone: UTC
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: false
    bing: false
    duckduckgo: false
    ecosia: false
    google: false
    pixabay: false
    yandex: false
    youtube: false
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  safe_fs_patterns:
  - /var/lib/adguardhome/userfilters/*
  max_http_size: 256MB
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled: true
  rewrites_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ''
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ''
  user: ''
  rlimit_nofile: 0
schema_version: 34
YAML
    } > "$outf"
}

validate_agh_yaml() {
    [ "$DRY" = 1 ] && { log "  [dry] skip AdGuardHome --check-config"; return 0; }
    [ -x "$AGH_BIN" ] || { warn "$AGH_BIN not executable - cannot validate config"; return 0; }
    mkdir -p "$AGH_WORKDIR" 2>/dev/null || true
    if ! "$AGH_BIN" --check-config --config "$AGH_YAML" --work-dir "$AGH_WORKDIR" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# -------------------------------- steps ---------------------------------------
step_preflight() {
    log "Preflight"
    if [ -f "$AGH_YAML" ]; then
        log "  - AdGuardHome config: $AGH_YAML"
    else
        log "  - AdGuardHome config: $AGH_YAML (will be created)"
    fi
    agh_running && AGH_PREV_RUNNING=1 || AGH_PREV_RUNNING=0
    detect_ipv6

    # Port 53 must be free, or held by our own AdGuardHome or by dnsmasq
    # (which we are about to move). Anything else gets refused up front.
    if port_busy "$AGH_PORT"; then
        if [ "$AGH_PREV_RUNNING" = 1 ]; then
            log "  - port ${AGH_PORT}: owned by running AdGuardHome (re-run)"
        elif dnsmasq_running && [ "$(dnsmasq_port)" = "$AGH_PORT" ]; then
            log "  - port ${AGH_PORT}: owned by dnsmasq (will move to ${DNSMASQ_PORT})"
            warn "if another resolver also listens on ${AGH_PORT} (smartdns/mosdns/stubby/"
            warn "dnscrypt-proxy), AdGuardHome will fail to bind and this run will roll back"
        else
            warn "port ${AGH_PORT}/tcp+udp is in use:"
            sockets | grep -E "[:.]${AGH_PORT}[[:space:]]" | head -n 5 | while read -r l; do
                printf '        %s\n' "$l"
            done
            die "free port ${AGH_PORT} first (smartdns/mosdns/stubby/dnscrypt-proxy?). Nothing changed."
        fi
    else
        log "  - port ${AGH_PORT}: free"
    fi

    if dnsmasq_running; then
        log "  - dnsmasq: running on port $(dnsmasq_port)"
    fi

    # AGH package is ~20 MB unpacked; filling a 16 MB overlay bricks first boot
    if ! pkg_installed adguardhome; then
        free_kb="$(df -k "$OVERLAY" 2>/dev/null | awk 'NR==2{print $4}')"
        [ -n "${free_kb:-}" ] || free_kb="$(df -k / 2>/dev/null | awk 'NR==2{print $4}')"
        log "  - free space on ${OVERLAY}: ${free_kb:-unknown} KiB"
        if [ -n "${free_kb:-}" ] && [ "$free_kb" -lt 20480 ]; then
            die "need >=20 MiB free to install AdGuardHome (have ${free_kb} KiB). Nothing changed."
        fi
    fi
}

step_packages() {
    log "Step 1/7: packages"
    pkg_installed adguardhome || pkg_install adguardhome || die "AdGuardHome install failed - see errors above"
    [ -x "$AGH_BIN" ] || die "$AGH_BIN missing after install - wrong package?"
    pkg_install luci-app-adguardhome || warn "luci-app-adguardhome not installed - CLI on :3000 still works"

    if ! pkg_installed passwall2 && ! pkg_installed luci-app-passwall2; then
        if ! pkg_install luci-app-passwall2; then
            die "PassWall2 is not in the configured feeds.
  Add the PassWall2 feed for your release (opkg:
  https://github.com/xiaorouji/openwrt-passwall-build, or the apk repo on
  apk-based releases), run 'opkg update', then:
      opkg install luci-app-passwall2
  Nothing was changed on this router."
        fi
    fi
    pkg_installed passwall2 || pkg_installed luci-app-passwall2 || die "PassWall2 still missing after install"
}

step_agh_config() {
    log "Step 2/7: AdGuardHome config (:${AGH_PORT}, upstream PassWall2 :${PW_DNS_PORT})"
    [ "$DRY" = 1 ] || mkdir -p "$AGH_DIR" "$AGH_WORKDIR"
    backup "$AGH_YAML"

    if [ -f "$AGH_YAML" ]; then
        new_yaml="${AGH_YAML}.agh-pw.new"
        patch_agh_dns "$AGH_YAML" "$new_yaml"
        [ -s "$new_yaml" ] || die "failed to generate patched AdGuardHome config"
        if [ "$DRY" = 1 ]; then
            log "  [dry] would replace $(basename "$AGH_YAML") (managed dns: keys)"
            rm -f "$new_yaml"
        else
            # validate before it ever becomes live
            mv -f "$new_yaml" "$AGH_YAML"
            if ! validate_agh_yaml; then
                die "AdGuardHome rejected the generated config - nothing else changed"
            fi
            if [ "$IPV6" = 1 ]; then binds="0.0.0.0 + ::"; else binds="0.0.0.0"; fi
            log "  - patched and validated (bind ${binds})"
        fi
    else
        if [ "$DRY" = 1 ]; then
            log "  [dry] would write a fresh $AGH_YAML"
        else
            # template -> patch, so a fresh install and a later re-run produce
            # byte-identical output (managed keys always in the same place)
            tmpl="${AGH_YAML}.agh-pw.tmpl"
            write_default_agh_yaml "$tmpl"
            patch_agh_dns "$tmpl" "$AGH_YAML"
            rm -f "$tmpl"
            if ! validate_agh_yaml; then
                die "AdGuardHome rejected the generated default config"
            fi
            log "  - wrote fresh config and validated it"
        fi
    fi

    if [ "$DRY" = 0 ]; then
        chmod 600 "$AGH_YAML" 2>/dev/null || true
        tmp_owner="$(cget adguardhome.config.user)"
        [ -n "${tmp_owner:-}" ] || tmp_owner="adguardhome"
        if id "$tmp_owner" >/dev/null 2>&1; then
            chown "$tmp_owner" "$AGH_YAML" 2>/dev/null || true
            chown -R "$tmp_owner" "$AGH_WORKDIR" 2>/dev/null || true
        fi
    fi

    backup "$AGH_UCI"
    [ "$DRY" = 1 ] || touch "$AGH_UCI"
    if ! uci -q get adguardhome.config >/dev/null 2>&1; then
        cmd uci set adguardhome.config='config'
    fi
    cmd uci set 'adguardhome.config.enabled=1'
    cmd uci set "adguardhome.config.config_file=$AGH_YAML"
    cmd uci set "adguardhome.config.work_dir=$AGH_WORKDIR"
    cmd uci commit adguardhome
}

step_dnsmasq() {
    log "Step 3/7: dnsmasq -> port ${DNSMASQ_PORT}, drop legacy /tmp drop-in"
    backup "$DHCP_CFG"

    if [ "$(cget dhcp.@dnsmasq[0].port)" != "$DNSMASQ_PORT" ]; then
        cmd uci set "dhcp.@dnsmasq[0].port=$DNSMASQ_PORT"
    fi
    cmd uci set 'dhcp.@dnsmasq[0].authoritative=1'
    # not a dnsmasq option, leftover from earlier versions of this script
    [ "$DRY" = 1 ] || uci -q delete 'dhcp.@dnsmasq[0].dns_redirect' 2>/dev/null || true

    drop="$(cget dhcp.@dnsmasq[0].confdir)"
    drop="${drop%%,*}"
    [ -n "${drop:-}" ] || drop="/tmp/dnsmasq.d"
    for f in "$drop/dnsmasq-passwall2.conf" /tmp/dnsmasq.d/dnsmasq-passwall2.conf; do
        [ -f "$f" ] || continue
        if grep -q 'Managed by agh-pw' "$f" 2>/dev/null; then
            cmd rm -f "$f"
            log "  - removed legacy drop-in $f"
        fi
    done

    if [ "$DNSMASQ_FORWARD" = 1 ]; then
        entry="127.0.0.1#${PW_DNS_PORT}"
        if uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | tr ' ' '\n' | grep -qxF "$entry"; then
            log "  - dnsmasq forward to $entry: already set"
        else
            cmd uci add_list "dhcp.@dnsmasq[0].server=$entry"
        fi
        cmd uci set 'dhcp.@dnsmasq[0].allservers=1'
    fi
    cmd uci commit dhcp
}

step_passwall() {
    log "Step 4/7: PassWall2 DNS settings"
    if ! uci -q show passwall2 >/dev/null 2>&1; then
        warn "passwall2 UCI config missing - skipping (install the core first)"
        return 0
    fi
    backup "$PW_CFG"
    cmd uci set 'passwall2.@global[0].dns_redirect=0'
    cmd uci set 'passwall2.@global[0].localhost_proxy=1'
    if [ -z "$(cget passwall2.@global[0].remote_dns)" ]; then
        cmd uci set "passwall2.@global[0].remote_dns=$BOOT1"
        cmd uci set 'passwall2.@global[0].remote_dns_protocol=tcp'
        cmd uci set 'passwall2.@global[0].remote_dns_detour=remote'
    else
        log "  - remote_dns already set ($(cget passwall2.@global[0].remote_dns)) - left alone"
    fi
    cmd uci commit passwall2
}

step_firewall() {
    log "Step 5/7: LAN-only firewall rule for :${AGH_PORT} and :3000"
    if [ ! -f "$FW_CFG" ]; then
        warn "$FW_CFG missing - skipping firewall rule (set one manually!)"
        return 0
    fi
    sec="$(uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='Allow-AdGuardHome-LAN'$/\1/p" | head -n 1)"
    if [ -n "${sec:-}" ]; then
        log "  - rule Allow-AdGuardHome-LAN: present"
        return 0
    fi
    backup "$FW_CFG"
    if [ "$DRY" = 1 ]; then
        log "  [dry] would add firewall rule Allow-AdGuardHome-LAN (lan -> :${AGH_PORT} :3000)"
        return 0
    fi
    sec="$(uci add firewall rule)" || die "cannot add firewall rule"
    uci set "firewall.${sec}.name=Allow-AdGuardHome-LAN"
    uci set "firewall.${sec}.src=lan"
    uci set "firewall.${sec}.dest_port=${AGH_PORT} 3000"
    uci set "firewall.${sec}.proto=tcp udp"
    uci set "firewall.${sec}.target=ACCEPT"
    uci commit firewall
    FW_ADDED="$sec"
    log "  - rule Allow-AdGuardHome-LAN added"
}

step_restart() {
    log "Step 6/7: restart dnsmasq -> passwall2 -> adguardhome"
    initctl dnsmasq restart || die "dnsmasq restart failed"
    initctl passwall2 enable || true
    initctl passwall2 restart || warn "passwall2 restart failed"
    initctl adguardhome enable || true
    initctl adguardhome restart || die "adguardhome restart failed"

    if [ "$DRY" = 1 ]; then
        log "  [dry] skip service verification"
        return 0
    fi

    i=0
    while [ "$i" -lt "${AGH_PW_WAIT:-15}" ]; do
        agh_listening && break
        i=$((i + 1))
        sleep 1
    done

    if ! agh_listening; then
        if command -v logread >/dev/null 2>&1; then
            logread -e AdGuardHome 2>/dev/null | tail -n 20
        fi
        die "AdGuardHome is not listening on :${AGH_PORT}"
    fi
    log "  - AdGuardHome listening on :${AGH_PORT}"

    if ! port_busy "$DNSMASQ_PORT"; then
        warn "dnsmasq does not look bound to :${DNSMASQ_PORT} - .lan names may fail"
    else
        log "  - dnsmasq listening on :${DNSMASQ_PORT}"
    fi

    if command -v nslookup >/dev/null 2>&1; then
        if nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1; then
            log "  - resolution through AdGuardHome: ok"
        else
            warn "resolution through AdGuardHome failed (no PassWall2 node yet, or no upstream)"
        fi
    fi
}

step_watchdog() {
    log "Step 7/7: AdGuardHome health watchdog (cron, every 2 min)"
    if [ "$WATCHDOG" = 0 ]; then
        log "  - disabled (--no-watchdog)"
        return 0
    fi
    if [ "$DRY" = 1 ]; then
        log "  [dry] would install $WD_BIN and cron '*/2 * * * * $WD_BIN'"
        return 0
    fi
    mkdir -p "$(dirname "$WD_BIN")" 2>/dev/null || true
    if ! cat > "$WD_BIN" <<WATCHDOG
#!/bin/sh
# agh-pw-watchdog - installed by openwrt-agh-passwall2/install.sh
# Restarts AdGuardHome if it stops answering on its port. Never edits
# configs, firewall or ports: only service restarts, throttled to one attempt
# per 5 minutes so it cannot cause a restart storm.
AGH_PORT=${AGH_PORT}
DNSMASQ_PORT=${DNSMASQ_PORT}
COOLDOWN=300
STAMP=/tmp/agh-pw-watchdog.stamp
INITD="\${AGH_PW_INITD:-/etc/init.d}"

say() { command -v logger >/dev/null 2>&1 && logger -t agh-pw-wd "\$*"; }
busy() {
    if command -v ss >/dev/null 2>&1 && ss -lnu >/dev/null 2>&1; then
        ss -lnu 2>/dev/null
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnu 2>/dev/null
    fi | grep -qE "[:.]\$1([[:space:]]|\$)"
}

if command -v pidof >/dev/null 2>&1 && pidof AdGuardHome >/dev/null 2>&1 && busy "\$AGH_PORT"; then
    if ! busy "\$DNSMASQ_PORT"; then
        say "dnsmasq not on :\$DNSMASQ_PORT (.lan lookups fail) - restarting"
        [ -x "\$INITD/dnsmasq" ] && "\$INITD/dnsmasq" restart >/dev/null 2>&1
    fi
    exit 0
fi

now="\$(date +%s)"
last="\$(cat "\$STAMP" 2>/dev/null || echo 0)"
case "\$last" in ''|*[!0-9]*) last=0 ;; esac
if [ \$((now - last)) -lt "\$COOLDOWN" ]; then
    exit 0
fi
printf '%s\n' "\$now" > "\$STAMP"
say "AdGuardHome not answering on :\$AGH_PORT - restarting"
[ -x "\$INITD/adguardhome" ] && "\$INITD/adguardhome" restart >/dev/null 2>&1
sleep 5
if command -v pidof >/dev/null 2>&1 && pidof AdGuardHome >/dev/null 2>&1 && busy "\$AGH_PORT"; then
    say "restart ok"
    exit 0
fi
say "still down - restarting dnsmasq and passwall2"
[ -x "\$INITD/dnsmasq" ] && "\$INITD/dnsmasq" restart >/dev/null 2>&1
[ -x "\$INITD/passwall2" ] && "\$INITD/passwall2" restart >/dev/null 2>&1
exit 1
WATCHDOG
    then
        warn "cannot write $WD_BIN - watchdog skipped (rest works)"
        return 0
    fi
    chmod 755 "$WD_BIN"

    mkdir -p "$(dirname "$CRON_FILE")" 2>/dev/null || true
    [ -f "$CRON_FILE" ] || : > "$CRON_FILE" 2>/dev/null || true
    if grep -qs 'agh-pw-watchdog' "$CRON_FILE"; then
        log "  - cron entry: present"
    else
        printf '%s\n' '*/2 * * * * /usr/sbin/agh-pw-watchdog >/dev/null 2>&1' >> "$CRON_FILE"
        log "  - cron entry added to $CRON_FILE"
    fi
    cmd "${INIT_D}/cron" enable || true
    cmd "${INIT_D}/cron" restart || warn "cron restart failed - watchdog will start after next reboot"
}

step_summary() {
    log "==== Summary ===="
    printf '  dnsmasq port             : %s\n' "$(cget dhcp.@dnsmasq[0].port)"
    printf '  passwall2 dns_redirect   : %s\n' "$(cget passwall2.@global[0].dns_redirect)"
    printf '  passwall2 localhost_proxy: %s\n' "$(cget passwall2.@global[0].localhost_proxy)"
    if [ "$DRY" = 1 ]; then
        printf '  mode                     : dry-run (nothing changed)\n'
        return 0
    fi
    if agh_listening; then
        printf '  AdGuardHome on :%s       : yes\n' "$AGH_PORT"
    else
        printf '  AdGuardHome on :%s       : NOT DETECTED\n' "$AGH_PORT"
    fi
    rip="$(cget network.lan.ipaddr)"
    rip="${rip%%/*}"
    [ -n "${rip:-}" ] || rip="<router-ip>"
    log "Next steps:"
    log "  1) Open AdGuardHome UI: http://${rip}:3000 - create the admin login now"
    log "     (until you do, anyone on the LAN can set it)"
    log "  2) Add/choose nodes in LuCI -> Services -> PassWall2"
    log "  3) Verify:  nslookup openwrt.org 127.0.0.1"
    if [ "$WATCHDOG" = 1 ] && [ -x "$WD_BIN" ]; then
        log "  watchdog: $WD_BIN (cron every 2 min, logread -t agh-pw-wd)"
    fi
    log "  Diagnose a hang: sh diagnose.sh  (read-only, prints a report)"
    log "  Backups + manifest: ${STATE_DIR}"
    log "  Revert everything : sh $0 --uninstall"
    log "Finished."
}

# ------------------------------ rollback --------------------------------------
rollback() {
    rc=$?
    [ "${ROLLBACK_ARMED:-0}" = 1 ] || return 0
    trap - EXIT
    warn "setup failed (exit $rc) - rolling back DNS changes"
    if [ -s "$RUN_DIR/files" ]; then
        while IFS="$(printf '\t')" read -r orig bak; do
            [ -n "${orig:-}" ] || continue
            if [ -f "$bak" ]; then
                cp -p "$bak" "$orig" && log "  restored $orig"
            fi
        done < "$RUN_DIR/files"
    fi
    if [ -n "${FW_ADDED:-}" ]; then
        uci -q delete "firewall.$FW_ADDED" 2>/dev/null || true
    fi
    uci -q commit dhcp 2>/dev/null || true
    uci -q commit passwall2 2>/dev/null || true
    uci -q commit adguardhome 2>/dev/null || true
    uci -q commit firewall 2>/dev/null || true
    if [ "$AGH_PREV_RUNNING" = 0 ]; then
        if [ -f "$WD_BIN" ]; then
        rm -f "$WD_BIN"
        log "  removed $WD_BIN"
    fi
    if [ -f "$CRON_FILE" ] && grep -qs 'agh-pw-watchdog' "$CRON_FILE"; then
        sed -i '/agh-pw-watchdog/d' "$CRON_FILE"
        log "  removed watchdog cron entry"
        "${INIT_D}/cron" restart >/dev/null 2>&1 || true
    fi
    "${INIT_D}/adguardhome" stop 2>/dev/null || true
        "${INIT_D}/adguardhome" disable 2>/dev/null || true
    fi
    "${INIT_D}/dnsmasq" restart 2>/dev/null || true
    warn "rollback done: dnsmasq should be back on :${AGH_PORT}. Check resolution: nslookup openwrt.org"
    ROLLBACK_ARMED=0
    return "$rc"
}

# ------------------------------ uninstall -------------------------------------
do_uninstall() {
    log "Uninstall: restoring previous DNS configuration"
    if [ "$ASSUME" = 0 ]; then
        if [ -t 0 ]; then
            printf 'Stop AdGuardHome and restore the previous DNS setup? [y/N] '
            read -r answer
            case "$answer" in
                y|Y|yes|YES) ;;
                *) die "aborted (exit 2)";;
            esac
        else
            die "refusing non-interactive uninstall without --yes (exit 2)"
        fi
    fi

    if [ ! -s "$STATE_DIR/manifest.txt" ]; then
        warn "no manifest at $STATE_DIR/manifest.txt - nothing recorded, cannot restore"
    else
        awk -F'\t' 'NF==2{last[$1]=$2} END{for (f in last) print f "\t" last[f]}' \
            "$STATE_DIR/manifest.txt" | while IFS="$(printf '\t')" read -r orig bak; do
            if [ -f "$bak" ]; then
                cp -p "$bak" "$orig" && log "  restored $orig (from $bak)"
            else
                warn "backup missing: $bak"
            fi
        done
    fi

    sec="$(uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='Allow-AdGuardHome-LAN'$/\1/p" | head -n 1)"
    if [ -n "${sec:-}" ]; then
        uci delete "firewall.$sec"
        uci commit firewall
        log "  removed firewall rule Allow-AdGuardHome-LAN"
    fi

    drop="$(cget dhcp.@dnsmasq[0].confdir)"
    drop="${drop%%,*}"
    [ -n "${drop:-}" ] || drop="/tmp/dnsmasq.d"
    for f in "$drop/dnsmasq-passwall2.conf" /tmp/dnsmasq.d/dnsmasq-passwall2.conf; do
        [ -f "$f" ] || continue
        grep -q 'Managed by agh-pw' "$f" 2>/dev/null && rm -f "$f" && log "  removed $f"
    done

    if [ -f "$WD_BIN" ]; then
        rm -f "$WD_BIN"
        log "  removed $WD_BIN"
    fi
    if [ -f "$CRON_FILE" ] && grep -qs 'agh-pw-watchdog' "$CRON_FILE"; then
        sed -i '/agh-pw-watchdog/d' "$CRON_FILE"
        log "  removed watchdog cron entry"
        "${INIT_D}/cron" restart >/dev/null 2>&1 || true
    fi
    "${INIT_D}/adguardhome" stop 2>/dev/null || true
    "${INIT_D}/adguardhome" disable 2>/dev/null || true
    log "  AdGuardHome stopped and disabled"

    if [ "$(cget dhcp.@dnsmasq[0].port)" != "53" ]; then
        uci set 'dhcp.@dnsmasq[0].port=53'
        uci commit dhcp
        log "  dnsmasq back on :53"
    fi
    if [ -x "${INIT_D}/dnsmasq" ]; then
        "${INIT_D}/dnsmasq" restart >/dev/null 2>&1 || warn "dnsmasq restart failed"
    fi
    if [ -x "${INIT_D}/passwall2" ]; then
        "${INIT_D}/passwall2" restart >/dev/null 2>&1 || warn "passwall2 restart failed"
    fi
    log "Done. AdGuardHome packages were NOT removed (opkg remove adguardhome)."
    log "Backups kept in $STATE_DIR (safe to delete after you are happy)."
}

# -------------------------------- main ----------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --uninstall|--rollback) UNINSTALL=1 ;;
        --dnsmasq-forward) DNSMASQ_FORWARD=1 ;;
        --no-watchdog) WATCHDOG=0 ;;
        -y|--yes) ASSUME=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; printf '[error] unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

need_root
trap rollback EXIT
trap 'exit 130' INT TERM

if [ "$UNINSTALL" = 1 ]; then
    do_uninstall
    rm -rf "$RUN_DIR" 2>/dev/null || true
    exit 0
fi

log "${C_BOLD}OpenWrt AdGuardHome + PassWall2 conflict-free setup${C_OFF}"
step_preflight
step_packages
ROLLBACK_ARMED=1
step_agh_config
step_dnsmasq
step_passwall
step_firewall
step_restart
ROLLBACK_ARMED=0
trap - EXIT
step_watchdog
step_summary
rm -rf "$RUN_DIR" 2>/dev/null || true

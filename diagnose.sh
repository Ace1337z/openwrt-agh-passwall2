#!/bin/sh
# ==============================================================================
#  diagnose.sh - read-only health report for AdGuardHome + PassWall2 on OpenWrt
#  Repo: https://github.com/Ace1337z/openwrt-agh-passwall2
#
#  Changes nothing. Run when "the internet stops working after a while":
#    wget -O /tmp/diagnose.sh https://raw.githubusercontent.com/Ace1337z/\
#openwrt-agh-passwall2/main/diagnose.sh
#    sh /tmp/diagnose.sh            # print report
#    sh /tmp/diagnose.sh /tmp/r.txt # also save it
# ==============================================================================

set -u

AGH_PORT="${AGH_PORT:-53}"
DNSMASQ_PORT="${DNSMASQ_PORT:-5335}"
AGH_YAML="${AGH_YAML:-/etc/adguardhome/adguardhome.yaml}"
HIJACK_NFT="${HIJACK_NFT:-/etc/nftables.d/20-agh-dns-hijack.nft}"
AGH_UPSTREAM1="${AGH_UPSTREAM1:-https://dns10.quad9.net/dns-query}"
OUT="${1:-}"
FINDINGS=0

say()  { printf '%s\n' "$*"; }
head2() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
note() { printf '  [note] %s\n' "$*"; }
bad()  { FINDINGS=$((FINDINGS + 1)); printf '  [!!]   %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
cfg()  { uci -q get "$1" 2>/dev/null || true; }

sockets() {
    if have ss && ss -lntu >/dev/null 2>&1; then
        ss -lntu 2>/dev/null
    elif have netstat; then
        netstat -lntu 2>/dev/null
    fi
}
listening() { sockets | grep -qE "[:.]$1([[:space:]]|$)"; }

run() {
    # run a reporter quietly in a subshell, keep going on failure
    "$@" 2>/dev/null || true
}

report() {
    head2 "system"
    say "  date      : $(date)"
    say "  uptime    : $(cut -d' ' -f1 /proc/uptime 2>/dev/null) s"
    say "  load      : $(cat /proc/loadavg 2>/dev/null)"
    awk '/MemTotal|MemFree|MemAvailable|Cached|Buffers|SwapTotal|SwapFree/{printf "  %-10s: %s kB\n", $1, $2}' /proc/meminfo 2>/dev/null
    say "  openwrt   : $(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null)"
    say "  kernel    : $(uname -sr)"

    head2 "out-of-memory / kills since boot"
    if have dmesg; then
        if dmesg 2>/dev/null | grep -qiE 'out of memory|oom-kill|killed process'; then
            bad "OOM kill recorded - a service was killed by the kernel (see dmesg)"
            dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -n 10 | sed 's/^/         /'
        else
            ok "no OOM kill in the kernel ring buffer"
        fi
    else
        note "dmesg not available"
    fi
    if have logread; then
        n=$(logread 2>/dev/null | grep -ciE 'out of memory|oom-kill')
        [ "${n:-0}" -gt 0 ] && bad "logread shows $n OOM related lines"
    fi

    head2 "listeners"
    for p in "$AGH_PORT" "$DNSMASQ_PORT"; do
        if listening "$p"; then
            ok "port $p: listening"
            sockets | grep -E "[:.]$p([[:space:]]|$)" | head -n 3 | sed 's/^/         /'
        else
            case "$p" in
                "$AGH_PORT")    bad "port $AGH_PORT (AdGuardHome) not listening - clients have no DNS" ;;
                *)              bad "port $p (dnsmasq) not listening - .lan/.local lookups fail" ;;
            esac
        fi
    done

    head2 "processes"
    # shellcheck disable=SC2009 # busybox may lack pgrep on old releases
    ps w 2>/dev/null | grep -E '[A]dGuardHome|[d]nsmasq|[c]hinadns|[d]ns2socks|[x]ray|[s]ing-box' |
        sed 's/^/  /' || note "ps not available"
    say "  conntrack : $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo n/a) / $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo n/a)"
    if [ -r /proc/sys/net/netfilter/nf_conntrack_count ] && [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
        c=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
        m=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
        [ "$m" -gt 0 ] && [ $((c * 100 / m)) -ge 80 ] && \
            bad "conntrack table ${c}/${m} (>=80%) - new connections start failing, looks like 'internet down'"
    fi

    head2 "uci: dns wiring"
    say "  dhcp dnsmasq port       : $(cfg dhcp.@dnsmasq[0].port)  (expect $DNSMASQ_PORT)"
    say "  dhcp dnsmasq localuse   : $(cfg dhcp.@dnsmasq[0].localuse)"
    say "  dhcp dnsmasq server     : $(cfg dhcp.@dnsmasq[0].server)"
    say "  passwall2 dns_redirect  : $(cfg passwall2.@global[0].dns_redirect)  (expect 0)"
    say "  passwall2 localhost_proxy: $(cfg passwall2.@global[0].localhost_proxy)"
    [ "$(cfg dhcp.@dnsmasq[0].port)" = "$DNSMASQ_PORT" ] || bad "dnsmasq is not on $DNSMASQ_PORT - config drifted (re-run install.sh)"
    [ "$(cfg passwall2.@global[0].dns_redirect)" = "0" ] || bad "PassWall2 DNS redirect is not 0 - it can hijack :$AGH_PORT"

    head2 "nftables DNS redirect ($HIJACK_NFT)"
    if [ -f "$HIJACK_NFT" ]; then
        ok "redirect chain file present"
        grep -E 'priority|dport 53|skuid' "$HIJACK_NFT" 2>/dev/null | sed 's/^/         /'
    else
        note "no redirect chain file - LAN clients may use their own resolver"
    fi
    if have nft; then
        nft list chain inet fw4 agh_dns_hijack >/dev/null 2>&1 &&
            ok "chain agh_dns_hijack is loaded in fw4" ||
            bad "chain agh_dns_hijack not loaded - reload the firewall (re-run install.sh)"
        nft list chain inet fw4 agh_dns_hijack_out >/dev/null 2>&1 &&
            ok "chain agh_dns_hijack_out is loaded in fw4" ||
            note "chain agh_dns_hijack_out not loaded - router DNS is not redirected"
    else
        note "nft not available - cannot verify loaded rules"
    fi
    if uci -q show firewall 2>/dev/null | grep -q "Block-LAN-DNS-Bypass"; then
        ok "LAN -> dnsmasq bypass block present"
    else
        note "no dnsmasq bypass block - LAN clients can query :$DNSMASQ_PORT directly"
    fi

    head2 "AdGuardHome config ($AGH_YAML)"
    if [ -f "$AGH_YAML" ]; then
        say "  size/owner: $(stat -c '%s bytes %U:%G' "$AGH_YAML" 2>/dev/null)"
        sed -n '/^dns:/,/^[a-z]/p' "$AGH_YAML" 2>/dev/null |
            grep -E '  (port|bind_hosts|upstream_dns|upstream_mode|bootstrap_dns|fallback_dns|cache_size|ratelimit|use_private_ptr_resolvers|enable_dnssec):|  - ' |
            head -n 30 | sed 's/^/  /'
        grep -q '^  port: 53' "$AGH_YAML" 2>/dev/null || bad "AdGuardHome is not configured for port 53"
        grep -q "https://dns10.quad9.net/dns-query" "$AGH_YAML" 2>/dev/null || bad "Quad9 DoH upstream missing"
        grep -q "https://cloudflare-dns.com/dns-query" "$AGH_YAML" 2>/dev/null || note "Cloudflare DoH second upstream missing"
        grep -q '\[/lan/\]127.0.0.1:'"$DNSMASQ_PORT" "$AGH_YAML" 2>/dev/null || bad "AdGuardHome /lan/ conditional upstream missing"
        grep -q '127.0.0.1:15353' "$AGH_YAML" 2>/dev/null && bad "obsolete PassWall2 DNS upstream still configured"
        case "$(grep -m1 '^  cache_size:' "$AGH_YAML" 2>/dev/null)" in
            *67108864*) bad "cache_size is 64 MiB - large for router RAM; use 4194304" ;;
        esac
        case "$(grep -m1 '^  ratelimit:' "$AGH_YAML" 2>/dev/null)" in
            *'ratelimit: 0') : ;;
            *'ratelimit:'*) note "ratelimit is enabled - bursts can look like DNS timeouts (0 disables it)" ;;
        esac
        grep -q '^  fallback_dns:' "$AGH_YAML" 2>/dev/null && \
            note "fallback_dns set: when both DoH upstreams fail, queries leak to plaintext resolvers"
    else
        bad "$AGH_YAML missing - AdGuardHome has no config"
    fi

    head2 "AdGuardHome data dirs"
    for d in /var/lib/adguardhome /etc/adguardhome; do
        [ -d "$d" ] || continue
        say "  $d: $(du -sk "$d" 2>/dev/null | awk '{print $1}') KiB"
    done
    if awk '$2=="/var"{print $3}' /proc/mounts 2>/dev/null | grep -q tmpfs; then
        note "/var is tmpfs - AGH querylog/stats are in RAM and lost on reboot"
    else
        say "  /var is on disk"
    fi

    head2 "functional DNS checks"
    if have nslookup; then
        if nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1; then
            ok "resolve via 127.0.0.1 (AdGuardHome -> DoH): ok"
        else
            bad "resolve via 127.0.0.1 failed"
        fi
        if have dig; then
            if dig +time=3 +tries=1 @"127.0.0.1" -p "$DNSMASQ_PORT" openwrt.lan >/dev/null 2>&1; then
                ok "dnsmasq :$DNSMASQ_PORT answers: ok"
            else
                note "dnsmasq :$DNSMASQ_PORT did not answer a .lan query (may be normal if the name does not exist)"
            fi
            if dig +time=3 +tries=1 @"127.0.0.1" openwrt.org >/dev/null 2>&1; then
                ok "AdGuardHome :$AGH_PORT answers: ok"
            else
                bad "AdGuardHome :$AGH_PORT did not answer"
            fi
        else
            note "dig not installed - cannot test :$DNSMASQ_PORT directly (opkg install bind-dig)"
        fi
    else
        note "nslookup not available"
    fi

    head2 "firewall / cron / logs"
    if [ -f /etc/crontabs/root ]; then
        if grep -qs agh-pw-watchdog /etc/crontabs/root; then ok "health watchdog cron installed"; else note "no watchdog cron - re-run install.sh"; fi
    fi
    if have logread; then
        head2 "last AdGuardHome / passwall log lines"
        logread 2>/dev/null | grep -aiE 'adguardhome|passwall|chinadns|dns2socks' | tail -n 25 | sed 's/^/  /'
        logread 2>/dev/null | grep -ai 'agh-pw-wd' | tail -n 10 | sed 's/^/  /'
    fi

    head2 "verdict"
    if [ "$FINDINGS" -eq 0 ]; then
        say "  No hard failures found in this snapshot."
        say "  If it only breaks after a while, capture this report while it is broken"
        say "  and compare: listeners, MemAvailable, conntrack, and logread OOM lines."
    else
        say "  $FINDINGS problem(s) marked [!!] above. Most common causes of"
        say "  'works, then DNS stops answering':"
        say "   1. dnsmasq moved off :$DNSMASQ_PORT - .lan lookups and DHCP break"
        say "   2. AdGuardHome stopped or lost :$AGH_PORT (OOM kill, config drift)"
        say "   3. nft chains gone after a firewall reload - LAN bypasses AdGuardHome"
        say "   4. Both DoH upstreams unreachable - bootstrap DNS blocked by a proxy rule"
    fi
}

if [ -n "$OUT" ]; then
    report > "$OUT" 2>&1
    printf 'report written to %s\n' "$OUT"
    cat "$OUT"
else
    report
fi

#!/usr/bin/env bash
# v2raya-node-watchdog v3
# 仅当 v2raya 在跑时才守护。
# v2 的缺陷：第二层探针 https://1.1.1.1/cdn-cgi/trace 依赖 TProxy 把 1.1.1.1:443
#   劫持进 proxy。一旦 DHCP renew / Tailscale 重排把 ip rule(fwmark 0xc0 lookup 100)
#   删掉，TProxy 就没了，探针必然失败 → 误判隧道故障 → fail-open 杀 v2raya。
#   而杀 v2raya 无法恢复 TProxy（只有重拉 v2raya 才会重挂），等于真正的故障发生时
#   看门狗杀掉了唯一能修复它的东西。
# v3 的改动：新增「TProxy 存活检查」。发现 ip rule 或 nft 表丢失 → 直接重启 v2raya 自愈，
#   而不是杀服务或等计数器。只有 TProxy 确认存活、隧道仍失败时才累计故障计数。
set -u

STATE=/run/v2raya-watchdog.fails
CONF=/etc/v2raya/config.json
CN_REF=223.5.5.5                            # geoip:cn → 直连，确认本地链路活着
TUNNEL_PROBE=https://1.1.1.1/cdn-cgi/trace  # 非 CN IP，直连被墙 → 有响应即隧道通
KILL_AFTER=4                                # 连续失败次数，45s 一次 ≈ 3 分钟

fails=$(cat "$STATE" 2>/dev/null || echo 0)
case $fails in ''|*[!0-9]*) fails=0 ;; esac
reset() { echo 0 >"$STATE"; exit 0; }

systemctl is-active --quiet v2raya || reset

# 1) 本地/ISP 链路：链路问题不归节点背，也不停服（停了链路恢复时反而没代理）
if ! timeout 5 bash -c "</dev/tcp/$CN_REF/443" 2>/dev/null; then
    logger -t v2raya-watchdog "local link down (cannot reach $CN_REF); holding"
    reset
fi

# 2) TProxy 存活检查：ip rule (fwmark 0xc0 lookup 100) + nft inet v2raya 表
#    任一丢失 → v2raya 的 TProxy 被冲掉了，只有重拉 v2raya 才会重挂。重启自愈，不累计。
LAST_RESTART=/run/v2raya-watchdog.lastrestart
if ! ip rule show 2>/dev/null | grep -q 'fwmark 0x[0-9a-f]*/0xc0 lookup 100' \
   || ! nft list table inet v2raya >/dev/null 2>&1; then
    now=$(date +%s)
    last=$(cat "$LAST_RESTART" 2>/dev/null || echo 0)
    if [ $((now - last)) -lt 60 ]; then
        logger -t v2raya-watchdog "TProxy still missing but restarted ${last} [${now-last}s ago]; holding"
        exit 0
    fi
    logger -t v2raya-watchdog "TProxy ip rule / nft table missing; restarting v2raya to rebuild"
    echo "$now" >"$LAST_RESTART"
    echo 0 >"$STATE"
    systemctl restart v2raya
    exit 0
fi

# 3) 隧道探测：TProxy 确认存活，此时 1.1.1.1 必然被劫持进 proxy，结果可信
if curl -s --max-time 8 "$TUNNEL_PROBE" 2>/dev/null | grep -q '^ip='; then
    reset
fi

fails=$((fails + 1))
echo "$fails" >"$STATE"

# 4) 节点自身 443（routing rule 0 判直连，不经隧道）
node=$(grep -oE '"vnext":\[\{"address":"[^"]+"' "$CONF" 2>/dev/null \
       | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
node_dead=0
if [ -n "$node" ] && ! timeout 5 bash -c "</dev/tcp/$node/443" 2>/dev/null; then
    node_dead=1
fi

fail_open() {
    logger -t v2raya-watchdog "$1; stopping v2raya to fail open"
    echo 0 >"$STATE"
    systemctl stop v2raya
    exit 0
}

# 节点 TCP 都不通 = 真死(是会黑洞 Tailscale 的那种死)，两次即可
if [ "$node_dead" = 1 ] && [ "$fails" -ge 2 ]; then
    fail_open "node ${node}:443 unreachable x${fails}"
fi

# 节点通但隧道持续不通(证书/UUID/被 QoS 等)，撑满窗口再停
if [ "$fails" -ge "$KILL_AFTER" ]; then
    fail_open "tunnel down x${fails} while node ${node:-?}:443 still reachable"
fi

logger -t v2raya-watchdog "probe failed ${fails}/${KILL_AFTER} (node ${node:-?} dead=${node_dead}); waiting"
exit 0

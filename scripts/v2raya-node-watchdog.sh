#!/usr/bin/env bash
# v2raya-node-watchdog v2
# 仅当 v2raya 在跑【且 TProxy 已挂(inet v2raya 表存在)】时才守护。
# v1 的问题：探针 curl http://www.google.com/generate_204 需要先在隧道里做一次
# DoH(1.1.1.1) 解析，DNS 慢过 --max-time 就报 000，一次 26s 窗口的瞬断即永久停服。
# v2 的三点改动：
#   1) 探针改用纯 IP 目标，把 DNS 从关键路径上摘掉；
#   2) 先判本地/ISP 链路，链路问题不归节点背，也不停服(停了链路恢复时反而没代理)；
#   3) 失败计数跨 timer 周期累计，并用节点 443 的可达性区分「节点死」和「隧道抖」。
set -u

STATE=/run/v2raya-watchdog.fails
CONF=/etc/v2raya/config.json
CN_REF=223.5.5.5                            # geoip:cn → 直连，用来确认本地链路活着
TUNNEL_PROBE=https://1.1.1.1/cdn-cgi/trace  # 非 CN IP 且直连被墙 → 有响应即隧道通
KILL_AFTER=4                                # 连续失败次数，45s 一次 ≈ 3 分钟

fails=$(cat "$STATE" 2>/dev/null || echo 0)
case $fails in ''|*[!0-9]*) fails=0 ;; esac
reset() { echo 0 >"$STATE"; exit 0; }

systemctl is-active --quiet v2raya || reset
nft list table inet v2raya >/dev/null 2>&1 || reset   # 没挂 TProxy = 没在代理，放过

# 1) 本地/ISP 链路
if ! timeout 5 bash -c "</dev/tcp/$CN_REF/443" 2>/dev/null; then
    logger -t v2raya-watchdog "local link down (cannot reach $CN_REF); holding"
    reset
fi

# 2) 隧道探测：无 DNS 依赖，回 ip= 即证明非 CN 流量能出去
if curl -s --max-time 8 "$TUNNEL_PROBE" 2>/dev/null | grep -q '^ip='; then
    reset
fi

fails=$((fails + 1))
echo "$fails" >"$STATE"

# 3) 节点自身 443（routing rule 0 判直连，不经隧道）
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

# 节点 TCP 都不通 = 真死(也正是会黑洞 Tailscale 的那种死)，两次即可
if [ "$node_dead" = 1 ] && [ "$fails" -ge 2 ]; then
    fail_open "node ${node}:443 unreachable x${fails}"
fi

# 节点通但隧道持续不通(证书/UUID/被 QoS 等)，撑满窗口再停
if [ "$fails" -ge "$KILL_AFTER" ]; then
    fail_open "tunnel down x${fails} while node ${node:-?}:443 still reachable"
fi

logger -t v2raya-watchdog "probe failed ${fails}/${KILL_AFTER} (node ${node:-?} dead=${node_dead}); waiting"
exit 0

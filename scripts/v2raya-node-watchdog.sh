#!/usr/bin/env bash
# v2raya-node-watchdog v4
# 改进重点：
# 1. 增加 Fail-Back（自动复活）：
#    当因故障触发 fail-open（停服直连）后，脚本持续在后台按退避周期探测节点；
#    一旦节点与隧道恢复，自动唤醒 v2raya，避免人工上班手动拉起的麻烦。
# 2. 增加 Restart 自愈预处理：
#    节点 TCP 通但隧道不通时，在触发 fail-open 停服前先尝试一次 restart 自愈（修复 xray 假死/连接池阻塞）。
# 3. 双探针冗余：
#    增加备用纯 IP 探针（1.0.0.1）和本地双 DNS（223.5.5.5 / 119.29.29.29），防单点偶发误判。
# 4. 保留 v3 的 TProxy 存活检测（nft / ip rule 丢失自动重启修复）。

set -u

STATE=/run/v2raya-watchdog.fails
FAILOPEN_FLAG=/run/v2raya-watchdog.failopen
LAST_RECOVER_ATTEMPT=/run/v2raya-watchdog.lastrecover
RECOVER_FAILS=/run/v2raya-watchdog.recover_fails
TRIED_RESTART=/run/v2raya-watchdog.tried_restart
LAST_RESTART=/run/v2raya-watchdog.lastrestart
CONF=/etc/v2raya/config.json

CN_REF1=223.5.5.5                            # 阿里 DNS
CN_REF2=119.29.29.29                         # 腾讯 DNS
KILL_AFTER=5                                # 连续失败次数，45s 一次 ≈ 3.5 分钟

# 本地链路检测（国内直连），只要一个通就算通
check_local_link() {
    timeout 3 bash -c "</dev/tcp/$CN_REF1/443" 2>/dev/null && return 0
    timeout 3 bash -c "</dev/tcp/$CN_REF2/443" 2>/dev/null && return 0
    return 1
}

# 隧道可用性检测：纯 IP，免 DNS 依赖；优先 1.1.1.1，失败回退 1.0.0.1
check_tunnel() {
    if curl -s --max-time 5 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null | grep -q '^ip='; then
        return 0
    fi
    if curl -s --max-time 5 "https://1.0.0.1/cdn-cgi/trace" 2>/dev/null | grep -q '^ip='; then
        return 0
    fi
    return 1
}

# 提取节点信息
get_node() {
    local n
    n=$(grep -oE '"vnext":\[\{"address":"[^"]+"' "$CONF" 2>/dev/null \
        | head -1 | sed 's/.*"address":"\([^"]*\)".*/\1/')
    if [ -z "$n" ]; then
        n=$(grep -oE '"vnext":\[\{"address":"[^"]+"' "$CONF" 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    echo "$n"
}

get_node_port() {
    local p
    p=$(grep -oE '"vnext":\[\{"address":"[^"]+","port":[0-9]+' "$CONF" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+$')
    echo "${p:-443}"
}

# 节点直连 TCP 可达性探测（不走代理）
check_node_reachable() {
    local n="$1"
    local p="$2"
    [ -z "$n" ] && return 1
    timeout 5 bash -c "</dev/tcp/$n/$p" 2>/dev/null
}

reset() {
    echo 0 >"$STATE" 2>/dev/null || true
    exit 0
}

cleanup_flags() {
    rm -f "$FAILOPEN_FLAG" "$LAST_RECOVER_ATTEMPT" "$RECOVER_FAILS" "$TRIED_RESTART" 2>/dev/null
}

fail_open() {
    logger -t v2raya-watchdog "$1; stopping v2raya to fail open"
    echo 0 >"$STATE" 2>/dev/null || true
    rm -f "$TRIED_RESTART" 2>/dev/null
    touch "$FAILOPEN_FLAG" 2>/dev/null || true
    systemctl stop v2raya
    exit 0
}

# ==========================================
# 分支一：v2raya 未在运行
# ==========================================
if ! systemctl is-active --quiet v2raya; then
    # 若不是由 watchdog fail-open 导致的停止（例如用户主动手动停止），不自动拉起
    if [ ! -f "$FAILOPEN_FLAG" ]; then
        reset
    fi

    # 如果服务被用户显式 disabled，清除状态并退出
    if ! systemctl is-enabled --quiet v2raya 2>/dev/null; then
        cleanup_flags
        reset
    fi

    # 1) 检查本地网络是否通畅
    if ! check_local_link; then
        logger -t v2raya-watchdog "fail-open hold: local link down, waiting"
        exit 0
    fi

    node=$(get_node)
    node_port=$(get_node_port)

    # 2) 检查远端节点 TCP 是否恢复可达
    if ! check_node_reachable "$node" "$node_port"; then
        # 节点 TCP 仍不通，继续维持直连状态
        exit 0
    fi

    # 3) 退避控制（Base 90s，每次失败 +60s，最大 600s）
    now=$(date +%s)
    last_recover=$(cat "$LAST_RECOVER_ATTEMPT" 2>/dev/null || echo 0)
    recover_fails=$(cat "$RECOVER_FAILS" 2>/dev/null || echo 0)
    case $recover_fails in ''|*[!0-9]*) recover_fails=0 ;; esac

    interval=$((90 + recover_fails * 60))
    [ "$interval" -gt 600 ] && interval=600

    if [ $((now - last_recover)) -lt "$interval" ]; then
        exit 0
    fi

    # 尝试唤醒测试
    echo "$now" > "$LAST_RECOVER_ATTEMPT" 2>/dev/null || true
    logger -t v2raya-watchdog "fail-open recovery: node ${node:-?}:${node_port} reachable, probing tunnel (attempt $((recover_fails + 1)))"

    systemctl start v2raya
    sleep 3

    if systemctl is-active --quiet v2raya && check_tunnel; then
        logger -t v2raya-watchdog "fail-back success: tunnel recovered, v2raya restored"
        cleanup_flags
        reset
    else
        recover_fails=$((recover_fails + 1))
        echo "$recover_fails" > "$RECOVER_FAILS" 2>/dev/null || true
        logger -t v2raya-watchdog "fail-back failed: tunnel still down; re-stopping v2raya to fail-open (retry in ${interval}s)"
        systemctl stop v2raya
        exit 0
    fi
fi

# ==========================================
# 分支二：v2raya 正在运行
# ==========================================

# 1) 本地/ISP 链路：链路问题不归节点背，也不停服
if ! check_local_link; then
    logger -t v2raya-watchdog "local link down (cannot reach CN DNS); holding"
    reset
fi

# 2) TProxy 存活检查：ip rule (fwmark 0xc0 lookup 100) + nft inet v2raya 表
#    任一丢失 → TProxy 被冲掉，重启 v2raya 自愈重建
if ! ip rule show 2>/dev/null | grep -q 'fwmark 0x[0-9a-f]*/0xc0 lookup 100' \
   || ! nft list table inet v2raya >/dev/null 2>&1; then
    now=$(date +%s)
    last=$(cat "$LAST_RESTART" 2>/dev/null || echo 0)
    if [ $((now - last)) -lt 60 ]; then
        logger -t v2raya-watchdog "TProxy still missing but restarted ${last} [${now-last}s ago]; holding"
        exit 0
    fi
    logger -t v2raya-watchdog "TProxy ip rule / nft table missing; restarting v2raya to rebuild"
    echo "$now" >"$LAST_RESTART" 2>/dev/null || true
    echo 0 >"$STATE" 2>/dev/null || true
    systemctl restart v2raya
    exit 0
fi

# 3) 隧道探测
if check_tunnel; then
    # 若此前有残留标记，说明已恢复健康，清除标记
    [ -f "$FAILOPEN_FLAG" ] && logger -t v2raya-watchdog "tunnel verified healthy, cleared fail-open state"
    cleanup_flags
    reset
fi

# 探针失败，计数累加
fails=$(cat "$STATE" 2>/dev/null || echo 0)
case $fails in ''|*[!0-9]*) fails=0 ;; esac
fails=$((fails + 1))
echo "$fails" >"$STATE" 2>/dev/null || true

# 4) 节点自身 TCP 可达性
node=$(get_node)
node_port=$(get_node_port)
node_dead=0
if ! check_node_reachable "$node" "$node_port"; then
    node_dead=1
fi

# 场景 A：节点 TCP 都不通 = 节点挂死，2 次失败即触发 fail-open
if [ "$node_dead" = 1 ] && [ "$fails" -ge 2 ]; then
    fail_open "node ${node:-?}:${node_port} unreachable x${fails}"
fi

# 场景 B：节点 TCP 通，但隧道不通（可能是 xray 进程连接池假死或网络阻断）
# 在达到停服阈值前（第 3 次失败时），先尝试 restart 一次自愈
if [ "$node_dead" = 0 ] && [ "$fails" -eq 3 ] && [ ! -f "$TRIED_RESTART" ]; then
    touch "$TRIED_RESTART" 2>/dev/null || true
    logger -t v2raya-watchdog "tunnel down x3 while node reachable; trying restart v2raya to heal"
    systemctl restart v2raya
    exit 0
fi

# 撑满阈值（KILL_AFTER=5）仍不通，进入 fail-open
if [ "$fails" -ge "$KILL_AFTER" ]; then
    fail_open "tunnel down x${fails} while node ${node:-?}:${node_port} still reachable"
fi

logger -t v2raya-watchdog "probe failed ${fails}/${KILL_AFTER} (node ${node:-?} dead=${node_dead}); waiting"
exit 0

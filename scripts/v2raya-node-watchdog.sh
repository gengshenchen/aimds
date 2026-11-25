#!/usr/bin/env bash
# v2raya-node-watchdog v5 (防封熔断安全版)
# 改进重点 (针对 2026-11 复盘的 v4 缺陷):
# 1. 彻底移除 0 字节裸 TCP 握手探测 (`</dev/tcp/$node/$port`)：
#    v4 在故障/恢复期频繁对 VPS 443 端口完成三次握手后不发 TLS ClientHello 直接断开，
#    产生强异常探测特征。v5 不再对远端节点发起裸 TCP 握手。
# 2. 低频随机化周期（配合 timer: 180s + RandomizedDelaySec=90s）：
#    消除 7x24 小时严格 45 秒固定周期的机械心跳特征。
# 3. 疑似被墙熔断机制 (Circuit Breaker)：
#    Fail-Back 指数退避拉长 (5m -> 10m -> 20m -> 40m -> 60m -> 60m)，最多重试 6 次。
#    达到上限后触发熔断停探 (写 TRIPPED_FLAG)，避免无限撞墙刷新 GFW 封锁计时器。
#    人工修复或手动 `systemctl start v2raya` 且隧道恢复健康后自动解除熔断。
# 4. 保留 TProxy 存活自愈、本地链路防误杀、停服前先 restart 一次自愈、双探针冗余。

set -u

STATE=/run/v2raya-watchdog.fails
FAILOPEN_FLAG=/run/v2raya-watchdog.failopen
TRIPPED_FLAG=/run/v2raya-watchdog.tripped
LAST_RECOVER_ATTEMPT=/run/v2raya-watchdog.lastrecover
RECOVER_FAILS=/run/v2raya-watchdog.recover_fails
TRIED_RESTART=/run/v2raya-watchdog.tried_restart
LAST_RESTART=/run/v2raya-watchdog.lastrestart

CN_REF1=223.5.5.5                            # 阿里 DNS (geoip:cn 直连)
CN_REF2=119.29.29.29                         # 腾讯 DNS (geoip:cn 直连)
KILL_AFTER=3                                 # 连续失败 3 次（~10-13 分钟）触发 fail-open
MAX_RECOVER_ATTEMPTS=6                       # Fail-Back 最多尝试 6 次（约 3 小时），超过则熔断停探

# 本地链路检测（国内直连），只要一个通就算通
check_local_link() {
    timeout 3 bash -c "</dev/tcp/$CN_REF1/443" 2>/dev/null && return 0
    timeout 3 bash -c "</dev/tcp/$CN_REF2/443" 2>/dev/null && return 0
    return 1
}

# 隧道可用性检测：纯 IP，免 DNS 依赖；优先 1.1.1.1，失败回退 1.0.0.1
check_tunnel() {
    if curl -s --max-time 6 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null | grep -q '^ip='; then
        return 0
    fi
    if curl -s --max-time 6 "https://1.0.0.1/cdn-cgi/trace" 2>/dev/null | grep -q '^ip='; then
        return 0
    fi
    return 1
}

backoff_seconds() {
    case "$1" in
        0) echo 300  ;;  # 5m
        1) echo 600  ;;  # 10m
        2) echo 1200 ;;  # 20m
        3) echo 2400 ;;  # 40m
        *) echo 3600 ;;  # 60m
    esac
}

reset() {
    echo 0 >"$STATE" 2>/dev/null || true
    exit 0
}

cleanup_flags() {
    rm -f "$FAILOPEN_FLAG" "$TRIPPED_FLAG" "$LAST_RECOVER_ATTEMPT" "$RECOVER_FAILS" "$TRIED_RESTART" 2>/dev/null
}

fail_open() {
    logger -t v2raya-watchdog "$1; stopping v2raya to fail open"
    echo 0 >"$STATE" 2>/dev/null || true
    rm -f "$TRIED_RESTART" 2>/dev/null
    touch "$FAILOPEN_FLAG" 2>/dev/null || true
    date +%s >"$LAST_RECOVER_ATTEMPT" 2>/dev/null || true
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

    # 已触发熔断：彻底静默，不再拉起撞墙，等待人工换节点或手动 start v2raya
    if [ -f "$TRIPPED_FLAG" ]; then
        exit 0
    fi

    # 1) 检查本地网络是否通畅
    if ! check_local_link; then
        logger -t v2raya-watchdog "fail-open hold: local link down, waiting"
        exit 0
    fi

    # 2) 指数退避 + 熔断上限检查（全程不发裸 TCP 探测！）
    now=$(date +%s)
    last_recover=$(cat "$LAST_RECOVER_ATTEMPT" 2>/dev/null || echo 0)
    recover_fails=$(cat "$RECOVER_FAILS" 2>/dev/null || echo 0)
    case $recover_fails in ''|*[!0-9]*) recover_fails=0 ;; esac

    if [ "$recover_fails" -ge "$MAX_RECOVER_ATTEMPTS" ]; then
        touch "$TRIPPED_FLAG" 2>/dev/null || true
        logger -t v2raya-watchdog "circuit breaker tripped after ${recover_fails} failed recoveries (node/IP may be blocked); halting auto-probes until manual restart"
        exit 0
    fi

    interval=$(backoff_seconds "$recover_fails")
    if [ $((now - last_recover)) -lt "$interval" ]; then
        exit 0
    fi

    # 3) 到达退避窗口：直接用正常 v2raya (完整 REALITY 握手) 探测一次
    echo "$now" > "$LAST_RECOVER_ATTEMPT" 2>/dev/null || true
    attempt=$((recover_fails + 1))
    logger -t v2raya-watchdog "fail-open recovery: probing tunnel via normal handshake (attempt ${attempt}/${MAX_RECOVER_ATTEMPTS})"

    systemctl start v2raya
    sleep 4

    if systemctl is-active --quiet v2raya && check_tunnel; then
        logger -t v2raya-watchdog "fail-back success: tunnel recovered, v2raya restored"
        cleanup_flags
        reset
    else
        recover_fails=$attempt
        echo "$recover_fails" > "$RECOVER_FAILS" 2>/dev/null || true
        systemctl stop v2raya
        if [ "$recover_fails" -ge "$MAX_RECOVER_ATTEMPTS" ]; then
            touch "$TRIPPED_FLAG" 2>/dev/null || true
            logger -t v2raya-watchdog "fail-back failed (${recover_fails}/${MAX_RECOVER_ATTEMPTS}); circuit breaker tripped, halting further probes"
        else
            next_iv=$(backoff_seconds "$recover_fails")
            logger -t v2raya-watchdog "fail-back failed (${recover_fails}/${MAX_RECOVER_ATTEMPTS}); re-stopped v2raya (next retry in ${next_iv}s)"
        fi
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
        logger -t v2raya-watchdog "TProxy still missing but restarted $((now - last))s ago; holding"
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
    if [ -f "$FAILOPEN_FLAG" ] || [ -f "$TRIPPED_FLAG" ]; then
        logger -t v2raya-watchdog "tunnel verified healthy, cleared fail-open/circuit-breaker state"
    fi
    cleanup_flags
    reset
fi

# 探针失败，计数累加
fails=$(cat "$STATE" 2>/dev/null || echo 0)
case $fails in ''|*[!0-9]*) fails=0 ;; esac
fails=$((fails + 1))
echo "$fails" >"$STATE" 2>/dev/null || true

# 4) 第 2 次失败：先尝试 restart 自愈一次（修复 xray 假死/连接池阻塞）
if [ "$fails" -eq 2 ] && [ ! -f "$TRIED_RESTART" ]; then
    touch "$TRIED_RESTART" 2>/dev/null || true
    logger -t v2raya-watchdog "tunnel down x${fails}; trying restart v2raya to heal"
    systemctl restart v2raya
    exit 0
fi

# 5) 撑满阈值（KILL_AFTER=3，约 10-13 分钟）仍不通，进入 fail-open
if [ "$fails" -ge "$KILL_AFTER" ]; then
    fail_open "tunnel down x${fails}"
fi

logger -t v2raya-watchdog "probe failed ${fails}/${KILL_AFTER}; waiting"
exit 0

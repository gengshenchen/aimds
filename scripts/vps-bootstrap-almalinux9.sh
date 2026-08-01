#!/usr/bin/env bash
# VLESS+REALITY 节点部署 + BBR 调优 + 加固 —— AlmaLinux 9 适配版
# 源手册: https://github.com/gengshenchen/aimds/blob/main/proxy-runbook.md
# 已验证: 搬瓦工 AlmaLinux 9.7 / kernel 5.14 / 2C1G / 洛杉矶 (2026-08)
#
# 与手册的差异(EL9 必须改, 否则命令直接报错):
#   apt-get -> dnf | ufw -> firewalld | restart ssh -> restart sshd | fail2ban 需 EPEL
#
# 用法(在 VPS 上以 root 执行):
#   bash vps-bootstrap-almalinux9.sh check       # 只体检, 不改任何东西
#   bash vps-bootstrap-almalinux9.sh node        # 手册 1.1-1.5 装 Xray + REALITY
#   bash vps-bootstrap-almalinux9.sh tune        # 手册 6.3 BBR + TCP 缓冲区
#   bash vps-bootstrap-almalinux9.sh secure      # 手册 1.7 firewalld/fail2ban/装公钥/更新
#   bash vps-bootstrap-almalinux9.sh selftest    # 手册 1.6 服务端本机自测
#   bash vps-bootstrap-almalinux9.sh link        # 重印 vless:// 链接
#   bash vps-bootstrap-almalinux9.sh harden-ssh  # ★另开终端确认密钥可登后才跑: 关密码登录
#   bash vps-bootstrap-almalinux9.sh all         # check+node+tune+secure+selftest+link
#
# 环境变量: SNI= PORT= NODE_NAME= SSH_PUBKEY=
set -euo pipefail

SNI="${SNI:-www.tesla.com}"
PORT="${PORT:-443}"
NODE_NAME="${NODE_NAME:-BWG-LA}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
XRAY=/usr/local/bin/xray
CFG=/usr/local/etc/xray/config.json
CREDS=/root/reality-creds.txt

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

case "${1:-help}" in
  help|-h|--help) ;;                                  # help 不需要 root
  *) [[ $EUID -eq 0 ]] || die "需要 root" ;;
esac

server_ip() {
  local ip
  ip=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
  [[ -n $ip ]] || ip=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
  [[ -n $ip ]] || die "取不到公网 IP"
  echo "$ip"
}

sshd_port() {
  # 不能用 awk 的 exit + pipefail: awk 先退出会让 sshd -T 吃 SIGPIPE,
  # 整条管道被判失败 -> 兜底的 echo 也执行 -> 返回 "22\n22" 污染后续 --add-port
  local out p
  out=$(sshd -T 2>/dev/null | awk '/^port /{print $2}') || true
  p=${out%%$'\n'*}
  [[ $p =~ ^[0-9]+$ ]] || p=22
  echo "$p"
}

do_check() {   # 手册 6.2 体检
  say "系统体检"
  printf '   OS       : %s\n' "$(source /etc/os-release; echo "$PRETTY_NAME")"
  printf '   kernel   : %s  (BBR 需 >= 4.9)\n' "$(uname -r)"
  printf '   mem      : %s\n' "$(free -h | awk '/^Mem:/{print $2" total, "$7" avail"}')"
  printf '   SELinux  : %s\n' "$(getenforce 2>/dev/null || echo n/a)"
  printf '   sshd port: %s\n' "$(sshd_port)"
  printf '   pubip    : %s\n' "$(server_ip)"
  say "TCP 现状 (208992 = 裸默认, 必须调)"
  for k in net.ipv4.tcp_congestion_control net.core.default_qdisc \
           net.core.rmem_max net.core.wmem_max net.ipv4.tcp_slow_start_after_idle; do
    printf '   %-40s = %s\n' "$k" "$(sysctl -n $k 2>/dev/null || echo n/a)"
  done
  say "对外监听端口 (加固后应只剩 sshd + xray)"
  ss -tlnp | grep -vE '127\.0\.0\.1|\[::1\]' || true
  say "可疑进程排查 (手册 5.6: 冒充内核线程的矿马)"
  # 真内核线程 PPID=2 且 RES=0; 反之 exe 指向 /tmp /dev/shm /etc 即木马
  local bad=0
  for p in $(ps -eo pid --no-headers); do
    local exe; exe=$(readlink -f "/proc/$p/exe" 2>/dev/null || true)
    [[ -n $exe ]] || continue
    if [[ $exe =~ ^/(tmp|dev/shm|var/tmp)/ ]]; then
      warn "可疑: pid=$p exe=$exe cmd=$(tr -d '\0' </proc/$p/cmdline 2>/dev/null)"; bad=1
    fi
  done
  [[ $bad -eq 0 ]] && ok "无进程从 /tmp /dev/shm /var/tmp 运行"
  printf '   CPU 占用 top3: %s\n' "$(ps -eo pcpu,comm --sort=-pcpu --no-headers | head -3 | tr '\n' ' ')"
}

do_node() {    # 手册 1.1-1.5
  say "安装依赖"
  # 必需项与可选项分开: qrencode 在 EL9 base 源没有(要 EPEL),
  # 混在一条 dnf 里会因它装不上而触发 set -e, 把整个部署卡死在第一步
  dnf -y install -q curl openssl tar >/dev/null && ok "curl/openssl/tar"
  if dnf -y install -q qrencode >/dev/null 2>&1; then ok "qrencode (二维码可用)"
  else warn "qrencode 装不上(需 EPEL), 只输出文本链接, 不影响部署"; fi

  say "安装官方 Xray (手册 1.1)"
  if [[ -x $XRAY ]]; then ok "已存在: $($XRAY version | head -1)"
  else
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    [[ -x $XRAY ]] || die "Xray 安装失败"
    ok "$($XRAY version | head -1)"
  fi

  if [[ -f $CFG ]] && grep -q '"privateKey"' "$CFG"; then
    warn "配置已存在, 跳过凭据生成 (要重建先 mv $CFG); 权限校正与重启仍会执行"
  else
  # --- 以下仅在没有配置时执行 ---
  say "生成凭据 (手册 1.2: 每台机重新生成, 绝不跨机复用)"
  local keys priv pub uuid sid
  keys=$($XRAY x25519)
  priv=$(echo "$keys" | grep -iE '^(private|PrivateKey)' | awk '{print $NF}')
  pub=$(echo  "$keys" | grep -iE '^(password|public)'    | awk '{print $NF}')
  uuid=$($XRAY uuid)
  sid=$(openssl rand -hex 8)
  [[ -n $priv && -n $pub && -n $uuid && -n $sid ]] || die "凭据生成失败"
  ok "已生成 (私钥不回显, 存 $CREDS)"

  say "写配置 $CFG (手册 1.3)"
  mkdir -p "$(dirname "$CFG")"
  cat > "$CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0", "port": $PORT, "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$uuid", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "dest": "$SNI:443", "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$priv",
        "shortIds": ["$sid"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
  chmod 600 "$CFG"

  { echo "# $(date -Is)  生成于 $(hostname)"
    echo "PRIVATE_KEY=$priv"; echo "PUBLIC_KEY=$pub"
    echo "UUID=$uuid"; echo "SHORT_ID=$sid"
    echo "SNI=$SNI"; echo "PORT=$PORT"; } > "$CREDS"
  chmod 600 "$CREDS"     # 凭据备份: root 独占, 服务不需要读它
  fi
  # --- 以上仅在没有配置时执行 ---

  say "校正配置权限 (官方单元跑 User=nobody)"
  # 600 root:root 会让 xray 读不到自己的配置(Configuration OK 是 root 跑的, 骗过校验),
  # 服务起来后报 permission denied。用 640 root:nobody: 服务可读, 但不给 world 读(内含 privateKey)
  local svc_user
  svc_user=$(awk -F= '/^User=/{print $2; exit}' /etc/systemd/system/xray.service 2>/dev/null)
  svc_user=${svc_user:-nobody}
  chown "root:${svc_user}" "$CFG"
  chmod 640 "$CFG"
  runuser -u "$svc_user" -- test -r "$CFG" \
    && ok "$svc_user 可读 config.json ($(stat -c '%U:%G %a' "$CFG"))" \
    || die "$svc_user 仍读不到 $CFG"

  say "校验并启动 (手册 1.4)"
  $XRAY run -test -config "$CFG" | tail -2 | grep -q 'Configuration OK' || die "配置校验未通过"
  ok "Configuration OK"
  systemctl enable --now xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 2
  [[ $(systemctl is-active xray) == active ]] || die "xray 未启动: $(journalctl -u xray -n 20 --no-pager)"
  ok "xray active, 监听: $(ss -tlnp | grep ":$PORT " | head -1 | awk '{print $4}')"
}

do_tune() {    # 手册 6.3 —— 优先级高于一切排错
  say "BBR + TCP 调优 (手册 6.3)"
  # RTT 163ms(实测) x 50Mbps => BDP ~1.02MB; 默认 208KB 天花板仅 ~10Mbps
  modprobe tcp_bbr 2>/dev/null || warn "modprobe tcp_bbr 失败(可能已内建)"
  echo tcp_bbr > /etc/modules-load.d/bbr.conf
  cat > /etc/sysctl.d/99-network-tuning.conf <<'EOF'
# ---- BBR + fq ----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ---- 缓冲区: 匹配高延迟跨境链路 BDP (163ms RTT) ----
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# ---- 高延迟链路优化 ----
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384

# ---- 代理场景多并发 ----
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 10000 65000
fs.file-max = 1048576
EOF
  sysctl -p /etc/sysctl.d/99-network-tuning.conf >/dev/null
  local cc qd
  cc=$(sysctl -n net.ipv4.tcp_congestion_control); qd=$(sysctl -n net.core.default_qdisc)
  [[ $cc == bbr ]] && ok "congestion_control = bbr" || die "BBR 没生效 (=$cc)"
  [[ $qd == fq  ]] && ok "default_qdisc = fq"      || warn "qdisc = $qd"
  ok "rmem_max = $(sysctl -n net.core.rmem_max)"
  warn "效果只能从中国这端测, 服务端本地测速看不出来 (手册 6.5)"
  echo "   回滚: rm /etc/sysctl.d/99-network-tuning.conf && sysctl --system"
}

do_secure() {  # 手册 1.7, EL9 版
  local sp; sp=$(sshd_port)

  say "放公钥 (手册 1.7a)"
  if [[ -n $SSH_PUBKEY ]]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    grep -qF "$SSH_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null \
      || echo "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    restorecon -R /root/.ssh 2>/dev/null || true   # EL9: SELinux 上下文, 漏了会拒绝公钥登录
    ok "已装入, authorized_keys 共 $(wc -l < /root/.ssh/authorized_keys) 条"
  else
    warn "未传 SSH_PUBKEY, 跳过 (稍后务必手动装, 否则不能关密码登录)"
  fi

  say "防火墙 firewalld (EL9 无 ufw)"
  dnf -y install -q firewalld >/dev/null 2>&1 || true
  systemctl enable --now firewalld >/dev/null || die "firewalld 起不来: journalctl -u firewalld -n 20"
  for i in $(seq 1 10); do firewall-cmd --state >/dev/null 2>&1 && break; sleep 1; done
  firewall-cmd --state >/dev/null 2>&1 || die "firewalld 未就绪"
  ok "firewalld running"
  # ★ --set-default-zone 是 stand-alone 选项, 不能和 --permanent 连用(它本身就是永久的),
  #   连用会报 "Can't use stand-alone options with other options" 并中断整个加固
  firewall-cmd --set-default-zone=public >/dev/null
  firewall-cmd --permanent --add-port="${sp}/tcp"   >/dev/null   # SSH
  firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null   # REALITY
  # 只留这两个, 其余服务全撤(含 cockpit/dhcpv6-client 等默认放行项)
  for s in $(firewall-cmd --permanent --list-services); do
    [[ $s == ssh ]] && continue
    firewall-cmd --permanent --remove-service="$s" >/dev/null 2>&1 || true
  done
  firewall-cmd --reload >/dev/null
  ok "放行: $(firewall-cmd --list-ports) + service $(firewall-cmd --list-services)"

  say "fail2ban (EL9 需先装 EPEL)"
  dnf -y install -q epel-release >/dev/null 2>&1 || true
  # python3-systemd 是 backend=systemd 的硬依赖, EL9 上缺了 fail2ban 直接起不来
  if dnf -y install -q fail2ban fail2ban-firewalld python3-systemd >/dev/null 2>&1; then
    cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port    = $sp
backend = systemd
maxretry = 4
findtime = 600
bantime  = 86400
EOF
    systemctl enable --now fail2ban >/dev/null 2>&1
    sleep 2
    [[ $(systemctl is-active fail2ban) == active ]] && ok "fail2ban active (sshd jail, ban 24h)" \
      || warn "fail2ban 起不来: journalctl -u fail2ban -n 20"
  else
    warn "fail2ban 装不上 (EPEL 不可用?), 跳过"
  fi

  say "系统更新"
  dnf -y -q update >/dev/null && ok "已更新" || warn "更新有告警, 检查 dnf update 输出"

  say "验证加固 (手册 1.7: 对外应只有 SSH + $PORT)"
  ss -tlnp | grep -vE '127\.0\.0\.1|\[::1\]' || true
  warn "★ 密码登录还开着。另开终端确认密钥能登进来后, 再跑: bash $0 harden-ssh"
}

do_harden_ssh() {   # 手册 1.7b —— 单独一步, 防把自己锁在外面
  say "关闭密码登录 (手册 1.7b)"
  [[ -s /root/.ssh/authorized_keys ]] || die "authorized_keys 为空, 关了密码就再也登不进来。先装公钥。"
  printf '\033[33m确认你已经用【密钥】成功登录过一次? 输入 yes 继续: \033[0m'
  read -r a; [[ $a == yes ]] || die "已取消"
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
  # EL9 的 50-redhat.conf / cloud-init drop-in 会覆盖主文件, 所以写 drop-in 且用最大序号
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
MaxAuthTries 3
EOF
  sshd -t || die "sshd 配置语法错误, 已中止 (原配置未动)"
  systemctl restart sshd
  sleep 1
  sshd -T | grep -iE '^(passwordauthentication|permitrootlogin)' | sed 's/^/   /'
  ok "已关闭密码登录。★ 现在别退出这个会话, 先另开终端验证能登进去。"
}

do_selftest() {  # 手册 1.6 —— 绕开 GFW 证明节点本身没问题
  say "服务端本机自测 (手册 1.6)"
  [[ -f $CREDS ]] || die "找不到 $CREDS, 先跑 node"
  local uuid pub sid sni ip
  uuid=$(grep '^UUID='       "$CREDS" | cut -d= -f2)
  pub=$(grep  '^PUBLIC_KEY=' "$CREDS" | cut -d= -f2)
  sid=$(grep  '^SHORT_ID='   "$CREDS" | cut -d= -f2)
  sni=$(grep  '^SNI='        "$CREDS" | cut -d= -f2)
  ip=$(server_ip)
  local t=/tmp/selftest.$$.json
  cat > "$t" <<EOF
{ "inbounds":[{"listen":"127.0.0.1","port":10999,"protocol":"socks","settings":{"udp":true}}],
  "outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"$ip","port":$PORT,
    "users":[{"id":"$uuid","encryption":"none","flow":"xtls-rprx-vision"}]}]},
    "streamSettings":{"network":"tcp","security":"reality","realitySettings":{
      "serverName":"$sni","fingerprint":"chrome","publicKey":"$pub","shortId":"$sid"}}}]}
EOF
  nohup $XRAY run -config "$t" >/tmp/selftest.$$.log 2>&1 &
  local pid=$!
  sleep 3
  local code
  code=$(curl -s --socks5-hostname 127.0.0.1:10999 --max-time 15 \
         -o /dev/null -w '%{http_code}' https://www.google.com || echo 000)
  kill $pid 2>/dev/null || true; rm -f "$t" /tmp/selftest.$$.log
  if [[ $code =~ ^(200|204|301|302)$ ]]; then ok "google:$code → 节点 100% 正常"
  else die "google:$code → 隧道不通, 看 journalctl -u xray -n 30"; fi

  say "隧道内吞吐 (VPS 本地到国际, 手册 5.1②)"
  curl -s -o /dev/null --max-time 30 -w '   VPS本地: %{speed_download} B/s\n' \
    "https://speed.cloudflare.com/__down?bytes=50000000" || warn "测速失败"
}

do_link() {    # 手册 1.5
  [[ -f $CREDS ]] || die "找不到 $CREDS, 先跑 node"
  local uuid pub sid sni ip
  uuid=$(grep '^UUID='       "$CREDS" | cut -d= -f2)
  pub=$(grep  '^PUBLIC_KEY=' "$CREDS" | cut -d= -f2)
  sid=$(grep  '^SHORT_ID='   "$CREDS" | cut -d= -f2)
  sni=$(grep  '^SNI='        "$CREDS" | cut -d= -f2)
  ip=$(server_ip)
  local link="vless://${uuid}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp&headerType=none#${NODE_NAME}"
  say "分享链接 (手册 1.5) —— 含 UUID, 别外发"
  echo "$link"
  command -v qrencode >/dev/null && { echo; qrencode -t ANSIUTF8 "$link"; }
}


case "${1:-help}" in
  check)      do_check ;;
  node)       do_node ;;
  tune)       do_tune ;;
  secure)     do_secure ;;
  selftest)   do_selftest ;;
  link)       do_link ;;
  harden-ssh) do_harden_ssh ;;
  all)        do_check; do_node; do_tune; do_secure; do_selftest; do_link
              say "完成"
              echo "   下一步: ①客户端导入上面链接并实测 ②确认密钥登录 OK 后跑 '$0 harden-ssh'" ;;
  *)          sed -n '2,26p' "$0" ;;
esac

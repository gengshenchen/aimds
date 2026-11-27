#!/usr/bin/env bash
# VLESS+REALITY 节点部署 + BBR 调优 + 加固 —— AlmaLinux 9 适配版 (v2 防封加固)
# 源手册: https://github.com/gengshenchen/aimds/blob/main/proxy-runbook.md
# 已验证: 搬瓦工 AlmaLinux 9.7/9.8 / kernel 5.14 / 2C1G / 洛杉矶 DC6 CN2 GIA-E (2026-11)
#
# 与手册的差异(EL9 必须改, 否则命令直接报错):
#   apt-get -> dnf | ufw -> firewalld | restart ssh -> restart sshd | fail2ban 需 EPEL
#
# 用法(在 VPS 上以 root 执行):
#   bash vps-bootstrap-almalinux9.sh check       # 只体检, 不改任何东西
#   bash vps-bootstrap-almalinux9.sh node        # 手册 1.1-1.5 装 Xray + REALITY (已存在配置则跳过轮换)
#   bash vps-bootstrap-almalinux9.sh rotate      # 换 IP / 换 SNI / 凭据泄露时强制全套轮换
#   bash vps-bootstrap-almalinux9.sh tune        # 手册 6.3 BBR + TCP 缓冲区 (已修复 tcp_mem 单位坑)
#   bash vps-bootstrap-almalinux9.sh secure      # 手册 1.7 firewalld/fail2ban/装公钥/更新
#   bash vps-bootstrap-almalinux9.sh selftest    # 手册 1.6 服务端本机自测 (含 google:200 + 回国拦截验证)
#   bash vps-bootstrap-almalinux9.sh link        # 重印 vless:// 链接
#   bash vps-bootstrap-almalinux9.sh cf-backup   # ★可选: 加 Cloudflare CDN 备用通道 (独立 xray@cf, 8443 仅放行 CF IP)
#   bash vps-bootstrap-almalinux9.sh harden-ssh  # ★另开终端确认密钥可登后才跑: 关密码登录 (可选改端口)
#   bash vps-bootstrap-almalinux9.sh all         # check+node+tune+secure+selftest+link
#
# 环境变量: SNI= PORT= NODE_NAME= SSH_PUBKEY= NEW_SSH_PORT= CF_HOST= CF_ORIGIN_PORT=
set -euo pipefail

# ★ 切勿使用 www.tesla.com / www.icloud.com 等 Akamai/Cloudflare 大 CDN 或全网默认 SNI:
#   实测 www.tesla.com 对机房 IP 返回 403 AkamaiGHost + h3, 易暴露且存在 CDN 回落被白嫖风险。
#   默认选加州伯克利独立高校镜像站(非大 CDN, TLS1.3+X25519+H2, HTTP 200), 建议按机房位置自定义。
SNI="${SNI:-mirrors.ocf.berkeley.edu}"
PORT="${PORT:-443}"
NODE_NAME="${NODE_NAME:-BWG-GIA}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
NEW_SSH_PORT="${NEW_SSH_PORT:-}"
CF_HOST="${CF_HOST:-}"
CF_ORIGIN_PORT="${CF_ORIGIN_PORT:-8443}"
XRAY=/usr/local/bin/xray
CFG=/usr/local/etc/xray/config.json
CREDS=/root/reality-creds.txt
SHOW_LINK=/root/show-link.sh

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

verify_sni() {
  local d="$1"
  say "验货 REALITY 伪装目标: $d"
  local tls http_out code srv
  tls=$(timeout 8 openssl s_client -connect "${d}:443" -servername "${d}" -alpn h2,http/1.1 </dev/null 2>&1 || true)
  echo "$tls" | grep -q 'TLSv1\.3'          || die "$d 不支持 TLSv1.3, 换一个目标 (SNI=...)"
  echo "$tls" | grep -qi 'X25519'           || die "$d 不支持 X25519, 换一个目标 (SNI=...)"
  echo "$tls" | grep -q 'ALPN protocol: h2' || die "$d 不支持 HTTP/2 (ALPN h2), 换一个目标 (SNI=...)"

  http_out=$(curl -4 -svI --tlsv1.3 --max-time 8 "https://${d}/" 2>&1 || true)
  code=$(echo "$http_out" | awk '/^< HTTP\//{print $3; exit}')
  srv=$(echo "$http_out" | grep -i '^< server:' | head -1 | cut -d: -f2- | tr -d '\r' | xargs || true)
  if [[ "$code" != "200" ]]; then
    die "$d 返回 HTTP ${code:-000} (不是 200; 若为 403/301/302 会暴露或触发 WAF), 请换 SNI="
  fi
  if echo "$srv" | grep -qiE 'Akamai|cloudflare'; then
    warn "$d 位于大厂 CDN ($srv), 存在回落被白嫖或 WAF 风险, 强烈建议换独立站"
  else
    ok "$d 验货通过: TLSv1.3 + X25519 + h2 + HTTP 200 (server=${srv:-unknown})"
  fi
}

write_config_and_creds() {
  verify_sni "$SNI"

  say "确认 NTP 时钟同步 (供 maxTimeDiff 防重放)"
  systemctl enable --now chronyd >/dev/null 2>&1 || timedatectl set-ntp true >/dev/null 2>&1 || true
  ok "$(timedatectl status 2>/dev/null | grep -i 'synchronized' | xargs || echo 'NTP check skipped')"

  say "生成全新凭据 (手册 1.2: 每台机/每次换 IP 重新生成, 绝不复用)"
  local keys priv pub uuid sid
  keys=$($XRAY x25519)
  priv=$(echo "$keys" | grep -iE '^(private|PrivateKey)' | awk '{print $NF}')
  pub=$(echo  "$keys" | grep -iE '^(password|public)'    | awk '{print $NF}')
  uuid=$($XRAY uuid)
  sid=$(openssl rand -hex 8)
  [[ -n $priv && -n $pub && -n $uuid && -n $sid ]] || die "凭据生成失败"
  ok "已生成 (私钥不回显, 存 $CREDS)"

  [[ -f $CFG   ]] && cp "$CFG"   "/root/config.json.bak.$(date +%s)"
  [[ -f $CREDS ]] && cp "$CREDS" "/root/reality-creds.txt.bak.$(date +%s)"

  say "写加固版配置 $CFG (手册 1.3)"
  mkdir -p "$(dirname "$CFG")"
  cat > "$CFG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "::",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$uuid", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "target": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$priv",
        "shortIds": ["$sid"],
        "maxTimeDiff": 120000
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private", "geoip:cn"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
  chmod 600 "$CFG"

  { echo "# $(date -Is)  生成于 $(hostname)"
    echo "PRIVATE_KEY=$priv"; echo "PUBLIC_KEY=$pub"
    echo "UUID=$uuid"; echo "SHORT_ID=$sid"
    echo "SNI=$SNI"; echo "PORT=$PORT"; } > "$CREDS"
  chmod 600 "$CREDS"     # 凭据备份: root 独占, 服务不需要读它

  cat > "$SHOW_LINK" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$CREDS"
IP="\${1:-\$(curl -4fsS --max-time 8 https://api.ipify.org)}"
LINK="vless://\${UUID}@\${IP}:\${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=\${SNI}&fp=chrome&pbk=\${PUBLIC_KEY}&sid=\${SHORT_ID}&type=raw&headerType=none#${NODE_NAME}"
echo "\$LINK"
command -v qrencode >/dev/null 2>&1 && { echo; qrencode -t ANSIUTF8 "\$LINK"; } || true
SH
  chmod 700 "$SHOW_LINK"
}

fix_perms_and_start() {
  say "校正配置权限 (官方单元 v26.11+ 用 User=xray, 旧版用 User=nobody)"
  # 600 root:root 会让服务用户读不到自己的配置(Configuration OK 是 root 跑的, 骗过校验),
  # 用 640 root:<svc_user>: 服务可读, 但不给 world 读(内含 privateKey)
  local svc_user
  svc_user=$(awk -F= '/^User=/{print $2; exit}' /etc/systemd/system/xray.service 2>/dev/null || true)
  svc_user=${svc_user:-nobody}
  chown "root:${svc_user}" "$CFG"
  chmod 640 "$CFG"
  runuser -u "$svc_user" -- test -r "$CFG" \
    && ok "$svc_user 可读 config.json ($(stat -c '%U:%G %a' "$CFG"))" \
    || die "$svc_user 仍读不到 $CFG"

  say "校验并启动 (手册 1.4)"
  $XRAY run -test -config "$CFG" | tail -3 | grep -q 'Configuration OK' || die "配置校验未通过"
  ok "Configuration OK"
  systemctl enable --now xray >/dev/null 2>&1 || true
  systemctl restart xray
  sleep 2
  [[ $(systemctl is-active xray) == active ]] || die "xray 未启动: $(journalctl -u xray -n 20 --no-pager)"
  ok "xray active, 监听: $(ss -tlnp | grep ":$PORT " | head -1 | awk '{print $4}')"
}

do_check() {   # 手册 6.2 体检
  say "系统体检"
  printf '   OS       : %s\n' "$(source /etc/os-release; echo "$PRETTY_NAME")"
  printf '   kernel   : %s  (BBR 需 >= 4.9)\n' "$(uname -r)"
  printf '   mem      : %s\n' "$(free -h | awk '/^Mem:/{print $2" total, "$7" avail"}')"
  printf '   SELinux  : %s\n' "$(getenforce 2>/dev/null || echo n/a)"
  printf '   NTP      : %s\n' "$(timedatectl status 2>/dev/null | grep -i 'synchronized' | xargs || echo n/a)"
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
  dnf -y install -q curl openssl tar >/dev/null && ok "curl/openssl/tar"
  if dnf -y install -q qrencode >/dev/null 2>&1; then ok "qrencode (二维码可用)"
  else warn "qrencode 装不上(需 EPEL), 只输出文本链接, 不影响部署"; fi

  say "安装/升级官方 Xray (手册 1.1)"
  if [[ -x $XRAY ]]; then ok "已存在: $($XRAY version | head -1)"
  else
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    [[ -x $XRAY ]] || die "Xray 安装失败"
    ok "$($XRAY version | head -1)"
  fi

  if [[ -f $CFG ]] && grep -q '"privateKey"' "$CFG"; then
    warn "配置已存在, 跳过凭据生成 (换 IP/换 SNI 请跑 '$0 rotate'); 权限校正与重启仍会执行"
  else
    write_config_and_creds
  fi

  fix_perms_and_start
}

do_rotate() {  # 换 IP / 换 SNI / 凭据泄露时强制全套轮换
  say "升级 Xray + 强制轮换全套凭据与配置"
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  [[ -x $XRAY ]] || die "Xray 安装失败"
  ok "$($XRAY version | head -1)"
  write_config_and_creds
  fix_perms_and_start
}

do_tune() {    # 手册 6.3 —— 优先级高于一切排错
  say "BBR + TCP 调优 (手册 6.3)"
  # RTT 163ms(实测) x 50Mbps => BDP ~1.02MB; 默认 208KB 天花板仅 ~10Mbps
  # ★ 切勿硬写 net.ipv4.tcp_mem (单位是 4KB 内存页不是字节, 1G 内存小鸡乱写会失去回收保护导致 OOM)
  # ★ 切勿盲开 net.ipv4.tcp_fastopen=3 (跨境中间箱对 TFO 兼容差)
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
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# ---- 高延迟链路优化 ----
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
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
  firewall-cmd --set-default-zone=public >/dev/null
  firewall-cmd --permanent --add-port="${sp}/tcp"   >/dev/null   # SSH
  firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null   # REALITY
  for s in $(firewall-cmd --permanent --list-services); do
    [[ $s == ssh && $sp == 22 ]] && continue
    firewall-cmd --permanent --remove-service="$s" >/dev/null 2>&1 || true
  done
  firewall-cmd --reload >/dev/null
  ok "放行: $(firewall-cmd --list-ports) + service $(firewall-cmd --list-services)"

  say "fail2ban (EL9 需先装 EPEL)"
  dnf -y install -q epel-release >/dev/null 2>&1 || true
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
    [[ $(systemctl is-active fail2ban) == active ]] && ok "fail2ban active (sshd jail port=$sp, ban 24h)" \
      || warn "fail2ban 起不来: journalctl -u fail2ban -n 20"
  else
    warn "fail2ban 装不上 (EPEL 不可用?), 跳过"
  fi

  say "系统更新"
  dnf -y -q update >/dev/null && ok "已更新" || warn "更新有告警, 检查 dnf update 输出"

  say "验证加固 (手册 1.7: 对外应只有 SSH + $PORT)"
  ss -tlnp | grep -vE '127\.0\.0\.1|\[::1\]' || true
  warn "★ 密码登录还开着。另开终端确认密钥能登进来后, 再跑: NEW_SSH_PORT=28422 bash $0 harden-ssh"
}

do_harden_ssh() {   # 手册 1.7b —— 单独一步, 防把自己锁在外面
  say "关闭密码登录 (手册 1.7b)"
  [[ -s /root/.ssh/authorized_keys ]] || die "authorized_keys 为空, 关了密码就再也登不进来。先装公钥。"
  printf '\033[33m确认你已经用【密钥】成功登录过一次? 输入 yes 继续: \033[0m'
  read -r a; [[ $a == yes ]] || die "已取消"
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"

  local old_p target_p
  old_p=$(sshd_port)
  target_p="${NEW_SSH_PORT:-$old_p}"

  if [[ "$target_p" != "$old_p" ]]; then
    say "改 SSH 端口: $old_p -> $target_p (先放行新端口, 验证后再手动关旧端口)"
    firewall-cmd --permanent --add-port="${target_p}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    semanage port -a -t ssh_port_t -p tcp "$target_p" 2>/dev/null || true
    sed -i "s/^[[:space:]]*Port[[:space:]]\+${old_p}\b/#Port ${old_p}/" /etc/ssh/sshd_config
  fi

  # ★ EL9 sshd 按字典序读 drop-in 且【首个匹配生效】!
  #   必须用 00-hardening.conf 排在 50-redhat.conf 之前, 用 99- 可能被 50-redhat.conf 覆盖。
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
Port ${target_p}
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
MaxAuthTries 3
EOF
  chmod 600 /etc/ssh/sshd_config.d/00-hardening.conf
  rm -f /etc/ssh/sshd_config.d/99-hardening.conf

  sshd -t || die "sshd 配置语法错误, 已中止"
  systemctl restart sshd
  sleep 1
  sshd -T | grep -iE '^(port|passwordauthentication|permitrootlogin|kbdinteractiveauthentication) ' | sed 's/^/   /'

  if [[ -f /etc/fail2ban/jail.d/sshd.local && "$target_p" != "$old_p" ]]; then
    sed -i "s/^port *= *.*/port    = ${target_p}/" /etc/fail2ban/jail.d/sshd.local
    systemctl restart fail2ban >/dev/null 2>&1 || true
  fi

  ok "已关闭密码登录 (端口 ${target_p})。★ 现在别退出当前会话, 先另开终端验证 ssh -p ${target_p} 能登进去。"
  if [[ "$target_p" != "$old_p" ]]; then
    warn "新端口验证通过后, 再手动封掉旧端口 ${old_p}:"
    echo "   firewall-cmd --permanent --remove-port=${old_p}/tcp; firewall-cmd --permanent --remove-service=ssh; firewall-cmd --reload"
  fi
}

do_selftest() {  # 手册 1.6 —— 绕开 GFW 证明节点本身没问题 + 验证回国拦截
  say "服务端本机自测 (手册 1.6)"
  [[ -f $CREDS ]] || die "找不到 $CREDS, 先跑 node"
  local uuid pub sid sni
  uuid=$(grep '^UUID='       "$CREDS" | cut -d= -f2)
  pub=$(grep  '^PUBLIC_KEY=' "$CREDS" | cut -d= -f2)
  sid=$(grep  '^SHORT_ID='   "$CREDS" | cut -d= -f2)
  sni=$(grep  '^SNI='        "$CREDS" | cut -d= -f2)
  local t=/tmp/selftest.$$.json
  cat > "$t" <<EOF
{ "inbounds":[{"listen":"127.0.0.1","port":10999,"protocol":"socks","settings":{"udp":true}}],
  "outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":$PORT,
    "users":[{"id":"$uuid","encryption":"none","flow":"xtls-rprx-vision"}]}]},
    "streamSettings":{"network":"raw","security":"reality","realitySettings":{
      "serverName":"$sni","fingerprint":"chrome","publicKey":"$pub","shortId":"$sid"}}}]}
EOF
  nohup $XRAY run -config "$t" >/tmp/selftest.$$.log 2>&1 &
  local pid=$!
  sleep 2
  local code cncode
  code=$(curl -s --socks5-hostname 127.0.0.1:10999 --max-time 15 \
         -o /dev/null -w '%{http_code}' https://www.google.com || echo 000)
  cncode=$(curl -s --socks5-hostname 127.0.0.1:10999 --max-time 6 \
         -o /dev/null -w '%{http_code}' https://223.5.5.5 || echo 000)
  kill $pid 2>/dev/null || true; rm -f "$t" /tmp/selftest.$$.log
  if [[ $code =~ ^(200|204|301|302)$ ]]; then ok "google:$code → 节点 100% 正常"
  else die "google:$code → 隧道不通, 看 journalctl -u xray -n 30"; fi
  if [[ $cncode == 000* ]]; then ok "cn_block:$cncode → 服务端 geoip:cn 回国拦截生效"
  else warn "cn_block:$cncode → 服务端未能拦截国内 IP, 检查 routing 规则与 geoip.dat"; fi

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
  local link="vless://${uuid}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=raw&headerType=none#${NODE_NAME}"
  say "分享链接 (手册 1.5) —— 含 UUID, 别外发"
  echo "$link"
  command -v qrencode >/dev/null && { echo; qrencode -t ANSIUTF8 "$link"; } || true
}


do_cf_backup() {  # EL9 手册第 7 节: 独立 xray@cf 备用通道 (8443 仅放行 Cloudflare 回源 IP)
  [[ -n $CF_HOST ]] || die "请传入 CF_HOST=sync.yourdomain.com"
  [[ -x $XRAY ]] || die "未找到 $XRAY, 先跑 node 装 Xray"

  say "配置 firewalld Cloudflare 官方回源 IP 白名单 (仅放行 ${CF_ORIGIN_PORT}/tcp)"
  local cf_v4 cf_v6
  cf_v4=$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v4) || die "拉取 CF IPv4 段失败"
  cf_v6=$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v6) || die "拉取 CF IPv6 段失败"
  firewall-cmd --permanent --get-ipsets | grep -qw cloudflare-v4 || \
    firewall-cmd --permanent --new-ipset=cloudflare-v4 --type=hash:net --option=family=inet >/dev/null
  firewall-cmd --permanent --get-ipsets | grep -qw cloudflare-v6 || \
    firewall-cmd --permanent --new-ipset=cloudflare-v6 --type=hash:net --option=family=inet6 >/dev/null
  for cidr in $cf_v4; do firewall-cmd --permanent --ipset=cloudflare-v4 --add-entry="$cidr" >/dev/null; done
  for cidr in $cf_v6; do firewall-cmd --permanent --ipset=cloudflare-v6 --add-entry="$cidr" >/dev/null; done
  firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source ipset=\"cloudflare-v4\" port port=\"${CF_ORIGIN_PORT}\" protocol=\"tcp\" accept" >/dev/null
  firewall-cmd --permanent --add-rich-rule="rule family=\"ipv6\" source ipset=\"cloudflare-v6\" port port=\"${CF_ORIGIN_PORT}\" protocol=\"tcp\" accept" >/dev/null
  firewall-cmd --reload >/dev/null
  ok "firewalld 已仅对 CF 回源段放行 ${CF_ORIGIN_PORT}/tcp (公网不可见)"

  local svc_user cf_creds cf_cfg cf_cert_dir cf_uuid cf_path
  svc_user=$(awk -F= '/^User=/{print $2; exit}' /etc/systemd/system/xray@.service 2>/dev/null || echo xray)
  svc_user=${svc_user:-xray}
  cf_creds=/root/cf-creds.txt
  cf_cfg=/usr/local/etc/xray/cf.json
  cf_cert_dir=/usr/local/etc/xray/certs

  mkdir -p "$cf_cert_dir"
  chown "root:${svc_user}" "$cf_cert_dir"
  chmod 750 "$cf_cert_dir"

  if [[ -f "$cf_creds" ]]; then
    source "$cf_creds"
    cf_uuid="$CF_UUID"; cf_path="$CF_PATH"
    warn "已存在 $cf_creds, 复用 CF 凭据 (host=${CF_HOST})"
  else
    cf_uuid=$($XRAY uuid)
    cf_path="/ws-$(openssl rand -hex 6)"
    { echo "# $(date -Is) Cloudflare CDN backup channel"
      echo "CF_HOST=${CF_HOST}"
      echo "CF_UUID=${cf_uuid}"
      echo "CF_PATH=${cf_path}"
      echo "CF_ORIGIN_PORT=${CF_ORIGIN_PORT}"; } > "$cf_creds"
    chmod 600 "$cf_creds"
    ok "已生成独立 CF 凭据 (存 $cf_creds, path=${cf_path})"
  fi

  cat > "$cf_cfg" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "::",
    "port": ${CF_ORIGIN_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${cf_uuid}" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "alpn": ["http/1.1"],
        "minVersion": "1.2",
        "certificates": [{
          "certificateFile": "${cf_cert_dir}/origin.pem",
          "keyFile": "${cf_cert_dir}/origin.key"
        }]
      },
      "wsSettings": { "path": "${cf_path}", "host": "${CF_HOST}" }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private", "geoip:cn"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
  chown "root:${svc_user}" "$cf_cfg"
  chmod 640 "$cf_cfg"

  cat > /root/show-cf-link.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source /root/cf-creds.txt
ADDR="${1:-$CF_HOST}"
ENC_PATH=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$CF_PATH")
LINK="vless://${CF_UUID}@${ADDR}:443?encryption=none&security=tls&sni=${CF_HOST}&fp=chrome&type=ws&host=${CF_HOST}&path=${ENC_PATH}#BWG-CF-BACKUP"
echo "$LINK"
command -v qrencode >/dev/null 2>&1 && { echo; qrencode -t ANSIUTF8 "$LINK"; } || true
SH
  chmod 700 /root/show-cf-link.sh

  if [[ -s "${cf_cert_dir}/origin.pem" && -s "${cf_cert_dir}/origin.key" ]]; then
    chown "root:${svc_user}" "${cf_cert_dir}/origin.pem" "${cf_cert_dir}/origin.key"
    chmod 640 "${cf_cert_dir}/origin.pem" "${cf_cert_dir}/origin.key"
    $XRAY run -test -config "$cf_cfg" | tail -3 | grep -q 'Configuration OK' || die "cf.json 校验失败"
    systemctl enable --now xray@cf
    systemctl restart xray@cf
    sleep 2
    [[ $(systemctl is-active xray@cf) == active ]] && ok "xray@cf active (:${CF_ORIGIN_PORT})" || die "xray@cf 启动失败"
    echo "   领链接: /root/show-cf-link.sh [可选优选CF_IP]"
  else
    warn "请先将 Cloudflare 15 年 Origin CA 证书写入 ${cf_cert_dir}/origin.pem 和 origin.key (640 root:${svc_user}), 再重跑本命令启动 xray@cf"
  fi
}


case "${1:-help}" in
  check)      do_check ;;
  node)       do_node ;;
  rotate)     do_rotate ;;
  tune)       do_tune ;;
  secure)     do_secure ;;
  selftest)   do_selftest ;;
  link)       do_link ;;
  cf-backup)  do_cf_backup ;;
  harden-ssh) do_harden_ssh ;;
  all)        do_check; do_node; do_tune; do_secure; do_selftest; do_link
              say "完成"
              echo "   下一步: ①客户端导入上面链接并实测 ②确认密钥登录 OK 后跑 'NEW_SSH_PORT=28422 bash $0 harden-ssh'" ;;
  *)          sed -n '2,27p' "$0" ;;
esac

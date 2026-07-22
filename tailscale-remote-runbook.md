# Tailscale 远程桌面 + v2rayA 共存手册（NoMachine over Tailscale）

> 用途：异地/跨网用一台电脑（客户端，如 Mac）经 **Tailscale** 远程连接家里另一台开着 **v2rayA 全局代理** 的电脑（被连方，如 Ubuntu 桌面），跑 **NoMachine** 远程桌面。
> 前提：两台都能上网；被连方已按 [proxy-runbook.md](proxy-runbook.md) 配好 v2rayA TProxy。
> 目标：① 远程能连上；② **不卡**（关键是别让 Tailscale 流量被 v2rayA 送去国外绕路）；③ 代理节点挂了也不会把你锁在门外。
> 已在 Ubuntu 24.04（被连方）+ macOS（客户端）验证（2026-07）。

---

## 0. 一句话原理（最重要，先看）

Tailscale 在两台机器间搭一条 WireGuard 虚拟局域网，双方各拿一个 `100.x` 地址，NoMachine 只管连那个 `100.x`。

**但如果任意一端的 v2rayA 是全局/Tun 代理，会把 Tailscale 自己的传输 UDP 也一起送进代理节点** → 这台机器在 Tailscale 眼里“出口 IP 变成了国外” → 选了个国外 DERP 中继 → 两台国内机器的远程桌面流量被迫**横跨太平洋来回绕**，延迟 400ms~3s，狂卡。

> ✅ 正确姿态：**Tailscale 的流量必须走直连，绝不进 v2rayA 的代理。** 两端都要满足。

---

## 1. 被连方（家里那台，Ubuntu + v2rayA）

### 1.1 起 Tailscale 并登录
```bash
sudo tailscale up            # 首次会打印 login 链接，浏览器登录同一账号授权本机
tailscale ip -4              # 记下本机 100.x 地址，例：100.116.230.54
```

### 1.2 NoMachine 服务端
```bash
systemctl status nxserver 2>/dev/null || ps -ef | grep -i nxserver
ss -tlnp | grep 4000        # 确认监听 0.0.0.0:4000（NoMachine 默认端口）
```

### 1.3 防火墙放行（若开了 ufw）
```bash
sudo ufw allow 4000/udp      # NoMachine（NX 协议走 UDP/TCP 4000）
sudo ufw allow 4000/tcp
sudo ufw allow 41641/udp     # Tailscale 打洞端口，利于建立直连
```

### 1.4 确认 v2rayA 没有代理 Tailscale（通常默认就对）
v2rayA 的 TProxy nft 白名单默认已含 `100.64.0.0/10`（Tailscale 的 CGNAT 段），所以叠加网寻址走直连。验证：
```bash
sudo nft list set inet v2raya whitelist | grep -q '100.64.0.0/10' && echo "OK: 100.64/10 已在白名单(直连)"
```
底层 WireGuard 传输是否也直连，用第 4 节的实测判据确认（看 DERP 是不是国内附近的）。

---

## 2. 客户端（要远程的那台，如 Mac）——**卡顿重灾区，重点配**

### 2.1 装并登录 Tailscale
装 Tailscale 客户端 → 登**同一个账号/tailnet** → 拿到自己的 `100.x`。

### 2.2 关键：让本机 v2rayA 不代理 Tailscale
按严重性从高到低任选：

- **最省事**：远程桌面期间，**把本机 v2rayA 断开/退出**（或关掉 Tun/全局模式）。Tailscale 立刻走直连。
- **系统代理模式**：把 v2rayA 切成 **“系统代理(System Proxy)”而非 Tun/透明代理**——系统代理只影响认它的 App，而 Tailscale 用裸 UDP，不吃系统 HTTP/SOCKS 代理，天然绕开。
- **Tun/全局模式下必须加分流白名单**（RoutingA 或对应设置），让下列走 **direct**：
  - `100.64.0.0/10`（Tailscale 叠加网段）
  - Tailscale 的 tun 网卡 / DERP 探测流量

### 2.3 NoMachine 连接
新建连接，主机填**被连方的 `100.x`**（例 `100.116.230.54`），端口 `4000`。**不要**填对方的 `192.168/172.16` 内网 IP。

---

## 3. 让它更顺：优先“直连”，其次调 NoMachine

### 3.1 尽量凑成局域网直连（体验最好）
- **让两台连同一个 WiFi/路由器**：Tailscale 会识别同网段 → 直接局域网直连，延迟≈0，NoMachine 如丝般顺。
- **别用手机热点当客户端网络**：运营商级 NAT（CGNAT，硬 NAT）打不了洞，只能走 DERP 中继。
- 被连方路由器**开 UPnP / NAT-PMP**，利于打洞。

### 3.2 NoMachine 高延迟调优（跨网必做）
会话内右上角揭开菜单 → **Display**：
- **Display quality 滑块拉到最左（speed）**
- 开 **Use hardware encoding（H.264/H.265）**
- 分辨率降到 **1080p**、颜色深度 **16 位**
- 被连方桌面里关掉窗口动画/字体平滑等特效

---

## 4. 验证：直连还是中继？（在被连方跑）
```bash
tailscale status | grep -i <客户端名>
tailscale ping <客户端名>
```
判读那一行结尾 / ping 的 `via`：

| 看到 | 含义 | 好坏 |
|---|---|---|
| `direct 1.2.3.4:41641` | 点对点直连 | ✅ 最好 |
| `relay "sin"` / `relay "hkg"` | 经新加坡/香港中继 | 🟡 没打通洞，但没绕远，~50-140ms 可用 |
| `relay "sfo"`（你在国内却中继美国） | **某端把 Tailscale 走了代理** | ❌ 400ms+ 巨卡，回第 2.2 节修 |
| `direct connection not established` | NAT 太硬（多为手机热点） | 🟡 换网络或接受中继 |

`tailscale netcheck` 若显示 `Nearest DERP` 是国内附近（sin/hkg/tok）且公网 IP 是国内 IP，说明本机 Tailscale 没被代理。

---

## 5. 节点失败兜底：别把自己锁在门外

**风险**：被连方 v2rayA 若“服务还在跑但代理节点已死”，出站流量被黑洞；万一你的远程链路某种程度依赖它，就会异地失联、连“关掉 v2rayA”都做不到。

**兜底 = 健康看门狗**：定时探测代理是否通，连不通就 `stop v2raya` → 触发 failopen 删 nft 表 → 全部直连 → 远程链路恢复。配合 v2rayA 的 failopen drop-in（`ExecStopPost` 删表 + `Restart=on-failure`，见 proxy-runbook.md）。

`/usr/local/bin/v2raya-node-watchdog.sh`：
```bash
#!/usr/bin/env bash
set -u
systemctl is-active --quiet v2raya || exit 0
TARGET="http://www.google.com/generate_204"   # 只有走通代理才回 204
code=""
for i in 1 2 3; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$TARGET" 2>/dev/null)
    [ "$code" = "204" ] && exit 0
    sleep 4
done
logger -t v2raya-watchdog "proxy path down (last='${code}'); stopping v2raya to fail open"
systemctl stop v2raya
```
`/etc/systemd/system/v2raya-watchdog.service`：
```ini
[Unit]
Description=v2rayA node health watchdog (fail-open to direct if proxy dead)
After=v2raya.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/v2raya-node-watchdog.sh
```
`/etc/systemd/system/v2raya-watchdog.timer`：
```ini
[Unit]
Description=Run v2rayA node watchdog periodically
[Timer]
OnBootSec=60s
OnUnitActiveSec=45s
AccuracySec=5s
[Install]
WantedBy=timers.target
```
启用：
```bash
sudo install -m755 v2raya-node-watchdog.sh /usr/local/bin/
sudo cp v2raya-watchdog.service v2raya-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now v2raya-watchdog.timer
# 手动测：健康时应退出码 0 且 v2raya 仍 active
sudo /usr/local/bin/v2raya-node-watchdog.sh; echo "退出码=$?"; systemctl is-active v2raya
```
> 停后**不自动重连**（故意：失败永远倒向“能上网/能远程”）。节点恢复后手动 `sudo systemctl start v2raya`。

---

## 6. 排错速查表（症状 → 原因 → 解法）

| 症状 | 原因 | 解法 |
|---|---|---|
| Mac 在国内却 `relay "sfo"`、延迟 400ms+ | **Mac 的 v2rayA 全局/Tun 代理把 Tailscale 送去了美国节点** | 断开 Mac 的 v2rayA，或切系统代理模式，或白名单放行 `100.64.0.0/10`（第 2.2 节） |
| `direct connection not established`，走 relay | NAT 太硬（手机热点 CGNAT）打不了洞 | 客户端换家用宽带；两台连同一 WiFi 直接局域网直连；路由器开 UPnP |
| 连不上、超时 | 被连方 ufw 挡了 4000 / 填了对方内网 IP | `ufw allow 4000/tcp,udp`；主机地址填对方 `100.x` |
| 画面糊/慢但不断 | NoMachine 画质设太高 | Display 画质拉到 speed、开硬件编码、降分辨率/色深 |
| 节点一挂远程就失联 | v2rayA 黑洞了流量 | 装第 5 节看门狗；应急直连 `sudo systemctl stop v2raya`（failopen 删表回直连） |
| `tailscale ping` 全超时 | 对端离线/休眠 | 确认对端 Tailscale 在线；被连方设为不休眠 |

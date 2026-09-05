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

- **v2rayA WEB 控制台分流（推荐）**：
  在 v2rayA 控制台（`http://127.0.0.1:2017`）-> **设置 (Settings)**：
  1. 将 **透明代理模式 (Transparent Proxy)** 设为 **“绕过大陆及局域网” (Bypass mainland China and LAN)**。
  2. 在自定义规则配置中显式添加 Tailscale 专属 CGNAT 网段直连：
     ```text
     ip(100.64.0.0/10) -> direct
     ```
- **系统代理模式**：把 v2rayA 切成 **“系统代理(System Proxy)”而非 Tun/透明代理**——系统代理只影响认它的 App，而 Tailscale 用裸 UDP，不吃系统 HTTP/SOCKS 代理，天然绕开。
- **最省事**：远程桌面期间，**把本机 v2rayA 断开/退出**（或关掉 Tun/全局模式）。Tailscale 立刻走直连。

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

## 4. 验证：直连（P2P）还是中继（DERP）？（在被连方或客户端跑）

要判断 NoMachine 当前是否在走 **P2P 点对点直连**，运行以下命令：

```bash
tailscale status
tailscale ping <对端Tailscale-IP或设备名>
```

### 判读命令输出：

1. **P2P 点对点直连 (Direct / 最优 ✅)**：
   - `tailscale ping` 返回类似：`pong from macbook (100.120.116.81) via 192.168.1.71:41641 in 5ms`
   - 只要包含 `via <IP>:<端口>` 或 `direct <IP>:<端口>` 且延迟在几毫秒到几十毫秒，说明已建立 **P2P 直连**，NoMachine 画音数据在两台设备间点对点传输，不经过中继服务器。

2. **DERP 服务器中继 (Relay / 次优 🟡)**：
   - `tailscale ping` 返回类似：`pong from macbook (100.120.116.81) via DERP(tok) in 65ms`
   - 说明 NAT 打洞未成功（多因硬 NAT 或防火墙阻断 UDP 41641），流量由 Tailscale 的 DERP 中继节点转发。

3. **被代理误劫持 (Relay SFO / 最差 ❌)**：
   - 输出显示 `via DERP(sfo)`（美国节点）且延迟高达 400ms+。
   - 说明 Tailscale 流量被 v2rayA 代理到了国外，需回到第 2.2 节配置 `100.64.0.0/10 -> direct` 规则。

| 提示输出 | 连接类型 | 性能与延迟 | 优化建议 |
|---|---|---|---|
| `via 192.168.x.x:41641` | 局域网 P2P 直连 | ⚡ 极致 (1~5ms) | 体验最佳，无需调整 |
| `via <公网IP>:41641` | 跨网 P2P 直连 | 🚀 极佳 (10~30ms) | 点对点打通成功 |
| `via DERP(tok/hkg)` | 附近 DERP 中继 | 🟡 一般 (50~140ms) | 检查路由器 UPnP 或切换连接网络 |
| `via DERP(sfo)` | 国外 DERP 代理误劫持 | ❌ 极差 (400ms+) | 将 `100.64.0.0/10` 设为 v2rayA 直连 |

`tailscale netcheck` 若显示 `Nearest DERP` 是国内附近（tok/hkg/sin）且公网 IP 是国内 IP，说明本机 Tailscale 传输未被代理误劫持。

---

## 5. 节点失败兜底：别把自己锁在门外

**风险**：被连方 v2rayA 若“服务还在跑但代理节点已死”，出站流量被黑洞；万一你的远程链路某种程度依赖它，就会异地失联、连“关掉 v2rayA”都做不到。

**兜底 = 健康看门狗**：定时探测代理是否通，连不通就 `stop v2raya` → 触发 failopen 删 nft 表 → 全部直连 → 远程链路恢复。配合 v2rayA 的 failopen drop-in（`ExecStopPost` 删表 + `Restart=on-failure`，见 proxy-runbook.md）。

`/usr/local/bin/v2raya-node-watchdog.sh` → **[scripts/v2raya-node-watchdog.sh](scripts/v2raya-node-watchdog.sh)**（脚本较长，独立成文件，别再内联抄）。

判据分三层，缺一层就会误杀（血泪见 5.1）：

| 层 | 探测 | 失败含义 | 动作 |
|---|---|---|---|
| 1 本地链路 | TCP `223.5.5.5:443`（geoip:cn→直连） | 是本机/ISP 断网，**不是节点的错** | 不停服（停了链路恢复时反而没代理） |
| 2 隧道 | `curl https://1.1.1.1/cdn-cgi/trace` 回 `ip=` | 非 CN 流量出不去 | 计数 +1 |
| 3 节点 | TCP `<节点IP>:443`（routing rule 0 判直连） | 节点真死（会黑洞 Tailscale 的那种） | 2 次即 fail-open |

- **探针必须用纯 IP**。`1.1.1.1` 在国内直连被墙、又不属 `geoip:cn`，所以「有响应」= 隧道通，且**全程不碰 DNS**。
- 节点通而只是隧道抖（证书/UUID/被 QoS），撑满 `KILL_AFTER=4` 次（45s 一轮 ≈ 3 分钟）才停。
- 失败计数存 `/run/v2raya-watchdog.fails`，**跨 timer 周期累计**，单轮瞬断不再构成死刑。

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
sudo install -m755 scripts/v2raya-node-watchdog.sh /usr/local/bin/v2raya-node-watchdog.sh
sudo cp v2raya-watchdog.service v2raya-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now v2raya-watchdog.timer
```
**装之前先确认探针在你的链路上成立**（不成立就别装，否则等于装了个定时炸弹）：
```bash
curl -s --max-time 8 https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|loc)='
# 期望: ip=<你的节点IP>  loc=US   ← 同时验证了出口确实是节点
```
再手动跑一轮，健康时应退出码 0、v2raya 仍 active、计数归零：
```bash
sudo /usr/local/bin/v2raya-node-watchdog.sh; echo "退出码=$?"
systemctl is-active v2raya; cat /run/v2raya-watchdog.fails   # 期望 active / 0
```
日常观察（v2 只在失败时说话，能看到中间态而非只在死后留一行）：
```bash
journalctl -t v2raya-watchdog -f
# probe failed 2/4 (node <节点IP> dead=0); waiting
```
> 停后**不自动重连**（故意：失败永远倒向“能上网/能远程”）。节点恢复后手动 `sudo systemctl start v2raya`。

### 5.1 复盘：看门狗自己成了故障源（2026-09-05）

**症状**：早 06:31 面板 `http://127.0.0.1:2017` 打不开，且已躺了近 5 小时。节点本身好的（手机能连）。

**日志只有一行**，`000` = 连 HTTP 状态码都没拿到，DNS 失败和连接超时长得一模一样，事后分不出是哪种：
```
v2raya-watchdog[294649]: proxy path down (last='000'); stopping v2raya to fail open
```

**根因**：v1 探针 `curl http://www.google.com/generate_204 --max-time 6` 把 DNS 串在关键路径上——`www.google.com` 不属 `geosite:cn`，要先经 `https://1.1.1.1/dns-query` 在**隧道里**做一次 DoH 往返，再在同一个 6 秒预算内跑完 HTTP。DoH 那腿慢过 6s 就吐 `000`，**隧道其实完全健康**。三连败共 26 秒的窗口对凌晨跨太平洋线路（06:31 CST = 美西下午拥塞时段）远不算异常，而停服后按设计不自动重连 → 一次瞬断换来 5 小时失联。

**排除项**（都查过）：本机无 suspend、无链路 down、`systemd-resolved` 静默；最近 DHCP 续租在 06:20:28 和 06:34:17，**都不在 06:31:12 的杀死窗口内**；节点 443 事后实测可达。

**教训**：
1. **健康探针不能依赖被探测系统的 DNS**，用纯 IP 目标。
2. **单轮判决 = 把瞬断当死亡**，计数要跨周期累计（`/run` 存盘）。
3. **要能区分「我断网」和「节点死」**，否则本地断网时停服会让链路恢复时也没代理。
4. **`xray` 的 `"error":"none"` 让事故无法回溯**——想留证据就把 loglevel 调回 `warning`。
5. 探针失败**必须记可诊断的中间态**，只在死后留一行 `000` 等于没记。

---

## 6. 排错速查表（症状 → 原因 → 解法）

| 症状 | 原因 | 解法 |
|---|---|---|
| Mac 在国内却 `relay "sfo"`、延迟 400ms+ | **Mac 的 v2rayA 全局/Tun 代理把 Tailscale 送去了美国节点** | 断开 Mac 的 v2rayA，或切系统代理模式，或白名单放行 `100.64.0.0/10`（第 2.2 节） |
| `direct connection not established`，走 relay | NAT 太硬（手机热点 CGNAT）打不了洞 | 客户端换家用宽带；两台连同一 WiFi 直接局域网直连；路由器开 UPnP |
| 连不上、超时 | 被连方 ufw 挡了 4000 / 填了对方内网 IP | `ufw allow 4000/tcp,udp`；主机地址填对方 `100.x` |
| 面板 `127.0.0.1:2017` 打不开，服务 inactive | **看门狗误杀**：探针含 DNS 腿，一次瞬断即停服；停后故意不自动重连 | `journalctl -t v2raya-watchdog` 看是否有 `proxy path down`；`systemctl start v2raya`；换 v2 探针（第 5 节 + 5.1） |
| 看门狗日志只有 `last='000'` | `000` = 没拿到状态码，DNS 失败/超时不可区分 | 改用纯 IP 探针，并记录 `probe failed N/4` 中间态 |
| `stop v2raya` 时 `nft delete table` 报 `No such file or directory` | 表在 stop 前已不存在（xray 先自己崩了），`ExecStopPost` 的 `-` 前缀已忽略返回值 | **无害**，可忽略 |
| `nft list table inet v2raya` 报 `Operation not permitted` | 非 root 读不到 netlink，**不代表表不存在** | 加 `sudo`；或用 `curl https://1.1.1.1/cdn-cgi/trace` 看出口 IP 判断 TProxy 是否生效 |
| 画面糊/慢但不断 | NoMachine 画质设太高 | Display 画质拉到 speed、开硬件编码、降分辨率/色深 |
| 节点一挂远程就失联 | v2rayA 黑洞了流量 | 装第 5 节看门狗；应急直连 `sudo systemctl stop v2raya`（failopen 删表回直连） |
| `tailscale ping` 全超时 | 对端离线/休眠 | 确认对端 Tailscale 在线；被连方设为不休眠 |

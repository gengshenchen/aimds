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

判据分层防御，缺一层就会误杀或漏杀。v4 完整实现了**「TProxy重建自愈 → 进程重启自愈 → 故障开路停服 → 后台退避自动复活」**的完整闭环（详见 5.1/5.2/5.3）：

| 层 | 探测 | 失败含义 | 动作 |
|---|---|---|---|
| 1 本地链路 | TCP `223.5.5.5:443` 或 `119.29.29.29:443`（geoip:cn→直连） | 是本机/ISP 断网，**不是节点的错** | 不停服、不累计（停了链路恢复时反而没代理） |
| 2 TProxy 存活 | `ip rule` 有 `fwmark 0xc0 lookup 100` 且 `nft inet v2raya` 表在 | TProxy 被 DHCP/Tailscale 重排冲掉（此时探针必假失败） | **重启 v2raya 重建**，不计数、不杀（60s 限速防抖） |
| 3 隧道双探针 | `1.1.1.1/cdn-cgi/trace`（失败回退 `1.0.0.1`）回 `ip=` | 非 CN 流量出不去 | 计数 +1 |
| 4 自愈预处理 | 节点 TCP 通，但探针连败 3 次 | xray 内部连接池假死 / socket 泄漏 | **先重启 v2raya 尝试自愈一次** |
| 5 节点与开路 | TCP `<节点IP>:443` 死（2 次）或撑满 `KILL_AFTER=5`（~3.5 分钟）仍失败 | 节点真死 / 跨国隧道彻底阻断 | **fail-open 停服**（`stop v2raya` 删表保直连） |
| 6 自动复活 | 处于 fail-open 期间，后台持续探测节点 TCP | 远端节点或网络已恢复 | **退避唤醒验证并恢复 v2raya（Fail-Back）** |

- **探针必须用纯 IP**。`1.1.1.1` 与 `1.0.0.1` 在国内直连被墙、又不属 `geoip:cn`，所以「有响应」= 隧道通，且**全程不碰 DNS**。但前提是 TProxy 把它们劫持进了 proxy——这正是层 2 要守护的：TProxy 不在时，纯 IP 探针会「假失败」，绝不能据此判隧道故障。
- **Fail-Back 自动闭环**：v4 彻底解决了 v2/v3「只杀不救」的痛点。当因故障触发停服后，看门狗在后台按退避周期（90s ~ 600s）持续测试节点；节点与隧道一旦恢复，自动重启拉起 v2rayA 恢复透明代理，不再需要人工到场手动拉起。
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
sudo cp scripts/v2raya-watchdog.service scripts/v2raya-watchdog.timer /etc/systemd/system/
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
日常观察（v4 只在失败或自愈时说话，能看到中间态而非只在死后留一行）：
```bash
journalctl -t v2raya-watchdog -f
# probe failed 2/5 (node <节点IP> dead=0); waiting
```
> **自动自愈与复活（Fail-Back）**：停服直连后，看门狗在后台持续监控，节点网络恢复后会自动重启唤醒 v2rayA；若紧急需要也可随时手动 `sudo systemctl start v2raya`。

### 5.1 复盘：看门狗自己成了故障源（2026-09-05）

**症状**：早 06:31 面板 `http://127.0.0.1:2017` 打不开，且已躺了近 5 小时。节点本身好的（手机能连）。

**日志只有一行**，`000` = 连 HTTP 状态码都没拿到，DNS 失败和连接超时长得一模一样，事后分不出是哪种：
```
v2raya-watchdog[294649]: proxy path down (last='000'); stopping v2raya to fail open
```

**根因**：v1 探针 `curl http://www.google.com/generate_204 --max-time 6` 把 DNS 串在关键路径上——`www.google.com` 不属 `geosite:cn`，要先经 `https://1.1.1.1/dns-query` 在**隧道里**做一次 DoH 往返，再在同一个 6 秒预算内跑完 HTTP。DoH 那腿慢过 6s 就吐 `000`，**隧道其实完全健康**。三连败共 26 秒的窗口对凌晨跨太平洋线路（06:31 CST = 美西下午拥塞时段）远不算异常，而停服后按设计不自动重连 → 一次瞬断换来 5 小时失联。

**实证（v2rayA 面板 Logs，2026-09-05 13:13 换 v2 后抓到）**——这不是推断，DNS 的额外开销在日志里看得见：
```
13:13:17.061 from 172.16.1.242:44534 accepted tcp:1.1.1.1:443        [transparent_ipv4 -> proxy]   ← v2 探针，直接进隧道
13:13:18.350 from DNS accepted tcp:119.29.29.29:53                   [dns -> direct]               ← 1.3s 后仍在补做解析
13:13:19.154 from DNS accepted tcp:208.67.220.220:5353               [dns -> direct]               ← 又 0.8s，串行第二轮
```
后两条是 `dns.alidns.com` 的**引导解析**（DoH 的域名自己得先解析），且**回落到 TCP 53**、两轮串行 ≈ 1.9s。v1 的 6s 预算要塞进「引导解析 → DoH 往返 → HTTP」整条链；v2 用纯 IP 目标，`1.1.1.1:443` 一条就进 `proxy`，全程不产生任何 `[dns -> ...]` 依赖。**这就是「探针不能依赖被探测系统的 DNS」的实测依据。**

**排除项**（都查过）：本机无 suspend、无链路 down、`systemd-resolved` 静默；最近 DHCP 续租在 06:20:28 和 06:34:17，**都不在 06:31:12 的杀死窗口内**；节点 443 事后实测可达。

**教训**：
1. **健康探针不能依赖被探测系统的 DNS**，用纯 IP 目标。
2. **单轮判决 = 把瞬断当死亡**，计数要跨周期累计（`/run` 存盘）。
3. **要能区分「我断网」和「节点死」**，否则本地断网时停服会让链路恢复时也没代理。
4. **`xray` 的 `"error":"none"` 让事故无法回溯**——想留证据就把 loglevel 调回 `warning`。
5. 探针失败**必须记可诊断的中间态**，只在死后留一行 `000` 等于没记。

### 5.2 复盘：v2 会因 TProxy 被冲而误杀（2026-09-08）

**症状**：09-07 早 05:32 v2raya 又被看门狗杀了，但节点和本地链路都是好的（手机能连、`223.5.5.5` 通、节点 443 通）。

**根因**：v2 的第二层探针 `curl https://1.1.1.1/cdn-cgi/trace` 想用「1.1.1.1 有响应」证明隧道通，但这话成立有个**隐藏前提**——TProxy 必须把 `1.1.1.1:443` 劫持进 proxy。而 TProxy 靠的是 ip rule（`fwmark 0xc0 lookup 100`）+ nft 表（`inet v2raya`），这两样会**在运行中被 DHCP 续租 / Tailscale 重排路由时从内核里冲掉**（`tailscaled` 日志 `ip rule deleted: ... Table:100 Mark:192`，`ip rule show` 里那条 `fwmark 0xc0 lookup 100` 直接消失）。TProxy 一没，`1.1.1.1` 就改走直连、被墙，探针**必然假失败**。v2 把假失败当隧道故障，累计 4 次后 fail-open 杀了 v2raya——可杀 v2raya 根本不会重挂 TProxy（只有重启 v2raya 才修），等于真故障发生时杀掉了唯一能修复它的东西，还让被墙流量全裸奔。

**实证**（都是直接证据）：
- `ip rule show` 里 TProxy 那条 `fwmark 0xc0 lookup 100` **消失了**（重启 v2raya 后 5209 行才回来）。
- `tailscaled` 日志：`monitor: ip rule deleted: ... Table:100 Mark:192`、`RTM_DELROUTE`。
- DHCP 续租（09-07 05:27:25 `dhcp4 new lease`）先于杀死（05:32:31）约 5 分钟——续租重排路由，正好把 ip rule 冲掉。
- 重启 v2raya 后 `1.1.1.1` 探针立刻恢复 `ip=<节点IP> loc=US`，证明隧道本身一直健康，只是 TProxy 掉线。

**修复（v3）**：新增「TProxy 存活检查」作为独立一层——每次先看 `ip rule` 有无 `fwmark 0xc0 lookup 100`、`nft inet v2raya` 表在不在；任一缺失就**重启 v2raya 重建 TProxy**（自愈，不累计、不杀），并加 60s 限速防止 DHCP 期间疯狂重启。只有确认 TProxy 存活、隧道仍失败，才走「节点死才杀 / 隧道抖撑满窗口」。

**教训**：
1. **探针要想可信，它依赖的中间层必须先确认存活**——「用 X 证明 Y 通」隐含了「X 还在工作」，中间层没了探针就假失败。
2. **修复动作要对症**：TProxy 掉了该「重启 v2raya 重挂」，不是「杀 v2raya fail-open」——后者恰好停在错误一侧。
3. **DHCP 续租、Tailscale 重排路由都会动 ip rule**，是 TProxy 的隐形敌人；这类系统事件值得进看门狗的检查清单。

### 5.3 复盘：v3 只有 fail-open 没有 fail-back，短抖动导致永久停服（2026-09-14）

**症状**：周一过来发现 v2rayA 停服，已瘫痪超过 25 小时（周日早 08:24 停服，直到周一 09:47 人工拉起）。

**日志证据**（`journalctl -t v2raya-watchdog`）：
```
Sep 13 08:22:19 v2raya-watchdog: probe failed 1/4 (node <节点IP> dead=0); waiting
Sep 13 08:23:09 v2raya-watchdog: probe failed 2/4 (node <节点IP> dead=0); waiting
Sep 13 08:23:59 v2raya-watchdog: probe failed 3/4 (node <节点IP> dead=0); waiting
Sep 13 08:24:46 v2raya-watchdog: tunnel down x4 while node <节点IP>:443 still reachable; stopping v2raya to fail open
```

**根因**：
1. **只杀不救（缺乏 Fail-Back 恢复机制）**：v3 脚本在开头判断 `systemctl is-active --quiet v2raya || reset`。一旦看门狗触发 `systemctl stop v2raya`，后续周期检测到服务未运行就直接重置并退出，**完全不再探测节点，也绝不会自动重新拉起服务**。这意味着只要周末清晨发生一次短短 2~3 分钟的网络抖动（如运营商 PPPoE 例行重拨或跨国路由抖动），v2rayA 就会永久躺平，直到人工手动启动。
2. **缺乏进程自愈预处理**：节点 TCP 443 一直是通的（`dead=0`），有时仅仅是 xray 内部连接池假死或 socket 阻塞，v3 却直接 `stop` 放弃治疗，没有给进程一次 `restart` 原地自愈的机会。
3. **单点探针与阈值偏紧**：仅依赖单一 `1.1.1.1`，4 次（约 2 分 15 秒）容忍度对跨太平洋线路偏窄。

**修复（v4）**：
1. **引入 Fail-Back 状态机**：进入 fail-open 后在 `/run` 保留标记，后台以指数退避周期（90s、150s、210s... 最大 600s）持续检测节点 TCP；只要节点可达且隧道探针通过，**自动拉起 v2rayA 恢复代理**。
2. **先 Restart 尝试自愈**：在达到停服阈值前（第 3 次失败），先尝试 `systemctl restart v2raya` 一次。若自愈成功则继续工作；自愈失败才进入 fail-open。
3. **双探针冗余**：优先探测 `1.1.1.1`，超时自动回退复核 `1.0.0.1`；本地直连增加腾讯 DNS（`119.29.29.29`）与阿里 DNS 双通道。

**教训**：
1. **任何故障保护都必须闭环**：有 fail-open 就必须有 fail-back，否则临时保护就会变成永久故障。
2. **杀停之前先给自愈机会**：进程内部假死往往可以通过重启原地解决，不需要直接拉闸全机网络。

---

## 6. 排错速查表（症状 → 原因 → 解法）

| 症状 | 原因 | 解法 |
|---|---|---|
| Mac 在国内却 `relay "sfo"`、延迟 400ms+ | **Mac 的 v2rayA 全局/Tun 代理把 Tailscale 送去了美国节点** | 断开 Mac 的 v2rayA，或切系统代理模式，或白名单放行 `100.64.0.0/10`（第 2.2 节） |
| `direct connection not established`，走 relay | NAT 太硬（手机热点 CGNAT）打不了洞 | 客户端换家用宽带；两台连同一 WiFi 直接局域网直连；路由器开 UPnP |
| 连不上、超时 | 被连方 ufw 挡了 4000 / 填了对方内网 IP | `ufw allow 4000/tcp,udp`；主机地址填对方 `100.x` |
| 面板 `127.0.0.1:2017` 打不开，服务 inactive | **看门狗误杀**：探针含 DNS 腿（5.1）、TProxy 被冲（5.2），或无恢复机制（5.3） | `journalctl -t v2raya-watchdog` 看是否有 `tunnel down`；`systemctl start v2raya`；换用具备自动复活的 v4 脚本（第 5 节） |
| 看门狗日志只有 `last='000'` | `000` = 没拿到状态码，DNS 失败/超时不可区分 | 改用纯 IP 探针，并记录 `probe failed N/5` 中间态 |
| 日志 `tunnel down x4/x5 while node ... still reachable` 但节点明明好的 | **短抖动触发停服或 TProxy 被冲**：v3 缺乏自动复活机制 | 升级至 v4 脚本，具备先 restart 自愈以及后台退避自动唤醒（Fail-Back）能力 |
| `stop v2raya` 时 `nft delete table` 报 `No such file or directory` | 表在 stop 前已不存在（xray 先自己崩了），`ExecStopPost` 的 `-` 前缀已忽略返回值 | **无害**，可忽略 |
| `nft list table inet v2raya` 报 `Operation not permitted` | 非 root 读不到 netlink，**不代表表不存在** | 加 `sudo`；或用 `curl https://1.1.1.1/cdn-cgi/trace` 看出口 IP 判断 TProxy 是否生效 |
| 画面糊/慢但不断 | NoMachine 画质设太高 | Display 画质拉到 speed、开硬件编码、降分辨率/色深 |
| 节点一挂远程就失联 | v2rayA 黑洞了流量 | 装第 5 节看门狗；应急直连 `sudo systemctl stop v2raya`（failopen 删表回直连） |
| `tailscale ping` 全超时 | 对端离线/休眠 | 确认对端 Tailscale 在线；被连方设为不休眠 |

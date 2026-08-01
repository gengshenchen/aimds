# 代理搭建与分流配置手册（VLESS+REALITY 服务端 + v2rayA 客户端）

> 用途：换新机器 / 新 VPS 时，照此一步到位。也可直接把本文件交给 AI 说「按这个配置」。
> 已在 Ubuntu 24.04 客户端 + RackNerd/LisaHost VPS 上验证通过（2026-06）。

---

## 名词与目标

- **服务端**：VPS，跑 Xray，提供 VLESS+REALITY 节点。
- **客户端**：本机 Ubuntu，跑 v2rayA（内含 Xray 内核），做 TProxy 全局透明代理 + 国内外分流 + DNS 分流。
- **目标**：国内直连、国外走代理；国内域名用国内 DNS、国外域名用国外 DNS；代理挂了不连累国内；能正常访问 Google/Gemini。

---

# 第一部分：服务端 —— 全新 VPS 上建 VLESS+REALITY 节点

适用：一台干净的 Ubuntu VPS（root）。若上面有旧的 3x-ui/xray，先卸载（见 1.0）。

> 🐧 **用 AlmaLinux / Rocky / RHEL 9？** 本部分命令有一半会报错（`apt-get`/`ufw`/`restart ssh`）。见 **[proxy-runbook-almalinux9.md](proxy-runbook-almalinux9.md)**，内含一键脚本与 EL9 专属排错表。
> ⚠️ 其中**第 1 节的权限坑不分发行版**——凡是用官方 systemd 单元（`User=nobody`）的机器都会中：给 `config.json` 上 `chmod 600` 后，`xray run -test` 因为是 root 执行**照样报 Configuration OK**，服务却起不来。**「校验通过但服务挂」先查权限**，别去改 JSON。

> 💥 **被入侵后重建**（如发现 `kswapd0` 等矿马、CPU 99%、SSH 都握不上手）：别手动清木马（后门难清干净），**直接在服务商后台重装系统**成干净镜像，再照本手册走一遍，最后**务必做 1.7 加固**。本手册用纯 Xray、**不装公网面板**，从根上去掉被打的入口。

### 1.0（可选）清理旧代理
```bash
systemctl stop x-ui 2>/dev/null; systemctl disable x-ui 2>/dev/null
pkill -9 xray; pkill -9 x-ui
rm -f /etc/systemd/system/x-ui.service /usr/lib/systemd/system/x-ui.service
systemctl daemon-reload
rm -rf /etc/x-ui /usr/local/x-ui /usr/bin/x-ui
```

### 1.1 安装官方 Xray
```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
/usr/local/bin/xray version   # 确认装好
```

### 1.2 生成凭据（每台服务器都要重新生成，别复用）
```bash
/usr/local/bin/xray x25519     # 记下 PrivateKey 和 Password(=PublicKey)
/usr/local/bin/xray uuid       # 记下 UUID
openssl rand -hex 8            # 记下 shortId
```

### 1.3 写配置 `/usr/local/etc/xray/config.json`
把下面 4 个 `<...>` 占位符替换成上一步生成的值。SNI 用一个 TLS1.3 的干净大站（推荐 `www.tesla.com` / `www.icloud.com`）。端口用 **443**（REALITY 就该伪装成正常 HTTPS）。
```json
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0", "port": 443, "protocol": "vless",
    "settings": {
      "clients": [{ "id": "<UUID>", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {
        "show": false, "dest": "www.tesla.com:443", "xver": 0,
        "serverNames": ["www.tesla.com"],
        "privateKey": "<PRIVATE_KEY>",
        "shortIds": ["<SHORT_ID>"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
```

### 1.4 校验、放行端口、启动
```bash
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json   # 必须 Configuration OK
ufw status | grep -q active && ufw allow 443/tcp    # 若开了 ufw
systemctl restart xray && systemctl enable xray
systemctl is-active xray            # active
ss -tlnp | grep ':443 '             # xray 在监听 443
```

### 1.5 生成分享链接 / 二维码
```bash
# 替换 <UUID> <PUBLIC_KEY> <SHORT_ID> <SERVER_IP>
LINK='vless://<UUID>@<SERVER_IP>:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.tesla.com&fp=chrome&pbk=<PUBLIC_KEY>&sid=<SHORT_ID>&type=tcp&headerType=none#MYNODE'
echo "$LINK"
apt-get install -y qrencode && qrencode -t ANSIUTF8 "$LINK"   # 手机扫码导入
```

### 1.6 服务端自测（关键：证明节点本身没问题）
在服务器本机连它自己，绕开 GFW 和双重代理，验证 REALITY 参数正确：
```bash
cat > /tmp/selftest.json <<EOF
{ "inbounds":[{"listen":"127.0.0.1","port":10999,"protocol":"socks","settings":{"udp":true}}],
  "outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"<SERVER_IP>","port":443,
    "users":[{"id":"<UUID>","encryption":"none","flow":"xtls-rprx-vision"}]}]},
    "streamSettings":{"network":"tcp","security":"reality","realitySettings":{
      "serverName":"www.tesla.com","fingerprint":"chrome","publicKey":"<PUBLIC_KEY>","shortId":"<SHORT_ID>"}}}]}
EOF
nohup /usr/local/bin/xray run -config /tmp/selftest.json >/tmp/selftest.log 2>&1 &
sleep 3
curl -s --socks5-hostname 127.0.0.1:10999 --max-time 12 -o /dev/null -w "google:%{http_code}\n" https://www.google.com
pkill -f selftest.json; rm -f /tmp/selftest.json /tmp/selftest.log
# 返回 google:200 → 节点 100% 正常
```

> ⚠️ 若客户端连不上但自测通过 → 多半是**客户端内核太旧**连不上过新的 Xray，升级客户端；或把服务端 Xray 换成与客户端同代的稳定版。

### 1.7 服务器加固（重装后必做——这次被黑就是缺这步）
```bash
# a. 先放入你本机的 SSH 公钥（在本机 ssh-keygen 生成后，把 .pub 内容填进来）
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<粘贴你的 SSH 公钥 ssh-ed25519 AAAA...>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# b. 关掉密码登录（★务必先另开一个终端确认密钥能登进来，再执行这步★）
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd

# c. 防火墙：默认拒绝入站，只放行 SSH + 节点端口
apt-get update && apt-get install -y ufw
ufw default deny incoming; ufw default allow outgoing
ufw allow 22/tcp          # 若改了 SSH 端口，换成新端口
ufw allow 443/tcp         # REALITY 节点
ufw --force enable

# d. fail2ban 挡 SSH 暴力破解
apt-get install -y fail2ban && systemctl enable --now fail2ban

# e. 系统更新
apt-get update && apt-get -y upgrade
```
> **绝不再装 3x-ui 等公网面板**——本手册用纯 Xray，没有面板就没有面板入口（本次入侵正是暴露的 3x-ui 面板被打）。若确实要面板，务必绑定 `127.0.0.1` 后用 SSH 隧道访问，绝不 `0.0.0.0` 对全网裸奔。
> 验证加固：`ss -tlnp | grep -vE '127.0.0.1|::1'` 应只看到 22 和 443 在对外监听。

---

# 第二部分：客户端 —— Ubuntu v2rayA（TProxy + 分流 + DNS 分流）

前提：已装 v2rayA 且服务在跑（面板 http://127.0.0.1:2017）。内核 Xray。

### 2.1 导入节点
面板 → 导入 → 粘贴第 1.5 的 `vless://` 链接 → 选中节点。

### 2.2 设置：透明代理
设置页：
- 「透明代理/系统代理 实现方式」→ **tproxy**
- 「透明代理分流模式」→ **规则模式 / 大陆白名单**

### 2.3 设置：防止 DNS 污染（国内/国外 DNS 分流）
选「自定义/高级」，两个框分别填：
- **域名查询服务器（国内）**：
  ```
  https://dns.alidns.com/dns-query -> direct
  119.29.29.29 -> direct
  ```
- **国外域名查询服务器（国外）**：
  ```
  https://1.1.1.1/dns-query -> proxy
  ```
> 国外框必须用加密 DoH(`https://`) + `-> proxy`，否则国外域名被污染。此框留空是最常见的污染原因。
> 也可用 FakeIP 模式（nslookup 全返回 198.18.x，正常，不是污染），效果等价但兼容性略差。

### 2.4 设置：自定义路由（RoutingA）—— 最终可用版
```
default: proxy
domain(geosite:category-ads-all)->block
network(udp)&&port(443)->block
domain(geosite:google)->proxy
domain(geosite:cn)->direct
domain(geosite:private)->direct
ip(geoip:cn)->direct
ip(geoip:private)->direct
```
逐行作用：
- `network(udp)&&port(443)->block`：**屏蔽 QUIC/HTTP3**，治 Chrome 访问 Google 一直转圈（强制回退 TCP）。
- `domain(geosite:google)->proxy`：Google 全域名走代理，**且必须排在 `geosite:cn` 直连之前**。治 gstatic/fonts/Gemini 字体按键加载失败（gstatic 被 geosite:cn 误收进直连清单）。
- 其余：国内直连、国外(default)代理、内网直连、广告拦截。

### 2.5 连接
主页选节点 → 连接 → 顶部模式切「透明代理」并打开。

### 2.6 崩溃兜底（代理挂了不连累国内）
v2rayA 的 nft 表名是 `inet v2raya`。加 systemd drop-in：
```bash
sudo mkdir -p /etc/systemd/system/v2raya.service.d
sudo tee /etc/systemd/system/v2raya.service.d/failopen.conf >/dev/null <<'EOF'
[Service]
Restart=on-failure
RestartSec=2
ExecStopPost=-/usr/sbin/nft delete table inet v2raya
EOF
sudo systemctl daemon-reload && sudo systemctl restart v2raya
```
效果：xray 崩→2 秒自动重启；起不来→自动删表回退直连，国内照常。

---

# 第三部分：验证命令

```bash
# 国外走代理（应返回节点所在国 IP）
curl -4 -s --max-time 12 "http://ip-api.com/json/?fields=query,country,isp"; echo
# 国内直连（应返回国内 IP）
curl -s --max-time 10 https://www.cip.cc | head -3
# 国外 DNS 干净（google 应 142.x/2404: 真实IP，不是 185.45/2001::1 污染）
nslookup www.google.com 8.8.8.8 | grep Address | tail -n +2 | head
# gstatic 走代理（返回 404/204/200 都算通，能拿到码=连上了）
curl -sI --max-time 10 "https://www.gstatic.com/generate_204" -o /dev/null -w '%{http_code}\n'
# 兜底实测：停服务后国内应仍通
sudo systemctl stop v2raya; sudo nft list tables | grep v2raya   # 应无输出
curl -s --max-time 8 https://www.cip.cc | head -3                # 应秒回国内IP
sudo systemctl start v2raya
```

---

# 第四部分：排错速查表

| 症状 | 原因 | 解法 |
|---|---|---|
| Gemini 字体/按键加载失败、gstatic 打不开 | gstatic 被 geosite:cn 判成直连，直连 Google 被墙 | RoutingA 加 `domain(geosite:google)->proxy` 且放在 cn 直连**之前** |
| Chrome 访问 Google 一直转圈 | QUIC(UDP443) 未被正确代理 | RoutingA 加 `network(udp)&&port(443)->block`（或 chrome://flags 关 QUIC） |
| Gemini「not supported in your country」 | **这个出口 IP 被 Google 判区拒绝**（与机房/住宅无关，看 IP 历史声誉）；少数情况是账号地区锁 | 按 **5.10** 判定：同账号同设备**换节点 A/B** 打开 `gemini.google.com`。换节点就好=IP 问题，换了还报=账号锁。**别去改支付资料国家** |
| 导入某节点后 v2rayA 崩、节点全没了 | 该节点协议/参数 Xray 解析不了，拖垮整体配置 | 可疑节点单独建订阅；解析失败就是协议不支持 |
| nslookup 全是 198.18.x / fc00:: | FakeIP 模式，**正常不是污染** | 无需处理；想看真实 IP 就切回 DoH 显式分流 |
| nslookup 出现 185.45 / 2001::1 等 | 真·DNS 污染 | 检查「国外域名查询服务器」是否填了 DoH+proxy |
| curl gstatic 返回 404 | 请求根路径无内容，**连接是成功的** | 正常，用 `/generate_204` 测会返回 204 |
| 代理挂了整机断网（含国内） | TProxy 规则残留、进程没了 | 第 2.6 兜底；急救 `sudo systemctl restart/stop v2raya` |
| 客户端连不上但服务端自测(1.6)通过 | 客户端内核太旧 | 升级客户端；或服务端 Xray 降到同代稳定版 |
| 想让某个站点直连，但不确定它有没有被拉进隧道 | 解析到境外 IP 的域名不匹配 `geosite:cn`/`geoip:cn`，被 `default->proxy` 兜走 | 按 **5.9** 用受控实验判定（**别用 `ping`/`time_connect`/短 `curl` 探针，全是假信号**），再加 `domain(domain:xxx)->direct` |
| VPS CPU 99%、进程名像 `kswapd0` 但 **RES≠0** 或 `/proc/<pid>/exe` 指向 `/etc`、`/tmp`、`/dev/shm` | **挖矿木马冒充内核线程**，多因暴露的 3x-ui 面板被入侵 | 真内核线程 RES=0、exe 指不到文件、PPID=2；反之即木马。备份参数→重装系统→按 1.7 加固，别装公网面板 |

---

# 关键取值备忘（本次实例，换机需重新生成）

- 服务端 nft 无关；**客户端 v2rayA 的 nft 表名 = `inet v2raya`**（兜底删表用）。
- REALITY 端口固定 **443**，SNI `www.tesla.com`。
- 凭据（UUID/PrivateKey/PublicKey/shortId）**每台服务器用 `xray x25519`/`uuid`/`openssl rand` 重新生成**，切勿跨机复用。
- 国内 DNS：`223.5.5.5`/`https://dns.alidns.com/dns-query`、`119.29.29.29`；国外 DNS：`https://1.1.1.1/dns-query`。

---

# 第五部分：线路诊断与「精品线路」防骗（重要）

> 场景：节点能连、能上网，但**看 YouTube/下载龟速**。多数不是配置问题，而是**跨境线路**被超售或被虚假宣传。本节给出一套定位方法，10 分钟判断「机器带宽真假 / 瓶颈在哪 / 商家有没有骗你」。

## 5.1 三段测速法：定位瓶颈到底在哪

关键思路：**分别测「本机→VPS→国际」和「VPS本地→国际」**，一对比就知道瓶颈是不是在跨境段。

```bash
# ① 本机经代理测速（走 VPS 出海的真实体验）
curl -s -o /dev/null -w "经代理: %{speed_download} B/s\n" --max-time 30 \
  "https://speed.cloudflare.com/__down?bytes=10000000"

# ② SSH 到 VPS，测 VPS 本地到国际（绕开中国这一段）
ssh -p <port> root@<vps-ip> \
  'curl -s -o /dev/null -w "VPS本地: %{speed_download} B/s\n" --max-time 30 \
   "https://speed.cloudflare.com/__down?bytes=50000000"'
```

判读：

| ① 经代理 | ② VPS 本地 | 结论 |
|---|---|---|
| 慢（如 0.1 Mbps） | 快（如 47 Mbps） | **瓶颈在跨境链路**：先按 5.2.1 分运营商复核（很可能是"你的运营商吃不到该精品线路"，如移动↔9929），其次才是超售/虚假宣传/晚高峰。改配置无用 |
| 慢 | 也慢 | **VPS 整体被限速**：找商家，可能是套餐限速或母鸡超售 |
| 快 | 快 | 线路没问题，卡是客户端本地（分流/DNS/网卡）问题 |

> 真实案例（LisaHost 192.220.22.76，2026-07）：经代理 **0.12 Mbps**，VPS 本地 **47 Mbps** → 坐实瓶颈在跨境段。

## 5.2 用 mtr/traceroute 验证「9929 / CN2 GIA」是不是真的

低价 VPS 常见套路：标称「9929 精品 / CN2 GIA」，实际给普通 NTT/163 中转。用路由跟踪对照 AS 号即可识破。

```bash
mtr -n -c 10 -r <vps-ip>          # 或 traceroute -n <vps-ip>
```

看去程/回程经过的骨干网 IP 段，对照下表：

| 宣传 | 应出现的节点特征 | 冒充它的常见「李鬼」 |
|---|---|---|
| **联通 AS9929**（精品） | `218.105.x` / `219.158.x`（联通骨干） | NTT `129.250.x`、移动 `223.120.x` |
| **电信 CN2 GIA**（顶级） | `59.43.x.x`（CN2 专属段） | 普通 163 `202.97.x` |
| **CN2 GT**（次级） | `59.43.x.x` 但绕路多 | — |
| 普通 NTT | `129.250.x.x`（AS2914） | — |
| 普通移动 CMI | `223.120.x` / `221.183.x`（AS58807/9808） | — |

**判定规则**：宣传的段一个都没出现，全程是「李鬼」段 → 可能虚假宣传。**但下结论前必须先做 5.2.1 的分运营商复核**——同一台 VPS 对电信/联通/移动可能是三条完全不同的线路。

## 5.2.1 ★ 关键：必须按「你自己上网的运营商」测回程，别只测一个就下结论

**血泪教训**：一台真 9929 的 VPS，只测「到移动用户」的回程会全程移动 CMI、看不到一个联通节点，极易误判成「假 9929」。真相是——**9929 是联通线路，只有电信/联通用户能接入；中国移动国际出口是独立 CMI，永远吃不到联通 9929**，在国内就被甩到移动骨干（`221.183.x`/`223.120.x`/`111.24.x`）走又挤又烂的移动国际出口。

正确做法：从 VPS 分别对**电信/联通/移动**各测一次回程：

```bash
# 在 VPS 上,对三网各选一个测试 IP 跑回程 mtr
for t in "202.106.195.68:北京联通" "219.141.140.10:北京电信" "<你家真实公网IP>:你的运营商"; do
  ip="${t%%:*}"; echo "== ${t##*:} =="; mtr -n -c 10 -r "$ip" | tail -12
done
```

判读：
- 到**电信/联通**出现 `218.105.x`/`219.158.x` → **9929 是真的**（商家没骗）。
- 到你家（若是**移动**）全程 `221.183.x`/`223.120.x` → 不是没 9929，是**移动接入不了 9929**。
- **结论取决于「你自己的运营商」那一条**：真凶常是「移动宽带 ↔ 9929 不匹配」，不是虚假宣传。

> 真实案例（LisaHost 192.220.22.76）：到北京电信/联通均见 `218.105.x`（真 9929 ✅），但到广东移动家宽全程移动 CMI（龟速 0.12M）。**是真 9929，只是家用移动宽带吃不到**。移动用户看视频需 **CMIN2 或香港中转**；此机对**联通手机开流量**则很快。**先前只测移动就误判成"假9929"，是典型错误。**

### 运营商 × 线路 匹配速查
- **9929 / CN2 / CU 精品**：电信、联通用户吃得到；**移动吃不到**。
- **移动用户**要快 → 找 **CMIN2**（移动自家精品）或 **香港/日本中转**（移动到港近，港再出海）。
- **决定走哪条线的是「当前上网出口的运营商」，不是手机 SIM**：手机连 WiFi 走的是路由器宽带的运营商；开流量才走 SIM 的运营商。

## 5.3 延迟与丢包基线（判断线路稳不稳）

```bash
ping -c 15 -i 0.3 <vps-ip>        # 看 avg 和 mdev(抖动)、丢包率
```

- **深圳→美西**物理极限 ~150–180ms，改任何配置都压不下去（光速限制）；卡视频是**吞吐**问题不是延迟问题。
- `mdev`（抖动）大、丢包高 → 线路劣质或晚高峰拥塞。稳定低抖动+0丢包但慢 → 是带宽被限，不是线路烂。
- 想看视频流畅：选**物理近**的节点——香港/日本/新加坡 ~30–80ms，跨境带宽足，1080p 秒开。美西留作「判美落地」（ChatGPT/Netflix 美区）。

## 5.4 排查「节点是否被蹭」（多设备/UUID 泄露后）

```bash
# 在 VPS 上看 443 端口所有活动连接的来源 IP
ssh -p <port> root@<vps-ip> \
  'ss -tn state established "( sport = :443 )" | grep ":443" | awk "{print \$4}" \
   | sed "s/.*ffff://; s/:.*//" | sort | uniq -c | sort -rn'
```

- 全是自己的家宽/移动 IP（多条属正常，浏览器多路复用 + 残留连接）→ **没被蹭**。
- 出现大量陌生 IP → UUID 可能泄露，按 5.5 换 UUID。

## 5.5 换 UUID（链接泄露 / 疑似被蹭时）

```bash
# VPS 上：生成新 UUID → 替换 config → 重启
NEW=$(xray uuid)
cp /usr/local/etc/xray/config.json /root/config.json.bak
OLD=$(grep -oP '"id"\s*:\s*"\K[^"]+' /usr/local/etc/xray/config.json | head -1)
sed -i "s/$OLD/$NEW/g" /usr/local/etc/xray/config.json
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json   # 应 Configuration OK
systemctl restart xray && systemctl is-active xray
echo "新 UUID: $NEW"   # 各客户端用它重新导入链接
```

⚠️ **坑**：若你正**经这台 VPS 的代理**去 SSH 它，`restart xray` 会瞬间掐断自己的 SSH 隧道（出口就是本机）——断开是正常的，直连重连即可，VPS 侧改动已生效。稳妥做法：SSH 走**直连**（不经代理）再执行。VPS 若无 `jq`，用上面的 `sed` 方案即可。

## 5.5.1 ★ 全套凭据轮换（私钥泄露时必做，换 UUID 不够）

**什么时候要走这节而不是 5.5**：只要 **REALITY `privateKey`** 有可能外泄（贴进聊天/AI对话/工单/截图/日志，或 `cat` 过凭据文件），**换 UUID 是不够的**——拿到私钥的人可以冒充你的服务端做中间人、也能解密握手。必须把 `privateKey` / `UUID` / `shortId` **三样全部重生成**。

```bash
set -e
cd /usr/local/etc/xray
cp config.json /root/config.json.bak.$(date +%s)

# 1) 生成全新三件套
KEYS=$(/usr/local/bin/xray x25519)
PRIV=$(echo "$KEYS" | grep -iE "^private|^PrivateKey" | awk '{print $NF}')
PUB=$(echo "$KEYS"  | grep -iE "^password|^public"    | awk '{print $NF}')
NEWUUID=$(/usr/local/bin/xray uuid)
NEWSID=$(openssl rand -hex 8)

# 2) 取出旧值（VPS 常无 jq，用 grep -oP）
OLDPRIV=$(grep -oP '"privateKey":\s*"\K[^"]+' config.json)
OLDUUID=$(grep -oP '"id":\s*"\K[^"]+' config.json)
OLDSID=$(grep -oP '"shortIds":\s*\["\K[^"]+' config.json)

# 3) 整文件替换
sed -i "s|${OLDPRIV}|${PRIV}|g; s|${OLDUUID}|${NEWUUID}|g; s|${OLDSID}|${NEWSID}|g" config.json

# 4) 校验后重启
/usr/local/bin/xray run -test -config config.json     # 必须 Configuration OK
systemctl restart xray && systemctl is-active xray

# 5) 只打印客户端需要的【公开】参数，私钥留在服务器
printf 'UUID=%s\nPUBLIC_KEY=%s\nSHORT_ID=%s\n' "$NEWUUID" "$PUB" "$NEWSID"
# 私钥另存本地只读文件，不要回显
printf 'PRIVATE_KEY=%s\n' "$PRIV" > /root/reality-creds.txt && chmod 600 /root/reality-creds.txt
```

拿 5 步输出的三个公开值按 **1.5** 重新拼 `vless://` 链接，**所有客户端（桌面/手机/Mac）都要重新导入**，旧链接立即失效。

### 轮换后的两个必踩坑

| 现象 | 原因 | 解法 |
|---|---|---|
| 换完 SSH 连不上，`:22/:443` 全是 **Connection refused**（不是 timeout） | 客户端 TProxy 把去 VPS 的包也拉进了**凭据已失效的隧道**，本地 xray 直接 RST。**服务器其实好着** | 先在客户端导入新链接；或 `sudo systemctl stop v2raya`（`sudo nft delete table inet v2raya`）后直连 SSH |
| 不确定新凭据对不对，又没法从国内验 | — | 在**服务端本机**按 **1.6** 用新参数自测，`google:200/302` 即凭据正确；顺手 `curl` 一下 speed.cloudflare 看隧道内吞吐 |

> 🔒 **铁律：绝不 `cat` 含私钥的文件**（`/root/reality-creds.txt`、`config.json`）。要看就 `grep` 具体的公开字段，或只 `echo` PublicKey/UUID。凭据一旦进过任何对话、日志、工单、截图，就当它**已经泄露**，立刻按本节轮换——重生成的成本是 1 分钟，泄露的代价是整条链路可被 MITM。

## 5.6 排错速查补充

| 症状 | 原因 | 解法 |
|---|---|---|
| 能连但下载/视频龟速，改配置无效 | 多为跨境链路；**最常见是运营商不匹配**（移动↔9929/CN2） | 先 5.2.1 分运营商复核；确认不匹配就换匹配线路(移动→CMIN2/香港)；确系超售/造假再按 5.2 维权 |
| 标称 9929/CN2 但你这慢 | 优先怀疑**你的运营商接入不了**该线路，其次才是李鬼 | 5.2.1 对电信/联通/移动分别测回程；到电信/联通有 218.105 就是真的 |
| `restart xray` 后 SSH 卡死/断开 | SSH 走了经该 VPS 的代理，重启掐断隧道 | SSH 改直连；断了重连，改动已生效 |

## 5.7 维权工单模板（线路虚假宣传 / 带宽缩水）

> ⚠️ **开工单前先做 5.2.1**：确认到**电信/联通**的回程也没有宣传的精品段，才谈得上"造假"。如果只是你自己是**移动宽带**吃不到 9929/CN2，那**不是商家的错**——别去维权，直接换匹配移动的线路（CMIN2/香港）或改用别的运营商出口。

确认确系造假/缩水后，用 5.1 + 5.2 + 5.2.1 的证据开工单：

```
标题：实例 <IP> 线路与宣传不符，要求换线或退款

正文：
购买的「<套餐名，如 美国9929精品>」套餐，实测：
1. 从 VPS 回程 traceroute 到【电信/联通】测试IP,均未见宣传的
   <应有 AS，如 联通 AS9929 的 218.105/219.158> 节点,全程走 <实际 AS>;
2. 从中国大陆经代理下载仅 <如 0.12> Mbps，而 VPS 本地到国际测速为 <如 47> Mbps，
   证明瓶颈在跨境线路而非机器带宽，与宣传 <如 50>Mbps 严重不符。
要求：①更换为宣传所述真实线路，或 ②按未使用时长退款。
```

> 维权只打「线路 AS 造假」+「带宽缩水」两点最硬（有客观证据），且证据必须是**到电信/联通**的回程（排除"自己是移动吃不到"这一非商家责任的情形）。
> **不要**拿「住宅IP」说事——很多机房段 `is_hosting=false`、判区干净，本就够用，纠缠这点反而弱化主张。

## 5.8 IP 质量判断（判美/判区是否好用）

用 `ipinfo.io/<ip>/json` 或 `https://ipinfo.io/widget/demo/<ip>` 看这几个字段：

| 字段 | 好（判区干净） | 差（易被墙/判为代理） |
|---|---|---|
| `is_hosting` | `false` | `true`（标准机房，Netflix 常拦） |
| `is_vpn`/`is_proxy`/`is_tor` | 全 `false` | 任一 `true` |
| `as.type` | `isp` | `hosting` |

- 全绿 → 登 ChatGPT / 看 Netflix 美区 / 各种判区服务**好用**，即使不是真住宅 IP。
- 有红 → 大概率被流媒体/Google 拦，判区场景别指望。
- **线路快慢（5.1）与 IP 干净（本节）是两回事**：一台可以「IP 很干净但跨境龟速」——判美好用、看视频不行，各取所需。

> ⚠️ **本表只是先验概率，不是判决书——尤其对 Gemini 完全不适用**。实测反例：一台 `AS36352 HostPapa` / `as.type: hosting` / **`is_hosting: true`** 的标准机房 IP，Gemini 开得好好的；另一台同为机房 IP 的却报「not supported in your country」。**决定 Google 判区结论的是「这个 IP 的历史行为」（有没有跑过挖矿/扫描/滥用、有没有被大量薅羊毛），而 `is_hosting` 只说明它在机房**。想知道某站点到底能不能用，只能**实测那个站点**，见 5.10。

## 5.9 ★ 判定「某站点走代理还是直连」，并给指定域名开直连

> 场景：某个站点（内网 API、国内加速的服务、公司系统）你**希望它直连**，但不确定 TProxy 有没有把它拉进隧道。下面先给**可靠的判定法**，再给改法。

### 先记住三个「看起来能判、实际不能判」的坑

| 方法 | 为什么不能用 |
|---|---|
| 看 `curl` 的 `time_connect` | TProxy 下 TCP 握手由**本地 xray 直接应答**，`connect` 恒为 ~0.0001s。直连站和代理站**完全一样**，区分不了 |
| `ping` 目标 IP 的 RTT | **ICMP 不被 TProxy 拦**，永远走直连路径。遇上 anycast 更会落到就近 PoP，给出与 TCP 毫不相干的 RTT（实测同一站：ICMP 86ms / 走代理 TLS 655ms / 直连 TLS 143ms） |
| `curl --max-time 5` 打一发，去出口侧看有没有连接 | **最阴的假阴性**：若该域名 DNS 慢（本例 4–6 秒），请求在进入 TCP 阶段前就超时了，压根没连上 → 出口侧当然是 0 条 → 被读成「直连」。**探针自己失败，长得和直连一模一样** |

勉强能用的弱信号是 `time_appconnect - time_connect`（TLS 握手净耗时）：一个往返量级≈直连，明显翻倍=绕了出口。但要定性还得看下面。

### 受控实验法（唯一可靠）

思路：**在本机挂住 N 条长连接，同时到出口 VPS 上数目的 IP 的 ESTABLISHED**——计数精确 `+N` 才是走代理，恒为 0 才是直连。

```bash
DOMAIN=<要测的域名>; PREFIX=<该域名解析出的 IP 前缀，如 203\.0\.113\.>
q(){ ssh -p <port> root@<vps-ip> "ss -tn state established | grep -cE '$PREFIX'"; }

echo "基线:  $(q)"                    # 记下基线，不能只看绝对值
for i in 1 2 3; do                    # 挂 3 条真实 TLS 长连接(sleep 喂 stdin 保持不关)
  sleep 40 | openssl s_client -connect $DOMAIN:443 -servername $DOMAIN -quiet >/dev/null 2>&1 &
done
sleep 9
echo "本机侧: $(ss -tn state established | grep -cE "$PREFIX")"   # ★必须非 0
echo "出口侧: $(q)"
kill $(jobs -p) 2>/dev/null
```

判读：

| 本机侧 | 出口侧 | 结论 |
|---|---|---|
| 非 0 | 基线 **+N** | **走代理** |
| 非 0 | 仍是**基线** | **直连** |
| **0** | 任意 | ❌ **实验无效**——连接压根没建立，出口侧的 0 是假阴性。查 DNS 是否超时、域名端口是否对 |

两条铁律：
1. **必须确认本机侧真的建立了连接**（`ss` 计数非 0），这是防假阴性的唯一防线。
2. **必须取基线看增量**。出口 VPS 常被多端共用（桌面/手机/Mac），别人的流量会污染绝对值。拿一个**已知国内站**（如 `www.baidu.com`）同时做对照组最稳：它在出口侧应恒为 0。

### 改法：给指定域名开直连

先确认分流规则**实际生效的样子**。注意 `/etc/v2raya/config.json` **不是 v2rayA 的设置文件，而是它生成给 xray 的运行时配置**（`xray run --config=` 指向它）；v2rayA 自己的设置在同目录 boltdb 里，grep `"mode"` 之类什么都匹配不到。

```bash
# 只打印路由规则(不含 UUID,可安全外发)。★ 别在对象里用 // empty,见下面的坑
sudo jq -r '.routing.rules | to_entries[] | "\(.key) out=\(.value.outboundTag // "-") \
 net=\(.value.network // "-") port=\(.value.port // "-") \
 domain=\(((.value.domain // []) | join(","))[0:100]) ip=\(((.value.ip // []) | join(","))[0:100])"' \
 /etc/v2raya/config.json
```

> 💥 **jq 的坑（曾据此得出完全错误的结论）**：jq 对象构造是**生成器的笛卡尔积**，`{out: .outboundTag, domain: (.domain // empty)}` 在 `.domain` 缺失时会让**整个对象消失**，不是只少一个字段。每条路由规则天然只带 domain/ip/port 之中的一个 → 19 条规则被全部抹掉、输出 `[]`，很容易误判成「路由规则是空的 / xray 跑的是陈旧配置」。**要省略字段就直接写 `.domain`（缺失时为 null）**，并用 `(.routing.rules|length)` 单独核对条数。

看清结构后就能定位原因。典型分工是：**nft 表 `inet v2raya` 的 `whitelist` 只含私有网段**（没有国内 IP 集合），它只负责把所有公网流量打标送进 xray；**国内外分流全在 xray 的 `routing.rules` 里**。于是一个**解析到境外 IP** 的域名（例如落在 AWS/Cloudflare anycast 上），既不匹配 `geosite:cn` 也不匹配 `geoip:cn`，就会被最后的 `default->proxy` 兜进隧道。

改法：面板 → 设置 → **自定义路由(RoutingA)**，在规则**最前面**加一行：

```
domain(domain:example.com)->direct
```

- `domain:` 前缀是**子域匹配**，`api.example.com`/`code.example.com` 一并覆盖。
- 放最前面，确保排在所有 `block`/`proxy` 规则之前。
- 透明代理下能按域名匹配靠 **sniffing**；若原有 `geosite:google`/`geosite:cn` 规则一直正常，说明 sniffing 是开着的，这行就会生效。想再兜一层可加 `ip(<IP>/32)->direct`，但 anycast 地址常与别的服务共用，会顺带放行它们，一般不必。
- 保存会**重启 xray、连接闪断**。改完用上面的受控实验复验：出口侧应变成恒为 0。

⚠️ **DNS 分流和流量分流是两套配置**：加了直连规则后，该域名的**解析**仍按「国外域名」走加密 DoH 经隧道查询（首次可能仍要几秒）。有 DNS 缓存所以只卡首访；真要治只能在 `/etc/hosts` 钉死 IP，代价是 anycast 地址变更后要手动更新（表现为突然连不上）。

## 5.10 ★ Gemini/判区类服务打不开：怎么定位是 IP、账号还是配置

> 场景：Gemini 报 `Gemini isn't currently supported in your country. Stay tuned!`，但同一节点下 Gmail、搜索、YouTube 全正常。

### 唯一可靠的判定法

**同一台设备、同一个 Google 账号、保持登录状态，只换节点，打开 `gemini.google.com`。**

| 换到另一个节点后 | 结论 |
|---|---|
| 能正常打开 | **就是原节点的出口 IP 问题**。换节点或换机器，配置别动 |
| 还是同样报错 | 才轮到怀疑**账号地区锁**（该账号长期在被判为受限地区的 IP 下使用） |

一次 A/B 就能定性，比下面任何侧面信号都强。

### 六个「看着能判、其实全判不出来」的信号（都实测踩过）

| 信号 | 为什么没用 |
|---|---|
| IP 地理位置（`gl=US`、`cdn-cgi/trace` 的 `loc=US`） | 能开的和不能开的**两台都是 US**。判区结论不等于地理位置 |
| ip-api 的 `proxy=false` / `hosting=false` | 两台都显示"干净"，区分不了 |
| ipinfo 的 `privacy` 全 false、`is_anonymous:false` | 同上。**`is_hosting:true` 也照样能开 Gemini**（见 5.8 的警告） |
| **直接打开 `https://www.google.com/sorry/index`** | ❌ **最坑的一个**。这个 URL 本来就是渲染验证码页的，**任何节点访问它都出「unusual traffic」页**——能开 Gemini 的节点也出。拿它判黑名单会得到 100% 假阳性 |
| 无痕模式 / 未登录访问 | 落地页**不套用登录后的区域门禁**，无痕下能打开不代表登录后能用 |
| 支付资料国家（Payments profile Country/Region 显示 HK） | 红鲱鱼。官方支持列表里有香港，**且千万别点「Create new profile」**——那是不可逆的账户变更，跟 Gemini 判区无关 |

### 唯一能用的侧面信号（比 A/B 弱，但一条命令就能跑）

不是"访问 `/sorry`"，而是**看 `gemini.google.com` 会不会被弹到 `/sorry`**：

```bash
for u in https://www.google.com/ https://gemini.google.com/; do
  printf '%-32s ' "$u"
  curl -4 -s -o /dev/null -w 'code=%{http_code} -> %{redirect_url}\n' --max-time 15 \
    -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36' "$u"
done
```

判读（关键是**两行对比**，不是看单行）：

- `www.google.com` 正常（200，或 302 到 `.com.hk`——这是无 cookie 时的 ccTLD 跳转，**不是被封**），而 `gemini.google.com` **302 到 `/sorry/index`** → 这个出口被 Gemini 单独拒绝了 ✅ 与实际报错吻合。
- 两行都正常 → 该 IP 对 Gemini 没有拦截。
- 两行都被弹 `/sorry` → 整个 IP 被 Google 限流，不只是 Gemini。

### 顺带排除「是不是套了 WARP / 到底走没走代理」

```bash
curl -4 -s --max-time 12 https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|warp|colo)='
```

`warp=` 是 **Cloudflare 自己**报告这个请求有没有从它的 WARP 隧道进来，比任何第三方 IP 库都权威；`ip=` 同时给出真实出口（可核对是不是你选的节点，顺便验证代理确实生效）。

> **别指望 WARP 解锁 Gemini**：WARP 出口是 AS13335 的巨型共享池，Google 当匿名器处理，`/sorry` 验证码和判区拦截反而**更多**。WARP 的口碑在 ChatGPT 和 IPv6，不在 Google 判区。

### 结论与对策

- **同为机房 IP，能不能开 Gemini 的差别在「这个 IP 的历史行为」**——被入侵过、跑过矿马/扫描的 IP，**重装系统洗不掉 Google 那边的账**（IP 没变）。这也是 1.7 加固值得做的另一个理由：一次沦陷可能永久损伤这个 IP 的判区能力。
- **换更贵的「精品线路」（CN2 GIA / 9929 / CMIN2）不解决判区问题**：那是**线路质量**（5.1/5.2），判区看的是**IP 声誉**（5.8/5.10），**两个正交的轴**。花钱买 CMIN2 是为了看视频不卡，不是为了开 Gemini。
- **⚠️ v2rayA 做不到「按域名分发到不同节点」**：它的 outbound 只有 `proxy`（=唯一选中的那个节点）/`direct`/`block`/`dns-out`，RoutingA 里写什么规则都只能在这几个里选。**想同时要「快节点」和「能开 Gemini 的节点」，得把客户端内核换成 mihomo(Clash.Meta) 或 sing-box**，用 proxy-group：

  ```
  gemini.google.com, generativelanguage.googleapis.com  →  解锁节点
  其余国外                                              →  快节点
  geosite:cn                                            →  direct
  ```
  Gemini 是纯文本交互，分给慢节点也无所谓。

---

# 第六部分：★ 服务端 BBR + TCP 调优（新 VPS 必做，优先级高于一切排错）

> **这是「代理慢」最常见、最容易被忽略的根因。** 排查顺序应该是：**先查这里 → 再怀疑线路/运营商 → 最后才怀疑被蹭/造假**。
> 真实案例：一台 50M 的美西 VPS，调优前移动出口 **0.12 Mbps**、联通出口 6.7 Mbps；开 BBR + 调缓冲后 → 移动 **7.6 Mbps（63倍）**、联通 **32 Mbps（4.8倍）**。**线路一个字没改。**

## 6.1 为什么必须做（两个硬伤）

**① 默认缓冲区把高延迟链路锁死在 ~9 Mbps**

TCP 单连接吞吐上限 = `缓冲区 ÷ RTT`。Ubuntu 默认 `rmem_max/wmem_max` 只有 **208KB**：

```
中美链路 RTT 180ms，带宽 50Mbps
需要的 BDP = 50e6 × 0.18 ÷ 8 ≈ 1.125 MB
实际上限   = 208KB
单连接天花板 = 208KB ÷ 0.18s ≈ 9.2 Mbps   ← 线路再好也吃不满
```

**② `cubic` 在丢包链路上直接崩**

默认拥塞控制 `cubic` **把丢包当拥塞信号**，一丢包就大幅降速。跨境线路（尤其中国移动 CMI）丢包常见 → 速度崩到 0.1 Mbps 级。
**BBR 以实测带宽和 RTT 建模、不看丢包**，同一条烂线能拉回几十倍。**「这条线没救」往往只是拥塞算法没选对。**

## 6.2 体检（先看你的机器中没中招）

```bash
sysctl net.ipv4.tcp_congestion_control    # 是 cubic/reno = 没开 BBR
sysctl net.core.default_qdisc             # 该是 fq
sysctl net.core.rmem_max net.core.wmem_max # 208992 = 裸默认，必须调
sysctl net.ipv4.tcp_slow_start_after_idle # 该是 0
uname -r                                  # >= 4.9 才支持 BBR
```

## 6.3 一键调优（幂等，可回滚）

```bash
# BBR 模块 + 开机自载
modprobe tcp_bbr
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

cat > /etc/sysctl.d/99-network-tuning.conf <<'EOF'
# ---- BBR + fq ----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ---- 缓冲区: 匹配高延迟跨境链路 BDP ----
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

sysctl -p /etc/sysctl.d/99-network-tuning.conf

# 验证
sysctl -n net.ipv4.tcp_congestion_control   # 应输出 bbr
sysctl -n net.core.default_qdisc            # 应输出 fq
lsmod | grep bbr
```

**回滚**：`rm /etc/sysctl.d/99-network-tuning.conf && sysctl --system`

> 调优只改内核参数，**不影响 SSH、不用重启、xray 不用动**。改完**立即在客户端实测**（服务端本地测速看不出效果，因为本地出海本来就没瓶颈——**必须从中国这端测**）。

## 6.4 缓冲区数值怎么定

`rmem_max ≥ 带宽(bps) × RTT(s) ÷ 8`，再乘 2-4 倍余量给多连接：

| 链路 | RTT | 带宽 | BDP | 建议 rmem_max |
|---|---|---|---|---|
| 中美（美西） | ~180ms | 50M | 1.1MB | 16–32MB |
| 中港/中日 | ~40ms | 100M | 0.5MB | 8–16MB |
| 中美（高带宽） | ~180ms | 500M | 11MB | 64MB+ |

上面模板给的 32MB 覆盖绝大多数场景，内存 1G 的小鸡也扛得住（这是上限不是预分配）。

## 6.5 排错速查补充

| 症状 | 原因 | 解法 |
|---|---|---|
| 代理速度只有零点几 Mbps，线路却正常 | `cubic` 遇丢包崩溃 | 开 **BBR**（6.3），丢包链路可提升数十倍 |
| 速度稳定卡在 ~9 Mbps 上不去 | `rmem_max` 208KB 默认值 × 180ms RTT 的天花板 | 调大缓冲区（6.3/6.4） |
| VPS 本地测速正常、客户端很慢 | 别急着怪线路 | **先做 6.2 体检**，多数是没调优；再按 5.2.1 分运营商测回程 |
| 调优后服务端本地测速没变化 | 正常 | 服务端出海本无瓶颈，**效果只在中国这端体现** |

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
| Gemini「not supported in your country」 | **机房 IP 被封** 或 **Google 账号地区=中国** | 用住宅/家宽 IP 落地；或用只在美国 IP 下使用的干净账号。换 IP 若无效则是账号锁 |
| 导入某节点后 v2rayA 崩、节点全没了 | 该节点协议/参数 Xray 解析不了，拖垮整体配置 | 可疑节点单独建订阅；解析失败就是协议不支持 |
| nslookup 全是 198.18.x / fc00:: | FakeIP 模式，**正常不是污染** | 无需处理；想看真实 IP 就切回 DoH 显式分流 |
| nslookup 出现 185.45 / 2001::1 等 | 真·DNS 污染 | 检查「国外域名查询服务器」是否填了 DoH+proxy |
| curl gstatic 返回 404 | 请求根路径无内容，**连接是成功的** | 正常，用 `/generate_204` 测会返回 204 |
| 代理挂了整机断网（含国内） | TProxy 规则残留、进程没了 | 第 2.6 兜底；急救 `sudo systemctl restart/stop v2raya` |
| 客户端连不上但服务端自测(1.6)通过 | 客户端内核太旧 | 升级客户端；或服务端 Xray 降到同代稳定版 |
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
| 慢（如 0.1 Mbps） | 快（如 47 Mbps） | **瓶颈在跨境链路**：线路超售 / 被虚假宣传 / 晚高峰拥塞。改配置无用 |
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

**判定规则**：宣传的段一个都没出现，全程是「李鬼」段 → **虚假宣传**，可据此维权。

> 真实案例：标称「美国9929精品」，mtr 全程 `129.250.x.x`（NTT AS2914）+ 前段移动 `223.120.x`，**无任何 `218.105/219.158` 联通节点** → 实为「移动→NTT」普通中转，非 9929。

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

## 5.6 排错速查补充

| 症状 | 原因 | 解法 |
|---|---|---|
| 能连但下载/视频龟速，改配置无效 | 跨境线路超售/虚假宣传 | 按 5.1 三段测速定位；5.2 验线路真假；据此维权或换近距离节点 |
| 标称 9929/CN2 但慢 | 李鬼线路 | 5.2 对照 AS 段；无宣传段=虚假宣传 |
| `restart xray` 后 SSH 卡死/断开 | SSH 走了经该 VPS 的代理，重启掐断隧道 | SSH 改直连；断了重连，改动已生效 |

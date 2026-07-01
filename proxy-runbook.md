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

---

# 关键取值备忘（本次实例，换机需重新生成）

- 服务端 nft 无关；**客户端 v2rayA 的 nft 表名 = `inet v2raya`**（兜底删表用）。
- REALITY 端口固定 **443**，SNI `www.tesla.com`。
- 凭据（UUID/PrivateKey/PublicKey/shortId）**每台服务器用 `xray x25519`/`uuid`/`openssl rand` 重新生成**，切勿跨机复用。
- 国内 DNS：`223.5.5.5`/`https://dns.alidns.com/dns-query`、`119.29.29.29`；国外 DNS：`https://1.1.1.1/dns-query`。

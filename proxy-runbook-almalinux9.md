# AlmaLinux 9 / RHEL 系服务端适配（VLESS+REALITY）

> **用途**：[proxy-runbook.md](proxy-runbook.md) 的服务端部分是 Ubuntu 版，直接套到 AlmaLinux / Rocky / RHEL 9 上有一半命令会报错。本篇只写**差异**和**主手册没有的坑**，其余（凭据生成、config.json 结构、1.6 自测、客户端配置、线路诊断）一律照主手册。
> **前提**：一台干净的 AlmaLinux 9 VPS（root）。已在搬瓦工 AlmaLinux 9.7 / kernel 5.14 / 2C1G 上验证通过（2026-08）。
> **目标**：用[一键脚本](scripts/vps-bootstrap-almalinux9.sh)在 EL9 上把主手册 1.1–1.7 + 第六部分走完，全程幂等、可重跑自愈。

---

## 0. 一键脚本（推荐）

主手册所有服务端步骤已封装成 [`scripts/vps-bootstrap-almalinux9.sh`](scripts/vps-bootstrap-almalinux9.sh)，**幂等**，可分步执行：

```bash
scp -P <port> scripts/vps-bootstrap-almalinux9.sh root@<vps-ip>:/root/
ssh -p <port> root@<vps-ip>

bash /root/vps-bootstrap-almalinux9.sh check       # 只读体检，不改任何东西
bash /root/vps-bootstrap-almalinux9.sh node        # 主手册 1.1-1.5 装 Xray + REALITY
bash /root/vps-bootstrap-almalinux9.sh tune        # 主手册 6.3 BBR + TCP 缓冲区
SSH_PUBKEY='ssh-ed25519 AAAA...' \
  bash /root/vps-bootstrap-almalinux9.sh secure    # 主手册 1.7 firewalld/fail2ban/公钥/更新
bash /root/vps-bootstrap-almalinux9.sh selftest    # 主手册 1.6 本机自测，要 google:200
bash /root/vps-bootstrap-almalinux9.sh link        # 输出 vless:// 链接
bash /root/vps-bootstrap-almalinux9.sh harden-ssh  # ★另开终端确认密钥可登后才跑：关密码登录
```

可用环境变量：`SNI=` `PORT=` `NODE_NAME=` `SSH_PUBKEY=`。

设计要点：
- **私钥永不回显**，只写入 `/root/reality-creds.txt`（600）。`link` 只拼公开参数（UUID/PublicKey/shortId）。
- **`harden-ssh` 单独一步**，不并入 `secure`。脚本硬检查 `authorized_keys` 非空 + 交互确认 + `sshd -t` 语法校验，任一不过就中止且不动原配置。
- 重跑能**自愈坏状态**（如下面第 1 条的权限问题）。

---

## 1. ★ `config.json` 权限：`run -test` 会骗过你

**这是本篇最值得记的一条，且不是 EL9 特有——凡是用官方 systemd 单元的发行版都会中，包括 Ubuntu。**

官方安装脚本生成的 `/etc/systemd/system/xray.service` 里跑的是 **`User=nobody`**。如果按「配置含私钥就该锁死」的直觉给：

```bash
chmod 600 /usr/local/etc/xray/config.json   # ← root:root 独占，nobody 读不到
```

结果是：

```bash
xray run -test -config /usr/local/etc/xray/config.json
# → Configuration OK        ★ 这一步是 root 执行的，照样通过，完全骗过校验

systemctl restart xray && systemctl is-active xray
# → failed
journalctl -u xray -n 5
# → Failed to start: main: failed to load config files: ... permission denied
```

**校验通过 ≠ 服务能跑。** 现象是「`Configuration OK` 但服务起不来」，极易误判成 JSON 写错、REALITY 参数不对，从而去反复改配置——方向完全错了。

正确权限：

```bash
SVC_USER=$(awk -F= '/^User=/{print $2; exit}' /etc/systemd/system/xray.service)
chown "root:${SVC_USER:-nobody}" /usr/local/etc/xray/config.json
chmod 640 /usr/local/etc/xray/config.json
# 验证服务用户真的读得到（别只看 ls）
runuser -u "${SVC_USER:-nobody}" -- test -r /usr/local/etc/xray/config.json && echo readable
```

`640 root:nobody`：服务组可读，**不给 world 读**（里面有 `privateKey`）。

> 顺带：`/root/reality-creds.txt` 保持 `600 root:root` 是对的——那是凭据备份，服务不需要读它。

---

## 2. 包管理与软件源差异

| 主手册（Ubuntu） | AlmaLinux 9 | 备注 |
|---|---|---|
| `apt-get install` | `dnf install` | — |
| `apt-get update && apt-get -y upgrade` | `dnf -y update` | — |
| `ufw` | **firewalld** | EL9 根本没有 ufw，见第 3 节 |
| `systemctl restart ssh` | `systemctl restart sshd` | 服务名不同 |
| `fail2ban` 在主源 | **需 EPEL** | `dnf install epel-release` |
| `qrencode` 在主源 | **需 EPEL** | 见下面的坑 |

**★ 坑：可选包会因 `set -e` 炸掉整个脚本。** `qrencode` 不在 EL9 base/appstream 源里。如果写成：

```bash
dnf -y install curl openssl qrencode tar     # ← qrencode 装不上 → 整条命令非 0 → set -e 直接退出
```

部署会**卡死在第一步**，而失败原因（少个二维码工具）和后果（节点没装上）完全不成比例。必需项与可选项必须分开：

```bash
dnf -y install curl openssl tar              # 必需，失败就该中止
dnf -y install qrencode || echo "跳过二维码，不影响部署"   # 可选，失败无所谓
```

**★ 坑：`fail2ban` 用 `backend = systemd` 必须装 `python3-systemd`**，EL9 上缺了它 fail2ban 直接起不来：

```bash
dnf -y install epel-release
dnf -y install fail2ban fail2ban-firewalld python3-systemd
```

> EL9 默认装的是完整 `curl`（不是 `curl-minimal`），所以 `dnf install curl` 不会撞包冲突。用 `rpm -q curl curl-minimal` 可确认。

---

## 3. 防火墙：firewalld 替代 ufw

```bash
dnf -y install firewalld
systemctl enable --now firewalld
# 等就绪，别急着下命令
for i in $(seq 1 10); do firewall-cmd --state >/dev/null 2>&1 && break; sleep 1; done

firewall-cmd --set-default-zone=public          # ★ 不能加 --permanent，见下
firewall-cmd --permanent --add-port=22/tcp      # SSH（改过端口就换成新端口）
firewall-cmd --permanent --add-port=443/tcp     # REALITY
# 撤掉默认放行的其余服务（cockpit / dhcpv6-client 等）
for s in $(firewall-cmd --permanent --list-services); do
  [ "$s" = ssh ] || firewall-cmd --permanent --remove-service="$s"
done
firewall-cmd --reload
firewall-cmd --list-ports                        # 应只有 22/tcp 443/tcp
```

**★ 坑：`--set-default-zone` 是 stand-alone 选项，不能和 `--permanent` 连用**（它本身就永久生效）：

```bash
firewall-cmd --permanent --set-default-zone=public
# → Can't use stand-alone options with other options.
```

报错会**中断整个加固脚本**。危险点在于此时 firewalld 已经被 `enable --now` 起来了，但端口放行规则还没下——**SSH 和 443 都可能被自己的防火墙挡掉**。所以下一节的兜底是必须的。

---

## 4. ★ 远程改防火墙：先挂「死人开关」

远程操作 firewalld 有把自己关在门外的实际风险。改之前先挂一个定时自动停火墙的兜底：

```bash
# 15 分钟后自动 stop firewalld；若期间一切正常，手动撤掉它
systemd-run --on-active=900 --unit=fw-deadman --description="firewalld 死人开关" \
  systemctl stop firewalld
```

改完后**用一条全新连接**验证（`ControlPath=none` 防止复用已有会话产生假阳性）：

```bash
ssh -o ControlPath=none -o BatchMode=yes -i ~/.ssh/id_ed25519 root@<vps-ip> \
  'echo OK; systemctl is-active firewalld fail2ban xray'
```

确认没断，再撤掉兜底：

```bash
systemctl stop fw-deadman.timer
systemctl reset-failed fw-deadman
```

> 实战验证：本篇第 3 节那个 `--set-default-zone` 报错就是在真机上撞出来的，脚本中断在 firewalld 刚启动、规则未下的状态——**死人开关真的救了场**（10 分钟后自动停掉火墙，SSH 恢复）。

---

## 5. SSH 加固：drop-in 而非改主文件

主手册用 `sed -i` 改 `/etc/ssh/sshd_config`。**EL9 上这可能不生效**——`/etc/ssh/sshd_config.d/50-redhat.conf` 和 cloud-init 的 drop-in 会覆盖主文件里的设置（sshd 取**第一次**出现的值，而主文件顶部通常就 `Include sshd_config.d/*.conf`）。

正确做法是写一个高序号 drop-in：

```bash
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
MaxAuthTries 3
EOF

sshd -t || echo "语法错误，别重启！"     # ★ 先校验
systemctl restart sshd
sshd -T | grep -iE '^(passwordauthentication|permitrootlogin)'   # 看实际生效值
```

**★ 执行前务必**：确认 `authorized_keys` 非空、且已用密钥成功登录过一次。**执行后别关当前会话**，先另开终端验证。

### SELinux：搬瓦工镜像默认没开

主手册没提 SELinux，很多 EL9 指南会让你跑 `restorecon` / `semanage port`。实测**搬瓦工 AlmaLinux 9 镜像 SELinux 是关闭的**（`getenforce` 命令不存在、无 `/sys/fs/selinux`），这些命令用不上。

但换别家镜像可能是 `enforcing`，所以脚本里要留保护：

```bash
# 放公钥后修上下文（SELinux 关闭时静默跳过，不要让它中断脚本）
restorecon -R /root/.ssh 2>/dev/null || true
# 改 SSH 端口时必须配套，否则 sshd 起不来
semanage port -a -t ssh_port_t -p tcp <新端口> 2>/dev/null || true
```

---

## 6. BBR 调优：EL9 出厂已开，真实增益在缓冲区

主手册第六部分假设 `cubic` + 208KB 默认值。**AlmaLinux 9 出厂就是 `bbr` + `fq`**，所以那部分收益拿不到——但**缓冲区仍是裸默认**，这才是瓶颈所在：

```
体检结果（AlmaLinux 9.7 裸机）：
  net.ipv4.tcp_congestion_control = bbr        ← 已经开了
  net.core.default_qdisc          = fq         ← 已经开了
  net.core.rmem_max               = 212992     ← ★ 裸默认，必须调
  net.ipv4.tcp_slow_start_after_idle = 1       ← ★ 该是 0
```

按主手册 6.1 的公式，RTT 163ms 下单连接天花板 = `212992 ÷ 0.163 ≈ 10 Mbps`，**线路给多少带宽都吃不满**。主手册 6.3 那份 `sysctl` 模板可直接用（脚本已内置），调完 `rmem_max` 到 32MB。

实测效果（搬瓦工洛杉矶 AS25820 IT7，RTT 163ms，中国移动家宽）：

| 测项 | 结果 |
|---|---|
| 本机经代理（单连接） | 6.7–7.7 MB/s = **54–61 Mbps** |
| 本机经代理（4 条并发聚合） | 13.5 MB/s = **108 Mbps** |
| VPS 本地到国际 | 212 MB/s ≈ 1.7 Gbps |
| 延迟 | avg 163ms，mdev **0.37ms**，0% 丢包 |

单连接 54–61 Mbps 已明显突破那个 10 Mbps 天花板 → 缓冲区调优生效。4 条并发几乎线性叠加（每条稳定 3.3–3.4 MB/s）说明跨境段有余量，不是拥塞。按主手册 5.1 判读表属「①快 ②快」→ 线路没问题，**无需再做 5.2.1 三网回程排查**（那是诊断「慢」用的）。

---

## 7. 排错速查表（EL9 专属）

| 症状 | 原因 | 解法 |
|---|---|---|
| `xray run -test` 报 **Configuration OK**，但 `systemctl start` 后 `is-active` = failed，日志 `permission denied` 读自己的 config | `config.json` 是 `600 root:root`，而单元跑 `User=nobody`。**校验是 root 执行的所以能过** | `chown root:nobody` + `chmod 640`，用 `runuser -u nobody -- test -r` 验证。见第 1 节 |
| 部署脚本刚开始就退出，只装了几个包 | `dnf install` 里混了 EPEL 才有的 `qrencode`，装不上触发 `set -e` | 必需/可选包分开装。见第 2 节 |
| `fail2ban` 启动即失败 | `backend = systemd` 缺 `python3-systemd` | `dnf install python3-systemd` |
| `Can't use stand-alone options with other options.` 加固中断 | `--permanent` 和 `--set-default-zone` 连用 | 去掉 `--permanent`。见第 3 节 |
| firewalld 状态是 `enabled` 但 `inactive`，重启后节点会被挡死 | 加固脚本中途报错退出，留下半成品状态 | 补完端口放行再 `enable --now`；重跑幂等脚本自愈 |
| `sed -i` 改了 `sshd_config` 但 `sshd -T` 显示没生效 | `sshd_config.d/50-redhat.conf` 覆盖了主文件 | 改用 `99-hardening.conf` drop-in。见第 5 节 |
| `getenforce: command not found` | 该镜像没启用 SELinux（搬瓦工 EL9 如此） | 正常，`restorecon`/`semanage` 加 `|| true` 跳过 |
| 脚本里取 SSH 端口得到 `"22\n22"`，拼进 `--add-port` 报错 | `sshd -T \| awk '...{exit}'` 在 `pipefail` 下让 `sshd -T` 吃 SIGPIPE → 管道判失败 → 兜底 `echo 22` 也执行 | 别在管道里用 `awk ... exit`；取首行后用 `${var%%$'\n'*}` |

---

## 关键取值备忘

- 服务用户 **`nobody`**（`awk -F= '/^User=/' /etc/systemd/system/xray.service` 确认），`config.json` 必须 `640 root:nobody`。
- 防火墙是 **firewalld**，只放 SSH + 443；`--set-default-zone` 不带 `--permanent`。
- SSH 加固走 `/etc/ssh/sshd_config.d/99-hardening.conf`，不改主文件。
- EL9 出厂已 `bbr`+`fq`，**只需调缓冲区**（`rmem_max` 212992 → 32MB）。
- 凭据（UUID/privateKey/shortId）**每台机重新生成**，切勿跨机复用——与主手册一致。

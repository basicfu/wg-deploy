# wg-deploy

Debian 13 (trixie) 上 WireGuard 的一键部署与管理脚本，内置传输加速（BBR + fq + 大缓冲 + MSS 钳制 + MTU 探测）。

## 快速开始

```bash
curl -fsSLO https://raw.githubusercontent.com/basicfu/wg-deploy/main/wg.sh
bash wg.sh install
bash wg.sh add phone      # 打印配置和二维码，手机扫码即用
```

## 基本形式

```bash
bash wg.sh <命令> [参数]
```

除 `show`、`list`、`status`、`help` 外，其余命令需要 root。客户端名称只允许字母、数字、下划线、短横线。

## 命令一览

| 命令 | 参数 | 作用 |
|---|---|---|
| `install` | 无 | 一键安装：交互确认端口/网段/DNS 等参数（回车用默认值），然后装包、生成密钥、开转发、写 nftables、BBR 调优、探测 MTU、启动服务 |
| `add` | `<名称>` | 新增客户端，自动分配 IP 和 PSK，打印配置文件和二维码 |
| `del` / `rm` | `<名称>` | 删除客户端，热同步不断其他人 |
| `show` / `qr` | `<名称>` | 再次打印某客户端的配置和二维码 |
| `ros` | `<名称> [接口名]` | 生成 RouterOS 7 的 wireguard 接口 / peer / 地址三条命令，复制粘贴到 RouterOS 终端即可，接口名默认 `wg-vps` |
| `list` / `ls` | 无 | 列出所有客户端：地址、最近握手时间、下行/上行流量 |
| `status` | 无 | 服务状态、`wg show`、BBR/队列/转发参数、当前 nft 规则 |
| `mtu` | `[数值]` | 不带参数重新探测，带参数手动设置，同步改服务端和所有客户端配置 |
| `tune` | 无 | 重新应用内核调优，系统升级后参数被覆盖时用 |
| `restart` | 无 | 重启 wg0 |
| `uninstall` | 无 | 停服务、删 nft 规则、删 `/etc/wireguard` 和 sysctl 文件，会先问确认 |
| `help` 或不带参数 | 无 | 打印用法 |

## 典型流程

```bash
bash wg.sh install
bash wg.sh add phone
bash wg.sh add laptop
bash wg.sh list
bash wg.sh show phone
bash wg.sh add router && bash wg.sh ros router
bash wg.sh del laptop
```

## 接入 RouterOS

```bash
bash wg.sh add router
bash wg.sh ros router
```

输出三条命令，粘贴到 RouterOS 7 终端：

```
/interface/wireguard add name=wg-vps mtu=1420 private-key="..."
/interface/wireguard/peers add interface=wg-vps name=router public-key="..." preshared-key="..." endpoint-address=1.2.3.4 endpoint-port=51820 allowed-address=0.0.0.0/0 persistent-keepalive=25s
/ip/address add address=10.8.0.2/24 interface=wg-vps
```

`allowed-address=0.0.0.0/0` 只是允许任意回包，RouterOS 不会因此自动加默认路由。要让内网设备走隧道，还需自行加 NAT、MSS 钳制和路由，例如：

```
/ip/firewall/nat add chain=srcnat out-interface=wg-vps action=masquerade
/ip/firewall/mangle add chain=forward out-interface=wg-vps protocol=tcp tcp-flags=syn action=change-mss new-mss=clamp-to-pmtu passthrough=yes
```

## 安装参数

`install` 会逐项交互询问，直接回车使用 `[]` 内的默认值，公网地址和出口网卡会自动探测后作为默认值：

```
==> 请确认参数，直接回车使用 [] 内默认值
接口名 [wg0]:
UDP 监听端口 [51820]: 443
内网网段前缀 (/24) [10.8.0]:
下发给客户端的 DNS [8.8.8.8]:
公网 IP 或域名 [23.246.153.38]:
NAT 出口网卡 [eth0]:
隧道 MTU (空=自动探测) [自动]:
```

环境变量可作为预填值；没有终端（如 CI、无 tty 的 `curl | bash`）时直接采用环境变量或默认值不再询问。参数固化到 `/etc/wireguard/wg-manage.conf`，后续命令自动读取：

```bash
WG_PORT=443 WG_NET=10.9.0 WG_DNS=1.1.1.1 bash wg.sh install
```

| 变量 | 默认值 | 说明 |
|---|---|---|
| `WG_IF` | `wg0` | 接口名 |
| `WG_PORT` | `51820` | UDP 监听端口 |
| `WG_NET` | `10.8.0` | 网段前缀，固定 /24，服务端占 `.1`，客户端从 `.2` 起分配 |
| `WG_DNS` | `8.8.8.8` | 下发给客户端的 DNS |
| `WG_MTU` | 自动探测 | 隧道 MTU，探测失败退到 1280 |
| `ENDPOINT` | 自动探测公网 IPv4 | 客户端连接地址，有域名就填域名 |
| `OUT_IF` | 默认路由网卡 | NAT 出口网卡，多网卡时手动指定 |

## 文件位置

```
/etc/wireguard/
├── wg0.conf           服务端配置，每个 Peer 用 # BEGIN/END <名称> 包裹
├── wg0.nft            nftables 规则，接口起落时自动加载卸载
├── wg-manage.conf     脚本参数
├── server.key / .pub  服务端密钥
└── clients/
    ├── <名称>.conf     客户端配置，可直接 scp 走或扫码
    └── <名称>.pub      客户端公钥，list 用它关联流量
```

## 加速做了什么

- `net.ipv4.tcp_congestion_control=bbr` + `net.core.default_qdisc=fq`
- 收发缓冲上限 32MB，`tcp_mtu_probing=1`，`tcp_fastopen=3`，`tcp_slow_start_after_idle=0`
- nftables forward 链对隧道两向 SYN 做 MSS 钳制（`rt mtu`），避免 PMTUD 黑洞导致网页卡住
- 安装时用 DF ping 探测出口路径 MTU，减 60 字节封装开销后写入服务端和客户端

## 注意事项

- `add` 和 `del` 用 `wg syncconf` 热更新，已连接的客户端不会掉线。
- `mtu` 改完后，已导入过配置的客户端需要重新导入，服务端立即生效。
- `install` 会自动禁用 ufw，因为它和脚本写的 nft 规则会互相覆盖。
- 已安装状态下再跑 `install` 会拒绝，要重装先 `uninstall`。
- 不装 qrencode 时 `show` 只打印配置文本。

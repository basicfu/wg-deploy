# wg-deploy

Debian 13 (trixie) 上 WireGuard 的一键部署与管理脚本，内置传输加速（BBR + fq + 大缓冲 + MSS 钳制 + MTU 探测）。

## 快速开始

```bash
curl -fsSLo wg.sh <raw-url>/wg.sh   # 或 scp 上去
bash wg.sh install
bash wg.sh add phone                 # 打印配置和二维码，手机扫码即用
```

## 命令

| 命令 | 说明 |
|---|---|
| `install` | 装包、生成密钥、开启转发、写 nftables、BBR 调优、探测 MTU、启动服务 |
| `add <名>` | 新增客户端（自动分配 IP、PSK），输出配置 + 二维码 |
| `del <名>` | 删除客户端并热同步 |
| `show <名>` | 再次显示某客户端配置与二维码 |
| `list` | 客户端列表：地址 / 最近握手 / 上下行流量 |
| `status` | 服务状态、wg show、内核参数、nft 规则 |
| `mtu [值]` | 重新探测或手动指定隧道 MTU |
| `tune` | 重新应用内核调优 |
| `restart` | 重启 wg0 |
| `uninstall` | 停服务、清规则、删配置 |

## 安装参数

安装前可用环境变量覆盖，之后固化在 `/etc/wireguard/wg-manage.conf`：

```bash
WG_PORT=443 WG_NET=10.9.0 WG_DNS=8.8.8.8 WG_MTU=1380 bash wg.sh install
```

| 变量 | 默认 | 说明 |
|---|---|---|
| `WG_IF` | wg0 | 接口名 |
| `WG_PORT` | 51820 | UDP 监听端口 |
| `WG_NET` | 10.8.0 | /24 网段前缀，服务端占 .1 |
| `WG_DNS` | 1.1.1.1 | 下发给客户端的 DNS |
| `WG_MTU` | 自动探测 | 隧道 MTU |
| `ENDPOINT` | 自动探测 | 客户端连接用的公网 IP/域名 |
| `OUT_IF` | 默认路由网卡 | NAT 出口网卡 |

## 文件布局

```
/etc/wireguard/
├── wg0.conf           服务端配置（Peer 以 # BEGIN/END <名> 包裹，便于增删）
├── wg0.nft            nftables 规则，由 PostUp/PostDown 加载卸载
├── wg-manage.conf     脚本参数
├── server.key / .pub
└── clients/<名>.conf / .pub
```

## 加速做了什么

- `net.ipv4.tcp_congestion_control=bbr` + `net.core.default_qdisc=fq`
- 收发缓冲上限 32MB，`tcp_mtu_probing=1`，`tcp_slow_start_after_idle=0`
- nftables forward 链对隧道两向 SYN 做 MSS 钳制（`rt mtu`），避免 PMTUD 黑洞导致网页卡住
- 安装时用 DF ping 探测出口路径 MTU，减 60 字节封装开销后写入服务端和客户端

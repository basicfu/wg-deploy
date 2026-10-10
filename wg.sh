#!/usr/bin/env bash
# wg.sh — Debian 13 WireGuard 一键部署 + 客户端管理 + 传输加速
# 用法: bash wg.sh help
set -euo pipefail

WG_DIR=/etc/wireguard
CONF=$WG_DIR/wg-manage.conf
CLIENTS_DIR=$WG_DIR/clients

# 默认参数。install 时交互确认后固化到 $CONF，之后所有子命令以 $CONF 为准，
# 这样换 shell/重启后 add/del 仍能算出正确网段和端口。环境变量可作为交互的预填值。
WG_IF=${WG_IF:-wg0}
WG_PORT=${WG_PORT:-51820}
WG_NET=${WG_NET:-10.8.0}      # /24，服务端固定占 .1
WG_DNS=${WG_DNS:-8.8.8.8}
WG_MTU=${WG_MTU:-}            # 留空由 install 探测
ENDPOINT=${ENDPOINT:-}        # 留空自动取公网 IPv4
OUT_IF=${OUT_IF:-}            # 留空取默认路由网卡

[[ -f $CONF ]] && source "$CONF"

SERVER_CONF=$WG_DIR/$WG_IF.conf
NFT_FILE=$WG_DIR/$WG_IF.nft

die()       { echo "错误: $*" >&2; exit 1; }
info()      { echo -e "\e[32m==>\e[0m $*"; }
need_root() { [[ $EUID -eq 0 ]] || die "请用 root 运行"; }
installed() { [[ -f $SERVER_CONF && -f $CONF ]]; }

# 从 /dev/tty 读，保证 curl | bash 方式也能交互；没有终端就全用默认值
ask() {
  local _var=$1 _prompt=$2 _def=$3 _re=${4:-} _v
  while :; do
    if [[ -r /dev/tty ]]; then read -rp "$_prompt [${_def:-自动}]: " _v </dev/tty; else _v=; fi
    _v=${_v:-$_def}
    [[ -z $_re || -z $_v || $_v =~ $_re ]] && break
    echo "  格式不对，请重输"
  done
  printf -v "$_var" '%s' "$_v"
}

detect_out_if() { ip -4 route show default | awk '{print $5; exit}'; }
detect_endpoint() {
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null \
    || ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}'
}

# 用 DF 包探测服务端出口路径 MTU，减去 IPv4(20)+UDP(8)+WG(32)=60 字节封装开销。
# 上限 1420 是 wg 默认值；探不到就退到 1280 保底。
probe_mtu() {
  local size
  for size in 1472 1452 1432 1412 1392 1372 1352 1332 1312 1292 1272 1252; do
    if ping -c1 -W1 -M do -s "$size" 1.1.1.1 &>/dev/null; then
      local mtu=$((size + 28 - 60))
      (( mtu > 1420 )) && mtu=1420
      echo "$mtu"; return
    fi
  done
  echo 1280
}

write_sysctl() {
  cat > /etc/sysctl.d/99-wg.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
EOF
  modprobe tcp_bbr 2>/dev/null || true
  echo tcp_bbr > /etc/modules-load.d/bbr.conf
  sysctl --system >/dev/null
}

# 独立 table，PostUp/PostDown 随接口生死，不碰 /etc/nftables.conf 里用户自己的规则。
# 开头"声明-删除-重建"三行让文件可重复加载；不能放在 PostUp 里用 ";" 串联，
# 因为 wg-quick 带 set -e，delete 不存在的表会直接中止整个钩子。
# MSS 钳制是隧道内 TCP 不卡顿的关键，比单调 MTU 更稳。
write_nft() {
  cat > "$NFT_FILE" <<EOF
table inet wg
delete table inet wg
table inet wg {
  chain input {
    type filter hook input priority 0; policy accept;
    udp dport $WG_PORT accept
  }
  chain forward {
    type filter hook forward priority 0; policy accept;
    iifname "$WG_IF" tcp flags syn tcp option maxseg size set rt mtu
    oifname "$WG_IF" tcp flags syn tcp option maxseg size set rt mtu
    iifname "$WG_IF" accept
    oifname "$WG_IF" ct state related,established accept
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $WG_NET.0/24 oifname "$OUT_IF" masquerade
  }
}
EOF
}

write_server_conf() {
  cat > "$SERVER_CONF" <<EOF
[Interface]
Address = $WG_NET.1/24
ListenPort = $WG_PORT
PrivateKey = $(cat "$WG_DIR/server.key")
MTU = $WG_MTU
PostUp = nft -f $NFT_FILE
PostDown = nft delete table inet wg
EOF
}

save_conf() {
  cat > "$CONF" <<EOF
WG_IF=$WG_IF
WG_PORT=$WG_PORT
WG_NET=$WG_NET
WG_DNS=$WG_DNS
WG_MTU=$WG_MTU
ENDPOINT=$ENDPOINT
OUT_IF=$OUT_IF
EOF
}

sync_peers() { wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF"); }

next_ip() {
  local i
  for i in $(seq 2 254); do
    grep -q "AllowedIPs = $WG_NET.$i/32" "$SERVER_CONF" || { echo "$i"; return; }
  done
  die "网段已满"
}

cmd_install() {
  need_root
  installed && die "已安装 ($SERVER_CONF 存在)。重装请先 bash $0 uninstall"
  grep -qi 'debian' /etc/os-release || echo "警告: 非 Debian 系统，继续尝试"

  info "安装软件包"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wireguard nftables qrencode curl iproute2 >/dev/null

  info "请确认参数，直接回车使用 [] 内默认值"
  ask WG_IF    "接口名"               "$WG_IF"    '^[A-Za-z0-9_-]+$'
  ask WG_PORT  "UDP 监听端口"         "$WG_PORT"  '^[0-9]{1,5}$'
  ask WG_NET   "内网网段前缀 (/24)"   "$WG_NET"   '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
  ask WG_DNS   "下发给客户端的 DNS"   "$WG_DNS"
  ask ENDPOINT "公网 IP 或域名"       "${ENDPOINT:-$(detect_endpoint)}"
  ask OUT_IF   "NAT 出口网卡"         "${OUT_IF:-$(detect_out_if)}"
  ask WG_MTU   "隧道 MTU (空=自动探测)" "$WG_MTU"   '^[0-9]{4}$'
  (( WG_PORT >= 1 && WG_PORT <= 65535 )) || die "端口超出范围"
  [[ -n $OUT_IF && -n $ENDPOINT ]] || die "出口网卡和公网地址不能为空"
  SERVER_CONF=$WG_DIR/$WG_IF.conf; NFT_FILE=$WG_DIR/$WG_IF.nft
  [[ -f $SERVER_CONF ]] && die "$SERVER_CONF 已存在"
  if [[ -z $WG_MTU ]]; then
    info "探测路径 MTU"
    WG_MTU=$(probe_mtu)
  fi
  echo
  info "接口=$WG_IF 端口=$WG_PORT 网段=$WG_NET.0/24 DNS=$WG_DNS 公网地址=$ENDPOINT 出口网卡=$OUT_IF MTU=$WG_MTU"

  info "生成服务端密钥"
  mkdir -p "$CLIENTS_DIR"; chmod 700 "$WG_DIR" "$CLIENTS_DIR"
  umask 077
  wg genkey | tee "$WG_DIR/server.key" | wg pubkey > "$WG_DIR/server.pub"

  info "写入内核参数 (转发 + BBR + fq + 大缓冲)"
  write_sysctl

  info "写入 nftables 与 $WG_IF 配置"
  write_nft
  write_server_conf
  save_conf

  # nftables 服务常驻保证开机加载；ufw 与 nft 规则会互相覆盖，关掉
  systemctl enable --now nftables >/dev/null 2>&1 || true
  systemctl disable --now ufw >/dev/null 2>&1 || true

  info "启动 wg-quick@$WG_IF"
  systemctl enable --now "wg-quick@$WG_IF"
  wg show "$WG_IF"
  echo
  info "安装完成。添加客户端: bash $0 add phone"
}

cmd_add() {
  need_root; installed || die "尚未安装"
  local name=${1:-}; [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || die "用法: add <名称>  (字母数字_-)"
  [[ -f $CLIENTS_DIR/$name.conf ]] && die "客户端 $name 已存在"

  local ip; ip=$(next_ip)
  umask 077
  local key pub psk
  key=$(wg genkey); pub=$(wg pubkey <<<"$key"); psk=$(wg genpsk)

  cat >> "$SERVER_CONF" <<EOF

# BEGIN $name
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $WG_NET.$ip/32
# END $name
EOF
  echo "$pub" > "$CLIENTS_DIR/$name.pub"

  cat > "$CLIENTS_DIR/$name.conf" <<EOF
[Interface]
PrivateKey = $key
Address = $WG_NET.$ip/24
DNS = $WG_DNS
MTU = $WG_MTU

[Peer]
PublicKey = $(cat "$WG_DIR/server.pub")
PresharedKey = $psk
Endpoint = $ENDPOINT:$WG_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  sync_peers
  info "已添加 $name ($WG_NET.$ip)"
  cmd_show "$name"
}

cmd_del() {
  need_root; installed || die "尚未安装"
  local name=${1:-}; [[ -n $name ]] || die "用法: del <名称>"
  [[ -f $CLIENTS_DIR/$name.conf ]] || die "客户端 $name 不存在"
  sed -i "/^# BEGIN $name\$/,/^# END $name\$/d" "$SERVER_CONF"
  # 合并连续空行，避免配置越删越松散
  sed -i '/^$/N;/^\n$/D' "$SERVER_CONF"
  rm -f "$CLIENTS_DIR/$name".{conf,pub}
  sync_peers
  info "已删除 $name"
}

cmd_show() {
  installed || die "尚未安装"
  local name=${1:-}; [[ -f $CLIENTS_DIR/$name.conf ]] || die "用法: show <名称>"
  echo "----- $CLIENTS_DIR/$name.conf -----"
  cat "$CLIENTS_DIR/$name.conf"
  echo "-----------------------------------"
  command -v qrencode >/dev/null && qrencode -t ansiutf8 < "$CLIENTS_DIR/$name.conf"
}

# 把客户端 conf 翻译成 RouterOS 7 命令，接口名默认 wg-vps，可用第二个参数改
cmd_ros() {
  installed || die "尚未安装"
  local name=${1:-} ifn=${2:-wg-vps} f
  f=$CLIENTS_DIR/$name.conf; [[ -f $f ]] || die "用法: ros <名称> [RouterOS 接口名]"
  local field; field() { sed -n "s/^$1 = //p" "$f" | head -1; }
  local key pub psk ep addr mtu
  key=$(field PrivateKey); pub=$(field PublicKey); psk=$(field PresharedKey)
  ep=$(field Endpoint); addr=$(field Address); mtu=$(field MTU)
  cat <<EOF
/interface/wireguard add name=$ifn mtu=$mtu private-key="$key"
/interface/wireguard/peers add interface=$ifn name=$name public-key="$pub" preshared-key="$psk" endpoint-address=${ep%:*} endpoint-port=${ep##*:} allowed-address=0.0.0.0/0 persistent-keepalive=25s
/ip/address add address=$addr interface=$ifn
EOF
}

cmd_list() {
  installed || die "尚未安装"
  local f name pub line
  printf "%-16s %-16s %-20s %-12s %-12s\n" 名称 地址 最近握手 下行 上行
  for f in "$CLIENTS_DIR"/*.pub; do
    [[ -e $f ]] || { echo "(无客户端)"; return; }
    name=$(basename "$f" .pub); pub=$(cat "$f")
    line=$(wg show "$WG_IF" dump 2>/dev/null | awk -v p="$pub" '$1==p')
    if [[ -n $line ]]; then
      awk -v n="$name" '
        function fmt(b){ if(b>1073741824) return sprintf("%.1fG",b/1073741824); if(b>1048576) return sprintf("%.1fM",b/1048576); if(b>1024) return sprintf("%.1fK",b/1024); return b "B" }
        { hs = ($5==0) ? "从未" : strftime("%m-%d %H:%M:%S", $5)
          printf "%-16s %-16s %-20s %-12s %-12s\n", n, $4, hs, fmt($6), fmt($7) }' <<<"$line"
    else
      printf "%-16s %-16s %-20s\n" "$name" "?" "(接口未启动)"
    fi
  done
}

cmd_status() {
  installed || die "尚未安装"
  systemctl --no-pager status "wg-quick@$WG_IF" 2>/dev/null | head -5 || true
  echo; wg show "$WG_IF" || true
  echo; echo "拥塞算法: $(sysctl -n net.ipv4.tcp_congestion_control)  队列: $(sysctl -n net.core.default_qdisc)  转发: $(sysctl -n net.ipv4.ip_forward)"
  echo "nft 规则:"; nft list table inet wg 2>/dev/null || echo "  (未加载)"
}

cmd_tune() {
  need_root
  write_sysctl
  info "已重新应用内核调优: bbr=$(sysctl -n net.ipv4.tcp_congestion_control) qdisc=$(sysctl -n net.core.default_qdisc)"
}

cmd_mtu() {
  need_root; installed || die "尚未安装"
  local new=${1:-}
  [[ -z $new ]] && { info "探测中"; new=$(probe_mtu); }
  [[ $new =~ ^[0-9]+$ ]] && (( new >= 1280 && new <= 1500 )) || die "MTU 需在 1280~1500"
  WG_MTU=$new; save_conf
  sed -i "s/^MTU = .*/MTU = $new/" "$SERVER_CONF" "$CLIENTS_DIR"/*.conf 2>/dev/null || true
  ip link set "$WG_IF" mtu "$new"
  info "MTU 已设为 $new (已有客户端需重新导入配置)"
}

# nft 规则由参数推导，重启时顺手重渲染，脚本升级后不用手改服务器上的文件
cmd_restart() {
  need_root; installed || die "尚未安装"
  write_nft
  sed -i "s|^PostUp = .*|PostUp = nft -f $NFT_FILE|" "$SERVER_CONF"
  systemctl restart "wg-quick@$WG_IF"; wg show "$WG_IF"
}

cmd_uninstall() {
  need_root
  read -rp "将停止 $WG_IF 并删除 $WG_DIR 下全部配置和密钥，确认? [y/N] " a
  [[ $a == y || $a == Y ]] || exit 0
  systemctl disable --now "wg-quick@$WG_IF" 2>/dev/null || true
  nft delete table inet wg 2>/dev/null || true
  rm -rf "$WG_DIR" /etc/sysctl.d/99-wg.conf /etc/modules-load.d/bbr.conf
  sysctl --system >/dev/null
  info "已卸载 (软件包保留，如需: apt purge wireguard nftables qrencode)"
}

usage() {
  cat <<EOF
用法: bash $0 <命令> [参数]

  install            一键安装，交互确认端口/网段/DNS 等参数，回车用默认值
  add <名称>         新增客户端，输出配置与二维码
  del <名称>         删除客户端
  show <名称>        再次显示客户端配置与二维码
  ros <名称> [接口名]  生成 RouterOS 7 的 wireguard 接口/peer/地址命令，默认接口名 wg-vps
  list               列出客户端及握手/流量
  status             服务、wg、内核参数、nft 规则概览
  mtu [值]           探测或手动设置隧道 MTU
  tune               重新应用 BBR/缓冲等内核调优
  restart            重启 $WG_IF
  uninstall          卸载并清理

环境变量可作为交互预填值 (无终端时直接生效):
  WG_PORT=51820 WG_NET=10.8.0 WG_DNS=8.8.8.8 WG_MTU= ENDPOINT= OUT_IF= bash $0 install
EOF
}

case ${1:-help} in
  install)   cmd_install ;;
  add)       cmd_add "${2:-}" ;;
  del|rm)    cmd_del "${2:-}" ;;
  show|qr)   cmd_show "${2:-}" ;;
  ros)       cmd_ros "${2:-}" "${3:-}" ;;
  list|ls)   cmd_list ;;
  status)    cmd_status ;;
  mtu)       cmd_mtu "${2:-}" ;;
  tune)      cmd_tune ;;
  restart)   cmd_restart ;;
  uninstall) cmd_uninstall ;;
  *)         usage ;;
esac

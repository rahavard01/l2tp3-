#!/usr/bin/env bash
# l2tp3 - L2TPv3 (Ethernet pseudowire) IR<->FR + Port Forward manager (EN-only)
# Install:  sudo bash l2tp3.sh install
# After install: sudo l2tp3   (interactive menu)
set -euo pipefail

APP="l2tp3"
BIN="/usr/local/bin/l2tp3"
BASE="/etc/l2tp3"
CFG="$BASE/config.env"
PORTS="$BASE/ports.list"
LOG_DIR="/var/log/l2tp3"
LOG_FILE="$LOG_DIR/l2tp3.log"

SERVICE="/etc/systemd/system/l2tp3.service"
TIMER_RESTART="/etc/systemd/system/l2tp3-autorestart.timer"
SERVICE_RESTART="/etc/systemd/system/l2tp3-autorestart.service"
TIMER_CACHE="/etc/systemd/system/l2tp3-cache.timer"
SERVICE_CACHE="/etc/systemd/system/l2tp3-cache.service"

# iptables custom chains
CHAIN_PREROUTING="L2TP3_PREROUTING"
CHAIN_POSTROUTING="L2TP3_POSTROUTING"
CHAIN_FORWARD="L2TP3_FORWARD"

say()  { echo -e "$*"; }
warn() { echo -e "WARNING: $*" >&2; }
die()  { echo -e "ERROR: $*" >&2; exit 1; }

need_root() { [[ "${EUID:-0}" -eq 0 ]] || die "This command must be run as root (use sudo)."; }
has() { command -v "$1" >/dev/null 2>&1; }

log_init() {
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE" || true
}
log() {
  log_init
  printf "[%s] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >/dev/null
}

pkg_install() {
  local pkgs=("$@")
  if has apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null
  elif has yum; then
    yum install -y "${pkgs[@]}" >/dev/null
  elif has dnf; then
    dnf install -y "${pkgs[@]}" >/dev/null
  else
    die "No supported package manager found (apt/yum/dnf). Install manually: ${pkgs[*]}"
  fi
}

read_cfg() {
  [[ -f "$CFG" ]] || return 1
  # shellcheck disable=SC1090
  . "$CFG"
  return 0
}

write_cfg_kv() {
  local k="$1" v="$2"
  mkdir -p "$BASE"
  touch "$CFG"
  if grep -qE "^${k}=" "$CFG"; then
    sed -i "s|^${k}=.*|${k}=\"${v}\"|g" "$CFG"
  else
    echo "${k}=\"${v}\"" >> "$CFG"
  fi
}

prompt() {
  local msg="$1" def="${2:-}"
  local ans
  if [[ -n "$def" ]]; then
    read -r -p "$msg [$def]: " ans || true
    ans="${ans:-$def}"
  else
    read -r -p "$msg: " ans || true
  fi
  echo "$ans"
}

public_ip_guess() {
  if has curl; then
    curl -4 -fsS https://api.ipify.org 2>/dev/null || true
  fi
}

b64enc() { base64 -w0; }
b64dec() { base64 -d; }

install_prereqs() {
  need_root
  say "Installing prerequisites..."
  pkg_install iproute2 iptables curl ca-certificates openssl
  # Optional for cache flush
  if has apt-get; then pkg_install conntrack || true; else pkg_install conntrack-tools || true; fi

  # Kernel modules (best effort)
  for m in l2tp_core l2tp_netlink l2tp_eth udp_tunnel ip6_udp_tunnel; do
    modprobe "$m" 2>/dev/null || true
  done

  mkdir -p "$BASE" "$LOG_DIR"
  touch "$PORTS" "$LOG_FILE"
  chmod 700 "$BASE"
  say "Done."
}

l2tp_iface_find() {
  ip -o link show | awk -F': ' '/l2tpeth[0-9]*/{print $2}' | tail -n1
}

l2tp_down() {
  read_cfg || return 0
  if has ip; then
    if ip l2tp show tunnel 2>/dev/null | grep -q "Tunnel ${TUNNEL_ID:-}"; then
      log "Deleting L2TP tunnel_id=${TUNNEL_ID}"
      ip l2tp del tunnel tunnel_id "$TUNNEL_ID" 2>/dev/null || true
    fi
  fi
}

l2tp_up() {
  need_root
  read_cfg || die "Config not found. Run setup first."
  [[ "${ENCAP:-udp}" == "udp" ]] || die "Only ENCAP=udp is supported for now."
  [[ -n "${LOCAL_PUBLIC:-}" && -n "${PEER_PUBLIC:-}" ]] || die "LOCAL_PUBLIC/PEER_PUBLIC is missing."
  [[ -n "${UDP_PORT:-}" && -n "${TUNNEL_ID:-}" && -n "${SESSION_ID:-}" ]] || die "UDP_PORT/TUNNEL_ID/SESSION_ID missing."
  [[ -n "${COOKIE_LOCAL:-}" && -n "${COOKIE_PEER:-}" ]] || die "COOKIE_LOCAL/COOKIE_PEER missing."
  [[ -n "${LOCAL_TUN_IP:-}" && -n "${PEER_TUN_IP:-}" ]] || die "LOCAL_TUN_IP/PEER_TUN_IP missing."

  l2tp_down || true

  log "Creating L2TPv3 tunnel (udp) local=${LOCAL_PUBLIC} peer=${PEER_PUBLIC} udp=${UDP_PORT} tid=${TUNNEL_ID} sid=${SESSION_ID}"
  ip l2tp add tunnel tunnel_id "$TUNNEL_ID" peer_tunnel_id "$TUNNEL_ID" \
    encap udp local "$LOCAL_PUBLIC" remote "$PEER_PUBLIC" \
    udp_sport "$UDP_PORT" udp_dport "$UDP_PORT"

  ip l2tp add session tunnel_id "$TUNNEL_ID" session_id "$SESSION_ID" peer_session_id "$SESSION_ID" \
    cookie "$COOKIE_LOCAL" peer_cookie "$COOKIE_PEER"

  local iface
  iface="$(l2tp_iface_find)"
  [[ -n "$iface" ]] || die "l2tpeth interface not created."
  write_cfg_kv IFACE "$iface"

  log "Bringing up iface=${iface}, MTU=${MTU:-1380}, IP=${LOCAL_TUN_IP}"
  ip link set "$iface" up
  ip link set dev "$iface" mtu "${MTU:-1380}" 2>/dev/null || true

  ip addr flush dev "$iface" 2>/dev/null || true
  ip addr add "$LOCAL_TUN_IP" dev "$iface"

  local peer_ip="${PEER_TUN_IP%/*}"
  ping -c 1 -W 1 "$peer_ip" >/dev/null 2>&1 || true
}

iptables_prepare_chains() {
  need_root
  iptables -t nat -N "$CHAIN_PREROUTING" 2>/dev/null || true
  iptables -t nat -N "$CHAIN_POSTROUTING" 2>/dev/null || true
  iptables -N "$CHAIN_FORWARD" 2>/dev/null || true

  iptables -t nat -C PREROUTING -j "$CHAIN_PREROUTING" 2>/dev/null || iptables -t nat -A PREROUTING -j "$CHAIN_PREROUTING"
  iptables -t nat -C POSTROUTING -j "$CHAIN_POSTROUTING" 2>/dev/null || iptables -t nat -A POSTROUTING -j "$CHAIN_POSTROUTING"
  iptables -C FORWARD -j "$CHAIN_FORWARD" 2>/dev/null || iptables -A FORWARD -j "$CHAIN_FORWARD"
}

iptables_flush_app_rules() {
  need_root
  iptables -t nat -F "$CHAIN_PREROUTING" 2>/dev/null || true
  iptables -t nat -F "$CHAIN_POSTROUTING" 2>/dev/null || true
  iptables -F "$CHAIN_FORWARD" 2>/dev/null || true
}

iptables_remove_all() {
  need_root
  iptables -t nat -D PREROUTING -j "$CHAIN_PREROUTING" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -j "$CHAIN_POSTROUTING" 2>/dev/null || true
  iptables -D FORWARD -j "$CHAIN_FORWARD" 2>/dev/null || true

  iptables -t nat -F "$CHAIN_PREROUTING" 2>/dev/null || true
  iptables -t nat -F "$CHAIN_POSTROUTING" 2>/dev/null || true
  iptables -F "$CHAIN_FORWARD" 2>/dev/null || true

  iptables -t nat -X "$CHAIN_PREROUTING" 2>/dev/null || true
  iptables -t nat -X "$CHAIN_POSTROUTING" 2>/dev/null || true
  iptables -X "$CHAIN_FORWARD" 2>/dev/null || true
}

apply_forward_rules() {
  need_root
  read_cfg || die "Config not found. Run setup first."

  if [[ "${ROLE:-}" != "entry" ]]; then
    log "ROLE=${ROLE:-} -> skipping port-forward (only entry uses it)."
    return 0
  fi

  iptables_prepare_chains
  iptables_flush_app_rules

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi

  local dst_ip="${PEER_TUN_IP%/*}"  # FR tunnel IP
  [[ -n "$dst_ip" ]] || die "Invalid PEER_TUN_IP."

  iptables -A "$CHAIN_FORWARD" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  if [[ ! -s "$PORTS" ]]; then
    log "No ports configured yet ($PORTS is empty)."
    return 0
  fi

  while IFS= read -r line; do
    line="${line// /}"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue

    local p proto
    p="${line%/*}"
    proto="${line#*/}"
    [[ "$p" =~ ^[0-9]+$ ]] || { warn "Invalid port spec: $line"; continue; }
    [[ "$proto" == "tcp" || "$proto" == "udp" ]] || { warn "Invalid protocol: $line"; continue; }

    iptables -t nat -A "$CHAIN_PREROUTING" -p "$proto" --dport "$p" -j DNAT --to-destination "${dst_ip}:${p}"
    iptables -A "$CHAIN_FORWARD" -p "$proto" -d "$dst_ip" --dport "$p" -j ACCEPT
    iptables -t nat -A "$CHAIN_POSTROUTING" -p "$proto" -d "$dst_ip" --dport "$p" -j MASQUERADE
  done < "$PORTS"

  log "Applied forwarding rules for $(grep -vE '^\s*#|^\s*$' "$PORTS" | wc -l) ports -> ${dst_ip}"
}

add_port() {
  need_root
  local spec="${1:-}"
  [[ -n "$spec" ]] || die "Usage: add-port 443/tcp or 3478/udp"
  spec="${spec// /}"
  [[ "$spec" =~ ^[0-9]+/(tcp|udp)$ ]] || die "Invalid format: $spec (example: 443/tcp)"

  mkdir -p "$BASE"; touch "$PORTS"
  if grep -qxF "$spec" "$PORTS"; then
    warn "Port already exists: $spec"
  else
    echo "$spec" >> "$PORTS"
    log "Added port: $spec"
  fi
  apply_forward_rules
}

del_port() {
  need_root
  local spec="${1:-}"
  [[ -n "$spec" ]] || die "Usage: del-port 443/tcp"
  spec="${spec// /}"
  [[ "$spec" =~ ^[0-9]+/(tcp|udp)$ ]] || die "Invalid format: $spec"

  [[ -f "$PORTS" ]] || die "Ports list not found."
  if ! grep -qxF "$spec" "$PORTS"; then
    warn "Port not in list: $spec"
  else
    grep -vxF "$spec" "$PORTS" > "${PORTS}.tmp"
    mv "${PORTS}.tmp" "$PORTS"
    log "Deleted port: $spec"
  fi
  apply_forward_rules
}

list_ports() {
  mkdir -p "$BASE"; touch "$PORTS"
  say "Ports:"
  if [[ ! -s "$PORTS" ]]; then
    say "  (empty)"
    return 0
  fi
  nl -ba "$PORTS" | sed 's/^/  /'
}

install_systemd() {
  need_root
  cat > "$SERVICE" <<'EOF'
[Unit]
Description=L2TPv3 tunnel + apply port-forward rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/l2tp3 up
ExecStart=/usr/local/bin/l2tp3 apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now l2tp3.service >/dev/null 2>&1 || true
}

enable_autorestart_timer() {
  need_root
  local minutes="${1:-}"
  [[ "$minutes" =~ ^[0-9]+$ ]] || die "Invalid minutes."
  [[ "$minutes" -ge 1 ]] || die "Minutes must be >= 1."

  cat > "$SERVICE_RESTART" <<'EOF'
[Unit]
Description=Restart l2tp3 periodically

[Service]
Type=oneshot
ExecStart=/usr/local/bin/l2tp3 restart
EOF

  cat > "$TIMER_RESTART" <<EOF
[Unit]
Description=Timer: restart l2tp3 every ${minutes} minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${minutes}min
Unit=l2tp3-autorestart.service
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now l2tp3-autorestart.timer >/dev/null 2>&1
  write_cfg_kv AUTORESTART_MIN "$minutes"
  log "Enabled autorestart every ${minutes} minutes."
}

disable_autorestart_timer() {
  need_root
  systemctl disable --now l2tp3-autorestart.timer >/dev/null 2>&1 || true
  rm -f "$TIMER_RESTART" "$SERVICE_RESTART"
  systemctl daemon-reload
  write_cfg_kv AUTORESTART_MIN ""
  log "Disabled autorestart timer."
}

enable_cache_timer() {
  need_root
  local minutes="${1:-}"
  [[ "$minutes" =~ ^[0-9]+$ ]] || die "Invalid minutes."
  [[ "$minutes" -ge 1 ]] || die "Minutes must be >= 1."

  cat > "$SERVICE_CACHE" <<'EOF'
[Unit]
Description=Flush conntrack cache periodically (optional)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/l2tp3 flush-cache
EOF

  cat > "$TIMER_CACHE" <<EOF
[Unit]
Description=Timer: flush cache every ${minutes} minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=${minutes}min
Unit=l2tp3-cache.service
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now l2tp3-cache.timer >/dev/null 2>&1
  write_cfg_kv CACHE_FLUSH_MIN "$minutes"
  log "Enabled cache flush every ${minutes} minutes."
}

disable_cache_timer() {
  need_root
  systemctl disable --now l2tp3-cache.timer >/dev/null 2>&1 || true
  rm -f "$TIMER_CACHE" "$SERVICE_CACHE"
  systemctl daemon-reload
  write_cfg_kv CACHE_FLUSH_MIN ""
  log "Disabled cache flush timer."
}

cmd_install() {
  need_root
  install_prereqs

  local src="${0}"
  if [[ "$src" != "$BIN" ]]; then
    cp -f "$src" "$BIN"
    chmod +x "$BIN"
  fi

  install_systemd

  say "Installed."
  say "Run: sudo l2tp3"
}

cmd_setup_exit() {
  need_root
  install_prereqs

  mkdir -p "$BASE"
  touch "$PORTS"

  local fr_pub ir_pub udp_port tid sid mtu
  fr_pub="$(prompt "FR public IP (LOCAL_PUBLIC)" "$(public_ip_guess)")"
  ir_pub="$(prompt "IR public IP (PEER_PUBLIC)" "")"
  udp_port="$(prompt "Tunnel UDP port" "17010")"
  tid="$(prompt "TUNNEL_ID" "1000")"
  sid="$(prompt "SESSION_ID" "1000")"
  mtu="$(prompt "MTU (suggest 1350-1420)" "1380")"

  local ck_fr ck_ir
  ck_fr="0x$(openssl rand -hex 4)"
  ck_ir="0x$(openssl rand -hex 4)"

  write_cfg_kv ROLE "exit"
  write_cfg_kv ENCAP "udp"
  write_cfg_kv LOCAL_PUBLIC "$fr_pub"
  write_cfg_kv PEER_PUBLIC "$ir_pub"
  write_cfg_kv UDP_PORT "$udp_port"
  write_cfg_kv TUNNEL_ID "$tid"
  write_cfg_kv SESSION_ID "$sid"
  write_cfg_kv MTU "$mtu"
  write_cfg_kv COOKIE_LOCAL "$ck_fr"
  write_cfg_kv COOKIE_PEER "$ck_ir"
  write_cfg_kv LOCAL_TUN_IP "10.200.0.2/30"
  write_cfg_kv PEER_TUN_IP "10.200.0.1/30"

  l2tp_up
  systemctl enable --now l2tp3.service >/dev/null 2>&1 || true

  local token
  token="$(
    cat <<EOF | b64enc
ROLE=entry
ENCAP=udp
LOCAL_PUBLIC=${ir_pub}
PEER_PUBLIC=${fr_pub}
UDP_PORT=${udp_port}
TUNNEL_ID=${tid}
SESSION_ID=${sid}
MTU=${mtu}
COOKIE_LOCAL=${ck_ir}
COOKIE_PEER=${ck_fr}
LOCAL_TUN_IP=10.200.0.1/30
PEER_TUN_IP=10.200.0.2/30
EOF
  )"

  say ""
  say "EXIT configured."
  say "Copy this TOKEN and paste it on IR during setup-entry:"
  say ""
  say "$token"
  say ""
}

cmd_setup_entry() {
  need_root
  install_prereqs

  mkdir -p "$BASE"
  touch "$PORTS"

  say "Paste TOKEN from EXIT (single base64 line)."
  local token
  token="$(prompt "TOKEN" "")"
  [[ -n "$token" ]] || die "TOKEN is empty."

  local decoded
  if ! decoded="$(echo "$token" | b64dec 2>/dev/null)"; then
    die "Invalid TOKEN (base64 decode failed)."
  fi

  : > "$CFG"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[A-Z0-9_]+= ]] || continue
    echo "$line" >> "$CFG"
  done <<< "$decoded"

  read_cfg || true
  local ip_guess local_pub
  ip_guess="$(public_ip_guess)"
  local_pub="$(prompt "IR public IP (LOCAL_PUBLIC)" "${LOCAL_PUBLIC:-$ip_guess}")"
  write_cfg_kv LOCAL_PUBLIC "$local_pub"
  write_cfg_kv ROLE "entry"

  say "Optional: add initial ports now (comma separated), example: 443/tcp,2053/tcp  (or leave empty)"
  local ports_in
  ports_in="$(prompt "Ports" "")"
  if [[ -n "$ports_in" ]]; then
    IFS=',' read -ra arr <<< "$ports_in"
    for item in "${arr[@]}"; do
      item="${item// /}"
      [[ -z "$item" ]] && continue
      if [[ "$item" =~ ^[0-9]+/(tcp|udp)$ ]]; then
        grep -qxF "$item" "$PORTS" 2>/dev/null || echo "$item" >> "$PORTS"
      else
        warn "Skipped invalid: $item"
      fi
    done
  fi

  l2tp_up
  apply_forward_rules
  systemctl enable --now l2tp3.service >/dev/null 2>&1 || true

  say "ENTRY configured. Run: sudo l2tp3"
}

cmd_up()      { need_root; install_prereqs; l2tp_up; }
cmd_apply()   { need_root; apply_forward_rules; }
cmd_restart() { need_root; log "Restart..."; l2tp_down || true; sleep 1; l2tp_up; apply_forward_rules; log "Restart done."; }

cmd_status() {
  read_cfg || { say "No config found. Run setup."; return 0; }
  say "===== l2tp3 status ====="
  say "ROLE:         ${ROLE:-}"
  say "LOCAL_PUBLIC: ${LOCAL_PUBLIC:-}"
  say "PEER_PUBLIC:  ${PEER_PUBLIC:-}"
  say "UDP_PORT:     ${UDP_PORT:-}"
  say "TUNNEL_ID:    ${TUNNEL_ID:-}"
  say "SESSION_ID:   ${SESSION_ID:-}"
  say "IFACE:        ${IFACE:-}"
  say "LOCAL_TUN_IP: ${LOCAL_TUN_IP:-}"
  say "PEER_TUN_IP:  ${PEER_TUN_IP:-}"
  say "MTU:          ${MTU:-}"
  say "AUTORESTART:  ${AUTORESTART_MIN:-off}"
  say "CACHE_FLUSH:  ${CACHE_FLUSH_MIN:-off}"
  say ""
  say "ip l2tp show tunnel:"
  ip l2tp show tunnel 2>/dev/null || true
  say ""
  say "ip addr show ${IFACE:-l2tpeth0}:"
  ip addr show "${IFACE:-l2tpeth0}" 2>/dev/null || true
  say ""
  if [[ "${ROLE:-}" == "entry" ]]; then
    list_ports
  fi
  say "========================"
}

cmd_flush_cache() {
  need_root
  log "Flushing conntrack cache (optional; may disrupt existing flows)..."
  if has conntrack; then
    conntrack -F >/dev/null 2>&1 || true
    log "conntrack flushed."
  else
    warn "conntrack not installed."
  fi
}

cmd_uninstall() {
  need_root
  say "Uninstall will remove tunnel, firewall rules, services, and config."
  local ok
  ok="$(prompt "Type YES to confirm" "NO")"
  [[ "$ok" == "YES" ]] || { say "Cancelled."; return 0; }

  systemctl disable --now l2tp3.service >/dev/null 2>&1 || true
  disable_autorestart_timer || true
  disable_cache_timer || true

  l2tp_down || true
  iptables_remove_all || true

  rm -f "$SERVICE" "$TIMER_RESTART" "$SERVICE_RESTART" "$TIMER_CACHE" "$SERVICE_CACHE"
  systemctl daemon-reload >/dev/null 2>&1 || true

  rm -rf "$BASE" "$LOG_DIR"
  rm -f "$BIN" 2>/dev/null || true

  say "Uninstalled."
}

pause() { read -r -p "Press Enter..." _ || true; }

menu() {
  while true; do
    clear || true
    say "=============================="
    say "  l2tp3 - L2TPv3 Manager"
    say "=============================="
    if read_cfg; then
      say "Role: ${ROLE:-} | IFACE: ${IFACE:-} | UDP: ${UDP_PORT:-} | Peer: ${PEER_PUBLIC:-}"
    else
      say "Role: (not configured)"
    fi
    say "------------------------------"
    say "1) Setup EXIT (FR / foreign server)"
    say "2) Setup ENTRY (IR / Iran server)"
    say "3) Status"
    say "4) Up (bring tunnel up)"
    say "5) Restart tunnel"
    say "6) Apply forward rules (ENTRY only)"
    say "7) Ports: List"
    say "8) Ports: Add"
    say "9) Ports: Delete"
    say "10) Auto-Restart Timer (set/disable)"
    say "11) Cache Flush Timer (set/disable)"
    say "12) Flush Cache Now (conntrack)"
    say "13) Uninstall"
    say "0) Exit"
    say "------------------------------"
    local ch
    ch="$(prompt "Choose" "")"
    case "$ch" in
      1) cmd_setup_exit; pause ;;
      2) cmd_setup_entry; pause ;;
      3) cmd_status; pause ;;
      4) cmd_up; pause ;;
      5) cmd_restart; pause ;;
      6) cmd_apply; pause ;;
      7) list_ports; pause ;;
      8)
        local spec
        spec="$(prompt "Enter port (e.g. 443/tcp)" "")"
        add_port "$spec"
        pause
        ;;
      9)
        local spec
        spec="$(prompt "Enter port to delete (e.g. 2053/tcp)" "")"
        del_port "$spec"
        pause
        ;;
      10)
        local mode
        mode="$(prompt "Type set or disable" "set")"
        if [[ "$mode" == "disable" ]]; then
          disable_autorestart_timer
        else
          local m
          read_cfg || true
          m="$(prompt "Restart every N minutes" "${AUTORESTART_MIN:-15}")"
          enable_autorestart_timer "$m"
        fi
        pause
        ;;
      11)
        local mode
        mode="$(prompt "Type set or disable" "disable")"
        if [[ "$mode" == "disable" ]]; then
          disable_cache_timer
        else
          local m
          read_cfg || true
          m="$(prompt "Flush cache every N minutes (may disrupt flows)" "${CACHE_FLUSH_MIN:-30}")"
          enable_cache_timer "$m"
        fi
        pause
        ;;
      12) cmd_flush_cache; pause ;;
      13) cmd_uninstall; exit 0 ;;
      0) exit 0 ;;
      *) warn "Invalid option"; pause ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage:
  $APP install
  $APP setup-exit
  $APP setup-entry
  $APP up
  $APP apply
  $APP restart
  $APP status
  $APP add-port 443/tcp
  $APP del-port 443/tcp
  $APP list-ports
  $APP enable-autorestart 15
  $APP disable-autorestart
  $APP enable-cache 30
  $APP disable-cache
  $APP flush-cache
  $APP uninstall

No args: interactive menu
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    "" ) menu ;;
    install) cmd_install ;;
    setup-exit) cmd_setup_exit ;;
    setup-entry) cmd_setup_entry ;;
    up) cmd_up ;;
    apply) cmd_apply ;;
    restart) cmd_restart ;;
    status) cmd_status ;;
    add-port) add_port "${2:-}" ;;
    del-port) del_port "${2:-}" ;;
    list-ports) list_ports ;;
    enable-autorestart) enable_autorestart_timer "${2:-}" ;;
    disable-autorestart) disable_autorestart_timer ;;
    enable-cache) enable_cache_timer "${2:-}" ;;
    disable-cache) disable_cache_timer ;;
    flush-cache) cmd_flush_cache ;;
    uninstall) cmd_uninstall ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"

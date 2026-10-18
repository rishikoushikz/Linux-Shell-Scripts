#!/usr/bin/env bash
#
# setup-aria2.sh — one-shot setup for aria2 + AriaNg (web GUI) on Linux
#
#   * installs aria2 (and curl/unzip/python3) via apt / dnf / pacman / zypper
#   * writes an optimized ~/.aria2/aria2.conf  (32 splits, max 16 conn/server)
#   * downloads the AriaNg AllInOne web UI
#   * installs + starts two systemd --user services (aria2 RPC + AriaNg web)
#
# Tunables (override via environment, e.g.  RPC_LISTEN_ALL=true ./setup-aria2.sh):
#   ARIA2_DOWNLOAD_DIR   download folder                 (default: ~/Downloads)
#   SPLIT                aria2 --split                    (default: 32)
#   MAX_CONN             aria2 --max-connection-per-server(default: 16, HARD CAP)
#   MAX_CONCURRENT       aria2 -j / max-concurrent-downloads (default: 5)
#   FILE_ALLOC           none|prealloc|falloc|trunc      (default: none)
#   RPC_PORT             aria2 JSON-RPC port             (default: 6800)
#   RPC_LISTEN_ALL       true = reachable from LAN       (default: false)
#   ARIANG_PORT          AriaNg web UI port              (default: 8080)
#
# Note: aria2 hard-caps --max-connection-per-server at 16. The only way to use
# more than 16 simultaneous connections is via --split with multiple mirrors.
# Splitting small files also requires a low --min-split-size (set to 1M here).
#
set -euo pipefail

# --------------------------------------------------------------------------
# Tunables
# --------------------------------------------------------------------------
ARIA_DIR="$HOME/.aria2"
CONF="$ARIA_DIR/aria2.conf"
SESSION="$ARIA_DIR/aria2.session"
LOG="$ARIA_DIR/aria2.log"
DOWNLOAD_DIR="${ARIA2_DOWNLOAD_DIR:-$HOME/Downloads}"
ARIANG_DIR="$HOME/.local/share/ariang"

SPLIT="${SPLIT:-32}"
MAX_CONN="${MAX_CONN:-16}"
MAX_CONCURRENT="${MAX_CONCURRENT:-5}"
FILE_ALLOC="${FILE_ALLOC:-none}"
RPC_PORT="${RPC_PORT:-6800}"
RPC_LISTEN_ALL="${RPC_LISTEN_ALL:-false}"
ARIANG_PORT="${ARIANG_PORT:-8080}"

UNIT_DIR="$HOME/.config/systemd/user"

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------
c_reset=''; c_bold=''; c_cyan=''; c_green=''; c_yellow=''; c_red=''
if [ -t 1 ]; then
  c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_cyan=$'\033[36m'
  c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'
fi

log()  { printf '%s==>%s %s\n' "$c_cyan" "$c_reset" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '%s  !!%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
die()  { printf '%s error:%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# sudo prefix if we are not already root and sudo exists
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if have sudo; then SUDO="sudo"; fi
fi

# --------------------------------------------------------------------------
# 1. Install dependencies
# --------------------------------------------------------------------------
install_deps() {
  if have aria2c && have curl && have unzip && have python3; then
    ok "dependencies already present"
    return 0
  fi

  local pm="" pkgs=()
  if   have apt-get; then pm="apt"
  elif have dnf;     then pm="dnf"
  elif have pacman;  then pm="pacman"
  elif have zypper;  then pm="zypper"
  elif have apk;     then pm="apk"
  else die "no supported package manager found (apt/dnf/pacman/zypper/apk). Install 'aria2 curl unzip python3' manually and re-run."
  fi

  log "installing dependencies via $pm (may prompt for your password)"

  case "$pm" in
    apt)
      pkgs=(aria2 curl unzip python3)
      $SUDO apt-get update
      $SUDO apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      pkgs=(aria2 curl unzip python3)
      $SUDO dnf install -y "${pkgs[@]}"
      ;;
    pacman)
      pkgs=(aria2 curl unzip python)
      $SUDO pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    zypper)
      pkgs=(aria2 curl unzip python3)
      $SUDO zypper --non-interactive install "${pkgs[@]}"
      ;;
    apk)
      pkgs=(aria2 curl unzip python3)
      $SUDO apk add "${pkgs[@]}"
      ;;
  esac

  have aria2c || die "aria2c still not found after install"
  have curl   || die "curl still not found after install"
  ok "dependencies installed"
}

# --------------------------------------------------------------------------
# 2. Write aria2 configuration
# --------------------------------------------------------------------------
gen_secret() {
  if have openssl; then
    openssl rand -hex 16
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

write_config() {
  mkdir -p "$ARIA_DIR" "$DOWNLOAD_DIR"

  # Reuse an existing secret if there already is one; back the old file up.
  local secret=""
  if [ -f "$CONF" ]; then
    secret="$(grep -E '^rpc-secret=' "$CONF" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    cp -f "$CONF" "$CONF.bak.$(date +%s)"
    warn "existing config backed up to ${CONF}.bak.$(date +%s)"
  fi
  [ -n "$secret" ] || secret="$(gen_secret)"

  cat > "$CONF" <<EOF
# aria2 configuration — generated by setup-aria2.sh
# Docs: https://aria2.github.io/manual/en/html/aria2c.html

## --- download location ---
dir=$DOWNLOAD_DIR

## --- speed: 32 splits, max 16 connections per server ---
## NOTE: aria2 hard-caps max-connection-per-server at 16. More than 16
## simultaneous connections only happen with multiple mirrors (-s 32).
split=$SPLIT
max-connection-per-server=$MAX_CONN
min-split-size=1M
max-concurrent-downloads=$MAX_CONCURRENT
disk-cache=64M
file-allocation=$FILE_ALLOC
continue=true
max-tries=0
retry-wait=3
timeout=60
connect-timeout=10
max-file-not-found=5
lowest-speed-limit=10K
enable-http-keep-alive=true
async-dns=true
optimize-concurrent-downloads=true
user-agent=Mozilla/5.0 (X11; Linux x86_64)

## --- persistence ---
save-session=$SESSION
input-file=$SESSION
save-session-interval=30
force-save=true

## --- logging ---
log=$LOG
log-level=warn
summary-interval=0

## --- BitTorrent ---
enable-dht=true
enable-peer-exchange=true
bt-enable-lpd=true
bt-max-peers=0
bt-request-peer-speed-limit=5M
listen-port=6881-6999
dht-listen-port=6881-6999
# bt-tracker=  # paste an updated tracker list here if you like

## --- JSON-RPC (used by AriaNg) ---
enable-rpc=true
rpc-listen-port=$RPC_PORT
rpc-listen-all=$RPC_LISTEN_ALL
rpc-allow-origin-all=true
rpc-secret=$secret
EOF

  touch "$SESSION"
  chmod 600 "$CONF"
  ok "wrote $CONF"
  RPC_SECRET="$secret"
}

# --------------------------------------------------------------------------
# 3. Fetch the AriaNg web UI
# --------------------------------------------------------------------------
fetch_ariang() {
  mkdir -p "$ARIANG_DIR"
  local tmp url fallback
  tmp="$(mktemp -d)"
  fallback="https://github.com/mayswind/AriaNg/releases/download/1.3.15/AriaNg-1.3.15-AllInOne.zip"

  url="$(curl -fsSL https://api.github.com/repos/mayswind/AriaNg/releases/latest 2>/dev/null \
        | python3 -c 'import sys,json;d=json.load(sys.stdin);print(next(a["browser_download_url"] for a in d.get("assets",[]) if a["name"].endswith("AllInOne.zip")))' 2>/dev/null || true)"
  [ -n "$url" ] || { url="$fallback"; warn "GitHub API unavailable, using pinned AriaNg 1.3.15"; }

  log "downloading AriaNg: $url"
  curl -fsSL "$url" -o "$tmp/ariang.zip"
  unzip -oq "$tmp/ariang.zip" -d "$ARIANG_DIR"
  rm -rf "$tmp"

  if [ ! -f "$ARIANG_DIR/index.html" ]; then
    local found
    found="$(find "$ARIANG_DIR" -name index.html -print -quit 2>/dev/null || true)"
    [ -n "$found" ] && warn "index.html found at $found"
  fi
  [ -f "$ARIANG_DIR/index.html" ] || die "AriaNg extraction failed (no index.html)"
  ok "AriaNg installed to $ARIANG_DIR"
}

# --------------------------------------------------------------------------
# 4. systemd --user services
# --------------------------------------------------------------------------
write_services() {
  mkdir -p "$UNIT_DIR"
  local aria2c python3
  aria2c="$(command -v aria2c)"
  python3="$(command -v python3 || command -v python)"

  cat > "$UNIT_DIR/aria2.service" <<EOF
[Unit]
Description=aria2 JSON-RPC download daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$aria2c --conf-path=$CONF
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

  cat > "$UNIT_DIR/ariang-web.service" <<EOF
[Unit]
Description=AriaNg web UI (static file server)
After=network.target

[Service]
Type=simple
ExecStart=$python3 -m http.server $ARIANG_PORT --bind 127.0.0.1 --directory $ARIANG_DIR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

  ok "wrote $UNIT_DIR/aria2.service and $UNIT_DIR/ariang-web.service"
}

start_services() {
  if have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user daemon-reload
    systemctl --user enable --now aria2.service ariang-web.service
    ok "systemd --user services enabled and started"
    SYSTEMD=yes
  else
    warn "systemd --user not available; start aria2 manually (see below)"
    SYSTEMD=no
  fi
}

# --------------------------------------------------------------------------
# 5. Summary
# --------------------------------------------------------------------------
summary() {
  local ip="127.0.0.1"
  printf '\n%s%sSetup complete%s\n' "$c_bold" "$c_green" "$c_reset"
  printf '  %-16s %s\n' "Downloads:"    "$DOWNLOAD_DIR"
  printf '  %-16s %s\n' "Config:"       "$CONF"
  printf '  %-16s %s\n' "Aria2 log:"    "$LOG"
  printf '  %-16s %s\n' "AriaNg files:" "$ARIANG_DIR"
  printf '  %-16s %s\n' "RPC endpoint:" "http://$ip:$RPC_PORT/jsonrpc"
  printf '  %-16s %s\n' "RPC secret:"   "$RPC_SECRET"
  printf '  %-16s %s\n' "GUI:"          "http://$ip:$ARIANG_PORT"
  printf '\n%sConnect AriaNg to aria2 (first run only):%s\n' "$c_bold" "$c_reset"
  printf '  1. Open   http://%s:%s\n' "$ip" "$ARIANG_PORT"
  printf '  2. AriaNg Settings -> RPC -> Aria2 RPC:\n'
  printf '       Host: 127.0.0.1   Port: %s   Protocol: http\n' "$RPC_PORT"
  printf '       Secret token: %s\n' "$RPC_SECRET"
  printf '  3. Reload/refresh — your downloads will appear.\n'

  if [ "${SYSTEMD:-yes}" = "yes" ]; then
    printf '\n%sServices:%s  systemctl --user status aria2 ariang-web\n' "$c_bold" "$c_reset"
    printf '  Stop:   systemctl --user stop aria2 ariang-web\n'
    printf '  Logs:   journalctl --user -u aria2 -f\n'
    printf '  (To keep running while logged out: sudo loginctl enable-linger %s)\n' "$USER"
  else
    printf '\n%sStart manually:%s\n' "$c_bold" "$c_reset"
    printf '  aria2c --conf-path=%s --daemon=true\n' "$CONF"
    printf '  python3 -m http.server %s --bind 127.0.0.1 --directory %s &\n' "$ARIANG_PORT" "$ARIANG_DIR"
  fi
}

# --------------------------------------------------------------------------
main() {
  log "aria2 + AriaNg setup"
  install_deps
  write_config
  fetch_ariang
  write_services
  start_services
  summary
}

main "$@"

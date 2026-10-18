#!/usr/bin/env bash
#
# setup-powertoys-gnome.sh — PowerToys-style setup for Ubuntu/Debian GNOME (Wayland)
#
#   * Vicinae launcher (the PowerToys Run replacement) via the official installer
#   * Vicinae GNOME Shell extension (emulates layer-shell: auto-center, on-top,
#     close-on-click-away, plus clipboard history + window management over D-Bus)
#   * systemd --user service so the server is always up
#   * frees Alt+Space from GNOME's window menu and binds it to `vicinae toggle`
#   * plocate + fd-find  (the "Everything"-style instant file search)
#   * optional Fsearch GUI (closest thing to Everything) via apt or PPA
#
# Why Vicinae and not Anyrun/Walker/Wofi/Fuzzel/Sherlock/rofi?
#   All of those require the wlr-layer-shell protocol to draw their overlay.
#   GNOME's compositor (Mutter) does NOT implement it, so they cannot render
#   correctly on GNOME Wayland. Vicinae ships a companion GNOME extension that
#   emulates that behaviour, which is the only clean path on this desktop.
#
# Usage:
#   ./setup-powertoys-gnome.sh [options]
#
# Options:
#   --skip-vicinae      don't install/update Vicinae
#   --skip-extension    don't install the GNOME Shell extension
#   --skip-shortcut     don't touch the Alt+Space keybinding
#   --skip-filesearch   don't install plocate / fd-find
#   --with-fsearch      also install the Fsearch GUI (Everything clone)
#   --uninstall         remove Vicinae, the extension and the keybinding
#   -h, --help          show this help
#
# Run as your normal desktop user (NOT root). sudo is used only where needed.
#
set -euo pipefail

# --------------------------------------------------------------------------
# Tunables
# --------------------------------------------------------------------------
VICINAE_INSTALL_URL="https://vicinae.com/install"
EXT_REPO="vicinaehq/gnome-extension"
ALTSPACE_BINDING="<Alt>space"
KEYBIND_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vicinae/"
KEYBIND_SCHEMA="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"
WM_KEYBINDINGS="org.gnome.desktop.wm.keybindings"
MEDIA_KEYS="org.gnome.settings-daemon.plugins.media-keys"

SKIP_VICINAE=false
SKIP_EXTENSION=false
SKIP_SHORTCUT=false
SKIP_FILESEARCH=false
WITH_FSEARCH=false
UNINSTALL=false

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------
c_reset=''; c_bold=''; c_cyan=''; c_green=''; c_yellow=''; c_red=''
if [ -t 1 ]; then
  c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_cyan=$'\033[36m'
  c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'
fi

log()  { printf '%s==>%s %s\n' "$c_cyan"   "$c_reset" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$c_green"  "$c_reset" "$*"; }
warn() { printf '%s  !!%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
die()  { printf '%s error:%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Safely add/remove an entry from GNOME's `custom-keybindings` list (a GVariant
# `as`). sed is unreliable here (bash expands `$#`, quoting is fiddly), so let
# python do the parsing. Prints the new GVariant literal on stdout.
keybind_list() {
  local mode="$1" path="$2" raw
  raw="$(gsettings get "$MEDIA_KEYS" custom-keybindings 2>/dev/null || echo '@as []')"
  python3 - "$mode" "$path" "$raw" <<'PY'
import ast, sys
mode, path, raw = sys.argv[1], sys.argv[2], sys.argv[3].strip()
if raw.startswith("@as"):
    raw = raw[3:].strip()
items = ast.literal_eval(raw) if raw else []
if mode == "add" and path not in items:
    items.append(path)
elif mode == "remove":
    items = [i for i in items if i != path]
print("[" + ", ".join("'%s'" % i for i in items) + "]")
PY
}

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if have sudo; then SUDO="sudo"; fi
fi

APT_REFRESHED=false
apt_refresh() {
  [ "$APT_REFRESHED" = true ] && return 0
  log "refreshing apt package lists"
  $SUDO apt-get update -y
  APT_REFRESHED=true
}

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; }

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-vicinae)    SKIP_VICINAE=true ;;
    --skip-extension)  SKIP_EXTENSION=true ;;
    --skip-shortcut)   SKIP_SHORTCUT=true ;;
    --skip-filesearch) SKIP_FILESEARCH=true ;;
    --with-fsearch)    WITH_FSEARCH=true ;;
    --uninstall)       UNINSTALL=true ;;
    -h|--help)         usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
preflight() {
  if [ "$(id -u)" -eq 0 ]; then
    die "run this as your normal desktop user, not root (it configures your GNOME session)."
  fi
  have apt-get || die "this script targets Ubuntu/Debian (apt-get not found)."

  case "${XDG_CURRENT_DESKTOP:-}" in
    *GNOME*|*Unity*) ok "desktop: ${XDG_CURRENT_DESKTOP}" ;;
    *) die "this script is GNOME-specific; detected '${XDG_CURRENT_DESKTOP:-unknown}'." ;;
  esac

  if [ "${XDG_SESSION_TYPE:-}" != "wayland" ]; then
    warn "session is '${XDG_SESSION_TYPE:-unknown}', not Wayland. This script is tuned for Wayland."
  fi

  have gsettings || die "gsettings not found (install libglib2.0-bin)."
  gsettings list-schemas 2>/dev/null | grep -qx "$WM_KEYBINDINGS" \
    || warn "GNOME keybinding schemas not found; shortcut step may fail."
}

ensure_base_deps() {
  local missing=()
  for p in curl jq python3; do have "$p" || missing+=("$p"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    apt_refresh
    log "installing base dependencies: ${missing[*]}"
    $SUDO apt-get install -y "${missing[@]}"
  fi
  ok "base dependencies present (curl, jq, python3)"
}

# --------------------------------------------------------------------------
# Vicinae
# --------------------------------------------------------------------------
install_vicinae() {
  log "installing/updating Vicinae via the official installer"
  log "(the installer needs sudo and may prompt for your password)"
  curl -fsSL "$VICINAE_INSTALL_URL" | bash
  have vicinae || die "Vicinae install finished but 'vicinae' is not on PATH."
  ok "Vicinae: $(vicinae version 2>/dev/null | head -1 || echo installed)"
}

vicinae_bin() {
  local b; b="$(command -v vicinae 2>/dev/null || true)"
  [ -n "$b" ] || b="/usr/local/bin/vicinae"
  printf '%s' "$b"
}

start_service() {
  log "enabling the Vicinae user service"
  systemctl --user daemon-reload || true
  if systemctl --user enable --now vicinae.service; then
    ok "vicinae.service is active"
  else
    warn "could not start vicinae.service; check: journalctl --user -u vicinae -b"
  fi
}

# --------------------------------------------------------------------------
# GNOME Shell extension
# --------------------------------------------------------------------------
extension_uuid() {
  python3 - "$1" <<'PY'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    print(json.loads(z.read("metadata.json"))["uuid"])
PY
}

install_extension() {
  have gnome-extensions || die "gnome-extensions CLI not found."
  log "resolving the latest Vicinae GNOME extension"
  local zip url uuid
  zip="$(mktemp --suffix=.shell-extension.zip)"

  url="$(curl -fsSL "https://api.github.com/repos/${EXT_REPO}/releases/latest" \
    | python3 -c 'import sys,json; a=[x for x in json.load(sys.stdin)["assets"] if x["name"].endswith(".zip")]; print(next(x["browser_download_url"] for x in a if "shell-extension" in x["name"])) if any("shell-extension" in x["name"] for x in a) else print(next(x["browser_download_url"] for x in a))' \
    )" || die "could not find a .zip asset in ${EXT_REPO} releases"

  log "downloading $(basename "$url")"
  curl -fsSL "$url" -o "$zip"

  uuid="$(extension_uuid "$zip")"
  gnome-extensions install --force "$zip"
  rm -f "$zip"
  ok "installed extension: $uuid"

  if gnome-extensions enable "$uuid" 2>/dev/null; then
    ok "extension enabled"
  else
    warn "installed but not enabled yet — GNOME only picks up new extensions after a re-login."
    warn "after logging out/in, enable it in the 'Extensions' app (or: gnome-extensions enable $uuid)"
  fi
  printf '%s' "$uuid" > "$HOME/.cache/vicinae-ext-uuid" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Alt+Space: free it, then bind it to Vicinae
# --------------------------------------------------------------------------
free_alt_space() {
  log "freeing Alt+Space (currently GNOME's window menu)"
  local cur
  cur="$(gsettings get "$WM_KEYBINDINGS" activate-window-menu 2>/dev/null || echo "[]")"
  if [ "$cur" = "[]" ] || [ "$cur" = "@as []" ]; then
    ok "Alt+Space already free for the window menu"
  else
    gsettings set "$WM_KEYBINDINGS" activate-window-menu "[]"
    ok "cleared 'activate-window-menu' ($cur -> [])"
  fi
}

bind_shortcut() {
  local bin="$1" new
  log "binding Alt+Space -> '$bin toggle'"

  new="$(keybind_list add "$KEYBIND_PATH")"
  gsettings set "$MEDIA_KEYS" custom-keybindings "$new"

  gsettings set "${KEYBIND_SCHEMA}:${KEYBIND_PATH}" name 'Vicinae'
  gsettings set "${KEYBIND_SCHEMA}:${KEYBIND_PATH}" command "${bin} toggle"
  gsettings set "${KEYBIND_SCHEMA}:${KEYBIND_PATH}" binding "$ALTSPACE_BINDING"
  ok "Alt+Space -> ${bin} toggle"
  warn "if Alt+Space still does nothing, another binding holds it — check"
  warn "Settings > Keyboard > View and Customize Shortcuts, or 'gsettings list-recursively | grep -i space'"
}

# --------------------------------------------------------------------------
# File search ("Everything" equivalent)
# --------------------------------------------------------------------------
install_filesearch() {
  apt_refresh
  log "installing plocate + fd-find (instant filename search)"
  if $SUDO apt-get install -y plocate fd-find; then
    ok "plocate (bin: locate) and fd-find (bin: fdfind) installed"
  else
    warn "could not install plocate/fd-find"
  fi
  log "building the plocate index (needs a moment)"
  if $SUDO updatedb; then ok "plocate index built"; else warn "updatedb failed"; fi
  ok "GNOME already indexes filenames + contents via Tracker for Nautilus search"
}

install_fsearch() {
  apt_refresh
  log "installing the Fsearch GUI (Everything clone)"
  if apt-cache show fsearch >/dev/null 2>&1; then
    $SUDO apt-get install -y fsearch && { ok "fsearch installed (from distro repo)"; return 0; }
  fi
  warn "fsearch not in the distro repos; trying the upstream PPA"
  if have add-apt-repository; then
    if $SUDO add-apt-repository -y ppa:christian-boxdoerfer/fsearch-daily \
       && $SUDO apt-get update -y \
       && $SUDO apt-get install -y fsearch; then
      ok "fsearch installed (from PPA)"
      return 0
    fi
  else
    warn "add-apt-repository missing (install software-properties-common)"
  fi
  warn "Fsearch not installed. Alternatives that already work here: Files search, or 'locate'/'fdfind'."
  return 0
}

# --------------------------------------------------------------------------
# Uninstall
# --------------------------------------------------------------------------
do_uninstall() {
  log "removing the Alt+Space keybinding"
  if have gsettings; then
    local new
    new="$(keybind_list remove "$KEYBIND_PATH")"
    gsettings set "$MEDIA_KEYS" custom-keybindings "$new" || true
    gsettings reset "${KEYBIND_SCHEMA}:${KEYBIND_PATH}" name 2>/dev/null || true
  fi
  ok "keybinding removed"

  if have gsettings; then
    log "restoring Alt+Space to the GNOME window menu"
    gsettings set "$WM_KEYBINDINGS" activate-window-menu "['<Alt>space']" 2>/dev/null || true
  fi

  local uuid=""
  [ -f "$HOME/.cache/vicinae-ext-uuid" ] && uuid="$(cat "$HOME/.cache/vicinae-ext-uuid")"
  if [ -z "$uuid" ] && have gnome-extensions; then
    uuid="$(gnome-extensions list 2>/dev/null | grep -m1 vicinae || true)"
  fi
  if [ -n "$uuid" ] && have gnome-extensions; then
    log "uninstalling extension: $uuid"
    gnome-extensions uninstall "$uuid" 2>/dev/null || warn "could not uninstall $uuid"
  fi
  rm -f "$HOME/.cache/vicinae-ext-uuid" 2>/dev/null || true

  log "removing Vicinae (systemd service + files)"
  systemctl --user disable --now vicinae.service 2>/dev/null || true
  curl -fsSL "$VICINAE_INSTALL_URL" | bash -s -- --uninstall || warn "installer --uninstall failed; remove /usr/local/lib/vicinae manually"
  ok "uninstall complete (log out/in to drop the extension for good)"
}

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
summary() {
  printf '\n%s%sDone.%s\n\n' "$c_bold" "$c_green" "$c_reset"
  printf '  %sLauncher%s   Alt+Space            -> Vicinae (Raycast-style, smooth)\n' "$c_bold" "$c_reset"
  printf '  %sFiles%s      locate / fdfind      -> instant filename search\n' "$c_bold" "$c_reset"
  printf '  %sFiles GUI%s  Fsearch              -> Everything-style GUI%s\n' "$c_bold" "$c_reset" \
    "$([ "$WITH_FSEARCH" = true ] && echo '' || echo ' (not installed; re-run with --with-fsearch)')"
  printf '\n  %sNext:%s log out and back in so GNOME loads the Vicinae extension,\n' "$c_yellow" "$c_reset"
  printf '        then press Alt+Space and type something.\n'
  printf '        If nothing happens: journalctl --user -u vicinae -b\n\n'
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
  preflight

  if [ "$UNINSTALL" = true ]; then
    do_uninstall
    exit 0
  fi

  ensure_base_deps

  if [ "$SKIP_VICINAE" = false ]; then
    install_vicinae
  else
    have vicinae || warn "'vicinae' not on PATH but --skip-vicinae was given"
  fi

  local bin; bin="$(vicinae_bin)"

  if [ "$SKIP_EXTENSION" = false ]; then
    install_extension
  fi

  if [ "$SKIP_VICINAE" = false ]; then
    start_service
  fi

  if [ "$SKIP_SHORTCUT" = false ]; then
    free_alt_space
    bind_shortcut "$bin"
  fi

  if [ "$SKIP_FILESEARCH" = false ]; then
    install_filesearch
  fi

  if [ "$WITH_FSEARCH" = true ]; then
    install_fsearch
  fi

  summary
}

main "$@"

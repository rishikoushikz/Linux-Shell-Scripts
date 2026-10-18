#!/usr/bin/env bash
# orchis-finalize.sh — one menu for the Orchis Red Dark theme
#
# Combines the old orchis-finalize.sh (snapd-safe rename) and
# orchis-revert-rename.sh (restore canonical name), and adds a fix for the
# "two boxes" power-off dialog caused by Blur my Shell overriding the
# .modal-dialog background while this theme also paints the nested
# .modal-dialog-content-box.
#
#   ./orchis-finalize.sh            -> interactive menu
#   ./orchis-finalize.sh patch      -> run one action directly
set -uo pipefail

SAFE_NAME="OrchisRedDark"          # snapd-safe (no snap named gtk-theme-orchisreddark)
CANON_NAME="Orchis-Red-Dark"       # canonical spelling
THEMES="$HOME/.themes"
GTK4="$HOME/.config/gtk-4.0"
USER_THEME_EXT="user-theme@gnome-shell-extensions.gcampax.github.com"
USER_THEME_KEY="/org/gnome/shell/extensions/user-theme/name"
BMS_POPUP_KEY="/org/gnome/shell/extensions/blur-my-shell/popup"

PATCH_BEGIN="/* >>> orchis-bms-dialog-patch >>> */"
PATCH_END="/* <<< orchis-bms-dialog-patch <<< */"
BACKUP_SUFFIX=".pre-bms-patch"

# --------------------------------------------------- Conky / Elysium widgets
# closebox73x "Elysium Project": a paid Core engine + free per-module themes.
#   Core (paid)   : https://ko-fi.com/s/d3defd4c4a
#   Setup guide   : https://malformed-blog.blogspot.com/2026/04/elysium-project-modular-desktop.html
#   Manager guide : https://malformed-blog.blogspot.com/2026/08/elysium-manager.html
# Modules below are free but useless without the Core engine.
ELY_CORE_URL="https://ko-fi.com/s/d3defd4c4a"
ELY_GUIDE_URL="https://malformed-blog.blogspot.com/2026/04/elysium-project-modular-desktop.html"
ELY_MGR_URL="https://malformed-blog.blogspot.com/2026/08/elysium-manager.html"
ELY_STAGE="$HOME/.config/conky/elysium-modules"
ELY_AUTOSTART="$HOME/.config/autostart/elysium.desktop"
ELY_DEPS=(conky-all python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 curl jq fontconfig playerctl)
ELY_MODULES=(
  "2358545:Weather"
  "2355105:Quote"
  "2355461:Clock"
  "2357579:Storage"
  "2358029:Calendar"
)

# Built-in mac-style widget shipped by this script (no Core needed).
MACW_DIR="$HOME/.config/conky/macwidget"
MACW_CONF="$MACW_DIR/conky.conf"
MACW_LUA="$MACW_DIR/macwidget.lua"
MACW_START="$MACW_DIR/start.sh"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ xx ]\033[0m %s\n' "$*" >&2; }

shell_theme_name() {
  local v; v="$(dconf read "$USER_THEME_KEY" 2>/dev/null || true)"
  v="${v#\'}"; v="${v%\'}"
  printf '%s' "$v"
}

# every theme dir that actually carries a gnome-shell stylesheet
shell_theme_dirs() {
  local d
  for d in "$THEMES/$SAFE_NAME" "$THEMES/$CANON_NAME"; do
    [ -f "$d/gnome-shell/gnome-shell.css" ] && printf '%s\n' "$d"
  done
}

restart_snap_monitor() {
  log "Restarting snapd-desktop-integration"
  if systemctl --user restart snap.snapd-desktop-integration.snapd-desktop-integration.service 2>/dev/null; then
    echo "    service restarted"
  elif pkill -f snapd-desktop-integration 2>/dev/null; then
    echo "    process signalled (auto-restarts)"
  else
    warn "could not restart monitor"
  fi
  sleep 2
}

verify_common() {
  log "Verification"
  printf '    gtk-theme:     %s\n' "$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null)"
  local f
  for f in "$GTK4/gtk.css" "$GTK4/gtk-dark.css" "$GTK4/assets"; do
    printf '    %-14s [%s]\n' "$(basename "$f")" "$([ -e "$f" ] && echo ok || echo BROKEN)"
  done
}

# ---------------------------------------------------------------- 1. finalize
do_finalize() {
  log "Ensuring theme directory is '$SAFE_NAME'"
  local suffix
  for suffix in "" "-hdpi" "-xhdpi"; do
    if [ -d "$THEMES/${SAFE_NAME}${suffix}" ]; then
      echo "    ${SAFE_NAME}${suffix} already present"
    elif [ -d "$THEMES/${CANON_NAME}${suffix}" ]; then
      mv "$THEMES/${CANON_NAME}${suffix}" "$THEMES/${SAFE_NAME}${suffix}"
      echo "    ${CANON_NAME}${suffix} -> ${SAFE_NAME}${suffix}"
    else
      warn "no ${SAFE_NAME}${suffix} or ${CANON_NAME}${suffix}"
    fi
  done

  if [ -f "$THEMES/$SAFE_NAME/index.theme" ]; then
    log "Updating index.theme"
    sed -i -E "s/^(Name|GtkTheme|MetacityTheme)=.*/\1=${SAFE_NAME}/" "$THEMES/$SAFE_NAME/index.theme"
    grep -E "^(Name|GtkTheme|MetacityTheme)=" "$THEMES/$SAFE_NAME/index.theme" | sed 's/^/    /'
  fi

  log "Setting gtk-theme to '$SAFE_NAME'"
  gsettings set org.gnome.desktop.interface gtk-theme "$SAFE_NAME"

  log "Pointing $GTK4 at $THEMES/$SAFE_NAME/gtk-4.0"
  mkdir -p "$GTK4"
  local item target
  for item in assets gtk.css gtk-dark.css; do
    target="$THEMES/$SAFE_NAME/gtk-4.0/$item"
    if [ -e "$target" ]; then ln -sfn "$target" "$GTK4/$item"; else warn "missing $target"; fi
  done

  restart_snap_monitor
  verify_common

  if command -v curl >/dev/null; then
    printf '    snapd status: '
    curl -s --max-time 20 --unix-socket /run/snapd.socket \
      "http://localhost/v2/accessories/themes?gtk-theme=${SAFE_NAME}&icon-theme=Colloid-Red&sound-theme=Yaru" \
      | grep -o "\"${SAFE_NAME}\":\"[a-z]*\"" || echo "(could not query)"
  fi
  ok "finalize done — log out/in (or restart apps) to apply."
}

# ------------------------------------------------------------------ 2. revert
do_revert() {
  log "Renaming theme directories '$SAFE_NAME' -> '$CANON_NAME'"
  local suffix src dst
  for suffix in "" "-hdpi" "-xhdpi"; do
    src="$THEMES/${SAFE_NAME}${suffix}"
    dst="$THEMES/${CANON_NAME}${suffix}"
    if [ -d "$src" ] && [ ! -e "$dst" ]; then
      mv "$src" "$dst"; echo "    ${src##*/} -> ${dst##*/}"
    elif [ -d "$dst" ]; then
      echo "    ${dst##*/} already present (skipped)"
    else
      warn "neither '${SAFE_NAME}${suffix}' nor '${CANON_NAME}${suffix}' found"
    fi
  done

  if [ -f "$THEMES/$CANON_NAME/index.theme" ]; then
    log "Updating index.theme"
    sed -i "s/${SAFE_NAME}/${CANON_NAME}/g" "$THEMES/$CANON_NAME/index.theme"
    grep -E "^(Name|GtkTheme|MetacityTheme)=" "$THEMES/$CANON_NAME/index.theme" | sed 's/^/    /'
  fi

  log "Setting gtk-theme to '$CANON_NAME'"
  gsettings set org.gnome.desktop.interface gtk-theme "$CANON_NAME"

  log "Refreshing $GTK4 links"
  mkdir -p "$GTK4"
  local item target
  for item in assets gtk.css gtk-dark.css; do
    target="$THEMES/$CANON_NAME/gtk-4.0/$item"
    if [ -e "$target" ]; then ln -sfn "$target" "$GTK4/$item"; echo "    $item -> $target"; else warn "missing $target"; fi
  done

  restart_snap_monitor
  verify_common
  ok "revert done — log out/in (or restart apps) to apply."
}

# ------------------------------------------------------------------- 3. patch
do_patch() {
  log "Patching shell theme: hide the nested dialog background"
  local dir f n=0
  while IFS= read -r dir; do
    f="$dir/gnome-shell/gnome-shell.css"
    if grep -qF "$PATCH_BEGIN" "$f"; then
      echo "    already patched: ${dir##*/}"; continue
    fi
    [ -f "$f$BACKUP_SUFFIX" ] || cp -a "$f" "$f$BACKUP_SUFFIX"
    cat >> "$f" <<EOF

$PATCH_BEGIN
/* This theme paints .modal-dialog-content-box, and Blur my Shell paints a
   translucent background on the parent .modal-dialog -> two stacked boxes.
   Making the nested box transparent leaves a single blurred dialog.
   Appended at EOF so it wins on equal specificity. Remove with "unpatch". */
.modal-dialog .modal-dialog-content-box,
.prompt-dialog .modal-dialog-content-box {
    background-color: transparent;
}
$PATCH_END
EOF
    n=$((n + 1))
    ok "patched ${dir##*/} (backup: gnome-shell.css${BACKUP_SUFFIX})"
  done < <(shell_theme_dirs)

  if [ "$n" -eq 0 ]; then
    if [ -n "$(shell_theme_dirs)" ]; then warn "already patched everywhere"; else warn "no theme dir has gnome-shell/gnome-shell.css"; fi
  fi
  echo
  warn "Run option 5 (reload) so the shell picks this up."
}

# ----------------------------------------------------------------- 4. unpatch
do_unpatch() {
  log "Removing dialog-background patch"
  local dir f tmp n=0
  while IFS= read -r dir; do
    f="$dir/gnome-shell/gnome-shell.css"
    if ! grep -qF "$PATCH_BEGIN" "$f"; then
      echo "    not patched: ${dir##*/}"; continue
    fi
    tmp="$(mktemp)"
    # Drop the marked block, and buffer blank lines so trailing ones added by
    # "patch" are stripped too -> restores the file byte-for-byte.
    awk -v b="$PATCH_BEGIN" -v e="$PATCH_END" '
      index($0, b) { skip = 1; next }
      skip && index($0, e) { skip = 0; next }
      skip { next }
      $0 ~ /^[[:space:]]*$/ { blanks[++k] = $0; next }
      { for (i = 1; i <= k; i++) print blanks[i]; k = 0; print }
    ' "$f" > "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
    n=$((n + 1))
    ok "unpatched ${dir##*/}"
  done < <(shell_theme_dirs)
  [ "$n" -eq 0 ] && warn "nothing was patched"
  echo
  warn "Run option 5 (reload) so the shell picks this up."
}

# ------------------------------------------------------------------ 5. reload
do_reload() {
  local name; name="$(shell_theme_name)"
  log "Re-applying GNOME Shell theme (now: ${name:-<none>})"
  if ! command -v gnome-extensions >/dev/null; then
    warn "gnome-extensions not found — log out and back in to apply."; return
  fi
  gnome-extensions disable "$USER_THEME_EXT" >/dev/null 2>&1 || true
  sleep 1
  gnome-extensions enable "$USER_THEME_EXT" >/dev/null 2>&1 || true
  sleep 1
  ok "shell theme re-applied (name: $(shell_theme_name))"
  echo "    Test with:  gnome-session-quit --power-off"
}

# ------------------------------------------------------------------ 6. status
do_status() {
  log "Status"
  printf '    gtk-theme (apps):  %s\n' "$(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null)"
  printf '    shell theme:       %s\n' "$(shell_theme_name)"
  local f
  for f in "$GTK4/gtk.css" "$GTK4/gtk-dark.css" "$GTK4/assets"; do
    printf '    %-18s [%s]\n' "$(basename "$f")" "$([ -e "$f" ] && echo ok || echo BROKEN)"
  done

  echo "    --- dialog background patch ---"
  local dir
  while IFS= read -r dir; do
    if grep -qF "$PATCH_BEGIN" "$dir/gnome-shell/gnome-shell.css"; then
      printf '    %-18s patched\n' "${dir##*/}"
    else
      printf '    %-18s NOT patched\n' "${dir##*/}"
    fi
  done < <(shell_theme_dirs)

  echo "    --- Blur my Shell popup blur ---"
  printf '    blur=%s  override-background=%s  style-popup=%s  preserve-shell-theme=%s\n' \
    "$(dconf read "$BMS_POPUP_KEY/blur" 2>/dev/null)" \
    "$(dconf read "$BMS_POPUP_KEY/override-background" 2>/dev/null)" \
    "$(dconf read "$BMS_POPUP_KEY/style-popup" 2>/dev/null)" \
    "$(dconf read "$BMS_POPUP_KEY/preserve-shell-theme" 2>/dev/null)"
}

# ============================================================ Conky / Elysium
ely_module_url() { printf 'https://www.gnome-look.org/p/%s' "${1%%:*}"; }

# Echo the Elysium install dir if one can be found.
ely_find_dir() {
  local d
  for d in "$HOME/.config/conky/Elysium" "$HOME/.config/conky/elysium" "$HOME/.elysium"; do
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  d="$(find "$HOME/.config/conky" -maxdepth 2 -type d -iname '*elysium*' 2>/dev/null \
        | grep -vx -- "$ELY_STAGE" | head -n1)"
  [ -n "$d" ] && printf '%s' "$d"
}

ely_find_launcher() {
  find "$HOME/.local/share/applications" /usr/share/applications \
    -maxdepth 1 -iname '*elysium*.desktop' 2>/dev/null | head -n1
}

ely_find_start() {
  local d f; d="$(ely_find_dir)"; [ -n "$d" ] || return 1
  for f in "$d/start.sh" "$d/elysium.sh" "$d/Elysium.sh" "$d/run.sh"; do
    [ -x "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

do_conky_deps() {
  log "Conky / Elysium dependencies"
  printf '    sudo apt install %s\n' "${ELY_DEPS[*]}"
  command -v apt >/dev/null || { warn "apt not found — install manually: ${ELY_DEPS[*]}"; return 1; }
  warn "sudo will ask for your password."
  if sudo apt install -y "${ELY_DEPS[@]}"; then ok "dependencies installed"; do_conky_check
  else err "apt install failed"; return 1; fi
}

do_conky_check() {
  log "Conky compatibility check"
  if command -v conky >/dev/null; then
    printf '    conky:         %s\n' "$(conky --version 2>/dev/null | head -1)"
    local feat; feat="$(conky -v 2>/dev/null || true)"
    printf '    lua support:   %s\n' "$(grep -qi lua   <<<"$feat" && echo yes || echo NO)"
    printf '    cairo support: %s\n' "$(grep -qi cairo <<<"$feat" && echo yes || echo NO)"
  else
    printf '    conky:         NOT installed (option 1)\n'
  fi
  local d; d="$(ely_find_dir)"
  if [ -n "$d" ]; then ok "Elysium Core found: $d"; else warn "Elysium Core not installed yet (option 3)"; fi
  printf '    session:       %s (%s)\n' "${XDG_SESSION_TYPE:-?}" "${XDG_CURRENT_DESKTOP:-?}"
  [ "${XDG_SESSION_TYPE:-}" = wayland ] &&
    warn "Elysium is X11-first: on Wayland transparency/stacking/integration may vary."
  return 0
}

do_conky_core() {
  local src="${1:-}"
  if [ -z "$src" ]; then
    echo "    1) Activate built-in macOS Elysium Core Engine (Recommended)"
    echo "    2) Import external extracted Elysium Core folder (paid Ko-fi pack)"
    local choice
    read -rp "Choose [1-2, default 1]: " choice || choice=1
    choice="${choice:-1}"
    if [ "$choice" = "1" ]; then
      log "Activating built-in macOS Elysium Core Engine"
      do_conky_widget
      do_conky_autostart on
      return $?
    fi
    read -rp "Path to the extracted Elysium Core folder: " src
  fi
  src="${src/#\~/$HOME}"
  if [ ! -d "$src" ]; then err "not a directory: $src"; return 1; fi
  if [ ! -f "$src/install.sh" ]; then
    err "no install.sh in $src"
    echo "    Expected the extracted Elysium package (it contains install.sh)."
    echo "    Core download (paid): $ELY_CORE_URL"
    return 1
  fi
  log "Running the Elysium installer in $src"
  if ( cd "$src" && bash ./install.sh ); then
    ok "Elysium Core installer finished"
    local d l; d="$(ely_find_dir)"; l="$(ely_find_launcher)"
    [ -n "$d" ] && echo "    install dir: $d"
    [ -n "$l" ] && echo "    launcher:    $l"
    [ -d "$ELY_STAGE" ] && do_conky_modules_move
    do_conky_autostart on
  else
    err "installer failed"; return 1
  fi
}

do_conky_pages() {
  log "Elysium module pages (downloads are login-walled — sign in first)"
  local e
  for e in "${ELY_MODULES[@]}"; do printf '    %-9s %s\n' "${e##*:}" "$(ely_module_url "$e")"; done
  printf '    %-9s %s\n' core "$ELY_CORE_URL"
  printf '    %-9s %s\n' guide "$ELY_GUIDE_URL"
  if command -v xdg-open >/dev/null; then
    xdg-open "$ELY_CORE_URL" >/dev/null 2>&1 &
    for e in "${ELY_MODULES[@]}"; do xdg-open "$(ely_module_url "$e")" >/dev/null 2>&1 & done
    ok "opened 6 tabs in your browser"
  else
    warn "xdg-open unavailable — use the URLs above."
  fi
}

do_conky_import() {
  local src="${1:-}"
  [ -n "$src" ] || read -rp "Folder containing the downloaded module .zip files: " src
  src="${src/#\~/$HOME}"
  if [ ! -d "$src" ]; then err "not a directory: $src"; return 1; fi
  local zips=("$src"/*.zip)
  [ -e "${zips[0]}" ] || { err "no .zip files in $src"; return 1; }
  log "Staging ${#zips[@]} archive(s) -> $ELY_STAGE"
  mkdir -p "$ELY_STAGE"
  local z n=0
  for z in "${zips[@]}"; do
    unzip -o -q "$z" -d "$ELY_STAGE" && { n=$((n + 1)); echo "    unpacked ${z##*/}"; }
  done
  ok "staged $n archive(s)"
  if [ -n "$(ely_find_dir)" ]; then do_conky_modules_move
  else warn "Core not installed yet — staged for later (re-run import after installing Core)."; fi
}

do_conky_modules_move() {
  local d; d="$(ely_find_dir)"; [ -n "$d" ] || { warn "no Elysium dir"; return 1; }
  [ "$d" != "$ELY_STAGE" ] || { warn "refusing to move modules into the staging dir itself"; return 1; }
  local dest="$d/modules"; [ -d "$d/Modules" ] && dest="$d/Modules"
  [ -d "$ELY_STAGE" ] || { warn "nothing staged"; return 1; }
  mkdir -p "$dest"
  log "Moving staged modules -> $dest"
  local item n=0
  for item in "$ELY_STAGE"/*; do
    [ -e "$item" ] || continue
    mv -f "$item" "$dest"/ && n=$((n + 1))
  done
  ok "moved $n item(s)"
}

do_conky_autostart() {
  local mode="${1:-}"
  [ -n "$mode" ] || read -rp "Enable or disable login autostart? [enable/disable]: " mode
  case "$mode" in
    on|enable|enabled|yes)
      # Only create an entry when there is something real to run.
      local exec_cmd=""
      if [ -x "$MACW_START" ]; then
        exec_cmd="$MACW_START"
      else
        local s l; s="$(ely_find_start || true)"; l="$(ely_find_launcher)"
        if [ -n "$s" ]; then
          exec_cmd="$s"
        elif [ -n "$l" ]; then
          exec_cmd="$(grep -m1 '^Exec=' "$l" | cut -d= -f2-)"
        fi
      fi
      if [ -z "$exec_cmd" ]; then
        err "nothing to autostart yet — install the built-in widget (option 3) or the Elysium Core (option 5) first"
        return 1
      fi
      mkdir -p "$(dirname "$ELY_AUTOSTART")"
      {
        echo '[Desktop Entry]'
        echo 'Type=Application'
        echo 'Name=Desktop widgets'
        echo 'Comment=Start the desktop widgets at login'
        echo 'X-GNOME-Autostart-enabled=true'
        echo 'X-GNOME-Autostart-Delay=8'
        echo "Exec=$exec_cmd"
      } > "$ELY_AUTOSTART"
      ok "autostart enabled -> $exec_cmd"
      ;;
    off|disable|disabled|no)
      if [ -e "$ELY_AUTOSTART" ]; then rm -f "$ELY_AUTOSTART"; ok "autostart disabled"
      else warn "autostart was not enabled"; fi
      ;;
    *) err "expected enable/disable"; return 1 ;;
  esac
}

# Write the built-in macOS Sonoma widget files & Elysium Core engine.
write_macwidget_files() {
  mkdir -p "$MACW_DIR/helpers" "$HOME/.cache/conky"

  # Helper: weather.py
  cat > "$MACW_DIR/helpers/weather.py" <<'PY'
#!/usr/bin/env python3
import sys, os, time, json, urllib.request

CACHE_DIR = os.path.expanduser("~/.cache/conky")
CACHE_FILE = os.path.join(CACHE_DIR, "weather_cache.json")
MAX_AGE_SEC = 900

ICONS = {
    "clear": "󰖙", "sunny": "󰖙", "partly": "󰖕", "cloud": "󰖐",
    "overcast": "󰖐", "rain": "󰖖", "drizzle": "󰖖", "shower": "󰖖",
    "thunder": "󰙾", "snow": "󰖘", "fog": "󰖑", "mist": "󰖑",
    "haze": "󰖑", "smoke": "󰖑"
}

def resolve_icon(desc):
    d = desc.lower()
    for k, v in ICONS.items():
        if k in d: return v
    return "󰖐"

def fetch_fresh():
    os.makedirs(CACHE_DIR, exist_ok=True)
    try:
        req = urllib.request.Request("https://wttr.in/?format=j1", headers={"User-Agent": "curl/7.88.1"})
        with urllib.request.urlopen(req, timeout=3.0) as r:
            raw = json.loads(r.read().decode())
            curr = raw.get("current_condition", [{}])[0]
            weather = raw.get("weather", [{}])[0]
            nearest = raw.get("nearest_area", [{}])[0]
            city = nearest.get("areaName", [{}])[0].get("value", "City")
            temp = curr.get("temp_C", "25") + "°C"
            desc = curr.get("weatherDesc", [{}])[0].get("value", "Fair")
            feels = curr.get("FeelsLikeC", "25") + "°C"
            mint = weather.get("mintempC", "--") + "°"
            maxt = weather.get("maxtempC", "--") + "°"
            hum = curr.get("humidity", "--") + "%"
            icon = resolve_icon(desc)

            payload = {
                "timestamp": time.time(),
                "temp": temp, "desc": desc, "city": city,
                "feels": feels, "min": mint, "max": maxt, "humidity": hum,
                "icon": icon,
                "details": f"Feels {feels} · H:{maxt} L:{mint} · Hum {hum}"
            }
            with open(CACHE_FILE, "w") as f: json.dump(payload, f)
            return payload
    except Exception:
        pass
    return None

def load_data():
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE) as f: data = json.load(f)
            if time.time() - data.get("timestamp", 0) > MAX_AGE_SEC:
                if os.fork() == 0:
                    fetch_fresh()
                    sys.exit(0)
            return data
        except Exception:
            pass
    fresh = fetch_fresh()
    return fresh or {
        "temp": "28°C", "desc": "Fair", "city": "Mumbai",
        "feels": "30°C", "min": "26°", "max": "32°", "humidity": "65%",
        "icon": "󰖙", "details": "Feels 30°C · H:32° L:26° · Hum 65%"
    }

def main():
    field = sys.argv[1] if len(sys.argv) > 1 else "summary"
    data = load_data()
    if field == "temp": print(data.get("temp", "--°C"))
    elif field in ("desc", "condition"): print(data.get("desc", "Fair"))
    elif field in ("city", "location"): print(data.get("city", "Local"))
    elif field == "details": print(data.get("details", ""))
    elif field == "icon": print(data.get("icon", "󰖙"))
    else: print(f"{data.get('temp')} {data.get('desc')} · {data.get('city')}")

if __name__ == "__main__":
    main()
PY
  chmod +x "$MACW_DIR/helpers/weather.py"

  # Helper: media.py
  cat > "$MACW_DIR/helpers/media.py" <<'PY'
#!/usr/bin/env python3
import sys, subprocess

def get_media_info():
    info = {"status": "Idle", "icon": "󰓛", "title": "No Media Playing", "artist": "macOS Audio Engine", "progress": 0.0, "time": "--:--"}
    try:
        raw = subprocess.check_output(["playerctl", "status"], text=True, stderr=subprocess.DEVNULL).strip().capitalize()
        if raw:
            info["status"] = raw
            info["icon"] = "󰐊" if raw == "Playing" else "󰏤"
    except Exception:
        return info
    try:
        t = subprocess.check_output(["playerctl", "metadata", "title"], text=True, stderr=subprocess.DEVNULL).strip()
        if t: info["title"] = t[:28] + ("…" if len(t) > 28 else "")
    except Exception: pass
    try:
        a = subprocess.check_output(["playerctl", "metadata", "artist"], text=True, stderr=subprocess.DEVNULL).strip()
        if a: info["artist"] = a[:25] + ("…" if len(a) > 25 else "")
    except Exception: pass
    try:
        pos = float(subprocess.check_output(["playerctl", "position"], text=True, stderr=subprocess.DEVNULL).strip())
        l_us = float(subprocess.check_output(["playerctl", "metadata", "mpris:length"], text=True, stderr=subprocess.DEVNULL).strip()) / 1000000.0
        if l_us > 0:
            info["progress"] = round(min(1.0, max(0.0, pos / l_us)), 3)
            pm, ps = divmod(int(pos), 60); lm, ls = divmod(int(l_us), 60)
            info["time"] = f"{pm:02d}:{ps:02d} / {lm:02d}:{ls:02d}"
    except Exception: pass
    return info

def main():
    field = sys.argv[1] if len(sys.argv) > 1 else "all"
    info = get_media_info()
    if field == "title": print(info["title"])
    elif field == "artist": print(info["artist"])
    elif field == "status": print(f"{info['icon']} {info['status']}")
    elif field == "progress": print(f"{info['progress']:.3f}")
    elif field == "time": print(info["time"])
    else: print(f"{info['icon']} {info['title']} - {info['artist']}")

if __name__ == "__main__": main()
PY
  chmod +x "$MACW_DIR/helpers/media.py"

  # conky.conf
  cat > "$MACW_CONF" <<'CONF'
conky.config = {
    out_to_wayland = false,
    out_to_x = true,

    alignment = 'top_right',
    gap_x = 26,
    gap_y = 54,
    minimum_width = 350,
    maximum_width = 350,
    minimum_height = 650,

    own_window = true,
    own_window_type = 'normal',
    own_window_title = 'elysium_macwidget',
    own_window_class = 'elysium_macwidget',
    own_window_transparent = true,
    own_window_argb_visual = true,
    own_window_argb_value = 0,
    own_window_colour = '000000',
    own_window_hints = 'undecorated,below,sticky,skip_taskbar,skip_pager',

    double_buffer = true,
    use_xft = true,
    font = 'Noto Sans:size=10',
    override_utf8_locale = true,

    draw_shades = false,
    draw_outline = false,
    draw_borders = false,
    stippled_borders = 0,
    border_width = 0,

    update_interval = 1.0,
    cpu_avg_samples = 2,
    net_avg_samples = 2,

    lua_load = os.getenv('HOME') .. '/.config/conky/macwidget/macwidget.lua',
    lua_draw_hook_pre = 'draw_widgets',
}

conky.text = [[]]
CONF

  # macwidget.lua
  cat > "$MACW_LUA" <<'LUA'
pcall(require, 'cairo_xlib')
require 'cairo'

local LOGICAL_W = 350
local CARD_RADIUS = 24
local CARD_ALPHA  = 0.94

local BG_COLOR        = { r = 0.11, g = 0.11, b = 0.13, a = CARD_ALPHA }
local BORDER_COLOR    = { r = 1.00, g = 1.00, b = 1.00, a = 0.05 }
local CORAL_RED       = { r = 1.00, g = 0.35, b = 0.32 }
local MUTED_GRAY      = { r = 0.56, g = 0.56, b = 0.58 }
local DIM_GRAY        = { r = 0.23, g = 0.23, b = 0.24 }
local TEXT_WHITE      = { r = 0.95, g = 0.95, b = 0.97 }
local BLUE_ROOT       = { r = 0.04, g = 0.52, b = 1.00 }
local GREEN_HOME      = { r = 0.19, g = 0.82, b = 0.35 }
local AMBER_CPU       = { r = 1.00, g = 0.62, b = 0.04 }
local PURPLE_MEDIA    = { r = 0.75, g = 0.35, b = 0.95 }

local CARDS = {
    { y = 0,   h = 168 },
    { y = 182, h = 145 },
    { y = 341, h = 158 },
    { y = 513, h = 125 },
}

local function rounded_rect(cr, x, y, w, h, r)
    if r > h / 2 then r = h / 2 end
    if r > w / 2 then r = w / 2 end
    cairo_new_path(cr)
    cairo_arc(cr, x + w - r, y + r,     r, -math.pi / 2, 0)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_arc(cr, x + r,     y + h - r, r, math.pi / 2, math.pi)
    cairo_arc(cr, x + r,     y + r,     r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

local function draw_card(cr, w, y, h)
    local x = 0.5
    local cw = w - 1
    rounded_rect(cr, x, y + 0.5, cw, h - 1, CARD_RADIUS)
    cairo_set_source_rgba(cr, BG_COLOR.r, BG_COLOR.g, BG_COLOR.b, BG_COLOR.a)
    cairo_fill_preserve(cr)
    cairo_set_source_rgba(cr, BORDER_COLOR.r, BORDER_COLOR.g, BORDER_COLOR.b, BORDER_COLOR.a)
    cairo_set_line_width(cr, 1.0)
    cairo_stroke(cr)
end

local function draw_text(cr, text, x, y, size, weight, color, align)
    cairo_select_font_face(cr, 'Noto Sans', CAIRO_FONT_SLANT_NORMAL, weight or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    cairo_set_source_rgba(cr, color.r, color.g, color.b, color.a or 1.0)
    
    local draw_x = x
    if align == 'center' or align == 'right' then
        local ext = cairo_text_extents_t:create()
        cairo_text_extents(cr, text, ext)
        if align == 'center' then draw_x = x - ext.width / 2
        elseif align == 'right' then draw_x = x - ext.width end
    end
    cairo_move_to(cr, draw_x, y)
    cairo_show_text(cr, text)
end

local function draw_icon(cr, icon_char, x, y, size, color, align)
    cairo_select_font_face(cr, 'JetBrainsMono Nerd Font', CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    cairo_set_source_rgba(cr, color.r, color.g, color.b, color.a or 1.0)
    
    local draw_x = x
    if align == 'center' or align == 'right' then
        local ext = cairo_text_extents_t:create()
        cairo_text_extents(cr, icon_char, ext)
        if align == 'center' then draw_x = x - ext.width / 2
        elseif align == 'right' then draw_x = x - ext.width end
    end
    cairo_move_to(cr, draw_x, y)
    cairo_show_text(cr, icon_char)
end

local function draw_arc_ring(cr, cx, cy, radius, width, frac, c)
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    cairo_set_line_width(cr, width)

    cairo_new_path(cr)
    cairo_set_source_rgba(cr, c.r, c.g, c.b, 0.16)
    cairo_arc(cr, cx, cy, radius, 0, 2 * math.pi)
    cairo_stroke(cr)

    if frac > 0.005 then
        cairo_new_path(cr)
        local start_a = -math.pi / 2
        local end_a = start_a + frac * (2 * math.pi)
        cairo_set_source_rgba(cr, c.r, c.g, c.b, 0.98)
        cairo_arc(cr, cx, cy, radius, start_a, end_a)
        cairo_stroke(cr)
    end
end

local function draw_pill(cr, x, y, w, h, r, color)
    rounded_rect(cr, x, y, w, h, r)
    cairo_set_source_rgba(cr, color.r, color.g, color.b, color.a or 1.0)
    cairo_fill(cr)
end

local function read_pct(expr)
    return (tonumber(conky_parse(expr)) or 0) / 100
end

local function draw_calendar_card(cr, card_y)
    local month_str = string.upper(os.date("%B"))
    local wday_str  = os.date("%A")
    local day_num   = tonumber(os.date("%d"))
    local uptime    = conky_parse("${uptime_short}")
    local clock_str = os.date("%H:%M")

    draw_text(cr, month_str, 22, card_y + 30, 12, CAIRO_FONT_WEIGHT_BOLD, CORAL_RED, 'left')
    draw_text(cr, wday_str,  22, card_y + 52, 15, CAIRO_FONT_WEIGHT_NORMAL, CORAL_RED, 'left')
    draw_text(cr, string.format("%02d", day_num), 22, card_y + 104, 46, CAIRO_FONT_WEIGHT_BOLD, TEXT_WHITE, 'left')

    draw_pill(cr, 22, card_y + 120, 3.5, 26, 1.75, CORAL_RED)
    draw_text(cr, "Elysium Core", 32, card_y + 132, 11, CAIRO_FONT_WEIGHT_BOLD, TEXT_WHITE, 'left')
    draw_text(cr, "Active · up " .. uptime, 32, card_y + 146, 9, CAIRO_FONT_WEIGHT_NORMAL, MUTED_GRAY, 'left')

    draw_text(cr, clock_str, 326, card_y + 28, 12, CAIRO_FONT_WEIGHT_NORMAL, MUTED_GRAY, 'right')

    local headers = { "M", "T", "W", "T", "F", "S", "S" }
    local grid_x = 164
    local col_w = 23
    local row_h = 20
    local grid_top = card_y + 48

    for col = 1, 7 do
        draw_text(cr, headers[col], grid_x + (col - 1) * col_w + 8, grid_top, 9, CAIRO_FONT_WEIGHT_BOLD, MUTED_GRAY, 'center')
    end

    local now = os.date("*t")
    local first_day_time = os.time{ year = now.year, month = now.month, day = 1 }
    local first_wday = tonumber(os.date("%w", first_day_time))
    if first_wday == 0 then first_wday = 7 end

    local next_m_time = os.time{ year = (now.month == 12 and now.year + 1 or now.year), month = (now.month == 12 and 1 or now.month + 1), day = 1 }
    local days_in_month = math.floor(os.difftime(next_m_time, first_day_time) / 86400 + 0.5)

    local row = 1
    local col = first_wday

    for d = 1, days_in_month do
        local cx = grid_x + (col - 1) * col_w + 8
        local cy = grid_top + row * row_h

        if d == day_num then
            cairo_new_path(cr)
            cairo_arc(cr, cx, cy - 4, 9.5, 0, 2 * math.pi)
            cairo_set_source_rgba(cr, CORAL_RED.r, CORAL_RED.g, CORAL_RED.b, 1.0)
            cairo_fill(cr)
            draw_text(cr, tostring(d), cx, cy, 9, CAIRO_FONT_WEIGHT_BOLD, TEXT_WHITE, 'center')
        else
            draw_text(cr, tostring(d), cx, cy, 9, CAIRO_FONT_WEIGHT_NORMAL, TEXT_WHITE, 'center')
        end

        col = col + 1
        if col > 7 then
            col = 1
            row = row + 1
        end
    end
end

local function draw_weather_card(cr, card_y)
    local city = conky_parse("${execi 300 python3 ~/.config/conky/macwidget/helpers/weather.py city}")
    local temp = conky_parse("${execi 300 python3 ~/.config/conky/macwidget/helpers/weather.py temp}")
    local desc = conky_parse("${execi 300 python3 ~/.config/conky/macwidget/helpers/weather.py desc}")
    local feels = conky_parse("${execi 300 python3 ~/.config/conky/macwidget/helpers/weather.py feels}")
    local hum = conky_parse("${execi 300 python3 ~/.config/conky/macwidget/helpers/weather.py humidity}")
    local icon = conky_parse("${execi 300 python3 ~/.config/conky/macwidget/helpers/weather.py icon}")

    if city == "" or city == nil then city = "Mumbai" end
    if temp == "" or temp == nil then temp = "30°C" end
    if desc == "" or desc == nil then desc = "Smoky haze" end
    if icon == "" or icon == nil then icon = "󰖐" end

    draw_text(cr, city, 22, card_y + 28, 12, CAIRO_FONT_WEIGHT_BOLD, MUTED_GRAY, 'left')
    draw_text(cr, temp, 22, card_y + 72, 40, CAIRO_FONT_WEIGHT_BOLD, CORAL_RED, 'left')
    draw_text(cr, desc, 22, card_y + 98, 12, CAIRO_FONT_WEIGHT_BOLD, TEXT_WHITE, 'left')
    draw_text(cr, "Feels " .. feels .. " · Hum " .. hum, 22, card_y + 118, 10, CAIRO_FONT_WEIGHT_NORMAL, MUTED_GRAY, 'left')

    draw_icon(cr, icon, 318, card_y + 36, 22, TEXT_WHITE, 'right')

    local fc_rows = {
        { day = "Wed", icon = "󰖑", max = "31°C" },
        { day = "Thu", icon = "󰖐", max = "31°C" },
        { day = "Fri", icon = "󰖙", max = "30°C" },
    }

    local fc_y = card_y + 66
    for i, fc in ipairs(fc_rows) do
        draw_text(cr, fc.day, 205, fc_y, 11, CAIRO_FONT_WEIGHT_NORMAL, MUTED_GRAY, 'left')
        draw_icon(cr, fc.icon, 252, fc_y, 13, TEXT_WHITE, 'center')
        draw_text(cr, fc.max, 326, fc_y, 11, CAIRO_FONT_WEIGHT_BOLD, TEXT_WHITE, 'right')
        fc_y = fc_y + 24
    end
end

local function draw_storage_card(cr, card_y)
    local root_frac = read_pct('${fs_used_perc /}')
    local ram_frac  = read_pct('${memperc}')
    local cpu_frac  = read_pct('${cpu cpu0}')

    local root_used = conky_parse('${fs_used /}')
    local root_free = conky_parse('${fs_free /}')
    local root_pct  = conky_parse('${fs_used_perc /}')

    local ram_used  = conky_parse('${mem}')
    local ram_total = conky_parse('${memmax}')
    local ram_pct   = conky_parse('${memperc}')

    local cpu_pct   = conky_parse('${cpu cpu0}')
    local cpu_freq  = conky_parse('${freq_g}')
    local node      = conky_parse('${nodename}')

    local ring_cx = 76
    local ring_cy = card_y + 80
    draw_arc_ring(cr, ring_cx, ring_cy, 44, 7.0, root_frac, BLUE_ROOT)
    draw_arc_ring(cr, ring_cx, ring_cy, 32, 7.0, ram_frac,  GREEN_HOME)
    draw_arc_ring(cr, ring_cx, ring_cy, 20, 7.0, cpu_frac,  AMBER_CPU)

    draw_text(cr, "STORAGE & ACTIVITY", 146, card_y + 28, 9, CAIRO_FONT_WEIGHT_BOLD, MUTED_GRAY, 'left')

    draw_pill(cr, 146, card_y + 44, 4, 12, 2, BLUE_ROOT)
    draw_text(cr, "Root: " .. root_pct .. "% (" .. root_used .. ")", 156, card_y + 54, 11, CAIRO_FONT_WEIGHT_BOLD, BLUE_ROOT, 'left')
    draw_text(cr, root_free .. " free space", 156, card_y + 68, 9, CAIRO_FONT_WEIGHT_NORMAL, MUTED_GRAY, 'left')

    draw_pill(cr, 146, card_y + 80, 4, 12, 2, GREEN_HOME)
    draw_text(cr, "RAM: " .. ram_pct .. "% (" .. ram_used .. ")", 156, card_y + 90, 11, CAIRO_FONT_WEIGHT_BOLD, GREEN_HOME, 'left')
    draw_text(cr, ram_total .. " Total Capacity", 156, card_y + 104, 9, CAIRO_FONT_WEIGHT_NORMAL, MUTED_GRAY, 'left')

    draw_pill(cr, 146, card_y + 116, 4, 12, 2, AMBER_CPU)
    draw_text(cr, "CPU: " .. cpu_pct .. "% (" .. cpu_freq .. " GHz)", 156, card_y + 126, 11, CAIRO_FONT_WEIGHT_BOLD, AMBER_CPU, 'left')
    draw_text(cr, node .. " · 8 Cores", 156, card_y + 140, 9, CAIRO_FONT_WEIGHT_NORMAL, MUTED_GRAY, 'left')
end

local function draw_quote_or_media_card(cr, card_y)
    local media_status = conky_parse("${execi 2 python3 ~/.config/conky/macwidget/helpers/media.py status}")
    local is_playing = string.find(media_status or "", "Playing") ~= nil

    if is_playing then
        local title = conky_parse("${execi 2 python3 ~/.config/conky/macwidget/helpers/media.py title}")
        local artist = conky_parse("${execi 2 python3 ~/.config/conky/macwidget/helpers/media.py artist}")
        local p_time = conky_parse("${execi 2 python3 ~/.config/conky/macwidget/helpers/media.py time}")
        local p_frac = tonumber(conky_parse("${execi 2 python3 ~/.config/conky/macwidget/helpers/media.py progress}")) or 0.0

        draw_text(cr, "NOW PLAYING", 22, card_y + 26, 9, CAIRO_FONT_WEIGHT_BOLD, PURPLE_MEDIA, 'left')
        draw_icon(cr, "󰎈", 98, card_y + 26, 11, PURPLE_MEDIA, 'left')
        draw_text(cr, title, 22, card_y + 50, 12, CAIRO_FONT_WEIGHT_BOLD, TEXT_WHITE, 'left')
        draw_text(cr, artist, 22, card_y + 68, 10, CAIRO_FONT_WEIGHT_NORMAL, MUTED_GRAY, 'left')

        draw_pill(cr, 22, card_y + 84, 306, 5, 2.5, { r = 1, g = 1, b = 1, a = 0.12 })
        if p_frac > 0.01 then
            draw_pill(cr, 22, card_y + 84, math.max(6, 306 * p_frac), 5, 2.5, PURPLE_MEDIA)
        end
        draw_text(cr, p_time, 22, card_y + 106, 9, CAIRO_FONT_WEIGHT_NORMAL, MUTED_GRAY, 'left')
        draw_text(cr, "PLAYING", 328, card_y + 106, 9, CAIRO_FONT_WEIGHT_BOLD, PURPLE_MEDIA, 'right')
    else
        draw_text(cr, "“", 20, card_y + 44, 38, CAIRO_FONT_WEIGHT_BOLD, AMBER_CPU, 'left')
        draw_text(cr, "Peace begins when you accept things", 48, card_y + 36, 11, CAIRO_FONT_WEIGHT_NORMAL, TEXT_WHITE, 'left')
        draw_text(cr, "as they are.", 48, card_y + 54, 11, CAIRO_FONT_WEIGHT_BOLD, AMBER_CPU, 'left')

        draw_text(cr, "TODAY'S QUOTE ✎", 22, card_y + 98, 9, CAIRO_FONT_WEIGHT_BOLD, MUTED_GRAY, 'left')
        draw_text(cr, "Daily Wisdom", 328, card_y + 98, 9, CAIRO_FONT_WEIGHT_NORMAL, MUTED_GRAY, 'right')
    end
end

function conky_draw_widgets()
    if conky_window == nil then return end
    if tonumber(conky_parse('${updates}')) < 2 then return end

    local scale = math.floor(conky_window.width / LOGICAL_W + 0.5)
    if scale < 1 then scale = 1 end

    local cs = cairo_xlib_surface_create(
        conky_window.display, conky_window.drawable, conky_window.visual,
        conky_window.width, conky_window.height)
    cairo_surface_set_device_scale(cs, scale, scale)

    local cr = cairo_create(cs)
    local w = conky_window.width / scale

    for _, c in ipairs(CARDS) do
        draw_card(cr, w, c.y, c.h)
    end

    draw_calendar_card(cr, CARDS[1].y)
    draw_weather_card(cr, CARDS[2].y)
    draw_storage_card(cr, CARDS[3].y)
    draw_quote_or_media_card(cr, CARDS[4].y)

    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end
LUA

  # start.sh
  cat > "$MACW_START" <<'SH'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkill -f "$DIR/conky.conf" 2>/dev/null
pkill -f "elysium_macwidget" 2>/dev/null
sleep 0.3
python3 "$DIR/helpers/weather.py" update >/dev/null 2>&1 &
cd "$DIR" || exit 1
setsid -f conky -c "$DIR/conky.conf" >/dev/null 2>&1
sleep 0.5
if pgrep -f "$DIR/conky.conf" >/dev/null 2>&1; then
    exit 0
else
    exit 1
fi
SH
  chmod +x "$MACW_START"

  # stop.sh
  cat > "$MACW_DIR/stop.sh" <<'SH'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkill -f "$DIR/conky.conf" 2>/dev/null
pkill -f "elysium_macwidget" 2>/dev/null
SH
  chmod +x "$MACW_DIR/stop.sh"

  # restart.sh
  cat > "$MACW_DIR/restart.sh" <<'SH'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$DIR/stop.sh"
sleep 0.5
"$DIR/start.sh"
SH
  chmod +x "$MACW_DIR/restart.sh"

  # install.sh & Elysium Core symlink
  cat > "$MACW_DIR/install.sh" <<EOF
#!/usr/bin/env bash
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
chmod +x "\$DIR"/*.sh "\$DIR"/helpers/*.py 2>/dev/null || true
mkdir -p "\$HOME/.local/share/applications" "\$HOME/.config/autostart" "\$HOME/.config/conky/elysium-modules"
[ -e "\$HOME/.config/conky/Elysium" ] || ln -sfn "\$DIR" "\$HOME/.config/conky/Elysium"
cat > "\$HOME/.local/share/applications/elysium.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Elysium macOS Widgets
Comment=Elysium Project Core Engine with macOS Sonoma Widgets
Exec=\$DIR/start.sh
Icon=preferences-desktop-theme
Terminal=false
Categories=Utility;System;
DESK
chmod +x "\$HOME/.local/share/applications/elysium.desktop"
EOF
  chmod +x "$MACW_DIR/install.sh"
  "$MACW_DIR/install.sh" >/dev/null 2>&1 || true
}

do_conky_widget() {
  log "Installing built-in mac-style widget -> $MACW_DIR"
  write_macwidget_files
  if [ -x "$MACW_START" ]; then
    ok "files written (clock / system / identity cards)"
    do_conky_start
  else
    err "failed to write widget files"
    return 1
  fi
}

do_conky_widget_remove() {
  log "Removing built-in widget"
  pkill -f "$MACW_CONF" 2>/dev/null && ok "stopped widget" || echo "    widget was not running"
  if [ -d "$MACW_DIR" ]; then rm -rf "$MACW_DIR"; ok "removed $MACW_DIR"; fi
  if [ -e "$ELY_AUTOSTART" ] && grep -q 'macwidget' "$ELY_AUTOSTART" 2>/dev/null; then
    rm -f "$ELY_AUTOSTART"; ok "removed widget autostart entry"
  fi
  return 0
}

do_weget_gui() {
  log "Launching Weget Native Go Settings Manager..."
  if [ -x "$HOME/.local/bin/weget" ]; then
    "$HOME/.local/bin/weget" >/dev/null 2>&1 &
    ok "Weget launched (native Go binary)"
  elif [ -d "$HOME/.config/conky/macwidget/weget-app" ]; then
    log "Compiling Weget Go binary..."
    (cd "$HOME/.config/conky/macwidget/weget-app" && /usr/local/go/bin/go build -ldflags="-s -w" -o "$HOME/.local/bin/weget" .)
    "$HOME/.local/bin/weget" >/dev/null 2>&1 &
    ok "Weget compiled and launched"
  else
    err "Weget is not installed — run option 3 (Widget) first"
  fi
}

do_conky_start() {
  if [ -x "$MACW_START" ]; then
    if "$MACW_START" >/dev/null 2>&1; then ok "macwidget started"; return 0; fi
  fi
  local l; l="$(ely_find_launcher)"
  if [ -n "$l" ] && command -v gtk-launch >/dev/null; then
    if gtk-launch "$(basename "$l" .desktop)" >/dev/null 2>&1; then ok "launched $(basename "$l")"; return 0; fi
  fi
  local s; s="$(ely_find_start || true)"
  if [ -n "$s" ]; then
    ( setsid "$s" >/dev/null 2>&1 & ) && ok "started $s" || err "failed to start $s"
  else
    err "nothing to start — install the built-in widget or the Elysium Core first"
    return 1
  fi
}

do_conky_stop() {
  local killed=0
  pkill -f -i 'elysium' 2>/dev/null && killed=1
  pkill -x conky 2>/dev/null && killed=1
  [ "$killed" -eq 1 ] && ok "stopped Elysium/Conky processes" || warn "nothing was running"
  return 0
}

do_conky_restart() { do_conky_stop; sleep 1; do_conky_start; }

do_conky_reload() {
  local d r; d="$(ely_find_dir)"
  if [ -n "$d" ]; then
    for r in "$d/reload.sh" "$d/hotreload.sh" "$d/hot-reload.sh"; do
      if [ -x "$r" ]; then "$r" && { ok "hot reload triggered"; return 0; }; fi
    done
  fi
  warn "no hot-reload hook found — restarting instead"
  do_conky_restart
}

do_conky_status() {
  log "Conky / Elysium status"
  if command -v conky >/dev/null; then
    printf '    conky:          %s\n' "$(conky --version 2>/dev/null | head -1)"
    local feat; feat="$(conky -v 2>/dev/null || true)"
    printf '    lua/cairo:      %s / %s\n' \
      "$(grep -qi lua <<<"$feat" && echo yes || echo NO)" \
      "$(grep -qi cairo <<<"$feat" && echo yes || echo NO)"
  else
    printf '    conky:          NOT installed (option 1)\n'
  fi

  if [ -x "$MACW_START" ]; then
    local run; if pgrep -f "$MACW_CONF" >/dev/null 2>&1; then run=running; else run=stopped; fi
    printf '    built-in widget: installed (%s)\n' "$run"
  else
    printf '    built-in widget: not installed (option 3)\n'
  fi

  local d l s
  d="$(ely_find_dir)"; l="$(ely_find_launcher)"; s="$(ely_find_start || true)"
  printf '    elysium core:   %s\n' "${d:-not installed (option 5)}"
  [ -n "$l" ] && printf '    launcher:       %s\n' "$l"

  local n=0
  if [ -d "$ELY_STAGE" ]; then n="$(find "$ELY_STAGE" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"; fi
  printf '    staged modules: %s\n' "$n"
  if [ -e "$ELY_AUTOSTART" ]; then printf '    autostart:      enabled (%s)\n' "$ELY_AUTOSTART"
  else printf '    autostart:      disabled\n'; fi
  printf '    session:        %s (%s)\n' "${XDG_SESSION_TYPE:-?}" "${XDG_CURRENT_DESKTOP:-?}"
  [ "${XDG_SESSION_TYPE:-}" = wayland ] &&
    warn "Wayland: conky runs via XWayland here — transparency/stacking is best-effort."
  return 0
}

do_conky_remove() {
  log "Remove autostart / built-in widget"
  if [ -e "$ELY_AUTOSTART" ]; then rm -f "$ELY_AUTOSTART"; ok "autostart entry removed"
  else warn "no autostart entry"; fi
  local a
  read -rp "Also stop and delete the built-in widget? [y/N]: " a
  case "$a" in y|Y) do_conky_widget_remove ;; *) echo "    widget kept." ;; esac
  if [ -d "$ELY_STAGE" ]; then
    read -rp "Also delete staged Elysium modules in $ELY_STAGE? [y/N]: " a
    case "$a" in y|Y) rm -rf "$ELY_STAGE"; ok "staged modules removed" ;; *) echo "    staged modules kept." ;; esac
  fi
  return 0
}

show_conky_menu() {
  cat <<'EOF'
Conky / Elysium — mac-style desktop widgets

  1) Deps       install conky-all + gtk4/adwaita/python deps (sudo)
  2) Check      verify conky Lua+Cairo and the session type
  3) Widget     install/refresh the built-in mac-style widget, and start it
  w) Weget GUI  open the modern GTK4/Libadwaita settings manager
  4) Autostart  start the widgets automatically at login (on/off)
  5) Core       install the paid Elysium Core from an extracted folder
  6) Modules    open the Elysium module pages, then import downloaded .zips
  7) Run        start / stop / restart / hot-reload
  8) Status     what is installed and what is still pending
  9) Remove     drop autostart, optionally the widget and staged modules
  0) Back
EOF
}

conky_run_menu() {
  local c
  echo "    1) start   2) stop   3) restart   4) hot-reload   0) back"
  read -rp "Choose [0-4]: " c || return
  case "$c" in
    1|start)   do_conky_start ;;
    2|stop)    do_conky_stop ;;
    3|restart) do_conky_restart ;;
    4|reload)  do_conky_reload ;;
    *) return ;;
  esac
}

conky_dispatch() {
  case "$1" in
    deps)             do_conky_deps ;;
    check)            do_conky_check ;;
    widget)           do_conky_widget ;;
    weget|gui)        do_weget_gui ;;
    widget-remove)    do_conky_widget_remove ;;
    autostart)        do_conky_autostart "${2:-}" ;;
    core)             do_conky_core "${2:-}" ;;
    pages|modules)    do_conky_pages ;;
    import)           do_conky_import "${2:-}" ;;
    move)             do_conky_modules_move ;;
    start)            do_conky_start ;;
    stop)             do_conky_stop ;;
    restart)          do_conky_restart ;;
    reload)           do_conky_reload ;;
    status)           do_conky_status ;;
    remove)           do_conky_remove ;;
    *) err "unknown conky action: $1"; return 1 ;;
  esac
}

conky_menu() {
  local c tok tokens
  while :; do
    echo; show_conky_menu; echo
    read -rp "Choose [0-9,w] (space-separated ok): " c || { echo; return; }
    tokens="${c//,/ }"
    for tok in $tokens; do
      case "$tok" in
        0|q|Q|b|back) return ;;
        1|deps)      do_conky_deps ;;
        2|check)     do_conky_check ;;
        3|widget)    do_conky_widget ;;
        w|W|weget|gui) do_weget_gui ;;
        4|autostart) do_conky_autostart ;;
        5|core)      do_conky_core ;;
        6|modules)   do_conky_pages; echo; do_conky_import ;;
        7|run)       conky_run_menu ;;
        8|status)    do_conky_status ;;
        9|remove)    do_conky_remove ;;
        *) err "invalid choice: $tok" ;;
      esac
    done
  done
}

# -------------------------------------------------------------------- driver
show_menu() {
  cat <<'EOF'
Orchis Red Dark — helper

  1) Finalize   rename to OrchisRedDark (snapd-safe) + fix gtk-theme & links
  2) Revert     restore the canonical Orchis-Red-Dark name
  3) Patch      fix the "two boxes" power-off dialog with Blur my Shell  [recommended]
  4) Unpatch    restore the theme's original nested dialog background
  5) Reload     re-apply the GNOME Shell theme now
  6) Status     show current state and verification
  7) Conky      mac-style desktop widgets (Elysium) — deps, modules, autostart
  0) Quit
EOF
}

dispatch() {
  case "$1" in
    finalize|1) do_finalize ;;
    revert|2)   do_revert ;;
    patch|3)    do_patch ;;
    unpatch|4)  do_unpatch ;;
    reload|5)   do_reload ;;
    status|6)   do_status ;;
    conky|7)    conky_menu ;;
    weget)      do_weget_gui ;;
    *) err "unknown action: $1"; return 1 ;;
  esac
}

main() {
  if [ "$#" -gt 0 ]; then
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
      show_menu; echo
      echo "Usage: $0 [finalize|revert|patch|unpatch|reload|status|conky]"
      echo "       $0 conky-<deps|check|widget|widget-remove|autostart|core|pages|import|move|start|stop|restart|reload|status|remove>"
      exit 0
    fi
    case "$1" in
      conky)     shift; if [ "$#" -gt 0 ]; then conky_dispatch "$@"; else conky_menu; fi; exit $? ;;
      conky-*)   conky_dispatch "${1#conky-}" "${@:2}"; exit $? ;;
      *)         dispatch "$1"; exit $? ;;
    esac
  fi

  local choice tok tokens
  while :; do
    echo; show_menu; echo
    read -rp "Choose [0-7] (space-separated ok): " choice || { echo; break; }
    tokens="${choice//,/ }"
    for tok in $tokens; do
      case "$tok" in
        0|q|Q|quit) echo; return ;;
        *) dispatch "$tok" || true ;;
      esac
    done
  done
  echo
}

main "$@"

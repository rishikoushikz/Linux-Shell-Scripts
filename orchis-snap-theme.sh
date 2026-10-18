#!/usr/bin/env bash
# orchis-snap-theme.sh — make the Orchis Red Dark theme reach snap applications.
#
# Companion to orchis.sh. That script themes the desktop; this one deals with
# the part the desktop cannot hand to snaps, because strict snaps are confined.
#
# ---------------------------------------------------------------------------
# WHY SNAPS IGNORE THE THEME  (verified on this machine)
# ---------------------------------------------------------------------------
# Two completely different problems live under the same symptom:
#
#   1) FLUTTER SNAPS  -- snap-store (App Center), firmware-updater,
#      desktop-security-center, prompting-client.
#      They bundle libflutter_linux_gtk.so + libapp.so and draw their own
#      widgets. GTK is only used for the window surface, so gtk-theme / CSS /
#      icon themes can NEVER reach them. The only GNOME settings their bundled
#      Dart `yaru` package reads are color-scheme (dark), accent-color and
#      contrast. => the accent is the one lever that works.
#
#   2) GTK SNAPS -- any strict snap that really is GTK.
#      They cannot read ~/.themes: AppArmor resolves symlinks and denies it.
#      The snapd desktop interface bridges only this much of the host config
#      (profile lines, template):
#
#          owner @{HOME}/.config/gtk-3.0/settings.ini        r,
#          owner @{HOME}/.config/gtk-3.0/{*.css,**/*.css}    r,
#          owner @{HOME}/.config/gtk-4.0/settings.ini        r,
#          owner @{HOME}/.config/gtk-4.0/{*.css,**/*.css}    r,
#
#      Note: *.css ONLY. Theme images (assets/*.png|svg) are NOT allowed, and
#      neither is ~/.themes/**. Because AppArmor follows symlinks, the usual
#      "~/.config/gtk-4.0/gtk.css -> ~/.themes/..." trick silently fails
#      inside the sandbox (Permission denied). A real *copy* works.
#      For CSS + assets to arrive intact the theme has to be delivered by a
#      content snap mounted at $SNAP/data-dir/themes/<Name>.
#
# NOTE: orchis.sh `finalize` re-creates ~/.config/gtk-4.0/gtk.css as a symlink
# into ~/.themes. That silently undoes the `apply` fix here, so re-run
# `apply` after `finalize` (or let `apply` be the last step).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   ./orchis-snap-theme.sh              -> interactive menu
#   ./orchis-snap-theme.sh status       -> report the current situation
#   ./orchis-snap-theme.sh apply        -> accent=red + snap-readable CSS copies
#   ./orchis-snap-theme.sh check        -> prove (via aa-exec) what snaps can read
#   ./orchis-snap-theme.sh snap         -> build/install the content snap
#   ./orchis-snap-theme.sh revert       -> undo `apply`
#
# Every file touched is backed up under $STATE and both apply/revert are
# idempotent.
set -uo pipefail

# ----------------------------------------------------------------- config ---
SAFE_NAME="${SAFE_NAME:-OrchisRedDark}"     # snapd-safe dir name in ~/.themes
THEMES="$HOME/.themes"
GTK3="$HOME/.config/gtk-3.0"
GTK4="$HOME/.config/gtk-4.0"
STATE="$HOME/.config/orchis-snap-theme"
BUILD_DIR="$HOME/snap-themes/gtk-theme-orchis-red"
CONTENT_SNAP="gtk-theme-orchis-red"

IFACE="org.gnome.desktop.interface"
ACCENT_DESIRED="red"

THEME_DIR="$THEMES/$SAFE_NAME"

# ---------------------------------------------------------------- helpers ---
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ xx ]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
short() { printf '%s' "${1/#$HOME/\~}"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

gget()  { gsettings get "$IFACE" "$1" 2>/dev/null; }
gset()  { gsettings set "$IFACE" "$1" "$2" 2>/dev/null || die "cannot write $IFACE $1"; }
unquote() { local v="$1"; v="${v#\'}"; v="${v%\'}"; printf '%s' "$v"; }

# A *strictly confined* snap's AppArmor profile, used to test readability the
# way a sandboxed app sees it. Classic profiles allow everything and would give
# a meaningless "readable" for ~/.themes, so they are never chosen.
snap_profile() {
  local p
  p="$(grep -ls '\.config/gtk-4\.0/settings\.ini' /var/lib/snapd/apparmor/profiles/snap.* 2>/dev/null | head -1)"
  [ -n "$p" ] || p="$(grep -ls '\.config/gtk-3\.0/settings\.ini' /var/lib/snapd/apparmor/profiles/snap.* 2>/dev/null | head -1)"
  [ -n "$p" ] || p="$(ls /var/lib/snapd/apparmor/profiles/snap.*.* 2>/dev/null | head -1)"
  [ -n "$p" ] && basename "$p"
}

have_aa_exec() { command -v aa-exec >/dev/null 2>&1; }

restart_snap_monitor() {
  log "Restarting snapd-desktop-integration"
  if systemctl --user restart snap.snapd-desktop-integration.snapd-desktop-integration.service 2>/dev/null; then
    echo "    service restarted"
  elif pkill -f snapd-desktop-integration 2>/dev/null; then
    echo "    process signalled (auto-restarts)"
  else
    warn "could not restart monitor"
  fi
  sleep 1
}

# Is this snap a Flutter app (drawn by itself) or a real GTK app?
snap_kind() {
  local snap="$1" rev
  rev="$(readlink -f "/snap/$snap/current" 2>/dev/null)"
  [ -d "$rev" ] || { printf 'unknown'; return; }
  if find "$rev" -maxdepth 4 -name 'libflutter_linux_gtk.so' 2>/dev/null | grep -q .; then
    printf 'flutter'
  elif find "$rev" -maxdepth 6 \( -name 'libgtk-3.so*' -o -name 'libgtk-4.so*' \) 2>/dev/null | grep -q .; then
    printf 'gtk'
  else
    printf 'other'
  fi
}

# ------------------------------------------------------------------ status ---
do_status() {
  log "Environment"
  printf '    session:        %s / %s\n' "${XDG_CURRENT_DESKTOP:-?}" "${XDG_SESSION_TYPE:-?}"
  printf '    gtk-theme:      %s\n' "$(gget gtk-theme)"
  printf '    icon-theme:     %s\n' "$(gget icon-theme)"
  printf '    color-scheme:   %s\n' "$(gget color-scheme)"
  printf '    accent-color:   %s\n' "$(gget accent-color)"

  log "Theme directory"
  if [ -d "$THEME_DIR" ]; then
    local n; n="$(find "$THEME_DIR" -maxdepth 1 -type d -name 'gtk-*' 2>/dev/null | wc -l)"
    echo "    $(short "$THEME_DIR")  (${n} gtk-* subdirs)"
    for d in gtk-3.0 gtk-4.0; do
      [ -d "$THEME_DIR/$d" ] && echo "      $d: present" || warn "  $d missing"
    done
  else
    warn "not found: $(short "$THEME_DIR")  (run orchis.sh finalize first)"
  fi

  log "Host GTK config (what snaps may read)"
  local f kind
  for f in "$GTK3/gtk.css" "$GTK4/gtk.css" "$GTK4/gtk-dark.css" "$GTK4/assets"; do
    [ -e "$f" ] || { printf '    %-14s absent\n' "$(short "$f")"; continue; }
    if [ -L "$f" ]; then kind="symlink -> $(readlink "$f")"; else kind="real file/dir"; fi
    printf '    %-14s %s\n' "$(basename "$f")" "$kind"
  done
  if [ -L "$GTK4/gtk.css" ]; then
    warn "gtk.css is a symlink into ~/.themes => snaps get 'Permission denied'"
    echo "         (run: $(basename "$0") apply)"
  fi

  log "Installed snaps"
  local snap
  while read -r snap; do
    [ -n "$snap" ] || continue
    printf '    %-24s %s\n' "$snap" "$(snap_kind "$snap")"
  done < <(snap list 2>/dev/null | awk 'NR>1 && $1!~/^(core|bare|snapd|gtk-common-themes|gnome-4|mesa|gtk-theme|icon-theme)/ {print $1}')

  if snap list "$CONTENT_SNAP" >/dev/null 2>&1; then
    ok "content snap '$CONTENT_SNAP' installed"
  else
    echo "    content snap '$CONTENT_SNAP': not installed (optional, see 'snap' action)"
  fi
}

# ------------------------------------------------------------------- apply ---
# Turn a symlink in ~/.config/gtk-X.0 into a real file, so a confined snap can
# read it. The original symlink (or file) is recorded for `revert`.
snapify_css() {
  local src="$1" dst="$2" key="$3"
  if [ ! -e "$src" ]; then warn "theme file missing, skipping: $(short "$src")"; return 1; fi
  mkdir -p "$(dirname "$dst")" "$STATE/links" "$STATE/backup"

  # Record the *original* shape once, so revert is exact and repeat runs are quiet.
  if [ ! -e "$STATE/links/$key" ] && [ ! -e "$STATE/backup/$key" ]; then
    if [ -L "$dst" ]; then
      readlink "$dst" > "$STATE/links/$key"
      log "recording original symlink: $(short "$dst") -> $(readlink "$dst")"
    elif [ -e "$dst" ]; then
      cp -a "$dst" "$STATE/backup/$key"
      log "recording original file: $(short "$dst")"
    fi
  fi

  # Must unlink first: install(1) would otherwise follow the symlink and write
  # through into ~/.themes.
  rm -f "$dst"
  install -m 0644 "$src" "$dst"
  ok "real copy in place: $(short "$dst")"
}

do_apply() {
  [ -d "$THEME_DIR" ] || die "theme dir not found: $(short "$THEME_DIR") (run orchis.sh finalize)"
  mkdir -p "$STATE"

  # 1. accent -> red (this is what the Flutter snaps actually read)
  local cur; cur="$(unquote "$(gget accent-color)")"
  if [ "$cur" != "$ACCENT_DESIRED" ]; then
    mkdir -p "$STATE"
    [ -e "$STATE/accent-color.orig" ] || printf '%s\n' "$cur" > "$STATE/accent-color.orig"
    log "accent-color: '${cur:-<unset>}' -> '$ACCENT_DESIRED'"
    gset accent-color "$ACCENT_DESIRED"
  else
    ok "accent-color already '$ACCENT_DESIRED'"
  fi

  # 2. snap-readable CSS copies (GTK snap apps; native apps unaffected)
  log "Making the theme CSS readable inside the sandbox"
  local css
  for css in gtk.css gtk-dark.css; do
    snapify_css "$THEME_DIR/gtk-4.0/$css" "$GTK4/$css" "gtk4-$css" || true
  done
  for css in gtk.css gtk-dark.css; do
    # only mirror gtk-3 as a fallback for GTK3 snaps; theming normally comes
    # from the theme name, so this is opt-in via ORCHIS_GTK3=1
    [ "${ORCHIS_GTK3:-0}" = "1" ] || break
    snapify_css "$THEME_DIR/gtk-3.0/$css" "$GTK3/$css" "gtk3-$css" || true
  done

  # 3. assets cannot be bridged: AppArmor there allows *.css only
  warn "theme images (assets/*.png|svg) cannot be bridged this way - snaps allow *.css only"
  echo "         for CSS *and* assets, use the content snap: $(basename "$0") snap"

  restart_snap_monitor
  ok "apply done - restart the snap apps to see the change."
}

# -------------------------------------------------------------- permit check --
# Can a confined snap actually read this path? AppArmor deliberately does not
# mediate access(2)/faccessat(2), so `test -r` lies (it reports "readable" even
# for ~/.themes). The only honest test is to open the path for real.
can_read() {
  local p="$1" prof="$2"
  if [ -d "$p" ]; then
    aa-exec -p "$prof" -- ls "$p" >/dev/null 2>&1
  else
    aa-exec -p "$prof" -- head -c 1 "$p" >/dev/null 2>&1
  fi
}

do_check() {
  local prof; prof="$(snap_profile)"
  if [ -z "$prof" ]; then warn "no snap AppArmor profile found; skipping"; return 0; fi
  if ! have_aa_exec; then warn "aa-exec not installed (apt install apparmor-utils); skipping"; return 0; fi

  log "Opening files as the snap '$prof' would"
  local target label
  for target in \
      "$GTK4/settings.ini:CSS settings" \
      "$GTK4/gtk.css:GTK4 user CSS" \
      "$GTK4/gtk-dark.css:GTK4 dark CSS" \
      "$GTK4/assets:GTK4 theme images" \
      "$THEME_DIR:theme directory" \
      "$THEMES:themes root"
  do
    label="${target##*:}"; target="${target%:*}"
    [ -e "$target" ] || { printf '    %-28s absent\n' "$label"; continue; }
    if can_read "$target" "$prof"; then
      printf '    %-28s \033[1;32mreadable\033[0m\n' "$label"
    else
      printf '    %-28s \033[1;31mDENIED\033[0m\n' "$label"
    fi
  done
  echo
  echo "    readable = a confined snap can open it"
  echo "    DENIED   = sandbox blocks it (expected for ~/.themes and for assets,"
  echo "               because AppArmor only whitelists *.css there)"
  echo "    (checked with real opens - access(2)/test -r is not mediated and lies)"
}

# ------------------------------------------------------------- content snap --
write_snapcraft_yaml() {
  mkdir -p "$BUILD_DIR/snap"
  cat > "$BUILD_DIR/snap/snapcraft.yaml" <<YAML
name: $CONTENT_SNAP
base: bare
build-base: core24
version: '1.0'
summary: $SAFE_NAME GTK theme for strictly-confined snaps
description: |
  Delivers the $SAFE_NAME GTK 3/4 theme (CSS and image assets) to snap
  applications, which cannot read ~/.themes themselves.
confinement: strict
grade: devel

slots:
  gtk-3-themes:
    interface: content
    source:
      read:
        - \$SNAP/share/themes/$SAFE_NAME
  gtk-4-themes:
    interface: content
    source:
      read:
        - \$SNAP/share/themes/$SAFE_NAME

parts:
  theme:
    plugin: dump
    source: ./theme
    organize:
      $SAFE_NAME: share/themes/$SAFE_NAME
YAML
}

do_snap() {
  [ -d "$THEME_DIR" ] || die "theme dir not found: $(short "$THEME_DIR")"
  need_cmd snap

  log "Preparing build tree in $(short "$BUILD_DIR")"
  mkdir -p "$BUILD_DIR/snap" "$BUILD_DIR/theme"
  rm -rf "$BUILD_DIR/theme/$SAFE_NAME"
  mkdir -p "$BUILD_DIR/theme/$SAFE_NAME"
  # only what a theme needs; keeps the snap small
  local item
  for item in index.theme gtk-2.0 gtk-3.0 gtk-4.0; do
    [ -e "$THEME_DIR/$item" ] && cp -a "$THEME_DIR/$item" "$BUILD_DIR/theme/$SAFE_NAME/"
  done
  write_snapcraft_yaml
  ok "snapcraft.yaml written"

  if ! command -v snapcraft >/dev/null 2>&1; then
    warn "snapcraft is not installed"
    cat <<'INSTR'
         install it with:
             sudo snap install snapcraft --classic
         and a build backend (pick one):
             sudo snap install lxd && sudo lxd init --minimal
             # or build directly on this host with:  snapcraft pack --destructive-mode
INSTR
    return 1
  fi

  log "Building (this can take a while)"
  ( cd "$BUILD_DIR" && snapcraft pack ) || {
    warn "build failed - see snapcraft output above"
    echo "         with no LXD/Multipass, retry: (cd $(short "$BUILD_DIR") && snapcraft pack --destructive-mode)"
    return 1
  }

  local pkg; pkg="$(ls -1t "$BUILD_DIR"/*.snap 2>/dev/null | head -1)"
  [ -n "$pkg" ] || { warn "no .snap produced"; return 1; }
  ok "built $(basename "$pkg")"

  log "Installing"
  sudo snap install --dangerous "$pkg" || die "snap install failed"

  log "Connecting to snaps that plug gtk-3-themes"
  local s n=0
  while read -r s; do
    [ -n "$s" ] || continue
    [ "$s" = "$CONTENT_SNAP" ] && continue
    if sudo snap connect "$s:gtk-3-themes" "$CONTENT_SNAP:gtk-3-themes" 2>/dev/null; then
      echo "    connected: $s"
      n=$((n + 1))
    fi
  done < <(snap connections 2>/dev/null \
             | awk '$1=="content[gtk-3-themes]" {sub(/:gtk-3-themes$/,"",$2); print $2}' | sort -u)
  [ "$n" -gt 0 ] || echo "    (nothing to connect yet - no GTK snap app installed)"
  restart_snap_monitor
  ok "content snap ready - any GTK snap app will now find '$SAFE_NAME'"
}

# ------------------------------------------------------------------ revert ---
do_revert() {
  [ -d "$STATE" ] || { warn "nothing to revert (no $STATE)"; return 0; }

  if [ -e "$STATE/accent-color.orig" ]; then
    local o; o="$(cat "$STATE/accent-color.orig")"
    if [ -n "$o" ]; then
      log "accent-color: '$(unquote "$(gget accent-color)")' -> '$o'"
      gset accent-color "$o"
    fi
    rm -f "$STATE/accent-color.orig"
  fi

  local key dst
  for key in gtk4-gtk.css gtk4-gtk-dark.css gtk3-gtk.css gtk3-gtk-dark.css; do
    case "$key" in gtk4-*) dst="$GTK4/${key#gtk4-}" ;; *) dst="$GTK3/${key#gtk3-}" ;; esac
    if [ -e "$STATE/links/$key" ]; then
      local tgt; tgt="$(cat "$STATE/links/$key")"
      ln -sfn "$tgt" "$dst"
      log "restored symlink $(short "$dst") -> $tgt"
      rm -f "$STATE/links/$key"
    elif [ -e "$STATE/backup/$key" ]; then
      cp -a "$STATE/backup/$key" "$dst"
      log "restored backup $(short "$dst")"
      rm -f "$STATE/backup/$key"
    fi
  done

  rmdir "$STATE/links" "$STATE/backup" "$STATE" 2>/dev/null || true
  restart_snap_monitor
  ok "revert done"
}

# ------------------------------------------------------------------- menu ----
do_help() {
  cat <<EOF
$(basename "$0") - make the Orchis Red Dark theme reach snap applications

Usage: $(basename "$0") [action]

  status     report settings, the theme dir, the GTK config bridge and snaps
  apply      accent-color=red + snap-readable copies of the theme CSS
  check      prove (via aa-exec) what a confined snap can and cannot read
  snap       build + install the '$CONTENT_SNAP' content snap
  revert     undo what 'apply' changed
  menu       interactive menu (default when run with no arguments)
  help       this text

Environment:
  SAFE_NAME=OrchisRedDark   theme directory name under ~/.themes
  ORCHIS_GTK3=1             also mirror the gtk-3.0 CSS (off by default)

Notes:
  * Flutter snaps (App Center, Firmware Updater, Security Center, prompts)
    only ever follow accent-color and color-scheme - not themes or CSS.
  * GTK snaps need 'apply' (CSS) and, for the image assets, 'snap'.
EOF
}

do_menu() {
  while :; do
    printf '\n\033[1mOrchis Snap Theme\033[0m - %s\n' "$(date '+%H:%M')"
    printf '  1) status\n'
    printf '  2) apply     (accent=red + snap-readable CSS)\n'
    printf '  3) check     (what snaps can read)\n'
    printf '  4) snap      (build/install content snap)\n'
    printf '  5) revert\n'
    printf '  q) quit\n'
    printf 'choose: '
    local c; read -r c || return 0
    case "$c" in
      1) do_status ;;
      2) do_apply ;;
      3) do_check ;;
      4) do_snap ;;
      5) do_revert ;;
      q|Q|"") return 0 ;;
      *) warn "unknown choice" ;;
    esac
    printf '\npress enter...'; read -r _ || true
  done
}

# -------------------------------------------------------------------- main ---
[ "$(id -u)" -ne 0 ] || die "run as your user, not root (it edits ~/.config)"

case "${1:-menu}" in
  status)  do_status ;;
  apply)   do_apply ;;
  check)   do_check ;;
  snap)    do_snap ;;
  revert)  do_revert ;;
  menu)    do_menu ;;
  help|-h|--help) do_help ;;
  *) err "unknown action: $1"; echo; do_help; exit 2 ;;
esac

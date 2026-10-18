#!/usr/bin/env bash
#
# orchis-qs-blur.sh - make Blur my Shell's blur actually visible on GNOME Shell
#                     popups (Quick Settings, its submenus, menus, calendar)
#                     when the Orchis-Red-Dark shell theme is active.
#
# ---------------------------------------------------------------------------
# WHY THE POPUP IS BLACK
# ---------------------------------------------------------------------------
# The Orchis shell theme paints every popup surface with a near-opaque fill:
#
#     .popup-menu .popup-menu-content { background-color: rgba(0, 0, 0, 0.97); }
#
# Blur my Shell (extension: blur-my-shell@aunetx) does not paint a background
# itself - it adds a *blur layer behind* each popup and, when
# "override background" is on, only overrides the colour of that surface.
# With a 97%-opaque black fill on top, the blur layer is invisible, so the
# Quick Settings panel looks flat black (and GNOME dims it another 40% while a
# submenu is open, making it look even darker).
#
# This script appends a small, clearly marked block to the theme's
# gnome-shell.css that turns those surfaces translucent again, so the blurred
# backdrop shows through.  It is idempotent and fully reversible.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   ./orchis-qs-blur.sh apply                 # recommended (dynamic blur)
#   ./orchis-qs-blur.sh apply --static        # BMS static-blur pipeline
#   ./orchis-qs-blur.sh apply --alpha 0.45    # darker/lighter fallback tint
#   ./orchis-qs-blur.sh apply --artifacts none
#   ./orchis-qs-blur.sh apply --theme-only    # only patch the theme, no dconf
#   ./orchis-qs-blur.sh revert                # remove patch + restore settings
#   ./orchis-qs-blur.sh status                # show current state
#   ./orchis-qs-blur.sh debug on|off          # BMS debug logging
#
# Notes
#   * apply/revert reload the shell theme (user-theme extension toggle) and
#     Blur my Shell, so the change is visible immediately - no logout needed.
#   * Every file is backed up before it is touched:
#         <theme>/gnome-shell/gnome-shell.css.pre-qs-blur-patch
#         ~/.config/orchis-qs-blur/bms-popup.before
#   * If the panel is translucent but not blurry, run `apply --static`; if you
#     still see black rectangles/artefacts, run `apply --artifacts none`.
#
set -uo pipefail

# ----------------------------------------------------------------- config ---
SAFE_NAME="OrchisRedDark"          # actual dir name in ~/.themes
CANON_NAME="Orchis-Red-Dark"       # canonical upstream spelling
THEMES="${HOME}/.themes"

USER_THEME_EXT="user-theme@gnome-shell-extensions.gcampax.github.com"
USER_THEME_KEY="/org/gnome/shell/extensions/user-theme/name"

BMS_UUID="blur-my-shell@aunetx"
BMS_DIR="${HOME}/.local/share/gnome-shell/extensions/${BMS_UUID}"
BMS_KEY="/org/gnome/shell/extensions/blur-my-shell"
BMS_POPUP="${BMS_KEY}/popup"

PATCH_BEGIN="/* >>> orchis-qs-blur-patch >>> */"
PATCH_END="/* <<< orchis-qs-blur-patch <<< */"
BACKUP_SUFFIX=".pre-qs-blur-patch"

STATE_DIR="${HOME}/.config/orchis-qs-blur"
BMS_BACKUP="${STATE_DIR}/bms-popup.before"

ALPHA="0.35"        # fallback tint alpha of the translucent popup surfaces
MODE="dynamic"      # dynamic | static   (Blur my Shell popup blur pipeline)
ARTIFACTS=""        # "" = leave as is | none | default
THEME_ONLY=0

# ---------------------------------------------------------------- helpers ---
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ xx ]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

dget() { dconf read "$1" 2>/dev/null; }

# write a value, or reset the key when the saved value was empty
dset() { dconf write "$1" "$2" 2>/dev/null || die "cannot write $1"; }
dreset() { dconf reset "$1" 2>/dev/null || true; }

shell_theme_name() {
  local v; v="$(dget "$USER_THEME_KEY")"
  v="${v#\'}"; v="${v%\'}"
  printf '%s' "$v"
}

theme_label() {
  local n; n="$(shell_theme_name)"
  printf '%s' "${n:-<none>}"
}

# the theme directory the running shell actually loads (if any)
active_theme_dir() {
  local name; name="$(shell_theme_name)"
  [ -n "$name" ] || return 0
  [ -f "${THEMES}/${name}/gnome-shell/gnome-shell.css" ] || return 0
  printf '%s' "${THEMES}/${name}"
}

# all theme dirs that carry a gnome-shell stylesheet, active one first
theme_dirs() {
  local d seen=" "
  for d in "$(active_theme_dir)" "${THEMES}/${SAFE_NAME}" "${THEMES}/${CANON_NAME}"; do
    [ -n "$d" ] || continue
    [ -f "${d}/gnome-shell/gnome-shell.css" ] || continue
    case "$seen" in *" ${d} "*) continue ;; esac
    seen="${seen}${d} "
    printf '%s\n' "$d"
  done
}

bms_installed() { [ -d "$BMS_DIR" ]; }

bms_enabled() {
  command -v gnome-extensions >/dev/null 2>&1 || return 1
  gnome-extensions info "$BMS_UUID" 2>/dev/null | grep -qiE 'State: (ACTIVE|ENABLED)'
}

# remove the marked block, restoring the file byte-for-byte
remove_patch_from() {
  local f="$1" tmp
  grep -qF "$PATCH_BEGIN" "$f" 2>/dev/null || return 1
  tmp="$(mktemp)"
  awk -v b="$PATCH_BEGIN" -v e="$PATCH_END" '
    index($0, b) { skip = 1; next }
    skip && index($0, e) { skip = 0; next }
    skip { next }
    $0 ~ /^[[:space:]]*$/ { blanks[++k] = $0; next }
    { for (i = 1; i <= k; i++) print blanks[i]; k = 0; print }
  ' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
  return 0
}

append_patch_to() {
  local f="$1"
  cat >> "$f" <<EOF

$PATCH_BEGIN
/* This theme fills every popup surface with a near-opaque colour
   (".popup-menu .popup-menu-content { background-color: rgba(0,0,0,0.97) }"),
   which hides the blur layer Blur my Shell draws BEHIND each popup - the
   Quick Settings panel therefore looks flat black.  Turning those surfaces
   translucent lets the blurred backdrop show through; Blur my Shell still
   contributes its own tint + shadow while "override background" is enabled
   and the rgba() below is the fallback tint.
   Appended at EOF so it wins on equal specificity.  Remove with "revert". */
.popup-menu .popup-menu-content,
.quick-settings,
.datemenu-popover,
.candidate-popup-content {
    background-color: rgba(20, 20, 24, ${ALPHA}) !important;
}
$PATCH_END
EOF
}

reload_theme() {
  if ! command -v gnome-extensions >/dev/null 2>&1; then
    warn "gnome-extensions not found - log out/in to reload the shell theme"
    return 0
  fi
  gnome-extensions disable "$USER_THEME_EXT" >/dev/null 2>&1 || true
  sleep 1
  gnome-extensions enable  "$USER_THEME_EXT" >/dev/null 2>&1 || true
  sleep 1
}

reload_bms() {
  command -v gnome-extensions >/dev/null 2>&1 || return 0
  gnome-extensions disable "$BMS_UUID" >/dev/null 2>&1 || true
  sleep 1
  gnome-extensions enable  "$BMS_UUID" >/dev/null 2>&1 || true
  sleep 1
}

# ------------------------------------------------------------ BMS settings ---
save_bms_backup() {
  [ -f "$BMS_BACKUP" ] && return 0
  mkdir -p "$STATE_DIR"
  {
    local k
    for k in blur static-blur override-background preserve-shell-theme \
             style-popup sigma brightness pipeline; do
      printf '%s=%s\n' "$k" "$(dget "${BMS_POPUP}/${k}")"
    done
    printf 'hacks-level=%s\n' "$(dget "${BMS_KEY}/hacks-level")"
  } > "$BMS_BACKUP"
  ok "saved current Blur my Shell popup settings -> ${BMS_BACKUP/$HOME/~}"
}

configure_bms() {
  bms_installed || { warn "Blur my Shell not found at ${BMS_DIR/$HOME/~} - skipping"; return 0; }
  log "Configuring Blur my Shell popup component"
  save_bms_backup

  dset "${BMS_POPUP}/blur" true
  dset "${BMS_POPUP}/override-background" true
  dset "${BMS_POPUP}/preserve-shell-theme" false
  dset "${BMS_POPUP}/style-popup" 3
  dset "${BMS_POPUP}/pipeline" "'pipeline_default_rounded'"
  dset "${BMS_POPUP}/sigma" 30
  dset "${BMS_POPUP}/brightness" 0.6

  if [ "$MODE" = "static" ]; then
    dset "${BMS_POPUP}/static-blur" true
    ok "popup blur: enabled, static pipeline, override-background on"
  else
    dset "${BMS_POPUP}/static-blur" false
    ok "popup blur: enabled, dynamic pipeline, override-background on"
  fi

  case "$ARTIFACTS" in
    none)    dset "${BMS_KEY}/hacks-level" 2; ok "artefact handling: none (clipped redraws off)" ;;
    default) dset "${BMS_KEY}/hacks-level" 1; ok "artefact handling: default" ;;
  esac
}

restore_bms_backup() {
  [ -f "$BMS_BACKUP" ] || { warn "no saved Blur my Shell settings to restore"; return 0; }
  log "Restoring Blur my Shell popup settings"
  local line k v target
  while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    case "$k" in
      hacks-level) target="${BMS_KEY}/hacks-level" ;;
      *)           target="${BMS_POPUP}/${k}" ;;
    esac
    if [ -n "$v" ]; then dset "$target" "$v"; else dreset "$target"; fi
  done < "$BMS_BACKUP"
  ok "restored (backup kept at ${BMS_BACKUP/$HOME/~})"
}

# ------------------------------------------------------------------ theme ---
patch_themes() {
  log "Making popup surfaces translucent (tint alpha ${ALPHA})"
  local dir f n=0
  while IFS= read -r dir; do
    f="${dir}/gnome-shell/gnome-shell.css"
    [ -f "$f" ] || continue
    [ -f "${f}${BACKUP_SUFFIX}" ] || cp -a "$f" "${f}${BACKUP_SUFFIX}"
    remove_patch_from "$f" >/dev/null 2>&1 || true   # refresh alpha on re-apply
    append_patch_to "$f"
    ok "patched ${dir##*/}  (backup: gnome-shell.css${BACKUP_SUFFIX})"
    n=$((n + 1))
  done < <(theme_dirs)

  if [ "$n" -eq 0 ]; then
    warn "no theme directory with gnome-shell/gnome-shell.css was found"
    warn "checked: ${THEMES}/${SAFE_NAME}, ${THEMES}/${CANON_NAME} (+ active theme)"
    return 1
  fi
}

unpatch_themes() {
  log "Removing popup-transparency patch"
  local dir f n=0
  while IFS= read -r dir; do
    f="${dir}/gnome-shell/gnome-shell.css"
    if remove_patch_from "$f"; then
      ok "unpatched ${dir##*/}"
      n=$((n + 1))
    fi
  done < <(theme_dirs)
  [ "$n" -eq 0 ] && warn "nothing was patched"
  return 0
}

# ---------------------------------------------------------------- actions ---
do_apply() {
  log "Applying Quick Settings blur (theme: $(theme_label))"

  [ "$THEME_ONLY" -eq 0 ] && configure_bms

  if [ "$(id -u)" -eq 0 ]; then
    warn "running as root - dconf/user-theme changes will not reach your session"
  fi

  patch_themes || return 1

  log "Reloading"
  reload_theme
  [ "$THEME_ONLY" -eq 0 ] && reload_bms

  echo
  ok "Done - open the Quick Settings panel now (Super+S or click the clock area)."
  echo "    The panel should show a blurred, slightly translucent backdrop,"
  echo "    and so should the Wi-Fi/Bluetooth submenu."
  echo
  echo "    Still flat black?          -> ./$(basename "$0") debug on, then read the journal"
  echo "    Translucent but not blurry -> ./$(basename "$0") apply --static"
  echo "    Black rectangles/artefacts -> ./$(basename "$0") apply --artifacts none"
  echo "    Undo everything            -> ./$(basename "$0") revert"
}

do_revert() {
  log "Reverting"
  unpatch_themes
  [ "$THEME_ONLY" -eq 0 ] && restore_bms_backup
  log "Reloading"
  reload_theme
  [ "$THEME_ONLY" -eq 0 ] && reload_bms
  ok "reverted - the theme's original opaque popup background is back"
}

do_status() {
  log "Status"
  printf '    shell theme       : %s\n' "$(theme_label)"
  printf '    active theme dir  : %s\n' "$(active_theme_dir | sed "s|^$HOME|~|")"

  echo "    --- popup-transparency patch ---"
  local dir f found=0
  while IFS= read -r dir; do
    f="${dir}/gnome-shell/gnome-shell.css"
    if grep -qF "$PATCH_BEGIN" "$f"; then
      printf '    %-18s patched  (tint alpha %s)\n' "${dir##*/}" \
        "$(sed -n "s/.*rgba(20, 20, 24, \([0-9.]*\)).*/\1/p" "$f" | tail -1)"
      found=1
    else
      printf '    %-18s not patched\n' "${dir##*/}"
    fi
  done < <(theme_dirs)
  [ "$found" -eq 0 ] && printf '    (no patch applied)\n'

  echo "    --- Blur my Shell ---"
  if bms_installed; then
    printf '    extension         : %s\n' "$(bms_enabled && echo ENABLED || echo 'disabled/unknown')"
    local k
    for k in blur override-background preserve-shell-theme static-blur style-popup \
             sigma brightness pipeline; do
      printf '    popup.%-20s %s\n' "$k" "$(dget "${BMS_POPUP}/${k}")"
    done
    printf '    %-20s %s\n' "hacks-level" "$(dget "${BMS_KEY}/hacks-level")"
    printf '    %-20s %s\n' "debug" "$(dget "${BMS_KEY}/debug")"
    printf '    %-20s %s\n' "rounded-blur-found" "$(dget "${BMS_KEY}/rounded-blur-found")"
    [ -f "$BMS_BACKUP" ] && printf '    saved backup      : %s\n' "${BMS_BACKUP/$HOME/~}"
  else
    warn "Blur my Shell not installed at ${BMS_DIR/$HOME/~}"
  fi
  return 0
}

do_debug() {
  local mode="${1:-}"
  case "$mode" in
    on|off) ;;
    *) die "usage: $(basename "$0") debug on|off" ;;
  esac
  if [ "$mode" = on ]; then
    dset "${BMS_KEY}/debug" true
    ok "Blur my Shell debug logging ON (reloading extension)"
  else
    dset "${BMS_KEY}/debug" false
    ok "Blur my Shell debug logging OFF (reloading extension)"
  fi
  reload_bms
  echo
  echo "    Now open Quick Settings (and the Wi-Fi submenu), then run:"
  echo "        journalctl --user -b -o cat | grep -i 'Blur my Shell'"
}

# ------------------------------------------------------------------- main ---
ACTION=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    apply|revert|status|debug) ACTION="$1" ;;
    --static)  MODE="static" ;;
    --dynamic) MODE="dynamic" ;;
    --artifacts)
      shift; ARTIFACTS="${1:-}"; [ -n "$ARTIFACTS" ] || die "--artifacts needs a value (none|default)" ;;
    --alpha)
      shift; ALPHA="${1:-}"; [ -n "$ALPHA" ] || die "--alpha needs a value (e.g. 0.35)"
      case "$ALPHA" in ''|*[!0-9.]*) die "--alpha must be a number like 0.35" ;; esac ;;
    --theme-only) THEME_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

need_cmd dconf

case "$ACTION" in
  apply)  do_apply ;;
  revert) do_revert ;;
  status) do_status ;;
  debug)  do_debug "${ARGS[0]:-}" ;;
  "")     usage; echo; do_status ;;
  *)      die "unknown action: $ACTION (try --help)" ;;
esac

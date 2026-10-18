#!/usr/bin/env bash
#
# gnome-50-fluid-animations.sh — make GNOME 50 (Wayland) feel fluid & smooth
#
# What it does
#   1. Native knobs: turns animations ON (GNOME 50's "Reduced Motion" is the
#      inverse of org.gnome.desktop.interface enable-animations), and points you
#      at Adaptive Sync (VRR) — the single biggest "no-jank" win on GNOME 50.
#   2. Installs GNOME 50-compatible animation extensions straight from
#      extensions.gnome.org (verified version tags below), compiles their
#      schemas locally, and enables them.
#   3. Applies exact recommended settings with gsettings.
#
# Extensions (every one lists GNOME 50 in its shell-version table)
#   just-perfection-desktop@just-perfection              v37  animation speed / UI
#   compiz-alike-magic-lamp-effect@hermes83.github.com   v25  minimize genie
#   compiz-windows-effect@hermes83.github.com            v33  wobbly drag
#   burn-my-windows@schneegans.github.com                v49  close/open effect
#   blur-my-shell@aunetx                                 v75  (WITH_COSMETIC=true)
#   rounded-window-corners@fxgn                          v25  (WITH_COSMETIC=true)
#
# Deliberately NOT used: "Animation Tweaks" (last supports GNOME 41).
#
# Burn My Windows stores its settings in a keyfile backend
# (~/.config/burn-my-windows/profiles/), not dconf, so its effect/duration are
# printed as manual steps with exact values.
#
# Usage
#   ./gnome-50-fluid-animations.sh                    # snappy (recommended default)
#   PROFILE=cinematic ./gnome-50-fluid-animations.sh  # slower, more "animated"
#   PROFILE=default   ./gnome-50-fluid-animations.sh  # GNOME speeds, extras only
#   WITH_COSMETIC=true ./gnome-50-fluid-animations.sh # + blur + rounded corners
#   ./gnome-50-fluid-animations.sh --dry-run          # show commands, change nothing
#   ./gnome-50-fluid-animations.sh --uninstall        # disable + remove extensions
#
# Env overrides
#   PROFILE=snappy|default|cinematic   (default: snappy)
#   WITH_COSMETIC=true|false           (default: false)
#   FORCE=true                         (default: false; re-download/reinstall)
#
set -euo pipefail

# --------------------------------------------------------------------------
# Tunables
# --------------------------------------------------------------------------
PROFILE="${PROFILE:-snappy}"
WITH_COSMETIC="${WITH_COSMETIC:-false}"
FORCE="${FORCE:-false}"

ACTION="install"
DRY_RUN=0
OPEN_DISPLAY=0
for arg in "$@"; do
  case "$arg" in
    --uninstall)   ACTION="uninstall" ;;
    --dry-run|-n)  DRY_RUN=1 ;;
    --open-display) OPEN_DISPLAY=1 ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

EXT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions"
ENV_FILE="$HOME/.config/environment.d/90-gnome-fluid-animations.conf"
WORK=""

# --------------------------------------------------------------------------
# Helpers
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

cleanup() { [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK" || true; }
trap cleanup EXIT

# gset <schema-dir> <schema-id> <key> <value>
# Values are validated by gsettings; failures warn instead of aborting.
gset() {
  local dir="$1" schema="$2" key="$3" value="$4"
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] GSETTINGS_SCHEMA_DIR=$dir gsettings set $schema $key $value"
    return 0
  fi
  if GSETTINGS_SCHEMA_DIR="$dir" gsettings set "$schema" "$key" "$value"; then
    ok "set ${schema##*.} ${key}=${value}"
  else
    warn "could not set ${schema} ${key} (schema missing? logged out?)"
  fi
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
preflight() {
  have gsettings    || die "gsettings not found (install glib2)"
  have curl         || die "curl not found"
  have unzip        || die "unzip not found"
  have glib-compile-schemas || warn "glib-compile-schemas missing; extension settings may not apply until re-login"

  local shell_ver=""
  if have gnome-shell; then
    shell_ver="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
  fi
  if [ -n "$shell_ver" ]; then
    if [ "$shell_ver" = "50" ]; then
      ok "GNOME Shell ${shell_ver} detected"
    else
      warn "detected GNOME Shell ${shell_ver}, not 50 — extensions below target 50/51; continue at your own risk"
    fi
  else
    warn "could not detect GNOME Shell version"
  fi

  if [ "${XDG_SESSION_TYPE:-}" = "x11" ]; then
    warn "X11 session detected; GNOME 50 is Wayland-only, some effects behave differently"
  fi
}

# --------------------------------------------------------------------------
# Native settings
# --------------------------------------------------------------------------
apply_native() {
  log "Applying native settings"
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] gsettings set org.gnome.desktop.interface enable-animations true"
  else
    gsettings set org.gnome.desktop.interface enable-animations true \
      && ok "animations enabled (Settings > Accessibility > Seeing > Reduced Motion = OFF)"
  fi

  if [ "$OPEN_DISPLAY" = 1 ] && have gnome-control-center; then
    log "Opening Displays panel — set 'Adaptive Sync' to 'Always' for VRR"
    [ "$DRY_RUN" = 1 ] || gnome-control-center display &
  else
    warn "Enable VRR manually: Settings > Displays > Adaptive Sync > Always (biggest smoothness win)"
  fi
}

# --------------------------------------------------------------------------
# Install / uninstall
# --------------------------------------------------------------------------
EXTS=(
  "just-perfection-desktop@just-perfection|74466|v37"
  "compiz-alike-magic-lamp-effect@hermes83.github.com|76122|v25"
  "compiz-windows-effect@hermes83.github.com|76121|v33"
  "burn-my-windows@schneegans.github.com|75536|v49"
)
COSMETIC_EXTS=(
  "blur-my-shell@aunetx|76297|v75"
  "rounded-window-corners@fxgn|73032|v25"
)

install_one() {
  local uuid="$1" tag="$2" label="$3" dest="$EXT_DIR/$1"
  if [ -d "$dest" ] && [ "$FORCE" != "true" ]; then
    ok "already installed: $uuid ($label)"
  else
    if [ "$DRY_RUN" = 1 ]; then
      log "[dry-run] curl -L 'https://extensions.gnome.org/download-extension/${uuid}.shell-extension.zip?version_tag=${tag}'"
    else
      WORK="$(mktemp -d)"
      log "downloading $uuid ($label)"
      curl -fsSL -o "$WORK/ext.zip" \
        "https://extensions.gnome.org/download-extension/${uuid}.shell-extension.zip?version_tag=${tag}"
      mkdir -p "$dest"
      unzip -oq "$WORK/ext.zip" -d "$dest"
      rm -rf "$WORK"; WORK=""
      ok "installed $uuid ($label)"
    fi
  fi
  # Compile the extension's schemas so `gsettings` can reach them.
  if [ "$DRY_RUN" != 1 ] && [ -d "$dest/schemas" ] && have glib-compile-schemas; then
    glib-compile-schemas "$dest/schemas" || warn "schema compile failed for $uuid"
  fi
}

enable_one() {
  local uuid="$1"
  if [ "$DRY_RUN" = 1 ]; then log "[dry-run] gnome-extensions enable $uuid"; return; fi
  if have gnome-extensions && gnome-extensions enable "$uuid" 2>/dev/null; then
    ok "enabled $uuid"
  else
    warn "could not enable $uuid yet — log out/in once, then: gnome-extensions enable $uuid"
  fi
}

do_install() {
  local list=("${EXTS[@]}")
  [ "$WITH_COSMETIC" = "true" ] && list+=("${COSMETIC_EXTS[@]}")

  log "Installing extensions into $EXT_DIR"
  local item uuid tag label
  for item in "${list[@]}"; do
    IFS='|' read -r uuid tag label <<<"$item"
    install_one "$uuid" "$tag" "$label"
    enable_one "$uuid"
  done

  apply_settings
  summary
}

do_uninstall() {
  log "Removing GNOME fluid-animation extensions"
  local item uuid tag label
  for item in "${EXTS[@]}" "${COSMETIC_EXTS[@]}"; do
    IFS='|' read -r uuid tag label <<<"$item"
    if [ "$DRY_RUN" = 1 ]; then log "[dry-run] disable + rm $uuid"; continue; fi
    have gnome-extensions && gnome-extensions disable "$uuid" 2>/dev/null || true
    rm -rf "${EXT_DIR:?}/$uuid"
    ok "removed $uuid"
  done
  rm -f "$ENV_FILE"
  warn "Extension dconf keys are left in place. To wipe them after removing:"
  warn "  gsettings reset-recursively org.gnome.shell.extensions.just-perfection"
  ok "uninstall complete (log out/in to fully unload)"
}

# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------
# Profiles. Just Perfection's 'animation' int maps to St slow_down_factor:
#   0=off 1=default | 2->0.01 3->0.2 4->0.6 5->0.8 6->1.3 7->1.6 8->2.8
case "$PROFILE" in
  snappy)    JP_ANIM=5; ML_DUR=250 ;;   # 0.8x  — responsive, still smooth
  default)   JP_ANIM=1; ML_DUR=400 ;;   # GNOME defaults
  cinematic) JP_ANIM=6; ML_DUR=450 ;;   # 1.3x  — slower, more "animated"
  *) die "unknown PROFILE '$PROFILE' (use snappy|default|cinematic)" ;;
esac

apply_settings() {
  log "Applying extension settings (profile: $PROFILE)"
  local jp_dir="$EXT_DIR/just-perfection-desktop@just-perfection/schemas"
  local ml_dir="$EXT_DIR/compiz-alike-magic-lamp-effect@hermes83.github.com/schemas"
  local cw_dir="$EXT_DIR/compiz-windows-effect@hermes83.github.com/schemas"
  local bms_dir="$EXT_DIR/blur-my-shell@aunetx/schemas"

  # --- Just Perfection: shell animation speed -----------------------------
  gset "$jp_dir" org.gnome.shell.extensions.just-perfection animation "$JP_ANIM"

  # --- Compiz alike magic lamp: fluid minimize/unminimize -----------------
  gset "$ml_dir" org.gnome.shell.extensions.com.github.hermes83.compiz-alike-magic-lamp-effect effect '"default"'   # or '"sine"'
  gset "$ml_dir" org.gnome.shell.extensions.com.github.hermes83.compiz-alike-magic-lamp-effect duration "$ML_DUR"

  # --- Compiz windows effect: subtle wobbly drag --------------------------
  # Defaults already smooth (friction 3.5, spring-k 3.8, mass 70, tiles 6).
  # Lower friction = more wobble; raise spring-k = springier.
  gset "$cw_dir" org.gnome.shell.extensions.com.github.hermes83.compiz-windows-effect friction 3.5
  gset "$cw_dir" org.gnome.shell.extensions.com.github.hermes83.compiz-windows-effect spring-k 3.8
  gset "$cw_dir" org.gnome.shell.extensions.com.github.hermes83.compiz-windows-effect maximize-effect true

  # --- Blur My Shell (cosmetic only): keep it cheap -----------------------
  # Applied when installed — either via WITH_COSMETIC or pre-existing.
  if [ "$WITH_COSMETIC" = "true" ] || [ -d "$EXT_DIR/blur-my-shell@aunetx" ]; then
    gset "$bms_dir" org.gnome.shell.extensions.blur-my-shell sigma 30
    gset "$bms_dir" org.gnome.shell.extensions.blur-my-shell.panel blur true
    gset "$bms_dir" org.gnome.shell.extensions.blur-my-shell.panel static-blur true
    gset "$bms_dir" org.gnome.shell.extensions.blur-my-shell.applications blur false   # main perf cost — off
  fi
}

summary() {
  echo
  printf '%s%s%s\n' "$c_bold" "Done. Summary" "$c_reset"
  echo "  profile        : $PROFILE (Just Perfection animation=$JP_ANIM, magic-lamp=${ML_DUR}ms)"
  if [ -d "$EXT_DIR/blur-my-shell@aunetx" ]; then
    echo "  cosmetic blur  : tuned (Blur My Shell installed; applications blur kept off for perf)"
  else
    echo "  cosmetic blur  : not installed (WITH_COSMETIC=$WITH_COSMETIC)"
  fi
  echo
  printf '%sManual steps%s\n' "$c_bold" "$c_reset"
  echo "  1. VRR: Settings > Displays > Adaptive Sync > Always  (do this once per monitor)"
  echo "  2. Burn My Windows (stores settings in a keyfile, not dconf):"
  echo "       gnome-extensions prefs burn-my-windows@schneegans.github.com"
  echo "       Closing animation = Glide, Animation Time = 300 (300-400ms reads as fluid)"
  echo "  3. On Wayland a brand-new extension only loads after a re-login."
  echo "       Log out and back in, then verify:"
  echo "         gnome-extensions list --enabled"
  echo
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
preflight
case "$ACTION" in
  install)   apply_native; do_install ;;
  uninstall) do_uninstall ;;
esac

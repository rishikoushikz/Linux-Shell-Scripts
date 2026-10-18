#!/usr/bin/env bash
# grub-theme-minimal.sh — a clean, neutral-dark minimal GRUB theme
# Target: Ubuntu 26.04, GRUB 2.14 (EFI). Idempotent.
#
# Usage:
#   ./grub-theme-minimal.sh              # install + apply (asks for sudo)
#   ./grub-theme-minimal.sh --uninstall  # restore prior config, remove theme
#
set -euo pipefail

THEME_NAME="minimal"
THEME_DIR="/boot/grub/themes/${THEME_NAME}"
GRUB_THEME_FILE="${THEME_DIR}/theme.txt"
DEFAULTS="/etc/default/grub"
TS="$(date +%Y%m%d-%H%M%S)"

# ---- display / geometry -----------------------------------------------------
BG_W=3440
BG_H=1440
FONT_PX=28
FONT_SRC="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
GFXMODE="3440x1440,1920x1080,auto"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- root -------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi

# ---- uninstall --------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
  log "Removing theme and restoring previous configuration"
  if [ -e "${DEFAULTS}.bak" ]; then
    cp -f "${DEFAULTS}.bak" "$DEFAULTS"
    log "restored ${DEFAULTS}.bak"
  else
    sed -i -E '/^GRUB_THEME=/d' "$DEFAULTS"
    warn "no ${DEFAULTS}.bak; removed GRUB_THEME line only"
  fi
  rm -rf "$THEME_DIR"
  command -v update-grub >/dev/null && update-grub
  log "Done. Reboot to confirm."
  exit 0
fi

# ---- dependencies -----------------------------------------------------------
for c in grub-mkfont grub-mkconfig; do
  command -v "$c" >/dev/null || die "missing required command: $c"
done
if   command -v magick  >/dev/null; then IM=magick
elif command -v convert >/dev/null; then IM=convert
else die "ImageMagick (magick/convert) is required"; fi
[ -f "$FONT_SRC" ] || die "font not found: $FONT_SRC"

# ---- backup -----------------------------------------------------------------
log "Backing up existing configuration"
[ -f "${DEFAULTS}.bak" ] || cp -a "$DEFAULTS" "${DEFAULTS}.bak"
[ -f /boot/grub/grub.cfg ] && cp -a /boot/grub/grub.cfg "/boot/grub/grub.cfg.bak.${TS}"
echo "    ${DEFAULTS}.bak"

# ---- theme directory --------------------------------------------------------
log "Creating ${THEME_DIR}"
mkdir -p "$THEME_DIR"

# ---- background -------------------------------------------------------------
log "Generating background ${BG_W}x${BG_H}"
"$IM" -size ${BG_W}x${BG_H} "gradient:#111116-#0b0b0e" \
  -alpha off "PNG24:${THEME_DIR}/background.png"

# ---- selected-item 9-slice --------------------------------------------------
log "Generating 9-slice selection pixmaps"
r=12
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
"$IM" -size $((2*r))x$((2*r)) xc:none \
  -fill '#1c1c22' -stroke '#2a2a30' -strokewidth 2 \
  -draw "roundrectangle 1,1 $((2*r-2)),$((2*r-2)) $r,$r" "$tmp/master.png"
slice() { "$IM" "$tmp/master.png" -crop "$1" +repage "PNG32:${THEME_DIR}/$2"; }
slice "${r}x${r}+0+0"                     select_nw.png
slice "${r}x${r}+${r}+0"                  select_ne.png
slice "${r}x${r}+0+${r}"                  select_sw.png
slice "${r}x${r}+${r}+${r}"               select_se.png
slice "1x${r}+${r}+0"                     select_n.png
slice "1x${r}+${r}+${r}"                  select_s.png
slice "${r}x1+0+${r}"                     select_w.png
slice "${r}x1+$((2*r-1))+${r}"            select_e.png
slice "1x1+${r}+${r}"                     select_c.png

# ---- font -------------------------------------------------------------------
log "Building GRUB font (${FONT_PX}px)"
grub-mkfont -s "$FONT_PX" -n Minimal -o "$THEME_DIR/minimal.pf2" "$FONT_SRC"
FONT_NAME="$(strings "$THEME_DIR/minimal.pf2" | grep -a '^Minimal' | head -1)"

# ---- theme.txt --------------------------------------------------------------
log "Writing theme.txt"
cat > "$GRUB_THEME_FILE" <<EOF
# Minimal GRUB theme — neutral dark
desktop-image: "background.png"
title-text: ""
terminal-font: "Unifont"

+ boot_menu {
    left  = 25%
    top   = 38%
    width = 50%
    height = 24%

    item_font            = "${FONT_NAME}"
    item_color           = "#8a8a92"
    selected_item_color  = "#ffffff"
    item_height          = 48
    item_spacing         = 6
    item_padding         = 12
    scrollbar            = false

    selected_item_pixmap_style = "select_*.png"
}
EOF

# ---- /etc/default/grub ------------------------------------------------------
log "Updating ${DEFAULTS}"
set_opt() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$DEFAULTS"; then
    sed -i -E "s|^${key}=.*|${key}=${val}|" "$DEFAULTS"
  else
    printf '%s=%s\n' "$key" "$val" >> "$DEFAULTS"
  fi
}
set_opt GRUB_TIMEOUT_STYLE menu
set_opt GRUB_TIMEOUT       -1
set_opt GRUB_GFXMODE       "$GFXMODE"
set_opt GRUB_THEME         "\"${GRUB_THEME_FILE}\""

# ---- regenerate -------------------------------------------------------------
log "Running update-grub"
update-grub

# ---- verify -----------------------------------------------------------------
log "Verifying generated grub.cfg"
grep -q "set theme=.*${THEME_NAME}" /boot/grub/grub.cfg \
  || warn "theme line not found in grub.cfg — check ${THEME_DIR}"
grep -q "set gfxmode=${GFXMODE}" /boot/grub/grub.cfg \
  || warn "gfxmode line not found in grub.cfg"

log "Done. Reboot to see the theme."
echo "    theme : ${GRUB_THEME_FILE}"
echo "    rollback: sudo $0 --uninstall"

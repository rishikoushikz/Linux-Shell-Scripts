#!/usr/bin/env bash
# install-antigravity.sh
#
# Installs the Google Antigravity apps for Linux (https://antigravity.google/download)
# into ~/Applications as user-owned installs, with a desktop launcher, icon,
# CLI symlink, and the desktop integrations a .deb would normally provide:
#   - "Open With > <app>" in the file manager for folders and text files
#     (via .desktop MimeType)
#   - "Open in <app>" right-click entry in Nautilus (via a small
#     python3-nautilus extension; GNOME / Nautilus only)
#   - <scheme>:// URL scheme handler
#
# Apps:
#   ide   Antigravity IDE (standalone desktop editor)
#   app   Antigravity app (the companion "hub" app; alias: hub)
#   cli   Antigravity CLI (runs the official installer, installs `agy`)
#
# Usage:
#   ./install-antigravity.sh                                  # interactive menu
#   ./install-antigravity.sh --app app                        # Antigravity app
#   ./install-antigravity.sh --app all                        # everything below
#   ./install-antigravity.sh --list
#   ./install-antigravity.sh --app ide --version 2.5.5-4923483625488384
#   ./install-antigravity.sh "/path/to/extracted/Antigravity IDE"
#   ./install-antigravity.sh "https://.../Antigravity.tar.gz"
#   ./install-antigravity.sh --app ide --uninstall
#   ./install-antigravity.sh --uninstall --all

set -euo pipefail

# --- Locations ------------------------------------------------------------
DOWNLOAD_PAGE="https://antigravity.google/download"
CLI_INSTALLER="https://antigravity.google/cli/install.sh"
CLI_UPDATER="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/"

APPLICATIONS_DIR="$HOME/Applications"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
BIN_DIR="$HOME/.local/bin"
NAUTILUS_EXT_DIR="$HOME/.local/share/nautilus-python/extensions"

# --- App registry ---------------------------------------------------------
# Every field is a plain variable so `app_field <app> <field>` can read it.
#   slug      install directory / desktop entry / icon / symlink basename
#   display   human readable name
#   binary    expected executable inside the tarball ("" = auto-detect)
#   kind      electron | cli
#   scheme    URL scheme this app registers (override with --scheme)
#   base      release server directory holding <base>/<version>/<platform>/<artifact>
#   artifact  file name inside the release directory
#   fallback  build used when the download page cannot be read
#   icon_rel  in-tarball icon path ("" = none shipped)
#   icon_url  icon to download when the tarball ships none ("" = none)
#   mimes     .desktop MimeType list (without the x-scheme-handler entry)

APP_ide_slug="antigravity-ide"
APP_ide_display="Antigravity IDE"
APP_ide_binary="antigravity-ide"
APP_ide_kind="electron"
APP_ide_scheme="antigravity-ide"
APP_ide_base="https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable"
APP_ide_artifact="Antigravity%20IDE.tar.gz"
APP_ide_fallback="2.5.5-4923483625488384"
APP_ide_icon_rel="resources/app/resources/linux/code.png"
APP_ide_icon_url=""
APP_ide_mimes="text/plain;inode/directory;application/x-antigravity-ide-workspace;"
APP_ide_comment="Antigravity IDE"
APP_ide_generic="Code Editor"
APP_ide_categories="Development;IDE;TextEditor;"

APP_app_slug="antigravity"
APP_app_display="Antigravity"
APP_app_binary="antigravity"
APP_app_kind="electron"
APP_app_scheme="antigravity"
APP_app_base="https://storage.googleapis.com/antigravity-public/antigravity-hub"
APP_app_artifact="Antigravity.tar.gz"
APP_app_fallback="2.23.1-6348059836284928"
APP_app_icon_rel=""
APP_app_icon_url="https://antigravity.google/assets/image/antigravity-logo.png"
APP_app_mimes="inode/directory;"
APP_app_comment="Antigravity app"
APP_app_generic="Antigravity"
APP_app_categories="Development;Utility;"

APP_cli_slug="antigravity-cli"
APP_cli_display="Antigravity CLI"
APP_cli_binary="agy"
APP_cli_kind="cli"

app_field() {
    local var="APP_${1}_${2}"
    printf '%s' "${!var-}"
}

known_apps() {
    printf '%s\n' ide app cli
}

normalize_app() {
    case "${1:-}" in
        ide|antigravity-ide) printf '%s' ide ;;
        app|hub|antigravity) printf '%s' app ;;
        cli|antigravity-cli) printf '%s' cli ;;
        *) printf '%s' "" ;;
    esac
}

# --- Options --------------------------------------------------------------
APP_REQUEST=""
INPUT=""
WANT_VERSION=""
SCHEME_OVERRIDE=""
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/antigravity"
KEEP_ARCHIVE="Y"
DO_UNINSTALL="N"
DO_ALL="N"
LIST_ONLY="N"

WANT_ROUNDED="Y"
DL_TOOL=""
PLATFORM=""
TMP_DIR=""
CACHE_CLEANUP=""
ARCHIVE_FILE=""
SRC=""
SRC_INPUT=""

usage() {
    cat <<EOF
Usage:
  $0 [options] [<path|url>]

Installs a Google Antigravity app for Linux from a local directory, a local
archive, a URL, or by downloading a build from Google's release server.
Run it with no arguments on a terminal to get an interactive menu.

Apps:
  ide                 Antigravity IDE (standalone desktop editor)
  app                 Antigravity app (alias: hub)
  cli                 Antigravity CLI (official installer, installs \`agy\`)
  all                 Every app above that is installable on Linux

Arguments:
  <path>              Local extracted directory or archive to install
  <url>               Direct URL to an Antigravity .tar.gz

Options:
  --app <name>        Which app to install (default: menu, or \`ide\`)
  --all               Same as --app all
  --list              Show available apps, versions, sizes and install status
  --latest            Download the newest build (default with no input)
  --version <ver>     Download a specific build of the selected app
  --scheme <scheme>   Override the URL scheme registered for the app
  --cache-dir <dir>   Where downloaded archives are kept (default: $CACHE_DIR)
  --no-keep-archive   Delete the downloaded archive after installing
  -h, --help          Show this help
  --uninstall         Remove the selected app (combine with --all for everything)
EOF
}

ARGC=$#

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)             [ -n "${2:-}" ] || { echo "Missing value for --app" >&2; exit 1; }
                           APP_REQUEST="$2"; shift 2 ;;
        --all)             DO_ALL="Y"; shift ;;
        --list)            LIST_ONLY="Y"; shift ;;
        --uninstall)       DO_UNINSTALL="Y"; shift ;;
        --latest)          shift ;;
        --version)         [ -n "${2:-}" ] || { echo "Missing value for --version" >&2; exit 1; }
                           WANT_VERSION="$2"; shift 2 ;;
        --scheme)          [ -n "${2:-}" ] || { echo "Missing value for --scheme" >&2; exit 1; }
                           SCHEME_OVERRIDE="$2"; shift 2 ;;
        --cache-dir)       [ -n "${2:-}" ] || { echo "Missing value for --cache-dir" >&2; exit 1; }
                           CACHE_DIR="$2"; shift 2 ;;
        --no-keep-archive) KEEP_ARCHIVE="N"; shift ;;
        -h|--help)         usage; exit 0 ;;
        --)                shift; break ;;
        -*)                echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)                 INPUT="$1"; shift ;;
    esac
done

if [ "$DO_ALL" = "Y" ] && [ -z "$APP_REQUEST" ]; then
    APP_REQUEST="all"
fi

if [ -n "$APP_REQUEST" ]; then
    case "$APP_REQUEST" in
        all) APP_REQUEST="all" ;;
        *)
            NORMALIZED="$(normalize_app "$APP_REQUEST")"
            if [ -z "$NORMALIZED" ]; then
                echo "Unknown app: $APP_REQUEST" >&2
                echo "Known apps: $(known_apps | tr '\n' ' ')" >&2
                exit 1
            fi
            APP_REQUEST="$NORMALIZED"
            ;;
    esac
fi

if [ -n "$WANT_VERSION" ] && [ "$APP_REQUEST" = "all" ]; then
    echo "--version cannot be combined with --app all; pick a single app." >&2
    exit 1
fi

if [ -n "$SCHEME_OVERRIDE" ] && [ "$APP_REQUEST" = "all" ]; then
    echo "--scheme cannot be combined with --app all; pick a single app." >&2
    exit 1
fi

case "$INPUT" in
    http://*|https://*)
        if [ -n "$WANT_VERSION" ]; then
            echo "--version cannot be combined with a URL; the URL already pins the build." >&2
            exit 1
        fi
        ;;
esac

# --- Helpers --------------------------------------------------------------
cleanup() {
    if [ -n "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    if [ -n "$CACHE_CLEANUP" ]; then
        rm -f "$CACHE_CLEANUP"
    fi
}
trap cleanup EXIT

detect_platform() {
    case "$(uname -s)" in
        Linux) PLATFORM="linux" ;;
        *) echo "Automatic download only supports Linux; pass a local path instead." >&2; return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  PLATFORM="$PLATFORM-x64" ;;
        arm64|aarch64) PLATFORM="$PLATFORM-arm" ;;
        *) echo "Unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac
    return 0
}

ensure_download_tool() {
    [ -n "$DL_TOOL" ] && return 0
    if command -v curl >/dev/null 2>&1; then
        DL_TOOL="curl"
    elif command -v wget >/dev/null 2>&1; then
        DL_TOOL="wget"
    else
        echo "Neither curl nor wget is available; install one or pass a local path." >&2
        return 1
    fi
    return 0
}

fetch_url() {
    if [ "$DL_TOOL" = "curl" ]; then
        curl -fsSL --compressed --max-time 60 "$1" 2>/dev/null
    else
        wget -qO- --compression=auto --timeout=60 "$1" 2>/dev/null
    fi
}

remote_size() {
    if [ "$DL_TOOL" = "curl" ]; then
        curl -fsSIL --max-time 30 "$1" 2>/dev/null \
            | tr -d '\r' | grep -i '^content-length:' | tail -n1 | awk '{print $2}'
    else
        wget --spider -S --timeout=30 "$1" 2>&1 \
            | tr -d '\r' | grep -i '^ *Content-Length:' | tail -n1 | awk '{print $2}'
    fi
}

human_size() {
    case "${1:-}" in
        ''|*[!0-9]*) printf '%s' "" ; return 0 ;;
    esac
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB TB", u, " ");
        i = 1;
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.0f %s"), b, u[i]
    }'
}

# Resolves the newest build URL for an app by scraping the download page.
# Neither desktop app publishes a "latest" URL, so the page is the only source.
resolve_url() {
    local app="$1" marker page
    case "$app" in
        ide) marker="antigravity/stable/" ;;
        app) marker="antigravity-hub/" ;;
        *) return 0 ;;
    esac
    page="$(fetch_url "$DOWNLOAD_PAGE" || true)"
    [ -n "$page" ] || return 0
    printf '%s' "$page" \
        | grep -oE "https://[^\"'<> ]*\.tar\.gz" \
        | grep -F "$marker" \
        | grep -F "/$PLATFORM/" \
        | head -n1 || true
    return 0
}

version_from_url() {
    printf '%s' "${1:-}" | sed -nE 's#.*/([^/]+)/'"$PLATFORM"'/.*#\1#p'
}

app_url_for_version() {
    local app="$1" ver="$2"
    printf '%s/%s/%s/%s' "$(app_field "$app" base)" "$ver" "$PLATFORM" "$(app_field "$app" artifact)"
}

app_installed() {
    local app="$1"
    case "$(app_field "$app" kind)" in
        cli) [ -x "$BIN_DIR/agy" ] ;;
        *)   [ -d "$APPLICATIONS_DIR/$(app_field "$app" slug)" ] ;;
    esac
}

installed_marker() {
    if app_installed "$1"; then printf '%s' "[installed]"; else printf '%s' ""; fi
}

# Downloads (or reuses) the archive for an app and sets ARCHIVE_FILE.
download_archive() {
    local app="$1" url="$2" ver="$3" slug
    slug="$(app_field "$app" slug)"

    mkdir -p "$CACHE_DIR"
    ARCHIVE_FILE="$CACHE_DIR/$slug-$ver-$PLATFORM.tar.gz"

    if [ -s "$ARCHIVE_FILE" ] && gzip -t "$ARCHIVE_FILE" 2>/dev/null; then
        echo "Using cached archive: $ARCHIVE_FILE"
    else
        rm -f "$ARCHIVE_FILE" "$ARCHIVE_FILE.part"
        echo "Downloading $(app_field "$app" display) $ver ($PLATFORM)"
        echo "  $url"
        local failed="N"
        if [ "$DL_TOOL" = "curl" ]; then
            curl -fL --progress-bar -o "$ARCHIVE_FILE.part" "$url" || failed="Y"
        else
            wget -q --show-progress -O "$ARCHIVE_FILE.part" "$url" || failed="Y"
        fi
        if [ "$failed" = "Y" ] || ! gzip -t "$ARCHIVE_FILE.part" 2>/dev/null; then
            rm -f "$ARCHIVE_FILE.part"
            echo "Download failed or the result is not a valid gzip archive:" >&2
            echo "  $url" >&2
            return 1
        fi
        mv "$ARCHIVE_FILE.part" "$ARCHIVE_FILE"
        echo "Saved to $ARCHIVE_FILE"
    fi

    if [ "$KEEP_ARCHIVE" = "N" ]; then
        CACHE_CLEANUP="$ARCHIVE_FILE"
    fi
    return 0
}

# Resolves + downloads the release for an app, from an explicit URL or from
# the newest/specified build on the release server. Sets INPUT to the archive.
prepare_download() {
    local app="$1" url="" ver=""

    detect_platform || return 1
    ensure_download_tool || return 1

    case "$INPUT" in
        http://*|https://*)
            url="$INPUT"
            ver="$(version_from_url "$url")"
            [ -n "$ver" ] || ver="custom"
            ;;
        "")
            if [ -n "$WANT_VERSION" ]; then
                ver="$WANT_VERSION"
                url="$(app_url_for_version "$app" "$ver")"
            else
                echo "Resolving the latest $(app_field "$app" display) build for $PLATFORM..."
                url="$(resolve_url "$app")"
                ver="$(version_from_url "$url")"
                if [ -z "$url" ] || [ -z "$ver" ]; then
                    ver="$(app_field "$app" fallback)"
                    echo "Could not read the download page; falling back to build $ver."
                    url="$(app_url_for_version "$app" "$ver")"
                fi
            fi
            ;;
        *)
            echo "Unexpected input for download: $INPUT" >&2
            return 1
            ;;
    esac

    download_archive "$app" "$url" "$ver" || return 1
    INPUT="$ARCHIVE_FILE"
    return 0
}

# Extracts the archive to a temp dir (or uses the directory as-is) and sets SRC.
# Repeated calls for the same INPUT reuse the already-prepared source.
prepare_source() {
    if [ -n "${SRC:-}" ] && [ "${SRC_INPUT:-}" = "$INPUT" ]; then
        return 0
    fi
    SRC=""
    if [ -d "$INPUT" ]; then
        SRC="$(cd "$INPUT" && pwd)"
    elif [ -f "$INPUT" ]; then
        if [ -n "$TMP_DIR" ]; then
            rm -rf "$TMP_DIR"
        fi
        TMP_DIR="$(mktemp -d)"
        case "$INPUT" in
            *.tar.gz|*.tgz) tar -xzf "$INPUT" -C "$TMP_DIR" ;;
            *.tar.xz)       tar -xJf "$INPUT" -C "$TMP_DIR" ;;
            *.tar.bz2)      tar -xjf "$INPUT" -C "$TMP_DIR" ;;
            *.tar)          tar -xf "$INPUT" -C "$TMP_DIR" ;;
            *.zip)          unzip -q "$INPUT" -d "$TMP_DIR" ;;
            *) echo "Unsupported archive format: $INPUT" >&2; return 1 ;;
        esac
        local marker
        marker="$(find "$TMP_DIR" -type f -name "chrome-sandbox" | head -n1 || true)"
        if [ -z "$marker" ]; then
            echo "Could not find valid Electron application structure inside archive." >&2
            return 1
        fi
        SRC="$(dirname "$marker")"
    else
        echo "Input does not exist: $INPUT" >&2
        return 1
    fi
    SRC="$(cd "$SRC" && pwd)"
    SRC_INPUT="$INPUT"
    return 0
}

detect_app_from_url() {
    case "$1" in
        *antigravity-hub*|*Antigravity.tar.gz) printf '%s' app ;;
        *antigravity/stable*|*Antigravity%20IDE*) printf '%s' ide ;;
        *) printf '%s' "" ;;
    esac
}

# Distinguishes the two Electron apps by layout: only the hub ships
# resources/app-update.yml and no resources/app tree.
detect_app_from_src() {
    local dir="$1"
    if [ -f "$dir/resources/app-update.yml" ] && [ ! -d "$dir/resources/app/out" ]; then
        printf '%s' app
        return 0
    fi
    if [ -f "$dir/resources/app/package.json" ] || [ -x "$dir/antigravity-ide" ]; then
        printf '%s' ide
        return 0
    fi
    if [ -x "$dir/antigravity" ] && [ ! -x "$dir/antigravity-ide" ]; then
        printf '%s' app
        return 0
    fi
    printf '%s' ""
}

pick_binary() {
    local dir="$1" expected="$2" f fname
    if [ -n "$expected" ] && [ -f "$dir/$expected" ]; then
        printf '%s' "$expected"
        return 0
    fi
    for f in "$dir"/*; do
        if [ -f "$f" ] && [ -x "$f" ]; then
            fname="$(basename "$f")"
            # Ignore common Chromium background helpers
            if [ "$fname" != "chrome-sandbox" ] && [ "$fname" != "chrome_crashpad_handler" ] && [ "${fname#*.}" = "$fname" ]; then
                printf '%s' "$fname"
                return 0
            fi
        fi
    done
    printf '%s' ""
}

# Returns the best icon source for an app: in-tarball icon, else the site icon.
icon_source() {
    local app="$1" dir="$2" rel cand url out
    rel="$(app_field "$app" icon_rel)"
    if [ -n "$rel" ] && [ -f "$dir/$rel" ]; then
        printf '%s' "$dir/$rel"
        return 0
    fi
    for cand in resources/app/resources/linux/antigravity.png resources/app/resources/linux/code.png; do
        if [ -f "$dir/$cand" ]; then
            printf '%s' "$dir/$cand"
            return 0
        fi
    done

    url="$(app_field "$app" icon_url)"
    if [ -n "$url" ]; then
        out="$CACHE_DIR/icon-$(app_field "$app" slug).png"
        if [ ! -s "$out" ]; then
            mkdir -p "$CACHE_DIR"
            echo "Fetching app icon from $url" >&2
            if [ "$DL_TOOL" = "curl" ]; then
                curl -fsSL --max-time 60 -o "$out.part" "$url" 2>/dev/null || true
            else
                wget -qO "$out.part" "$url" 2>/dev/null || true
            fi
            if [ -s "$out.part" ]; then
                mv "$out.part" "$out"
            else
                rm -f "$out.part"
            fi
        fi
        if [ -s "$out" ]; then
            printf '%s' "$out"
            return 0
        fi
    fi
    printf '%s' ""
    return 0
}

install_icon() {
    local src="$1" dest="$2"
    if [ -z "$src" ]; then
        echo "No icon available for this app; skipping icon install."
        return 0
    fi
    if [ "$WANT_ROUNDED" = "Y" ] && command -v magick >/dev/null 2>&1; then
        echo "Applying deep squircle corners to icon via ImageMagick..."
        magick "$src" -resize 512x512 \
          \( -size 512x512 xc:none -draw "roundrectangle 0,0,511,511,115,115" \) \
          -compose DstIn -composite "$dest"
    elif [ "$WANT_ROUNDED" = "Y" ] && command -v convert >/dev/null 2>&1; then
        echo "Applying deep squircle corners to icon via Legacy ImageMagick..."
        convert "$src" -resize 512x512 \
          \( -size 512x512 xc:none -draw "roundrectangle 0,0,511,511,115,115" \) \
          -compose DstIn -composite "$dest"
    else
        echo "Installing default square layout icon."
        install -Dm644 "$src" "$dest"
    fi
    chmod 644 "$dest"
    gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
    return 0
}

install_nautilus_extension() {
    local app="$1" binary="$2" slug display dest class
    slug="$(app_field "$app" slug)"
    display="$(app_field "$app" display)"
    dest="$NAUTILUS_EXT_DIR/$slug.py"
    class="OpenIn$(printf '%s' "$slug" | sed -E 's/[^A-Za-z0-9]+/ /g' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)}}1' | tr -d ' ')"

    if ! command -v nautilus >/dev/null 2>&1; then
        return 0
    fi
    if ! dpkg -s python3-nautilus >/dev/null 2>&1; then
        echo
        echo "Nautilus 'Open in $display' menu entry needs the python3-nautilus package."
        if [ -t 0 ]; then
            read -r -p "  Install it now? [Y/n] " ans
        else
            ans="Y"
        fi
        case "${ans:-Y}" in
            [Nn]*) echo "Skipping Nautilus extension."; return 0 ;;
        esac
        sudo apt-get install -y python3-nautilus || {
            echo "Failed to install python3-nautilus; skipping Nautilus extension."
            return 0
        }
    fi

    mkdir -p "$NAUTILUS_EXT_DIR"
    cat > "$dest" <<PYEOF
"""Nautilus right-click entry: Open in $display."""
import os
import subprocess
from urllib.parse import unquote, urlparse

import gi
for _v in ("4.1", "4.0", "3.0"):
    try:
        gi.require_version("Nautilus", _v)
        break
    except ValueError:
        continue
from gi.repository import GObject, Nautilus

APP_DISPLAY = "$display"
SLUG = "$slug"
BINARY = "$binary"


def _local_path(file_info):
    parts = urlparse(file_info.get_uri())
    if parts.scheme != "file":
        return None
    return unquote(parts.path)


def _launch(paths):
    subprocess.Popen([BINARY, *paths], start_new_session=True)


class $class(GObject.GObject, Nautilus.MenuProvider):
    def _item(self, name, label, paths):
        item = Nautilus.MenuItem(name=name, label=label, tip=f"Open in {APP_DISPLAY}")
        item.connect("activate", lambda _i, _p=paths: _launch(_p))
        return item

    def get_file_items(self, files):
        paths = [p for p in (_local_path(f) for f in files) if p]
        if not paths:
            return []
        return [self._item(f"{SLUG}::open_files",
                           f"Open in {APP_DISPLAY}", paths)]

    def get_background_items(self, folder):
        path = _local_path(folder)
        if not path:
            return []
        return [self._item(f"{SLUG}::open_folder",
                           f"Open Folder in {APP_DISPLAY}", [path])]
PYEOF
    nautilus -q 2>/dev/null || true
    echo "Nautilus extension installed at $dest"
    return 0
}

# --- Install / uninstall --------------------------------------------------
install_electron_app() {
    local app="$1" slug display scheme binary dest icon_dest desktop bin_link
    slug="$(app_field "$app" slug)"
    display="$(app_field "$app" display)"
    scheme="${SCHEME_OVERRIDE:-$(app_field "$app" scheme)}"
    dest="$APPLICATIONS_DIR/$slug"
    icon_dest="$ICON_DIR/$slug.png"
    desktop="$DESKTOP_DIR/$slug.desktop"
    bin_link="$BIN_DIR/$slug"

    prepare_source || return 1

    binary="$(pick_binary "$SRC" "$(app_field "$app" binary)")"
    if [ -z "$binary" ]; then
        echo "Could not auto-detect the main application executable in $SRC." >&2
        return 1
    fi

    # 1. Move the app into ~/Applications
    mkdir -p "$APPLICATIONS_DIR" "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR"
    rm -rf "$dest"
    cp -aT "$SRC" "$dest"

    # 2. Icon (squircle optional; the hub app has none in its tarball)
    install_icon "$(icon_source "$app" "$dest")" "$icon_dest"

    # 3. Sandbox: try an AppArmor profile, else fall back to --no-sandbox
    local exec_line="\"$dest/$binary\" %F"
    local userns_restricted
    userns_restricted="$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)"
    if [ "$userns_restricted" = "1" ]; then
        local profile_name="userns-${slug}-${USER}"
        local profile_path="/etc/apparmor.d/${profile_name}"
        local profile_body="abi <abi/4.0>,
include <tunables/global>

profile ${profile_name} \"$dest/$binary\" flags=(unconfined) {
  userns,
  include if exists <local/${profile_name}>
}
"
        echo "Ubuntu AppArmor restricts unprivileged user namespaces."
        echo "Installing a one-time AppArmor profile so Chromium's sandbox works"
        echo "(requires sudo; updates afterwards will not need sudo)."
        if echo "$profile_body" | sudo tee "$profile_path" >/dev/null \
           && sudo apparmor_parser -r "$profile_path"; then
            echo "AppArmor profile installed: $profile_path"
        else
            echo "AppArmor profile install failed; using --no-sandbox in launcher."
            exec_line="\"$dest/$binary\" --no-sandbox %F"
        fi
    fi

    # 4. Desktop launcher
    local mimes
    mimes="$(app_field "$app" mimes)x-scheme-handler/$scheme;"
    cat > "$desktop" <<EOF
[Desktop Entry]
Name=$display
Comment=$(app_field "$app" comment)
GenericName=$(app_field "$app" generic)
Exec=$exec_line
Icon=$icon_dest
Terminal=false
Type=Application
Categories=$(app_field "$app" categories)
StartupWMClass=$binary
MimeType=$mimes
EOF
    if [ "$app" = "ide" ]; then
        cat >> "$desktop" <<EOF
Actions=new-empty-window;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec=$exec_line --new-window
Icon=$icon_dest
EOF
    fi
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    rm -rf ~/.cache/thumbnails/*

    # 5. CLI symlink
    ln -sf "$dest/$binary" "$bin_link"

    # 6. Register as the handler for its URL scheme
    xdg-mime default "$slug.desktop" "x-scheme-handler/$scheme" 2>/dev/null || true

    # 7. Nautilus right-click entry
    install_nautilus_extension "$app" "$dest/$binary"

    echo
    echo "Installed $display -> $dest"
    echo "Launch from your application menu, or run: $slug"
    return 0
}

install_cli() {
    local display
    display="$(app_field cli display)"
    ensure_download_tool || return 1
    mkdir -p "$BIN_DIR"
    echo "Installing $display via the official installer..."
    if [ "$DL_TOOL" = "curl" ]; then
        curl -fsSL "$CLI_INSTALLER" | bash
    else
        wget -qO- "$CLI_INSTALLER" | bash
    fi
    echo
    echo "Installed $display -> $BIN_DIR/agy"
    return 0
}

uninstall_app() {
    local app="$1" slug display
    slug="$(app_field "$app" slug)"
    display="$(app_field "$app" display)"

    if [ "$(app_field "$app" kind)" = "cli" ]; then
        echo "Uninstalling $display..."
        rm -f "$BIN_DIR/agy"
        echo "Uninstallation complete."
        return 0
    fi

    echo "Uninstalling $display..."
    rm -rf "$APPLICATIONS_DIR/$slug"
    rm -f "$DESKTOP_DIR/$slug.desktop"
    rm -f "$BIN_DIR/$slug"
    rm -f "$ICON_DIR/$slug.png"
    rm -f "$HOME/.local/share/icons/hicolor/1024x1024/apps/$slug.png"
    rm -f "$NAUTILUS_EXT_DIR/$slug.py"

    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
    rm -rf ~/.cache/thumbnails/*

    echo "Uninstallation complete."
    echo "Note: the AppArmor profile in /etc/apparmor.d/userns-$slug-$USER (if any) was left in place."
    return 0
}

# --- App listing / menu ---------------------------------------------------
# Version and size lookups hit the network, so cache them for the session: the
# interactive menu is redrawn after every action.
latest_version_for() {
    local app="$1" var="LATEST_VER_$1" ver url
    if [ -n "${!var-}" ]; then
        printf '%s' "${!var}"
        return 0
    fi
    case "$(app_field "$app" kind)" in
        cli)
            ver="$(fetch_url "$CLI_UPDATER" 2>/dev/null | grep -oE 'Stable Version: [^ ]+' | head -n1 | awk '{print $3}' | sed -E 's/\.$//' || true)"
            ;;
        *)
            if [ -z "$PLATFORM" ]; then
                ver="unknown"
            else
                url="$(resolve_url "$app")"
                ver="$(version_from_url "$url")"
            fi
            ;;
    esac
    [ -n "$ver" ] || ver="unknown"
    printf -v "$var" '%s' "$ver"
    printf '%s' "$ver"
    return 0
}

latest_size_for() {
    local app="$1" done_var="LATEST_SIZE_DONE_$1" size_var="LATEST_SIZE_$1"
    local ver url size=""
    if [ -n "${!done_var-}" ]; then
        printf '%s' "${!size_var-}"
        return 0
    fi
    if [ "$(app_field "$app" kind)" != "cli" ]; then
        ver="$(latest_version_for "$app")"
        case "$ver" in
            unknown|unsupported|"") : ;;
            *) size="$(human_size "$(remote_size "$(app_url_for_version "$app" "$ver")")")" ;;
        esac
    fi
    printf -v "$done_var" '%s' "Y"
    printf -v "$size_var" '%s' "$size"
    printf '%s' "$size"
    return 0
}

show_list() {
    local app display ver size marker
    echo "Antigravity apps available for ${PLATFORM:-this platform}:"
    echo
    for app in $(known_apps); do
        display="$(app_field "$app" display)"
        ver="$(latest_version_for "$app")"
        size="$(latest_size_for "$app")"
        marker="$(installed_marker "$app")"
        printf '  %-18s %-26s %-9s %s\n' "$app" "$display" "$ver" "${size:+$size} $marker"
    done
    echo
    echo "Install with: $0 --app <$(known_apps | tr '\n' '|' | sed 's/|$//')|all>"
    echo "Remove with:  $0 --uninstall --app <name>|--all"
    return 0
}

# Asks about rounded icon corners once and makes sure ImageMagick is present.
prompt_rounded_corners() {
    if [ -t 0 ]; then
        echo
        read -r -p "Do you want rounded corner icons? [Y/n] " ans || ans="Y"
        case "${ans:-Y}" in
            [Yy]*) WANT_ROUNDED="Y" ;;
            *)     WANT_ROUNDED="N" ;;
        esac
    else
        WANT_ROUNDED="Y"
    fi

    if [ "$WANT_ROUNDED" = "Y" ] \
       && ! command -v magick >/dev/null 2>&1 \
       && ! command -v convert >/dev/null 2>&1; then
        echo "ImageMagick is required for rounded corners but is missing."
        echo "Automatically installing 'imagemagick' package (requires sudo)..."
        sudo apt-get update && sudo apt-get install -y imagemagick \
            || echo "Continuing without rounded corners." >&2
    fi
    return 0
}

# Force panels to drop old graphical memory caches
restart_panels() {
    killall lxpanel xfce4-panel gnome-shell-extension-prefs 2>/dev/null || true
    if command -v xfce4-panel >/dev/null 2>&1; then
        xfce4-panel --restart 2>/dev/null || true
    fi
    return 0
}

run_uninstall_targets() {
    local app
    for app in $1; do
        uninstall_app "$app" || return 1
    done
    return 0
}

# Installs every app key given in $1 ("ide", "app", "cli", "ide app cli", ...).
run_install_targets() {
    local apps="$1" app saved_input="$INPUT"
    for app in $apps; do
        if [ -z "$(app_field "$app" slug)" ]; then
            echo "Unknown app: $app" >&2
            echo "Known apps: $(known_apps | tr '\n' ' ')" >&2
            INPUT="$saved_input"
            return 1
        fi
        INPUT="$saved_input"
        if [ "$(app_field "$app" kind)" = "cli" ]; then
            if [ -n "$INPUT" ]; then
                echo "--app cli does not take a path or URL." >&2
                return 1
            fi
            install_cli || return 1
            continue
        fi
        ensure_download_tool || return 1

        # A URL input is downloaded here; an empty input resolves the latest build.
        if [ -z "$INPUT" ] || [ "${INPUT#http}" != "$INPUT" ]; then
            prepare_download "$app" || return 1
        fi

        install_electron_app "$app" || return 1
    done
    INPUT="$saved_input"
    restart_panels
    return 0
}

choose_uninstall_target() {
    local items=() actions=() app
    for app in $(known_apps); do
        items+=("$(app_field "$app" display)$(installed_marker "$app")")
        actions+=("$app")
    done
    items+=("Everything"); actions+=("all")
    items+=("Cancel");    actions+=("")

    echo "Which app do you want to uninstall?" >&2
    PS3="Select [1-${#items[@]}]: "
    select _choice in "${items[@]}"; do
        if [ -z "${_choice:-}" ]; then
            echo "Invalid selection." >&2
            continue
        fi
        printf '%s' "${actions[$((REPLY-1))]}"
        return 0
    done
    printf '%s' ""
    return 0
}

# Prints the action string for the chosen menu entry, e.g. "install:app".
interactive_menu() {
    local items=() actions=() app display ver size
    for app in $(known_apps); do
        display="$(app_field "$app" display)"
        ver="$(latest_version_for "$app")"
        size="$(latest_size_for "$app")"
        items+=("Install $display $ver${size:+ ($size)}$(installed_marker "$app")")
        actions+=("install:$app")
    done
    items+=("Install everything");                     actions+=("install:all")
    items+=("Uninstall an app");                       actions+=("uninstall")
    items+=("Show versions, sizes and install status"); actions+=("list")
    items+=("Show help");                              actions+=("help")
    items+=("Quit");                                   actions+=("quit")

    echo >&2
    echo "Antigravity installer - what do you want to do?" >&2
    PS3="Select [1-${#items[@]}]: "
    select _choice in "${items[@]}"; do
        if [ -z "${_choice:-}" ]; then
            echo "Invalid selection." >&2
            continue
        fi
        printf '%s' "${actions[$((REPLY-1))]}"
        return 0
    done
    printf '%s' "quit"
    return 0
}

interactive_loop() {
    local action target
    while true; do
        action="$(interactive_menu)" || action="quit"
        case "$action" in
            install:*)
                INPUT=""
                run_install_targets "${action#install:}" || echo "Install failed." >&2
                ;;
            uninstall)
                target="$(choose_uninstall_target)"
                if [ -n "$target" ]; then
                    run_uninstall_targets "$target" || echo "Uninstall failed." >&2
                else
                    echo "Cancelled."
                fi
                ;;
            list) show_list ;;
            help) usage ;;
            *|quit) break ;;
        esac
        echo
        read -r -p "Press Enter to return to the menu... " _dummy || { echo; break; }
        echo
    done
    return 0
}

# --- Main -----------------------------------------------------------------
# Platform is needed for version and size lookups; set it once in this shell.
detect_platform >/dev/null 2>&1 || true

if [ "$LIST_ONLY" = "Y" ]; then
    ensure_download_tool || exit 1
    show_list
    exit 0
fi

# No arguments at all on a terminal: drive everything from the menu.
if [ "$ARGC" -eq 0 ] && [ -t 0 ]; then
    prompt_rounded_corners
    interactive_loop
    exit 0
fi

# Work out which app(s) are being acted on.
if [ -n "$APP_REQUEST" ]; then
    TARGET_APPS="$APP_REQUEST"
elif [ -n "$INPUT" ] && { [ -d "$INPUT" ] || [ -f "$INPUT" ]; }; then
    TARGET_APPS=""
else
    case "$INPUT" in
        http://*|https://*)
            TARGET_APPS="$(detect_app_from_url "$INPUT")"
            if [ -z "$TARGET_APPS" ]; then
                echo "Could not tell which app $INPUT belongs to; pass --app." >&2
                exit 1
            fi
            ;;
        "")
            if [ -t 0 ] && [ "$DO_UNINSTALL" = "Y" ]; then
                ensure_download_tool >/dev/null 2>&1 || true
                TARGET_APPS="$(choose_uninstall_target)"
                if [ -z "$TARGET_APPS" ]; then
                    echo "Cancelled." >&2
                    exit 0
                fi
            elif [ "$DO_UNINSTALL" = "Y" ]; then
                # Do not guess when removing something.
                TARGET_APPS=""
            else
                TARGET_APPS="ide"
            fi
            ;;
        *)
            echo "Input does not exist: $INPUT" >&2
            exit 1
            ;;
    esac
fi

if [ "$TARGET_APPS" = "all" ]; then
    TARGET_APPS="$(known_apps | tr '\n' ' ')"
fi

# A single local path/URL can only describe one app.
if [ -n "$INPUT" ]; then
    TARGET_COUNT="$(printf '%s\n' $TARGET_APPS | grep -c . || true)"
    if [ "$TARGET_COUNT" -gt 1 ]; then
        echo "A local path or URL can only install one app; pass a single --app." >&2
        exit 1
    fi
fi

# Uninstall mode: nothing is downloaded, apps are only removed.
if [ "$DO_UNINSTALL" = "Y" ]; then
    if [ -z "$TARGET_APPS" ]; then
        echo "Nothing to uninstall; pass --app <name> or --all." >&2
        exit 1
    fi
    run_uninstall_targets "$TARGET_APPS" || exit 1
    exit 0
fi

prompt_rounded_corners

# Narrow down which app a local path/archive belongs to, if it wasn't given.
if [ -z "$TARGET_APPS" ]; then
    ensure_download_tool >/dev/null 2>&1 || true
    prepare_source || exit 1
    for app in $(known_apps); do
        [ "$(app_field "$app" kind)" = "cli" ] && continue
        if [ "$(app_field "$app" binary)" != "" ] && [ -f "$SRC/$(app_field "$app" binary)" ]; then
            TARGET_APPS="$app"
            break
        fi
    done
    if [ -z "$TARGET_APPS" ]; then
        TARGET_APPS="$(detect_app_from_src "$SRC")"
    fi
    if [ -z "$TARGET_APPS" ]; then
        echo "Could not tell which app this is; pass --app." >&2
        exit 1
    fi
    echo "Detected app: $(app_field "$TARGET_APPS" display)"
fi

run_install_targets "$TARGET_APPS" || exit 1


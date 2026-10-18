#!/usr/bin/env bash
# terminal-setup.sh — clean, fast, professional zsh + modern CLI stack
# Ubuntu 22.04 (jammy), 24.04 (noble), 26.04 (resolute) and newer.
# Auto-detects the release and picks the right packages / install source.
#
# Interactive: run with no arguments for a numbered menu. Each action is
# idempotent, so you can re-run any step safely.
# Non-interactive: pass --all (or --yes/-y), or pipe the script / run with
# stdin closed, to run the whole sequence without the menu.
#
# Run as your normal user (NOT with sudo). The script calls sudo itself for
# the steps that need root. If it detects it was started via sudo it re-execs
# as the real user, so configs land in your home and chsh targets your account.
set -euo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
SWAP_SYNTAX_HL="${SWAP_SYNTAX_HL:-1}"        # 1 = fast-syntax-highlighting, 0 = keep current
INSTALL_AUTOSUGGEST="${INSTALL_AUTOSUGGEST:-1}"  # 1 = install zsh-autosuggestions
PTYXIS_PALETTE="${PTYXIS_PALETTE:-}"         # e.g. "Catppuccin Mocha"; empty = leave current
APT_UPDATED=0                                # guards apt-get update to once per run

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# ---------- Preamble: never run as root; resolve the real target user ----------
# Running under sudo makes $USER=root and $HOME=/root, so zsh would be set as
# *root's* login shell and every dotfile would land in /root. Detect that and
# re-exec as the invoking user (sudo is still used internally where needed).
if [[ "${EUID}" -eq 0 ]]; then
  _real="${SUDO_USER:-}"
  if [[ -z "$_real" || "$_real" == "root" ]]; then
    warn "Do not run this script as root or with sudo."
    warn "Run it as your normal user instead:  ./terminal-setup.sh"
    exit 1
  fi
  _real_home="$(getent passwd "$_real" | cut -d: -f6)"
  if [[ -z "$_real_home" ]]; then
    warn "Cannot resolve home directory for user '$_real'"
    exit 1
  fi
  log "sudo detected: re-running as '$_real' (config -> $_real_home)"
  exec sudo -u "$_real" -H env PATH="$PATH" bash "$0" "$@"
fi

# The user we configure, even if invoked oddly (e.g. USER unset).
TARGET_USER="$(id -un)"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || TARGET_HOME="$HOME"

# ---------- 0. Detect Ubuntu release ----------
[[ -r /etc/os-release ]] && . /etc/os-release
OS_ID="${ID:-ubuntu}"
OS_VER="${VERSION_ID:-0}"
OS_CODENAME="${VERSION_CODENAME:-unknown}"

# ---------- helpers ----------
apt_update_once() {
  if [[ "$APT_UPDATED" -eq 0 ]]; then
    sudo apt-get update
    APT_UPDATED=1
  fi
}

# install_file <target>  — read content from stdin, back up once per run,
# and skip the write when the file already has identical content.
install_file() {
  local target="$1" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    echo "    unchanged $target"
    rm -f "$tmp"
    return 0
  fi
  if [[ -f "$target" && ! -f "$target.bak.$TS" ]]; then
    cp "$target" "$target.bak.$TS"
    echo "    saved $target.bak.$TS"
  fi
  mkdir -p "$(dirname "$target")"
  mv -f "$tmp" "$target"
  echo "    wrote $target"
}

# ---------- 1. Backup ----------
do_backup() {
  log "Backing up existing configs"
  local f
  for f in "$HOME/.zshrc" "$HOME/.tmux.conf" "$HOME/.config/starship.toml"; do
    [[ -f "$f" ]] || continue
    if [[ -f "$f.bak.$TS" ]]; then
      echo "    already saved $f.bak.$TS"
    else
      cp "$f" "$f.bak.$TS" && echo "    saved $f.bak.$TS"
    fi
  done
}

# ---------- 2. Packages ----------
do_packages() {
  log "Installing packages (sudo password required)"
  apt_update_once

  # Present on every supported release (22.04 / 24.04 / 26.04).
  local base_pkgs=(zsh git curl unzip fontconfig tmux ripgrep fzf fd-find bat zoxide btop duf)
  local ls_repl install_pkgs

  # Modern ls replacement: eza on 24.04+, but 22.04 only ships exa.
  if apt-cache show eza >/dev/null 2>&1; then
    ls_repl=eza
  elif apt-cache show exa >/dev/null 2>&1; then
    ls_repl=exa
    warn "eza not packaged for ${OS_VER} (${OS_CODENAME}); falling back to exa"
  else
    ls_repl=""
    warn "neither eza nor exa available; keeping plain ls"
  fi

  install_pkgs=("${base_pkgs[@]}")
  [[ -n "$ls_repl" ]] && install_pkgs+=("$ls_repl")
  sudo apt-get install -y "${install_pkgs[@]}"
}

# ---------- 2b. starship + atuin ----------
# Packaged since Ubuntu 25.10 (questing); on 22.04 / 24.04 install upstream.
#   starship -> /usr/local/bin (installer escalates via sudo as needed)
#   atuin    -> ~/.atuin/bin (added to PATH in ~/.zshrc below)
do_cli_extras() {
  log "Installing starship"
  if apt-cache show starship >/dev/null 2>&1; then
    sudo apt-get install -y starship
    echo "    apt package"
  elif command -v starship >/dev/null 2>&1; then
    echo "    already installed: $(starship --version | head -n1)"
  else
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y
  fi

  log "Installing atuin"
  if apt-cache show atuin >/dev/null 2>&1; then
    sudo apt-get install -y atuin
    echo "    apt package"
  elif [[ -x "$HOME/.atuin/bin/atuin" ]]; then
    echo "    already installed: $("$HOME/.atuin/bin/atuin" --version)"
  else
    curl -fsSL https://setup.atuin.sh | sh -s -- --non-interactive
  fi
}

# ---------- 2c. Default shell ----------
do_shell() {
  local zsh_path current_shell
  zsh_path="$(command -v zsh || true)"
  current_shell="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
  if [[ -z "$zsh_path" ]]; then
    warn "zsh not found; cannot set default shell"
  elif [[ "$current_shell" == "$zsh_path" ]]; then
    echo "    login shell already $zsh_path"
  else
    log "Setting login shell for $TARGET_USER to $zsh_path"
    grep -qxF "$zsh_path" /etc/shells 2>/dev/null || \
      echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
    if sudo chsh -s "$zsh_path" "$TARGET_USER"; then
      echo "    default shell updated (active on next login)"
    else
      warn "chsh failed; run manually: chsh -s $zsh_path"
    fi
  fi
}

# ---------- 3. Nerd Font (user-local, no sudo) ----------
do_font() {
  local font_dir="$HOME/.local/share/fonts"
  if compgen -G "$font_dir/JetBrainsMono*.ttf" >/dev/null; then
    echo "    JetBrainsMono Nerd Font already present in $font_dir"
    return 0
  fi
  log "Installing JetBrainsMono Nerd Font"
  mkdir -p "$font_dir"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/JetBrainsMono.zip" \
    https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip
  unzip -oq "$tmp/JetBrainsMono.zip" -d "$tmp/jbmono"
  find "$tmp/jbmono" -name '*.ttf' -exec cp -f {} "$font_dir/" \;
  rm -rf "$tmp"
  fc-cache -f "$font_dir" >/dev/null
}

# ---------- 4. zsh plugins ----------
do_plugins() {
  log "Installing zsh plugins into $ZSH_CUSTOM"
  mkdir -p "$ZSH_CUSTOM/plugins"

  clone_plugin() {
    local name="$1" url="$2"
    if [[ -d "$ZSH_CUSTOM/plugins/$name" ]]; then
      echo "    already installed: $name"
    else
      git clone --depth=1 "$url" "$ZSH_CUSTOM/plugins/$name"
    fi
  }

  clone_plugin fzf-tab https://github.com/Aloxaf/fzf-tab
  if [[ "$SWAP_SYNTAX_HL" == "1" ]]; then
    clone_plugin fast-syntax-highlighting https://github.com/zdharma-continuum/fast-syntax-highlighting
  fi
  if [[ "$INSTALL_AUTOSUGGEST" == "1" ]]; then
    clone_plugin zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions
  fi
}

# ---------- 5. Starship ----------
do_starship_cfg() {
  log "Writing ~/.config/starship.toml"
  install_file "$HOME/.config/starship.toml" <<'TOM'
add_newline = true

format = """
[╭─](bold blue)$directory$git_branch$git_status$python$nodejs$rust$golang$java$docker_context
[╰─](bold blue)$character"""

[directory]
style = "bold cyan"
truncation_length = 4
truncate_to_repo = true

[git_branch]
symbol = "\ue0a0 "
style = "bold purple"

[git_status]
style = "bold red"
disabled = false

[python]
symbol = "\ue606 "
[nodejs]
symbol = "\ue718 "
[rust]
symbol = "\ue7a8 "
[golang]
symbol = "\ue627 "
[java]
symbol = "\ue738 "

[cmd_duration]
min_time = 500
format = "took [$duration]($style) "
style = "bold yellow"

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"
vimcmd_symbol = "[❮](bold green)"
TOM
}

# ---------- 6. tmux ----------
do_tmux_cfg() {
  log "Writing ~/.tmux.conf"
  install_file "$HOME/.tmux.conf" <<'TMUX'
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g history-limit 20000
set -g escape-time 10
set -sg escape-time 10
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc"
setw -g mode-keys vi
set -g status-style "bg=default,fg=white"
set -g status-left "#[bold] #S "
set -g status-left-length 30
set -g status-right "#{?window_zoomed_flag,#[bold yellow]ZOOM ,}#[default] %Y-%m-%d %H:%M "
set -g status-right-length 60
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind r source-file ~/.tmux.conf \; display "config reloaded"
TMUX
}

# ---------- 7. .zshrc ----------
do_zshrc() {
  log "Writing ~/.zshrc"
  install_file "$HOME/.zshrc" <<'ZRC'
# ~/.zshrc — clean / fast / professional
# ------------- options -------------
setopt autocd interactivecomments magicequalsubst nonomatch notify numericglobsort promptsubst
setopt hist_ignore_dups hist_ignore_space hist_verify hist_expire_dups_first
setopt share_history append_history inc_append_history extended_history hist_reduce_blanks

WORDCHARS='_-'
PROMPT_EOL_MARK=""
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

# ------------- PATH -------------
export PATH="$HOME/.opencode/bin:$HOME/.atuin/bin:$PATH"

# ------------- history -------------
HISTFILE="$HOME/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000
alias history="history 0"

# ------------- keybindings -------------
bindkey -e
bindkey ' ' magic-space
bindkey '^U' backward-kill-line
bindkey '^[[3~' delete-char
bindkey '^[[1;5C' forward-word
bindkey '^[[1;5D' backward-word
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[Z' undo

# ------------- completion -------------
autoload -Uz compinit
[[ -d "$HOME/.cache" ]] || mkdir -p "$HOME/.cache"
compinit -d "$HOME/.cache/zcompdump"
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' group-name ''
zstyle ':completion:*' format 'Completing %d'

# ------------- fzf -------------
for f in /usr/share/doc/fzf/examples/key-bindings.zsh /usr/share/fzf/key-bindings.zsh; do
  [[ -f "$f" ]] && source "$f" && break
done
for f in /usr/share/doc/fzf/examples/completion.zsh /usr/share/fzf/completion.zsh; do
  [[ -f "$f" ]] && source "$f" && break
done
export FZF_DEFAULT_OPTS="--height=45% --layout=reverse --border --info=inline"

# ------------- zoxide -------------
command -v zoxide >/dev/null && eval "$(zoxide init zsh)"

# ------------- plugins -------------
[[ -f "$ZSH_CUSTOM/plugins/fzf-tab/fzf-tab.zsh" ]] && \
  source "$ZSH_CUSTOM/plugins/fzf-tab/fzf-tab.zsh"
if [[ -f "$ZSH_CUSTOM/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
  ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=244'
  source "$ZSH_CUSTOM/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
fi
if [[ -f "$ZSH_CUSTOM/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh" ]]; then
  source "$ZSH_CUSTOM/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"
elif [[ -f "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]]; then
  source "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
  typeset -A ZSH_HIGHLIGHT_STYLES
  ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=red,bold'
  ZSH_HIGHLIGHT_STYLES[path]='underline'
fi

# ------------- atuin (Ctrl-R fuzzy history) -------------
command -v atuin >/dev/null && eval "$(atuin init zsh)"

# ------------- starship prompt -------------
command -v starship >/dev/null && eval "$(starship init zsh)"

# ------------- aliases -------------
# eza on 24.04+, exa on 22.04; fall back to plain ls if neither exists.
if command -v eza >/dev/null 2>&1; then _ls=eza
elif command -v exa >/dev/null 2>&1; then _ls=exa
else _ls=''; fi
if [[ -n "$_ls" ]]; then
  alias ls="$_ls --icons --group-directories-first"
  alias ll="$_ls -lh --icons --group-directories-first --git"
  alias la="$_ls -lah --icons --group-directories-first --git"
  alias lt="$_ls --tree --level=2 --icons"
  alias l="$_ls -1 --icons"
fi
unset _ls
alias cat='batcat --style=plain --paging=never'
alias catn='batcat --style=numbers --paging=never'
alias grep='rg --color=auto'
alias fd='fdfind'
alias diff='diff --color=auto'
command -v btop >/dev/null && alias top='btop'

# ------------- env -------------
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ZRC
}

do_configs() {
  do_starship_cfg
  do_tmux_cfg
  do_zshrc
}

# ---------- 8. Verify ----------
do_verify() {
  log "Verifying tools"
  zsh -i -c 'for c in batcat rg fzf zoxide starship atuin btop duf tmux; do
  if command -v "$c" >/dev/null 2>&1; then printf "  ok      %s\n" "$c"; else printf "  MISSING %s\n" "$c"; fi
done
if command -v eza >/dev/null 2>&1; then printf "  ok      eza\n"
elif command -v exa >/dev/null 2>&1; then printf "  ok      exa (eza unavailable on this release)\n"
else printf "  MISSING eza/exa\n"; fi
for p in fzf-tab fast-syntax-highlighting zsh-autosuggestions; do
  if [[ -d "$ZSH_CUSTOM/plugins/$p" ]]; then printf "  ok      plugin %s\n" "$p"; else printf "  MISSING plugin %s\n" "$p"; fi
done'

  echo "  palette: $(current_palette)"

  log "Startup time:"
  zsh -i -c exit 2>&1 | tail -n 1
}

# ---------- 9. Terminal theme (Ptyxis color palette) ----------
PTYXIS_PALETTE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/org.gnome.Ptyxis/palettes"

# Curated "best of" list. Everything else is reachable with the "a" (all) option.
THEME_CHOICES=(
  "Catppuccin Mocha"
  "Catppuccin Macchiato"
  "Catppuccin Frappé"
  "Catppuccin Latte"
  "Tokyo Night"
  "Tokyo Night Storm"
  "Tokyo Night Moon"
  "Dracula"
  "Gruvbox"
  "Gruvbox Material"
  "Nord"
  "Ayu"
  "Ayu Mirage"
  "Everforest"
  "Kanagawa"
  "Github"
  "Solarized Dark Higher Contrast"
  "Sweet Terminal"
  "Synthwave"
  "Zenburn"
  "campbell"
  "gnome"
)

# All palettes Ptyxis knows: built-ins from the bundle + user palettes on disk.
list_palettes() {
  local bin
  bin="$(command -v ptyxis || true)"
  if [[ -n "$bin" ]] && command -v gresource >/dev/null 2>&1; then
    gresource list "$bin" 2>/dev/null | sed -n 's#.*/palettes/##p' | sed 's/\.palette$//'
  fi
  if [[ -d "$PTYXIS_PALETTE_DIR" ]]; then
    find "$PTYXIS_PALETTE_DIR" -maxdepth 1 -name '*.palette' -printf '%f\n' 2>/dev/null | sed 's/\.palette$//'
  fi
  return 0
}

current_palette() {
  local uuid
  uuid="$(gsettings get org.gnome.Ptyxis default-profile-uuid 2>/dev/null | tr -d "'" || true)"
  [[ -n "$uuid" ]] || return 0
  gsettings get "org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$uuid/" palette 2>/dev/null | tr -d "'" || true
}

# Apply a palette name to every Ptyxis profile. Always returns 0 so the menu
# loop can't be tripped up by set -e.
resolve_palette() {
  local want="$1" hit
  hit="$(list_palettes | grep -ixF "$want" | head -n1 || true)"
  printf '%s' "${hit:-$want}"
}

apply_palette() {
  local name uuid applied=0
  name="$(resolve_palette "$1")"
  if ! list_palettes | grep -qxF "$name"; then
    warn "'$1' is not a known palette; setting '$name' anyway"
  fi
  while IFS= read -r uuid; do
    uuid="${uuid%/}"
    [[ -n "$uuid" ]] || continue
    if gsettings set "org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/$uuid/" palette "$name" 2>/dev/null; then
      echo "    profile $uuid -> $name"
      applied=1
    fi
  done < <(dconf list /org/gnome/Ptyxis/Profiles/ 2>/dev/null)
  if [[ "$applied" -eq 0 ]]; then
    warn "No Ptyxis profiles found; set it in Ptyxis > Preferences > Appearance"
  fi
  return 0
}

do_theme() {
  log "Ptyxis terminal theme"
  if ! command -v ptyxis >/dev/null 2>&1; then
    warn "Ptyxis not installed; skipping palette setup"
    return 0
  fi

  local cur
  cur="$(current_palette)"
  echo "    current palette: ${cur:-unknown}"
  echo
  local i
  for i in "${!THEME_CHOICES[@]}"; do
    printf '    %2d) %s\n' "$((i + 1))" "${THEME_CHOICES[$i]}"
  done
  echo "     a) show ALL available palettes"
  echo "     Enter) keep current"
  echo

  local choice name=""
  if ! read -r -p "Theme> " choice </dev/tty; then
    echo
    return 0
  fi
  case "$choice" in
    "") echo "    keeping ${cur:-current}"; return 0 ;;
    a|A)
      local all
      all="$(list_palettes | sort -u)"
      if [[ -z "$all" ]]; then
        warn "Could not enumerate palettes"
        return 0
      fi
      echo
      printf '%s\n' "$all" | nl -w4 -s') '
      echo
      read -r -p "Enter exact theme name (blank to cancel)> " name </dev/tty || return 0
      [[ -n "$name" ]] || { echo "    cancelled"; return 0; }
      ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#THEME_CHOICES[@]} )); then
        name="${THEME_CHOICES[$((choice - 1))]}"
      else
        warn "Invalid choice: '$choice'"
        return 0
      fi
      ;;
  esac

  apply_palette "$name"
}

# ---------- restore ----------
do_restore() {
  local f latest restored=0
  for f in "$HOME/.zshrc" "$HOME/.tmux.conf" "$HOME/.config/starship.toml"; do
    latest="$(ls -1t "$f".bak.* 2>/dev/null | head -n1 || true)"
    if [[ -n "$latest" ]]; then
      cp -f "$latest" "$f"
      echo "    restored $f  <-- $latest"
      restored=1
    else
      echo "    no backup for $f"
    fi
  done
  [[ "$restored" -eq 1 ]] || warn "No backups found to restore"
}

# ---------- full sequence ----------
run_full() {
  do_backup
  do_packages
  do_cli_extras
  do_shell
  do_font
  do_plugins
  do_configs
  if [[ -n "$PTYXIS_PALETTE" ]]; then
    apply_palette "$PTYXIS_PALETTE"
  fi
  do_verify
}

print_finish() {
  cat <<'DONE'

Done. Next steps:
  1. Ptyxis -> Preferences -> Font -> "JetBrainsMono Nerd Font" (10-12pt)
  2. Log out / back in (or run: exec zsh) to use zsh as your default shell
  3. Ctrl-R  = fuzzy history (atuin)   |   Tab = fuzzy completion (fzf-tab)
     z <dir> = smart cd (zoxide)        |   ls/ll/lt, cat, fd, rg = modern tools
     tmux    = multiplexer
  4. Theme   = menu option 9 (245 built-in Ptyxis palettes, e.g. "Catppuccin Mocha")

Rollback: restore ~/.zshrc.bak.<timestamp> and delete ~/.config/starship.toml
          (menu option "r" restores the newest backups for you)
DONE
}

# ---------- menu ----------
print_menu() {
  local shell_now palette_now
  shell_now="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
  palette_now="$(current_palette)"
  cat <<EOF

────────────────────────────────────────────────────────────
 terminal-setup.sh — interactive setup
   User:        $TARGET_USER
   Distro:      ${PRETTY_NAME:-unknown}
   Login shell: ${shell_now:-unknown}
   Plugin dir:  $ZSH_CUSTOM/plugins
   Theme:       ${palette_now:-unknown}
────────────────────────────────────────────────────────────
   1) Full setup            (backup + all steps, in order)
   2) Backup configs
   3) Install packages      (apt + eza/exa + starship + atuin)
   4) Set zsh as login shell
   5) Install Nerd Font
   6) Install zsh plugins   (fzf-tab, fast-syntax-highlighting, autosuggestions)
   7) Write shell configs   (.zshrc, starship.toml, tmux.conf)
   8) Verify install
   9) Terminal theme        (Ptyxis color palette)
   r) Restore latest backup
   q) Quit
EOF
}

menu() {
  local choice
  while true; do
    print_menu
    if ! read -r -p "Select> " choice </dev/tty; then
      echo
      return 0
    fi
    case "$choice" in
      1) run_full ;;
      2) do_backup ;;
      3) do_packages ;;
      4) do_shell ;;
      5) do_font ;;
      6) do_plugins ;;
      7) do_configs ;;
      8) do_verify ;;
      9) do_theme ;;
      r|R) do_restore ;;
      q|Q) echo "Bye."; return 0 ;;
      "") continue ;;
      *) warn "Invalid choice: '$choice'"; continue ;;
    esac
    echo
    read -r -p "Press Enter to return to the menu..." _ </dev/tty || true
  done
}

usage() {
  cat <<USAGE
Usage: ${0##*/} [--all|-y|--yes] [--theme NAME] [--help]

  (no args)     interactive numbered menu
  --all, -y     run the full setup non-interactively
  --theme NAME  apply a Ptyxis color palette and exit (e.g. --theme "Catppuccin Mocha")
  --help        show this help

Env vars:
  PTYXIS_PALETTE="Catppuccin Mocha"   palette applied during --all
USAGE
}

main() {
  log "Detected ${PRETTY_NAME:-unknown} (${OS_ID} ${OS_VER}, ${OS_CODENAME})"
  [[ "$OS_ID" == "ubuntu" ]] || warn "Not Ubuntu (${OS_ID}); package choices fall back to probing"

  case "${1:-}" in
    --help|-h) usage; return 0 ;;
    --all|--yes|-y) echo; run_full; print_finish; return 0 ;;
    --theme)
      PTYXIS_PALETTE="${2:-}"
      if [[ -z "$PTYXIS_PALETTE" ]]; then
        warn "--theme needs a palette name"
        usage
        return 1
      fi
      apply_palette "$PTYXIS_PALETTE"
      return 0 ;;
    --theme=*)
      PTYXIS_PALETTE="${1#--theme=}"
      apply_palette "$PTYXIS_PALETTE"
      return 0 ;;
  esac

  # No TTY on stdin -> cannot prompt; behave like --all.
  if [[ ! -t 0 && ! -e /dev/tty ]]; then
    warn "No terminal available; running full setup non-interactively"
    run_full
    print_finish
    return 0
  fi

  menu
}

main "$@"

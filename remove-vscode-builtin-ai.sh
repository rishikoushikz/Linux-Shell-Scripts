#!/usr/bin/env bash
#
# remove-vscode-builtin-ai.sh
# ---------------------------------------------------------------------------
# Disables / removes the AI that ships INSIDE Visual Studio Code (the built-in
# chat + the bundled "GitHub Copilot Chat" extension), while deliberately
# leaving all EXTENSION-BASED AI (e.g. google.google-antigravity, Copilot,
# Gemini, Continue, ...) untouched.
#
# It does NOT touch the standalone "Antigravity IDE" application.
#
# Everything is backed up first and can be reverted with:  --restore
#
# Tested against: code 1.141.1  (product.json defaultChatAgent.chatExtensionId)
# ---------------------------------------------------------------------------
set -euo pipefail

VERSION="1.0.0"

# --- paths (override via env if your install differs) -----------------------
CODE_USER_DIR="${CODE_USER_DIR:-$HOME/.config/Code/User}"
CODE_APP_DIR="${CODE_APP_DIR:-/usr/share/code/resources/app}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/.config/Code/ai-removal-backups}"

GLOBAL_STORAGE="$CODE_USER_DIR/globalStorage"
STATE_DB="$GLOBAL_STORAGE/state.vscdb"
SETTINGS="$CODE_USER_DIR/settings.json"
MODELS="$CODE_USER_DIR/chatLanguageModels.json"
ARGV="$HOME/.config/Code/argv.json"

# --- built-in (bundled) AI identifiers --------------------------------------
CHAT_EXT_ID="github.copilot-chat"             # bundled GitHub Copilot Chat
JSTS_EXT_ID="typescriptteam.jsts-chat-features"  # bundled JS/TS chat features
DISABLED_KEY="extensionsIdentifiers/disabled"

# --- flags -------------------------------------------------------------------
DRY_RUN=0; FORCE=0; PURGE=0; HARD=0; RESTORE=0

if [ -t 1 ]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_0=
fi
info(){ printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok(){   printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
err(){  printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die(){  err "$*"; exit 1; }
step(){ if [ "$DRY_RUN" = 1 ]; then printf '%s[ dry-run ]%s %s\n' "$C_Y" "$C_0" "$*"; else "$@"; fi; }

usage(){
  cat <<EOF
remove-vscode-builtin-ai.sh v$VERSION

Disable/remove the AI built into VS Code (built-in chat + bundled
GitHub Copilot Chat). Extension-based AI is left alone.

USAGE
  ./remove-vscode-builtin-ai.sh [options]

OPTIONS
  -n, --dry-run     Show what would change; write nothing.
  -f, --force       Kill running VS Code instead of aborting.
      --purge-data  Also remove built-in chat/agent session state
                    (agent-host-*, empty chat sessions, workspace chatSessions).
      --hard        Physically move the bundled extension folders aside
                    (needs write access to $CODE_APP_DIR; reverted on update).
      --restore     Restore the most recent backup and re-enable everything.
  -h, --help        This help.

NOTES
  * VS Code must be closed (state is written to globalStorage/state.vscdb).
  * Built-in chat/Copilot is compiled into the binary; this disables it and
    wipes its state. For a build with the AI code physically absent, use a
    non-AI distribution such as VSCodium.
  * Env overrides: CODE_USER_DIR, CODE_APP_DIR, BACKUP_ROOT
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run)   DRY_RUN=1 ;;
    -f|--force)     FORCE=1 ;;
    --purge-data)   PURGE=1 ;;
    --hard)         HARD=1 ;;
    --restore)      RESTORE=1 ;;
    -h|--help)      usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

export DRY_RUN CHAT_EXT_ID JSTS_EXT_ID DISABLED_KEY

# ===========================================================================
# Embedded Python helper: JSONC-tolerant settings merge + sqlite state edit
# ===========================================================================
PYPROG=$(cat <<'PY'
import sys, os, re, json, sqlite3

def strip_jsonc(text):
    out=[]; i=0; n=len(text); in_str=False; esc=False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if esc: esc=False
            elif c=='\\': esc=True
            elif c=='"': in_str=False
            i+=1; continue
        if c=='"':
            in_str=True; out.append(c); i+=1; continue
        if c=='/' and i+1<n and text[i+1]=='/':
            while i<n and text[i] not in '\r\n': i+=1
            continue
        if c=='/' and i+1<n and text[i+1]=='*':
            i+=2
            while i+1<n and not (text[i]=='*' and text[i+1]=='/'): i+=1
            i+=2
            continue
        out.append(c); i+=1
    s=''.join(out)
    s=re.sub(r',(\s*[}\]])', r'\1', s)   # drop trailing commas
    return s

def load_jsonc(path, default):
    if not os.path.exists(path) or os.path.getsize(path)==0:
        return default
    with open(path, encoding='utf-8') as f:
        raw=f.read()
    try:
        return json.loads(raw)
    except Exception:
        return json.loads(strip_jsonc(raw))

def cmd_settings(path, dry):
    data = load_jsonc(path, {})
    if not isinstance(data, dict):
        data = {}
    desired = {
        'chat.disableAIFeatures': True,
        'github.copilot.enable': {'*': False},
        'inlineChat.enable': False,
    }
    changed = {k: v for k, v in desired.items() if data.get(k) != v}
    if not changed:
        print('settings:already'); return
    if dry:
        print('settings:dry ' + json.dumps(changed)); return
    for k, v in changed.items():
        data[k] = v
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=4); f.write('\n')
    os.replace(tmp, path)
    print('settings:applied ' + json.dumps(changed))

def _load_disabled(con, key):
    row = con.execute("SELECT value FROM ItemTable WHERE key=?", (key,)).fetchone()
    if not row or row[0] in (None, ''):
        return []
    v = row[0]
    if isinstance(v, (bytes, bytearray)):
        v = v.decode('utf-8', 'replace')
    try:
        arr = json.loads(v)
    except Exception:
        return []
    return arr if isinstance(arr, list) else []

def _ids(arr):
    s = set()
    for e in arr:
        if isinstance(e, dict) and e.get('id'):
            s.add(str(e['id']).lower())
        elif isinstance(e, str):
            s.add(e.lower())
    return s

def cmd_set_ext(db, dry, add, ids):
    if not os.path.exists(db):
        print('ext:nodb'); return
    key = os.environ['DISABLED_KEY']
    want = [i.lower() for i in ids]
    con = sqlite3.connect(db)
    try:
        arr = _load_disabled(con, key)
        have = _ids(arr)
        if add:
            new = [i for i in want if i not in have]
            for i in new:
                arr.append({'id': i})
        else:
            wset = set(want)
            new = [i for i in want if i in have]
            arr = [e for e in arr if not (
                (isinstance(e, dict) and str(e.get('id', '')).lower() in wset) or
                (isinstance(e, str) and e.lower() in wset))]
        if not new:
            print('ext:already'); return
        if dry:
            print('ext:dry ' + json.dumps(new)); return
        con.execute("INSERT OR REPLACE INTO ItemTable(key,value) VALUES(?,?)",
                    (key, json.dumps(arr)))
        con.commit()
        print('ext:applied ' + json.dumps(new))
    finally:
        con.close()

def cmd_reset_models(path, dry):
    if not os.path.exists(path):
        print('models:absent'); return
    try:
        cur = load_jsonc(path, [])
    except Exception:
        cur = None
    if cur == []:
        print('models:already'); return
    if dry:
        print('models:dry'); return
    with open(path, 'w', encoding='utf-8') as f:
        f.write('[]\n')
    print('models:applied')

def main():
    mode = sys.argv[1]
    args = sys.argv[2:]
    dry = os.environ.get('DRY_RUN', '0') == '1'
    if mode == 'settings':
        cmd_settings(args[0], dry)
    elif mode == 'disable-ext':
        cmd_set_ext(args[0], dry, True, args[1:])
    elif mode == 'enable-ext':
        cmd_set_ext(args[0], dry, False, args[1:])
    elif mode == 'reset-models':
        cmd_reset_models(args[0], dry)
    else:
        sys.exit('unknown mode: ' + mode)

main()
PY
)

py(){ printf '%s' "$PYPROG" | python3 - "$@"; }

# ===========================================================================
# Helpers
# ===========================================================================
code_running(){
  pgrep -x code >/dev/null 2>&1 || pgrep -x code-insiders >/dev/null 2>&1
}

BK=""        # backup dir, set in main
MANIFEST=""  # manifest path

move_aside(){
  local orig="$1"
  [ -e "$orig" ] || return 0
  local dest="$BK/moved/$(printf '%s' "$orig" | tr '/' '_')"
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s[ dry-run ]%s mv %s -> %s\n' "$C_Y" "$C_0" "$orig" "$dest"
    return 0
  fi
  mkdir -p "$BK/moved"
  mv "$orig" "$dest"
  printf 'MOVE\t%s\t%s\n' "$orig" "$dest" >> "$MANIFEST"
  ok "moved aside: $orig"
}

backup_file(){
  local f="$1"
  [ -f "$f" ] || return 0
  local dest="$BK/$(basename "$f")"
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s[ dry-run ]%s cp -a %s -> %s\n' "$C_Y" "$C_0" "$f" "$dest"
    return 0
  fi
  cp -a "$f" "$dest"
  ok "backed up: $f"
}

# ===========================================================================
# Restore
# ===========================================================================
do_restore(){
  [ -d "$BACKUP_ROOT" ] || die "No backups found in $BACKUP_ROOT"
  local bk
  bk="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -n 1 || true)"
  [ -n "$bk" ] || die "No backup directories in $BACKUP_ROOT"
  bk="${bk%/}"
  info "Restoring from $bk"

  if [ -f "$bk/settings.json" ]; then
    step cp -a "$bk/settings.json" "$SETTINGS"; ok "restored $SETTINGS"
  fi
  if [ -f "$bk/chatLanguageModels.json" ]; then
    step cp -a "$bk/chatLanguageModels.json" "$MODELS"; ok "restored $MODELS"
  fi
  if [ -f "$bk/state.vscdb" ]; then
    step cp -a "$bk/state.vscdb" "$STATE_DB"; ok "restored $STATE_DB"
  fi
  if [ -f "$bk/argv.json" ]; then
    step cp -a "$bk/argv.json" "$ARGV"; ok "restored $ARGV"
  fi
  if [ -f "$bk/manifest.tsv" ]; then
    while IFS=$'\t' read -r action orig saved; do
      [ -n "${action:-}" ] || continue
      if [ "$action" = "MOVE" ] && [ -e "$saved" ]; then
        if [ "$DRY_RUN" = 1 ]; then
          printf '%s[ dry-run ]%s mv %s -> %s\n' "$C_Y" "$C_0" "$saved" "$orig"
        else
          mkdir -p "$(dirname "$orig")"
          mv "$saved" "$orig"
          ok "restored $orig"
        fi
      fi
    done < "$bk/manifest.tsv"
  fi
  ok "Restore complete. Start VS Code again."
}

# ===========================================================================
# Main
# ===========================================================================
main(){
  info "remove-vscode-builtin-ai.sh v$VERSION"
  [ "$DRY_RUN" = 1 ] && warn "DRY-RUN: nothing will be changed."

  if [ ! -d "$CODE_USER_DIR" ]; then
    die "VS Code user dir not found: $CODE_USER_DIR (set CODE_USER_DIR)"
  fi

  if code_running; then
    if [ "$FORCE" = 1 ]; then
      warn "VS Code is running - terminating it (--force)."
      step pkill -x code || true
      step pkill -x code-insiders || true
      sleep 1
    elif [ "$DRY_RUN" = 1 ]; then
      warn "VS Code is running (ok for dry-run)."
    else
      die "VS Code is running. Close it first, or pass --force."
    fi
  fi

  if [ "$RESTORE" = 1 ]; then
    do_restore
    exit 0
  fi

  # --- backup ---------------------------------------------------------------
  if [ "$DRY_RUN" = 1 ]; then
    BK="$BACKUP_ROOT/<timestamp>"
  else
    BK="$BACKUP_ROOT/$(date -u +%Y%m%d-%H%M%S)"
    mkdir -p "$BK"
  fi
  MANIFEST="$BK/manifest.tsv"

  info "Backing up current state"
  backup_file "$SETTINGS"
  backup_file "$MODELS"
  backup_file "$STATE_DB"
  backup_file "$ARGV"

  # --- 1. settings switches -------------------------------------------------
  info "1/4 Disabling built-in AI features (settings.json)"
  res="$(py settings "$SETTINGS")"
  case "$res" in
    settings:already) ok "settings already AI-off" ;;
    settings:dry*)    warn "${res#settings:dry }" ;;
    settings:applied*) ok "set ${res#settings:applied }" ;;
  esac

  # --- 2. disable bundled extensions ---------------------------------------
  info "2/4 Disabling bundled extensions (state.vscdb)"
  res="$(py disable-ext "$STATE_DB" "$CHAT_EXT_ID" "$JSTS_EXT_ID")"
  case "$res" in
    ext:nodb)       warn "state.vscdb not found; skipped" ;;
    ext:already)    ok "bundled extensions already disabled" ;;
    ext:dry*)       warn "${res#ext:dry }" ;;
    ext:applied*)   ok "disabled ${res#ext:applied }" ;;
  esac

  # --- 3. wipe built-in Copilot state --------------------------------------
  info "3/4 Removing built-in Copilot state"
  move_aside "$GLOBAL_STORAGE/github.copilot-chat"

  if [ -f "$MODELS" ]; then
    res="$(py reset-models "$MODELS")"
    case "$res" in
      models:applied) ok "reset chatLanguageModels.json to []" ;;
      models:already|models:absent) ok "chatLanguageModels.json already empty" ;;
      models:dry) warn "would reset chatLanguageModels.json" ;;
    esac
  fi

  if [ "$PURGE" = 1 ]; then
    info "    --purge-data: removing agent/chat session state"
    for d in "$GLOBAL_STORAGE"/agent-host* ; do
      [ -e "$d" ] || continue
      move_aside "$d"
    done
    move_aside "$GLOBAL_STORAGE/emptyWindowChatSessions"
    if [ -d "$CODE_USER_DIR/workspaceStorage" ]; then
      for d in "$CODE_USER_DIR"/workspaceStorage/*/chatSessions ; do
        [ -e "$d" ] || continue
        move_aside "$d"
      done
    fi
  fi

  # --- 4. optional hard removal of bundled extension dirs -------------------
  info "4/4 Bundled extension folders"
  if [ "$HARD" = 1 ]; then
    for d in "$CODE_APP_DIR/extensions/copilot" \
             "$CODE_APP_DIR/extensions/TypeScriptTeam.jsts-chat-features" ; do
      [ -e "$d" ] || continue
      if [ -w "$(dirname "$d")" ]; then
        if [ "$DRY_RUN" = 1 ]; then
          printf '%s[ dry-run ]%s mv %s -> %s.ai-disabled\n' "$C_Y" "$C_0" "$d" "$d"
        else
          mv "$d" "$d.ai-disabled"
          printf 'MOVE\t%s\t%s\n' "$d" "$d.ai-disabled" >> "$MANIFEST"
          ok "disabled bundled dir: $d"
        fi
      else
        warn "no write access to $(dirname "$d"); re-run with sudo for --hard"
      fi
    done
  else
    ok "left in place (use --hard to physically move them aside)"
  fi

  # --- summary --------------------------------------------------------------
  printf '\n'
  ok "Done."
  if [ "$DRY_RUN" = 1 ]; then
    warn "Dry-run only - nothing was written. Re-run without -n to apply."
  else
    info "Backup: $BK"
    info "Revert with:  $0 --restore"
  fi
  info "Extension-based AI (Antigravity, etc.) was NOT touched."
}

main

#!/usr/bin/env bash
# user-path.sh <dir>: makes the programs in <dir> (unitask) runnable from the user's own terminals,
# not only from Claude's Bash tool. Idempotent; prints "path-added: <what>" only when it changed
# something, so the SessionStart hook can tell the user to open a new terminal.
#   Linux, macOS, WSL: symlink ~/.local/bin/<program> -> <dir>/<program>; if ~/.local/bin is not in
#     PATH, a marked block that adds it goes into the existing shell rc files (once).
#   Windows (Git Bash): <dir> is added to the user's PATH in the registry, which cmd, PowerShell and
#     new Git Bash windows all read.
set -uo pipefail

DIR="${1:?usage: user-path.sh <dir>}"
MARK="# mospolytech-lms: unitask"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    win_dir="$(cygpath -w "$DIR")"
    # Reads and writes the user PATH without expanding %VARS% in it; prints "added" when it changed.
    out="$(powershell.exe -NoProfile -Command "
      \$dir = '$win_dir'
      \$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', \$true)
      \$cur = \$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
      \$parts = @(\$cur -split ';' | Where-Object { \$_ -ne '' })
      if (\$parts -notcontains \$dir) {
        \$new = ((\$parts + \$dir) -join ';')
        \$key.SetValue('Path', \$new, 'ExpandString')
        # Any user-scope SetEnvironmentVariable broadcasts WM_SETTINGCHANGE, so Explorer and the
        # terminals it starts pick up the new PATH without a logout.
        [Environment]::SetEnvironmentVariable('MOSPOLYTECH_LMS_PATH_REFRESH', \$null, 'User')
        'added'
      }" 2>/dev/null | tr -d '\r')"
    [[ "$out" == *added* ]] && echo "path-added: $win_dir → PATH пользователя Windows"
    exit 0 ;;
esac

LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN" || exit 0
for prog in "$DIR"/*; do
  [[ -f "$prog" && -x "$prog" ]] || continue
  link="$LOCAL_BIN/${prog##*/}"
  if [[ "$(readlink "$link" 2>/dev/null)" != "$prog" ]]; then
    # Never replace a real program the user installed there; only our own (possibly stale) symlinks.
    if [[ -e "$link" && ! -L "$link" ]]; then
      echo "path-skipped: $link уже существует и это не ссылка плагина"
      continue
    fi
    ln -sfn "$prog" "$link" && echo "path-added: $link"
  fi
done

case ":${PATH}:" in
  *":$LOCAL_BIN:"*) exit 0 ;;
esac
# ~/.local/bin is not in PATH for this process. Shell rc files decide what new terminals get, so add
# the block once to the rc files that exist (and ~/.profile, read by login shells and many desktops).
rcs=("$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc")
[[ "$(uname -s)" == Darwin ]] && rcs+=("$HOME/.zprofile" "$HOME/.bash_profile")
for rc in "${rcs[@]}"; do
  [[ -f "$rc" || "$rc" == "$HOME/.profile" ]] || continue
  grep -qF "$MARK" "$rc" 2>/dev/null && continue
  printf '\n%s\ncase ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n' "$MARK" >> "$rc" \
    && echo "path-added: ~/.local/bin → PATH в ~/${rc#"$HOME"/}"
done
exit 0

#!/usr/bin/env bash
# 手元の Mac / Linux から実行し、リモートに Codex CLI を導入する。
#
# 使い方（リポジトリのルートから）:
#   bash script/setup-codex/setup-codex-ec2.sh isu1
#   SSH_USER=ubuntu SSH_KEY=~/.ssh/example.pem \
#     bash script/setup-codex/setup-codex-ec2.sh example.com
#   bash script/setup-codex/setup-codex-ec2.sh --help
#
# 環境変数:
#   SSH_HOST      接続先のホスト名・IPv4・SSH alias（引数を優先。未指定なら対話入力）
#   SSH_USER      SSH 接続ユーザー（既定: SSH 設定に従う）
#   SSH_KEY       秘密鍵のパス（既定: SSH 設定・ssh-agent に従う）
#   INSTALL_USER  導入先ユーザー（既定: isucon）
#
# 導入先ユーザーは作成済みであること。接続ユーザーが異なる場合は、
# sudo -n -iu で切り替えられること。認証設定は導入後に各自で行う。
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: setup-codex-ec2.sh [HOST_OR_SSH_ALIAS]

Install Codex CLI remotely as INSTALL_USER (default: isucon).
SSH_HOST       Host or ~/.ssh/config alias; positional argument takes precedence
SSH_USER       SSH login user (default: use SSH config / ssh default)
SSH_KEY        Optional private key path (default: use SSH config / ssh-agent)
INSTALL_USER   Remote installation user (default: isucon)

Example:
  SSH_USER=ubuntu SSH_KEY=~/.ssh/example.pem bash script/setup-codex/setup-codex-ec2.sh example.com
  bash script/setup-codex/setup-codex-ec2.sh isu1
HELP
}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# -le 1 ]] || { usage >&2; exit 2; }
SSH_HOST="${1:-${SSH_HOST:-}}"
SSH_USER="${SSH_USER:-}"
SSH_KEY="${SSH_KEY:-}"
INSTALL_USER="${INSTALL_USER:-isucon}"
if [[ -z "$SSH_HOST" ]]; then
  read -r -p 'Remote hostname, IP or SSH alias: ' SSH_HOST
fi
[[ "$SSH_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || {
  echo 'Enter a hostname, IPv4 address or SSH alias only.' >&2; exit 2
}
[[ "$INSTALL_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
  echo 'Invalid INSTALL_USER.' >&2; exit 2
}
SSH_ARGS=(-o ConnectTimeout=15)
if [[ -n "$SSH_USER" ]]; then
  [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
    echo 'Invalid SSH_USER.' >&2; exit 2
  }
  SSH_ARGS+=(-l "$SSH_USER")
fi
if [[ -n "$SSH_KEY" ]]; then
  [[ -r "$SSH_KEY" ]] || { echo "SSH key not readable: $SSH_KEY" >&2; exit 1; }
  SSH_ARGS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
fi

echo "Installing Codex CLI as $INSTALL_USER on $SSH_HOST..."
ssh "${SSH_ARGS[@]}" "$SSH_HOST" "bash -c 'if [[ \"\$(id -un)\" == $INSTALL_USER ]]; then exec bash -s; else exec sudo -n -iu $INSTALL_USER bash -s; fi'" <<'REMOTE'
set -euo pipefail
command -v curl >/dev/null || {
  echo 'curl is missing. Ask a sudo-capable user to run: sudo apt-get update && sudo apt-get install -y curl ca-certificates' >&2
  exit 1
}
installer_file="$(mktemp)"
trap 'rm -f -- "$installer_file"' EXIT
curl --fail --silent --show-error --location --retry 3 \
  https://chatgpt.com/codex/install.sh -o "$installer_file"
CODEX_NON_INTERACTIVE=1 CODEX_INSTALL_DIR="$HOME/.local/bin" sh "$installer_file"
# Cover interactive shells and login shells, which may skip .bashrc.
# Do not create .bash_profile/.bash_login: doing so would shadow .profile.
path_line='export PATH="$HOME/.local/bin:$PATH"'
touch "$HOME/.bashrc" "$HOME/.profile"
for startup_file in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login"; do
  [[ -f "$startup_file" ]] || continue
  if [[ "$(head -n 1 "$startup_file")" != "$path_line" ]]; then
    sed -i '1i export PATH="$HOME/.local/bin:$PATH"' "$startup_file"
  fi
done
export PATH="$HOME/.local/bin:$PATH"
codex --version
echo 'Checking Codex PATH in a fresh Bash login shell...'
env PATH=/usr/bin:/bin bash -lc 'command -v codex && codex --version'
REMOTE

echo "Codex CLI installation and PATH checks completed on $SSH_HOST (user: $INSTALL_USER)."

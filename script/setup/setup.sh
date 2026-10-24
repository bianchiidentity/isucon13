#!/usr/bin/env bash
# 各サーバーで最初に 1 回行う準備。join.sh で全台を同じリポジトリの状態にした後に、各台で root で実行する
#
# 使い方: sudo script/setup/setup.sh --git-user=<GitHub のユーザー名>            準備する
#         sudo script/setup/setup.sh --git-user=<GitHub のユーザー名> --dry-run  行うことを表示するだけ
#
# 1. OS の自動アップデートを止める（base-conf と同じ。apt を使う前に止める）
# 2. /etc/hosts にこのサーバーのホスト名を足す（無いと sudo のたびに「unable to resolve host」が出る）
# 3. setup-tools.sh でツールを入れる（4 で使う jq も）
# 4. isucon の git の作者を、その台を使う人の GitHub のユーザー名にする（サーバー上でのコミットに記録される）
# 済んでいるものは飛ばす。何度実行しても同じ結果になる
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SETUP_DIR/../.." && pwd)"
source "$REPO_DIR/script/lib/common.sh"
require_file "$REPO_DIR/script/deploy/deploy.env"
# shellcheck source=../deploy/deploy.env
source "$REPO_DIR/script/deploy/deploy.env"

GIT_USER=""
DRY=0

parse_args() {
  local arg
  for arg in "$@"; do
    case $arg in
      --git-user=*) GIT_USER="${arg#*=}" ;;
      -n|--dry-run) DRY=1 ;;
      *) die "unknown argument: $arg" ;;
    esac
  done
  if [[ -z $GIT_USER ]]; then
    die "--git-user=<GitHub のユーザー名> を渡す（この台を使う人）"
  fi
  if (( EUID != 0 )); then
    die "sudo で実行する"
  fi
}

# base-conf の stop_auto_updates と同じ。base-conf より先に setup-tools の apt を使うので、ここでも止める。
# 動いたままの自動アップデートは、apt-get update を引き金に数百のパッケージを更新し、MySQL を再起動した（isucon12）
stop_auto_updates() {
  local u
  log "OS の自動アップデート"
  if (( ! DRY )); then
    systemctl stop apt-daily-upgrade.service apt-daily.service unattended-upgrades.service 2> /dev/null || true
    systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2> /dev/null || true
    # 更新の途中で止めたときに、壊れたパッケージが残っていないか
    dpkg --audit
  fi
  for u in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service; do
    printf '%s: %s\n' "$u" "$(systemctl is-enabled "$u" 2> /dev/null || true)"
  done
}

setup_hosts() {
  local name
  name="$(hostname)"
  log "/etc/hosts"
  if getent hosts "$name" > /dev/null; then
    echo "引ける: $name"
    return 0
  fi
  echo "足す: 127.0.1.1 $name"
  if (( ! DRY )); then
    echo "127.0.1.1 $name" >> /etc/hosts
  fi
}

setup_tools() {
  if (( DRY )); then
    "$REPO_DIR/script/setup-tools/setup-tools.sh" --dry-run
  else
    "$REPO_DIR/script/setup-tools/setup-tools.sh"
  fi
}

# メールアドレスは GitHub の noreply（<ID>+<ユーザー名>@users.noreply.github.com）にし、コミットをその人のアカウントに結び付ける
setup_git_author() {
  local json id email
  log "isucon の git の作者"
  if (( DRY )) && ! command -v jq > /dev/null; then
    echo "設定する: $GIT_USER（ID は setup-tools が jq を入れた後に GitHub の API で引く）"
    return 0
  fi
  if ! json="$(curl -fsS "https://api.github.com/users/$GIT_USER")"; then
    die "GitHub のユーザー $GIT_USER を引けない。名前を確かめる"
  fi
  id="$(jq -r '.id // empty' <<< "$json")"
  if [[ ! $id =~ ^[0-9]+$ ]]; then
    die "GitHub の応答から $GIT_USER の ID を取れない"
  fi
  email="$id+$GIT_USER@users.noreply.github.com"

  if [[ $(sudo -u "$APP_USER" -H git config --global user.name || true) == "$GIT_USER" \
     && $(sudo -u "$APP_USER" -H git config --global user.email || true) == "$email" ]]; then
    echo "設定済み: $GIT_USER <$email>"
    return 0
  fi
  echo "設定する: $GIT_USER <$email>"
  if (( ! DRY )); then
    sudo -u "$APP_USER" -H git config --global user.name "$GIT_USER"
    sudo -u "$APP_USER" -H git config --global user.email "$email"
  fi
}

main() {
  parse_args "$@"
  stop_auto_updates
  setup_hosts
  setup_tools
  setup_git_author
}

main "$@"

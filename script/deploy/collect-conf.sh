#!/usr/bin/env bash
# サーバーの今の設定ファイルを、リポジトリの conf/ に集める。当日の最初（G1 の base-conf を入れた後）に 1 回実行し、commit する
#
# 使い方: script/deploy/collect-conf.sh              conf/default/ に集める（全サーバー共通）。HOST_PATHS は conf/<ホスト名>/
#         script/deploy/collect-conf.sh --name=isu1  HOST_PATHS を conf/isu1/ に集める（./deploy --server= に渡す名前に合わせる）
#         script/deploy/collect-conf.sh --to=isu1    すべてを conf/isu1/ に集める（そのサーバーだけの設定）
#
# 集めるのは deploy.env の COLLECT_PATHS。ディレクトリなら中のファイルすべて。
# 集めたファイルは、./deploy が同じ絶対パスに反映する。集めた後は ./deploy --dry-run で差分が出ないことを確かめる
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$DEPLOY_DIR/../.." && pwd)"
# shellcheck source=deploy.env
source "$DEPLOY_DIR/deploy.env"

TO=default
# ./deploy と同じく、--server が無いときの名前はホスト名
NAME="$(hostname -s)"
case "${1:-}" in
  "") ;;
  --to=*) TO="${1#*=}" ;;
  --name=*) NAME="${1#*=}" ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

is_host_path() {  # $1: 集めるファイルの絶対パス
  local p
  for p in "${HOST_PATHS[@]:-}"; do
    [[ -n $p && ( $1 == "$p" || $1 == "$p"/* ) ]] && return 0
  done
  return 1
}

for p in "${COLLECT_PATHS[@]}"; do
  if ! sudo test -e "$p"; then echo "ない: $p"; continue; fi
  while IFS= read -r f; do
    to=$TO
    # 台ごとに中身が違うファイルを conf/default に入れると、ほかの台に配られてしまう
    [[ $TO == default ]] && is_host_path "$f" && to=$NAME
    dst="$REPO_DIR/conf/$to$f"
    mkdir -p "$(dirname "$dst")"
    sudo cat "$f" > "$dst"
    echo "$f → conf/$to$f"
  done < <(sudo find "$p" -type f)
done
echo "集めたら git diff で確かめて commit し、./deploy --dry-run で差分が出ないことを確かめる"

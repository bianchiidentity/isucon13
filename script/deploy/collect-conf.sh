#!/usr/bin/env bash
# サーバーの今の設定ファイルを、リポジトリの conf/ に集める。当日の最初（G1 の base-conf を入れた後）に 1 回実行し、commit する
#
# 使い方: script/deploy/collect-conf.sh             conf/default/ に集める（全サーバー共通）
#         script/deploy/collect-conf.sh --to=isu1   conf/isu1/ に集める（そのサーバーだけの設定）
#
# 集めるのは deploy.env の COLLECT_PATHS。ディレクトリなら中のファイルすべて。
# 集めたファイルは、./deploy が同じ絶対パスに反映する
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$DEPLOY_DIR/../.." && pwd)"
# shellcheck source=deploy.env
source "$DEPLOY_DIR/deploy.env"

TO=default
case "${1:-}" in
  "") ;;
  --to=*) TO="${1#*=}" ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

for p in "${COLLECT_PATHS[@]}"; do
  if ! sudo test -e "$p"; then echo "ない: $p"; continue; fi
  while IFS= read -r f; do
    dst="$REPO_DIR/conf/$TO$f"
    mkdir -p "$(dirname "$dst")"
    sudo cat "$f" > "$dst"
    echo "$f → conf/$TO$f"
  done < <(sudo find "$p" -type f)
done
echo "集めたら git diff で確かめて commit する"

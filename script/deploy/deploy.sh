#!/usr/bin/env bash
# リポジトリの内容をサーバーに反映する。入口はリポジトリ直下の ./deploy
#
# 使い方: ./deploy                          このサーバーだけに、作業ツリーの内容を反映する（前半: 1 人 1 台）
#         ./deploy --server=isu1,isu2,isu3  各サーバーに ssh し、このサーバーの HEAD を並列で反映する（後半: 複数台）
#         ./deploy --serial --server=...    1 台ずつ反映し、失敗したらそこで止める
#         ./deploy --dry-run [...]          変わる内容を表示するだけ
#         ./deploy --allow-drop [...]       sqldef の DROP（列やインデックスの削除）も適用する
#         ./deploy --only=nginx,app [...]   指定した段だけを実行する（common mysql nginx app。ログのローテートは毎回）
#
# 何を反映するかは roles.env のサーバーごとの役割で決まる（書いていなければ nginx app mysql の全部）。
# 順番: 共通の設定（systemd、sysctl、環境変数のファイル）→ MySQL → nginx → app。最後に反映した版を記録する
# 中身は lib/ に分けてある: conf.sh（設定ファイルの反映）、steps.sh（各段）、remote.sh（複数台）
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$DEPLOY_DIR/../.." && pwd)"
source "$REPO_DIR/script/lib/common.sh"
# shellcheck source=deploy.env
source "$DEPLOY_DIR/deploy.env"
# shellcheck source=roles.env
source "$DEPLOY_DIR/roles.env"
source "$DEPLOY_DIR/lib/conf.sh"
source "$DEPLOY_DIR/lib/steps.sh"
source "$DEPLOY_DIR/lib/remote.sh"

SERVERS="" NAME="" LOCAL=0 DRY=0 ALLOW_DROP=0 ONLY="" SERIAL=0
for arg in "$@"; do
  case $arg in
    --server=*) SERVERS="${arg#*=}" ;;
    --serial) SERIAL=1 ;;
    -n|--dry-run) DRY=1 ;;
    --allow-drop) ALLOW_DROP=1 ;;
    --only=*) ONLY="${arg#*=}" ;;
    --local) LOCAL=1 ;;               # 内部用: --server から ssh で呼ばれたとき
    --name=*) NAME="${arg#*=}" ;;     # 内部用: そのときのサーバー名
    -h|--help) sed -n '4,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
for step in ${ONLY//,/ }; do
  case $step in common|mysql|nginx|app) ;; *) die "--only に使えるのは common mysql nginx app: $step" ;; esac
done

dry() { (( DRY )); }

# --server の dry-run は一時的な worktree で動く。SCHEMA_FILE が元のリポジトリの中を指していたら、worktree の同じファイルに読み替える
if [[ -n ${DEPLOY_ORIG_REPO:-} && -n ${SCHEMA_FILE:-} ]]; then
  real="$(realpath -m "$SCHEMA_FILE")"
  [[ $real == "$DEPLOY_ORIG_REPO"/* ]] && SCHEMA_FILE="$REPO_DIR/${real#"$DEPLOY_ORIG_REPO"/}"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

deploy_local() {
  NAME="${NAME:-$(hostname -s)}"
  ROLES="$(roles_of "$NAME")"
  # 同じサーバーで 2 つの ./deploy が同時に動くと、片方の巻き戻しがもう片方の反映を消す
  exec 9> /tmp/isucon-deploy.lock
  flock -w 60 9 || die "別の ./deploy が 60 秒たっても終わらない"

  log "サーバー: ${NAME}、役割: ${ROLES}${ONLY:+、実行する段: ${ONLY}}$(dry && echo '（dry-run）')"
  run_step common
  run_step mysql
  run_step nginx
  run_step app
  conf::tidy_manifest
  deployed::record
  (( ${#CONF_CHANGED[@]} )) && echo "変える前のファイル: $CONF_BACKUP"
  log "完了（${NAME}）所要時間（秒）: ${STEP_TIMES[*]:-なし}"
}

if [[ -n $SERVERS && $LOCAL -eq 0 ]]; then remote::fan_out; else deploy_local; fi

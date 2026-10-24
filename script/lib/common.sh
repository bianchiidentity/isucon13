# deploy と bench で共有する関数。source して使う

log() { printf '\n== %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# このサーバーの名前（isu1 など）。join.sh が全台に書く。conf/<名前>/ と roles.env を引くのに使い、AWS のホスト名は使わない
SERVER_NAME_FILE=/etc/isucon-server-name

server_name() {
  if [[ ! -s $SERVER_NAME_FILE ]]; then
    die "$SERVER_NAME_FILE が無く、このサーバーの名前が決まっていない。1 台目で script/setup-repo/join.sh を先に実行する"
  fi
  cat "$SERVER_NAME_FILE"
}

# roles.env に書いたサーバーごとの役割。書いていなければ全部入り
roles_of() {  # $1: サーバー名
  local var="ROLES_${1//[^a-zA-Z0-9_]/_}"
  echo "${!var:-nginx app mysql}"
}

role_has() {  # $1: 役割の一覧（roles_of の出力）、$2: 役割
  [[ " $1 " == *" $2 "* ]]
}

require_file() {  # $1: 問題ごとに書くファイル。無ければ、テンプレートから写すよう伝えて止まる
  if [[ ! -f $1 ]]; then
    die "$1 が無い。$1.template を写して、問題に合わせて書く"
  fi
}

require_values() {  # $@: 変数名。deploy.env の値が空なら、名前を並べて止まる（テンプレートから写したまま埋めていない）
  local v empty=()
  for v in "$@"; do
    if [[ -z ${!v:-} ]]; then empty+=("$v"); fi
  done
  if (( ${#empty[@]} )); then
    die "deploy.env の ${empty[*]} が空。README の「問題に合わせる」で埋める"
  fi
}

elapsed() {  # $1: 開始時の ${EPOCHREALTIME}。経過秒数を小数 1 桁で出す
  awk -v a="$1" -v b="$EPOCHREALTIME" 'BEGIN { printf "%.1f", b - a }'
}

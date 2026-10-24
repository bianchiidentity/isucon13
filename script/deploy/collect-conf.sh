#!/usr/bin/env bash
# サーバーの今の設定ファイルを、リポジトリの conf/ に集める。当日の最初（誰も触る前、G1 の base-conf を入れた直後）に 1 回実行し、commit する
#
# 使い方: script/deploy/collect-conf.sh --server=isu1,isu2,isu3  全台のハッシュを比べ、全台で同じなら conf/default/、違えば conf/<サーバー名>/ に集める
#         script/deploy/collect-conf.sh --to=isu1                  このサーバーのファイルをすべて conf/isu1/ に集める（そのサーバーだけの設定）
#
# 集めるのは deploy.env の COLLECT_PATHS。ディレクトリなら中のファイルすべて。
# --server の名前は ./deploy --server= に渡す名前と同じにする（conf/<サーバー名>/ を引く名前になる）。実行するサーバー自身も ssh で入れること。
# 一部の台にしか無いファイルも、台ごとのファイルとして扱う。
# 集めたファイルは、./deploy が同じ絶対パスに反映する。集めた後は ./deploy --dry-run で差分が出ないことを確かめる
set -euo pipefail
# $(...) の中でも set -e を効かせる（ssh の失敗を見逃さない）
shopt -s inherit_errexit

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$DEPLOY_DIR/../.." && pwd)"
source "$REPO_DIR/script/lib/common.sh"
# shellcheck source=deploy.env
source "$DEPLOY_DIR/deploy.env"

# コマンドライン引数から決まる値。読むのは parse_args だけで、ほかの関数には main が引数で渡す
SERVERS="" TO=""
# 各台のハッシュと、その振り分けの結果。bash は連想配列を引数で渡せないので、ここで宣言して関数から読み書きする
declare -A HASH=()      # "サーバー名|パス" → ハッシュ（collect_hashes が書く）
declare -A FILES=()     # パス → 1。全台のファイルの和集合（collect_hashes が書く）
COMMON=()               # 全台で同じファイルのパス（classify が書く）
declare -A PER_HOST=()  # サーバー名 → 台ごとのファイルのパス、改行区切り（classify が書く）

usage() { echo "使い方: $0 --server=isu1,isu2,isu3 | --to=<名前>" >&2; exit 2; }

parse_args() {
  (( $# == 1 )) || usage
  case "$1" in
    --server=?*) SERVERS="${1#*=}" ;;
    --to=?*) TO="${1#*=}" ;;
    *) usage ;;
  esac
}

# 引数のパスの下のファイルを「ハッシュ  パス」で 1 行ずつ出す。ssh の先でも動くよう、関数ごと送る
list_hashes() {  # $@: 集めるパス
  local p
  for p in "$@"; do
    if sudo test -e "$p"; then sudo find "$p" -type f; else echo "ない: $p" >&2; fi
  done | sort | xargs -r -d '\n' sudo sha256sum
}

# --to: このサーバーのファイルを、すべて <置き場所> に集める
collect_local() {  # $1: 置き場所のディレクトリ、残り: 集めるパス
  local dir=$1 f; shift
  while read -r _ f; do
    mkdir -p "$(dirname "$dir$f")"
    sudo cat "$f" > "$dir$f"
    echo "$f → $dir$f"
  done < <(list_hashes "$@")
}

# --server に渡した名前が、その台の名前（join.sh が書いたもの）と同じか。違うと ./deploy が引かない conf/<名前>/ に集めてしまう
check_name() {  # $1: サーバー名
  local own
  own=$(ssh -n -o BatchMode=yes "$1" "cat $SERVER_NAME_FILE 2> /dev/null || true")
  if [[ $own != "$1" ]]; then
    die "$1 の名前が ${own:-（$SERVER_NAME_FILE が無い）} になっている。join.sh で決めた名前を --server に渡す"
  fi
}

# 1 台のハッシュを HASH と FILES に足す。つながらなければ失敗する（その台に何も無いとみなすと、conf/default を消してしまう）
collect_hashes() {  # $1: サーバー名、残り: 集めるパス
  local h=$1 out sum f; shift
  out=$(ssh -n -o BatchMode=yes "$h" "$(declare -f list_hashes); list_hashes $(printf '%q ' "$@")")
  while read -r sum f; do
    [[ -n $sum ]] || continue
    HASH["$h|$f"]=$sum; FILES["$f"]=1
  done <<< "$out"
}

is_common() {  # $1: パス、残り: サーバー名。全台にあり、ハッシュが同じなら真
  local p=$1 h first; shift
  first="${HASH["$1|$p"]:-}"
  [[ -n $first ]] || return 1
  for h in "$@"; do [[ ${HASH["$h|$p"]:-} == "$first" ]] || return 1; done
}

# ファイルを COMMON と PER_HOST に分け、使わなくなった写しを消す（conf/<サーバー名>/ が conf/default/ より優先されるため、古い写しが残ると効いてしまう）
classify() {  # $1: conf のディレクトリ、残り: サーバー名
  local conf=$1 f h all; shift
  mapfile -t all < <(printf '%s\n' "${!FILES[@]}" | sort)
  for f in "${all[@]}"; do
    if is_common "$f" "$@"; then
      COMMON+=("$f")
      for h in "$@"; do rm -f "$conf/$h$f"; done
    else
      rm -f "$conf/default$f"
      for h in "$@"; do
        if [[ -n ${HASH["$h|$f"]:-} ]]; then PER_HOST[$h]+="$f"$'\n'; else rm -f "$conf/$h$f"; fi
      done
    fi
  done
}

fetch() {  # $1: 置き場所のディレクトリ、$2: 取る台、残り: ファイルの絶対パス
  local dir=$1 h=$2 f; shift 2
  mkdir -p "$dir"
  # -n: ssh が呼び出し元の標準入力を読まないように
  ssh -n -o BatchMode=yes "$h" "sudo tar -C / -cf - $(printf '%q ' "${@#/}")" \
    | tar -C "$dir" --no-same-owner --no-same-permissions -xf -
  # tar は実行ビットを残すが、git の差分に出ないよう、前と同じく 644 にそろえる
  for f in "$@"; do chmod 644 "$dir$f"; echo "[$h] $f → $dir$f"; done
}

# 共通のファイルは 1 台目から、台ごとのファイルは各台から取る
fetch_all() {  # $1: conf のディレクトリ、残り: サーバー名
  local conf=$1 h fs; shift
  if (( ${#COMMON[@]} )); then fetch "$conf/default" "$1" "${COMMON[@]}"; fi
  for h in "$@"; do
    [[ -n ${PER_HOST[$h]:-} ]] || continue
    mapfile -t fs < <(printf '%s' "${PER_HOST[$h]}")
    fetch "$conf/$h" "$h" "${fs[@]}"
  done
}

print_per_host() {  # $@: サーバー名
  local h
  echo
  echo "台ごとに中身が違う（または一部の台にしか無い）ファイル:"
  for h in "$@"; do printf '%s' "${PER_HOST[$h]:-}" | sed "s|^|  conf/$h|"; done
}

main() {
  parse_args "$@"
  local conf="$REPO_DIR/conf" hosts h
  if [[ -n $TO ]]; then
    collect_local "$conf/$TO" "${COLLECT_PATHS[@]}"
  else
    IFS=, read -ra hosts <<< "$SERVERS"
    for h in "${hosts[@]}"; do check_name "$h"; done
    for h in "${hosts[@]}"; do collect_hashes "$h" "${COLLECT_PATHS[@]}"; done
    classify "$conf" "${hosts[@]}"
    fetch_all "$conf" "${hosts[@]}"
    print_per_host "${hosts[@]}"
  fi
  echo "集めたら git diff で確かめて commit し、./deploy --dry-run で差分が出ないことを確かめる"
}

main "$@"

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

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$DEPLOY_DIR/../.." && pwd)"
# shellcheck source=deploy.env
source "$DEPLOY_DIR/deploy.env"

SERVERS="" TO=""
HOSTS=()
declare -A HASH=()      # "サーバー|パス" → ハッシュ
declare -A FILES=()     # パス → 1（全台のファイルの和集合）
COMMON=()               # 全台で同じファイル
declare -A PER_HOST=()  # サーバー名 → 台ごとのファイル（改行区切り）

parse_args() {
  case "${1:-}" in
    --server=*) SERVERS="${1#*=}"; IFS=, read -ra HOSTS <<< "$SERVERS" ;;
    --to=*) TO="${1#*=}" ;;
    *) echo "使い方: $0 --server=isu1,isu2,isu3 | --to=<名前>" >&2; exit 2 ;;
  esac
}

# COLLECT_PATHS の下のファイルを「ハッシュ  パス」で 1 行ずつ出す。ssh の先でも動くよう、関数ごと送る
list_hashes() {
  local p
  for p in "$@"; do
    if sudo test -e "$p"; then sudo find "$p" -type f; else echo "ない: $p" >&2; fi
  done | sort | xargs -r -d '\n' sudo sha256sum
}

remote_list_hashes() {  # $1: サーバー名
  ssh -o BatchMode=yes "$1" "$(declare -f list_hashes); list_hashes $(printf '%q ' "${COLLECT_PATHS[@]}")"
}

# --to: このサーバーのファイルを、すべて conf/<名前>/ に集める
collect_local() {
  local f dst
  while read -r _ f; do
    dst="$REPO_DIR/conf/$TO$f"
    mkdir -p "$(dirname "$dst")"
    sudo cat "$f" > "$dst"
    echo "$f → conf/$TO$f"
  done < <(list_hashes "${COLLECT_PATHS[@]}")
}

# 全台のファイルのハッシュを HASH と FILES に集める
collect_hashes() {
  local h sum f
  for h in "${HOSTS[@]}"; do
    while read -r sum f; do
      HASH["$h|$f"]=$sum; FILES["$f"]=1
    done < <(remote_list_hashes "$h")
  done
}

is_common() {  # $1: パス。全台にあり、ハッシュが同じなら真
  local h first="${HASH["${HOSTS[0]}|$1"]:-}"
  [[ -n $first ]] || return 1
  for h in "${HOSTS[@]}"; do [[ ${HASH["$h|$1"]:-} == "$first" ]] || return 1; done
}

# ファイルを COMMON と PER_HOST に分け、使わなくなった写しを conf/ から消す（conf/<サーバー名>/ が conf/default/ より優先されるため）
classify() {
  local f h all
  mapfile -t all < <(printf '%s\n' "${!FILES[@]}" | sort)
  for f in "${all[@]}"; do
    if is_common "$f"; then
      COMMON+=("$f")
      for h in "${HOSTS[@]}"; do rm -f "$REPO_DIR/conf/$h$f"; done
    else
      rm -f "$REPO_DIR/conf/default$f"
      for h in "${HOSTS[@]}"; do
        if [[ -n ${HASH["$h|$f"]:-} ]]; then PER_HOST[$h]+="$f"$'\n'; else rm -f "$REPO_DIR/conf/$h$f"; fi
      done
    fi
  done
}

# $1: サーバー名、$2: 置き場所（conf/ の下の名前）、残り: ファイルの絶対パス
fetch() {
  local h=$1 to=$2 f; shift 2
  mkdir -p "$REPO_DIR/conf/$to"
  ssh -o BatchMode=yes "$h" "sudo tar -C / -cf - $(printf '%q ' "${@#/}")" \
    | tar -C "$REPO_DIR/conf/$to" --no-same-owner --no-same-permissions -xf -
  # tar は実行ビットを残すが、git の差分に出ないよう、前と同じく 644 にそろえる
  for f in "$@"; do chmod 644 "$REPO_DIR/conf/$to$f"; echo "[$h] $f → conf/$to$f"; done
}

# 共通のファイルは 1 台目から、台ごとのファイルは各台から取る
fetch_all() {
  local h fs
  if (( ${#COMMON[@]} )); then fetch "${HOSTS[0]}" default "${COMMON[@]}"; fi
  for h in "${HOSTS[@]}"; do
    [[ -n ${PER_HOST[$h]:-} ]] || continue
    mapfile -t fs < <(printf '%s' "${PER_HOST[$h]}")
    fetch "$h" "$h" "${fs[@]}"
  done
}

print_per_host() {
  local h
  echo
  echo "台ごとに中身が違う（または一部の台にしか無い）ファイル:"
  for h in "${HOSTS[@]}"; do printf '%s' "${PER_HOST[$h]:-}" | sed "s|^|  conf/$h|"; done
}

main() {
  parse_args "$@"
  if [[ -n $TO ]]; then
    collect_local
  else
    collect_hashes
    classify
    fetch_all
    print_per_host
  fi
  echo "集めたら git diff で確かめて commit し、./deploy --dry-run で差分が出ないことを確かめる"
}

main "$@"

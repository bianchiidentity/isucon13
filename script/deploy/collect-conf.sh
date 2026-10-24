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
# shellcheck source=deploy.env
source "$DEPLOY_DIR/deploy.env"

# コマンドライン引数から決まる値。読むのは parse_args だけで、ほかの関数には main が引数で渡す
SERVERS="" TO=""

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

# 各台のファイルのハッシュを「サーバー名 ハッシュ  パス」で出す。つながらない台があれば失敗する
collect_hashes() {  # $1: サーバー名（カンマ区切り）、残り: 集めるパス
  local hosts h out; IFS=, read -ra hosts <<< "$1"; shift
  for h in "${hosts[@]}"; do
    out=$(ssh -n -o BatchMode=yes "$h" "$(declare -f list_hashes); list_hashes $(printf '%q ' "$@")")
    [[ -z $out ]] || sed "s|^|$h |" <<< "$out"
  done
}

# 標準入力のハッシュから、ファイルごとの置き場所を「置き場所 取る台 パス」で出す。
# 全台にあり中身が同じなら default（1 台目から取る）、それ以外はそのファイルがある各台
classify() {  # $1: サーバー名（カンマ区切り）
  awk -v hosts="$1" '
    BEGIN { n = split(hosts, H, ",") }
    { p = $0; sub(/^[^ ]+ [^ ]+  /, "", p); sum[$1, p] = $2; files[p] = 1 }
    END {
      for (p in files) {
        # sum[...] を読むだけでキーが作られるので、全台にあるかを in で確かめてから中身を比べる
        same = 1
        for (i = 1; i <= n; i++) if (!((H[i], p) in sum)) same = 0
        if (same) for (i = 2; i <= n; i++) if (sum[H[i], p] != sum[H[1], p]) same = 0
        if (same) { print "default", H[1], p; continue }
        for (i = 1; i <= n; i++) if ((H[i], p) in sum) print H[i], H[i], p
      }
    }' | sort
}

# 標準入力の置き場所に無いほうの写しを消す（conf/<サーバー名>/ が conf/default/ より優先されるため、古い写しが残ると効いてしまう）
prune_stale() {  # $1: conf のディレクトリ、$2: サーバー名（カンマ区切り）
  local conf=$1 hosts to p d; IFS=, read -ra hosts <<< "$2"
  local -A planned=()
  local -a paths=()
  while read -r to _ p; do
    [[ -n $to ]] || continue  # 空の入力（<<< "" は空行を 1 行渡す）
    planned["$to|$p"]=1; paths+=("$p")
  done
  (( ${#paths[@]} )) || return 0
  mapfile -t paths < <(printf '%s\n' "${paths[@]}" | sort -u)
  for p in "${paths[@]}"; do
    for d in default "${hosts[@]}"; do
      [[ -n ${planned["$d|$p"]:-} ]] || rm -f "$conf/$d$p"
    done
  done
}

fetch() {  # $1: 置き場所のディレクトリ、$2: 取る台、残り: ファイルの絶対パス
  local dir=$1 h=$2 f; shift 2
  mkdir -p "$dir"
  # -n: ssh が呼び出し元（fetch_planned）の標準入力を読み尽くさないように
  ssh -n -o BatchMode=yes "$h" "sudo tar -C / -cf - $(printf '%q ' "${@#/}")" \
    | tar -C "$dir" --no-same-owner --no-same-permissions -xf -
  # tar は実行ビットを残すが、git の差分に出ないよう、前と同じく 644 にそろえる
  for f in "$@"; do chmod 644 "$dir$f"; echo "[$h] $f → $dir$f"; done
}

# 標準入力の置き場所に従い、置き場所と取る台の組ごとにまとめて取る
fetch_planned() {  # $1: conf のディレクトリ
  local conf=$1 to h p key last="" files=()
  while read -r to h p; do
    [[ -n $to ]] || continue
    key="$to $h"
    if [[ $key != "$last" && -n $last ]]; then fetch "$conf/${last% *}" "${last#* }" "${files[@]}"; files=(); fi
    last=$key; files+=("$p")
  done
  if [[ -n $last ]]; then fetch "$conf/${last% *}" "${last#* }" "${files[@]}"; fi
}

print_per_host() {  # 標準入力: 置き場所
  echo
  echo "台ごとに中身が違う（または一部の台にしか無い）ファイル:"
  awk '$1 != "default" { p = $0; sub(/^[^ ]+ [^ ]+ /, "", p); print "  conf/" $1 p }'
}

main() {
  parse_args "$@"
  local conf="$REPO_DIR/conf" hashes plan
  if [[ -n $TO ]]; then
    collect_local "$conf/$TO" "${COLLECT_PATHS[@]}"
  else
    hashes=$(collect_hashes "$SERVERS" "${COLLECT_PATHS[@]}")
    plan=$(classify "$SERVERS" <<< "$hashes")
    prune_stale "$conf" "$SERVERS" <<< "$plan"
    fetch_planned "$conf" <<< "$plan"
    print_per_host <<< "$plan"
  fi
  echo "集めたら git diff で確かめて commit し、./deploy --dry-run で差分が出ないことを確かめる"
}

main "$@"

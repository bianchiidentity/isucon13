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
case "${1:-}" in
  --server=*) SERVERS="${1#*=}" ;;
  --to=*) TO="${1#*=}" ;;
  *) echo "使い方: $0 --server=isu1,isu2,isu3 | --to=<名前>" >&2; exit 2 ;;
esac

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
# $1: サーバー名、$2: 置き場所（conf/ の下の名前）、残り: ファイルの絶対パス
fetch() {
  local h=$1 to=$2; shift 2
  mkdir -p "$REPO_DIR/conf/$to"
  ssh -o BatchMode=yes "$h" "sudo tar -C / -cf - $(printf '%q ' "${@#/}")" \
    | tar -C "$REPO_DIR/conf/$to" --no-same-owner --no-same-permissions -xf -
  # tar は実行ビットを残すが、git の差分に出ないよう、前と同じく 644 にそろえる
  for f in "$@"; do chmod 644 "$REPO_DIR/conf/$to$f"; echo "[$h] $f → conf/$to$f"; done
}

if [[ -n $TO ]]; then
  while read -r _ f; do
    dst="$REPO_DIR/conf/$TO$f"
    mkdir -p "$(dirname "$dst")"
    sudo cat "$f" > "$dst"
    echo "$f → conf/$TO$f"
  done < <(list_hashes "${COLLECT_PATHS[@]}")
  echo "集めたら git diff で確かめて commit し、./deploy --dry-run で差分が出ないことを確かめる"
  exit 0
fi

IFS=, read -ra HOSTS <<< "$SERVERS"
declare -A HASH=()   # "サーバー|パス" → ハッシュ
declare -A FILES=()  # パス → 1（全台のファイルの和集合）
for h in "${HOSTS[@]}"; do
  while read -r sum f; do
    HASH["$h|$f"]=$sum; FILES["$f"]=1
  done < <(remote_list_hashes "$h")
done

common=()
declare -A per_host=()  # サーバー名 → 台ごとのファイル（改行区切り）
mapfile -t all < <(printf '%s\n' "${!FILES[@]}" | sort)
for f in "${all[@]}"; do
  first="${HASH["${HOSTS[0]}|$f"]:-}" same=1
  for h in "${HOSTS[@]}"; do [[ ${HASH["$h|$f"]:-} == "$first" && -n $first ]] || same=0; done
  if (( same )); then
    common+=("$f")
    # 前に台ごとに分けていたファイルが共通に戻ったら、古い写しを消す（conf/<サーバー名>/ が優先されるため）
    for h in "${HOSTS[@]}"; do rm -f "$REPO_DIR/conf/$h$f"; done
  else
    rm -f "$REPO_DIR/conf/default$f"
    for h in "${HOSTS[@]}"; do
      if [[ -n ${HASH["$h|$f"]:-} ]]; then per_host[$h]+="$f"$'\n'; else rm -f "$REPO_DIR/conf/$h$f"; fi
    done
  fi
done

(( ${#common[@]} )) && fetch "${HOSTS[0]}" default "${common[@]}"
for h in "${HOSTS[@]}"; do
  [[ -n ${per_host[$h]:-} ]] || continue
  mapfile -t fs < <(printf '%s' "${per_host[$h]}")
  fetch "$h" "$h" "${fs[@]}"
done

echo
echo "台ごとに中身が違う（または一部の台にしか無い）ファイル:"
for h in "${HOSTS[@]}"; do printf '%s' "${per_host[$h]:-}" | sed "s|^|  conf/$h|"; done
echo "集めたら git diff で確かめて commit し、./deploy --dry-run で差分が出ないことを確かめる"

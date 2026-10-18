#!/usr/bin/env bash
# 変更の前後で、決めたリクエストの応答が変わっていないかを確かめる（回帰の確認）。入口はリポジトリ直下の ./deploy-check
#
# 使い方: ./deploy-check --before            変更の前: /initialize の後に paths.txt のリクエストを送り、応答を保存する
#         ./deploy-check --after             変更の後: 同じリクエストを送り、保存した応答と比べる（違えば終了コード 1）
#         ./deploy-check --no-init [...]     /initialize を呼ばない（今のデータのまま比べる）
#
# paths.txt の 1 行が 1 リクエスト。種類ごとの比べ方:
#   json:   ステータス、Content-Type、header= で指定したヘッダ、jq -S で整形した本文（キーの順や空白の違いは無視）
#   static: ステータス、Content-Type、header= で指定したヘッダ、本文の sha256
#   login:  比べない。1 回の実行の中で Cookie を受け渡すので、以降のリクエストはこのログインの Cookie で送られる
#   init:   初期化。比べない（--no-init で飛ばす）
# 応答は results/deploy-check/{before,after}/ に置く
set -euo pipefail

CHECK_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$CHECK_DIR/../.." && pwd)"
source "$REPO_DIR/script/lib/common.sh"

PATHS_FILE="$CHECK_DIR/paths.txt"
STORE="$REPO_DIR/results/deploy-check"
DIFF_LINES=40      # 1 件あたりに表示する差分の行数
MODE="" NO_INIT=0
for arg in "$@"; do
  case $arg in
    --before) MODE=before ;;
    --after) MODE=after ;;
    --no-init) NO_INIT=1 ;;
    -h|--help) sed -n '4,6p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
[[ -n $MODE ]] || { sed -n '4,6p' "$0" >&2; exit 2; }
command -v jq > /dev/null || die "jq がない（base-conf の apply.sh で入る。sudo apt-get install -y jq でもよい）"
[[ -f $PATHS_FILE ]] || die "$PATHS_FILE がない"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
JAR="$WORK_DIR/cookies"   # 1 回の実行の中で、ログインで受け取った Cookie を次のリクエストに渡す
BODY="$WORK_DIR/body"
HEADERS="$WORK_DIR/headers"
LINENO_IN_PATHS=0         # エラーに出す、paths.txt の行番号

# curl を 1 回実行し、ステータスを出す。本文は $BODY、ヘッダは $HEADERS に書く。$1: メソッド、$2: URL、残り: curl の引数
request() {
  local method=$1 url=$2
  shift 2
  # つながらなかったときに、前のリクエストの本文やヘッダを今回のものとして使わないように消す
  rm -f "$BODY" "$HEADERS"; touch "$BODY" "$HEADERS"
  # -m 30 は既定の上限。paths.txt で -m を書けば、後ろに書いたほうが効く
  local code
  # つながらないと、curl は 000 を出したうえで失敗の終了コードを返す
  code="$(curl -s -m 30 -b "$JAR" -c "$JAR" -X "$method" -D "$HEADERS" -o "$BODY" -w '%{http_code}' "$@" "$url")" || true
  echo "${code:-000}"
}

header_value() {  # $1: ヘッダの名前。最後の応答の中の値（なければ「（なし）」）
  local v
  v="$(grep -i "^$1:" "$HEADERS" | tail -1 | cut -d: -f2- | sed 's/^ *//' | tr -d '\r' || true)"
  echo "${v:-（なし）}"
}

# 1 行を解釈して、比べる形にした応答を標準出力に出す。$1: 種類、$2: メソッド、$3: URL、残り: jq=<式>、header=<名前>、curl の引数
fetch() {
  local kind=$1 method=$2 url=$3 jq_filter='.' a status h out
  shift 3
  local args=() headers=()
  for a in "$@"; do
    case $a in
      jq=*) jq_filter="${a#jq=}" ;;
      header=*) headers+=("${a#header=}") ;;
      *) args+=("$a") ;;
    esac
  done
  status="$(request "$method" "$url" "${args[@]}")"
  echo "status: $status"
  echo "content-type: $(header_value Content-Type)"
  for h in "${headers[@]}"; do echo "header $h: $(header_value "$h")"; done
  case $kind in
    json)
      # jq は空の入力を正しい JSON として扱うので、先に分ける
      if [[ ! -s $BODY ]]; then echo "（本文なし）"; return 0; fi
      if ! jq -e . "$BODY" > /dev/null 2>&1; then
        echo "（JSON ではない）"; cat "$BODY"; return 0
      fi
      # 式の誤りを「JSON ではない」と取り違えると、毎回変わる項目を除けていないことに気づけない
      if ! out="$(jq -S "$jq_filter" "$BODY" 2>&1)"; then
        echo "$out" >&2
        die "paths.txt の ${LINENO_IN_PATHS} 行目: jq の式が使えない: $jq_filter"
      fi
      echo "$out"
      ;;
    static) echo "sha256: $(sha256sum "$BODY" | cut -d' ' -f1)" ;;
  esac
}

# init と login は比べず、成功したかだけを見る。$1: 種類、$2: メソッド、$3: URL、残り: curl の引数
send() {
  local kind=$1 start status
  shift
  start=$EPOCHREALTIME
  # 初期化は時間がかかるので、上限を長くする
  if [[ $kind == init ]]; then status="$(request "$@" -m 120)"; else status="$(request "$@")"; fi
  [[ $status == [23]* ]] || die "paths.txt の ${LINENO_IN_PATHS} 行目: $2 が $status を返した"
  echo "${kind}: $2（HTTP ${status}、$(elapsed "$start") 秒）"
}

run() {  # 応答を $1 のディレクトリに書く
  local out=$1 line n=0 key
  rm -rf "$out"; mkdir -p "$out"
  rm -f "$JAR"; touch "$JAR"
  LINENO_IN_PATHS=0
  while IFS= read -r line; do
    LINENO_IN_PATHS=$(( LINENO_IN_PATHS + 1 ))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    # 引用符を含む値（Cookie や jq の式）を 1 つの引数として扱うため、シェルの書き方で分ける
    eval "set -- $line" 2> /dev/null || die "paths.txt の ${LINENO_IN_PATHS} 行目を解釈できない（引用符の閉じ忘れなど）: $line"
    (( $# >= 3 )) || die "paths.txt の ${LINENO_IN_PATHS} 行目: <種類> <メソッド> <URL> が要る: $line"
    case $1 in
      init)
        if (( NO_INIT )); then echo "init: 飛ばす（--no-init）"; else send "$@"; fi ;;
      login) send "$@" ;;
      json|static)
        n=$(( n + 1 ))
        key="$(printf '%02d' "$n")-$2-$(echo "$3" | sed -E 's#^https?://[^/]*##; s#[^A-Za-z0-9._-]+#_#g; s#^_##' | cut -c1-80)"
        fetch "$@" > "$out/$key.txt" ;;
      *) die "paths.txt の ${LINENO_IN_PATHS} 行目: 種類は init、login、json、static のどれか: $1" ;;
    esac
  done < "$PATHS_FILE"
  echo "$n 件のリクエストを比べる形で保存した"
}

# 保存した日時と、そのとき ./deploy が記録していた版（なければ日時だけ）
saved_at() {
  local d=/var/lib/isucon-deploy/deployed v
  v="$(sudo -n cat "$d" 2> /dev/null | awk '$1 == "repo:" || $1 == "webapp:" { printf "%s %s%s、", ($1 == "repo:" ? "repo" : "webapp"), $3, ($4 == "dirty" ? " 未コミットあり" : "") }' || true)"
  echo "$(date '+%Y-%m-%d %H:%M') に保存${v:+（${v%、}）}"
}

if [[ $MODE == before ]]; then
  run "$STORE/before"
  # after で同じ条件かを確かめるために、paths.txt と --no-init の有無を残す
  cp "$PATHS_FILE" "$STORE/before/.paths.txt"
  echo "no_init=$NO_INIT" > "$STORE/before/.conditions"
  saved_at > "$STORE/before/.saved"
  log "保存した: $STORE/before"
  cat "$STORE/before/.saved"
  exit 0
fi

[[ -d $STORE/before ]] || die "変更の前の応答がない。変更の前に ./deploy-check --before を実行する"
# --before のし忘れで古い応答と比べていないかを、目で確かめられるようにする
echo "比較の相手: $(cat "$STORE/before/.saved" 2> /dev/null || echo '保存した日時がわからない')"
# 保存するファイル名は行の順番で付けているので、paths.txt が変わると別のリクエストどうしを比べてしまう
cmp -s "$PATHS_FILE" "$STORE/before/.paths.txt" \
  || die "--before の後で paths.txt が変わった。変更の前の状態で ./deploy-check --before からやり直す"
if [[ $(cat "$STORE/before/.conditions" 2> /dev/null) != "no_init=$NO_INIT" ]]; then
  echo "警告: --before と --no-init の有無が違う（データが違うので、差分が出ることがある）" >&2
fi

run "$STORE/after"
ng=0
log "比較"
for f in "$STORE"/before/*.txt; do
  name="$(basename "$f")"
  if [[ ! -f $STORE/after/$name ]]; then echo "NG  ${name}（今回の応答がない）"; ng=1; continue; fi
  if cmp -s "$f" "$STORE/after/$name"; then echo "OK  $name"; continue; fi
  echo "NG  $name"
  diff -u "$f" "$STORE/after/$name" > "$WORK_DIR/diff" || true   # diff は差分があると 1 を返す
  sed -n "3,$(( DIFF_LINES + 2 ))p" "$WORK_DIR/diff"
  if (( $(wc -l < "$WORK_DIR/diff") > DIFF_LINES + 2 )); then
    echo "  …（以下略。全文: diff -u $f $STORE/after/${name}）"
  fi
  ng=1
done
(( ng )) && die "応答が変わった"
log "すべて同じ"

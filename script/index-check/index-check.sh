#!/usr/bin/env bash
# インデックスの案を、本物のテーブルに当てずに比べる。DB が動いているサーバーで実行する
#
# 使い方: script/index-check/index-check.sh --table=<テーブル> --queries=<SQL のファイル> [--index='<列, 列>' ...] [--bare] [--db=<DB 名>]
#   例:   script/index-check/index-check.sh --table=reservation_slots --queries=/tmp/q.sql \
#           --index='start_at, end_at' --index='end_at, start_at'
#
# 1. テーブルを一時テーブル（この接続の中だけにあり、終わると消える）に写す。インデックスも写る。
#    --bare なら、主キー以外のインデックスを外して、主キーだけの状態から比べる
# 2. 今のインデックス（--bare なら主キーだけ）と、それに --index の案を 1 つずつ足したものごとに、SQL のファイルの各行を実行し、読んだ行の数（Handler_read_* の増え方）と EXPLAIN を出す
#    UPDATE や DELETE、FOR UPDATE も BEGIN と ROLLBACK で挟むので、一時テーブルの中身は変わらない
# SQL のファイルは 1 行 1 文。テーブル名の代わりに {t} と書く。# で始まる行と空行は飛ばす
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DB=""
[[ -f $REPO_DIR/script/deploy/deploy.env ]] && DB="$(source "$REPO_DIR/script/deploy/deploy.env" && echo "${DB_NAME:-}")"

TABLE="" QUERIES="" INDEXES=() BARE=0
for arg in "$@"; do
  case $arg in
    --table=*) TABLE="${arg#*=}" ;;
    --queries=*) QUERIES="${arg#*=}" ;;
    --index=*) INDEXES+=("${arg#*=}") ;;
    --db=*) DB="${arg#*=}" ;;
    --bare) BARE=1 ;;
    -h|--help) sed -n '4,6p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
[[ -n $TABLE && -n $QUERIES && -n $DB ]] || { sed -n '4,6p' "$0" >&2; exit 2; }
[[ -f $QUERIES ]] || { echo "ない: $QUERIES" >&2; exit 1; }

T=index_check_tmp
mapfile -t SQLS < <(grep -vE '^[[:space:]]*(#|$)' "$QUERIES" | sed -E 's/;[[:space:]]*$//')
(( ${#SQLS[@]} > 0 )) || { echo "SQL が 1 行もない: $QUERIES" >&2; exit 1; }

STATUS="SELECT SUM(VARIABLE_VALUE) FROM performance_schema.session_status WHERE VARIABLE_NAME IN
  ('Handler_read_first','Handler_read_key','Handler_read_next','Handler_read_prev','Handler_read_rnd','Handler_read_rnd_next')"

gen() {
  # 元のテーブルに共有ロックを取らずに写す（REPEATABLE READ の INSERT ... SELECT は、読んだ行をロックする）
  echo "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;"
  echo "CREATE TEMPORARY TABLE $T LIKE \`$TABLE\`;"
  echo "INSERT INTO $T SELECT * FROM \`$TABLE\`;"
  if (( BARE )); then
    local idx
    for idx in "${EXISTING[@]}"; do echo "ALTER TABLE $T DROP INDEX \`$idx\`;"; done
  fi
  echo "SELECT '@ROWS', COUNT(*) FROM $T;"
  local cases=("" "${INDEXES[@]}") c i q
  for c in "${cases[@]}"; do
    [[ -n $c ]] && echo "ALTER TABLE $T ADD INDEX index_check_idx ($c);"
    for i in "${!SQLS[@]}"; do
      q="${SQLS[$i]//\{t\}/$T}"
      echo "SELECT '@EXPLAIN';"
      echo "EXPLAIN $q;"
      # FLUSH は実行中のトランザクションを暗黙にコミットするので、BEGIN より前に置く
      echo "FLUSH STATUS; BEGIN;"
      echo "SELECT '@BEGIN';"
      echo "$q;"
      echo "SELECT '@READ', '${c:-$BASE_LABEL}', $((i + 1)), ($STATUS);"
      echo "ROLLBACK;"
    done
    [[ -n $c ]] && echo "ALTER TABLE $T DROP INDEX index_check_idx;"
  done
  echo "DROP TEMPORARY TABLE $T;"
}

# 元のテーブルの、主キー以外のインデックス
mapfile -t EXISTING < <(sudo mysql -N -B "$DB" -e "SELECT DISTINCT INDEX_NAME FROM information_schema.STATISTICS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '$TABLE' AND INDEX_NAME <> 'PRIMARY'")
if (( BARE )); then BASE_LABEL="（主キーだけ）"; else BASE_LABEL="（今のまま）"; fi
echo "今のインデックス（主キー以外）: ${EXISTING[*]:-なし}$( (( BARE )) && echo '。--bare なので外して比べる')"
for i in "${!SQLS[@]}"; do printf 'SQL %d: %s\n' $((i + 1)) "${SQLS[$i]}"; done
echo
# EXPLAIN の行の type（5 列目）、key（7 列目）、rows（10 列目）と、読んだ行の数を、案と SQL ごとに 1 行にまとめる
gen | sudo mysql -N -B "$DB" | awk -F'\t' '
  $1 == "@ROWS"    { printf "テーブル %s の行数: %s\n\n", "'"$TABLE"'", $2; printf "%-28s %-4s %-8s %-28s %10s %12s\n", "インデックス", "SQL", "type", "key", "rows(推定)", "読んだ行"; next }
  $1 == "@EXPLAIN" { want = 1; next }
  want             { type = $5; key = $7; rows = $10; want = 0; next }
  $1 == "@BEGIN"   { next }
  $1 == "@READ"    { printf "%-28s %-4s %-8s %-28s %10s %12s\n", $2, $3, type, (key == "index_check_idx" ? "（案）" : key), rows, $4; next }
'
echo
echo "読んだ行: Handler_read_* の増え方。Index Condition Pushdown で絞った分は数えないので、インデックスの中で辿った件数はもう少し多い"

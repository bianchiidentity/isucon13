# index-check

インデックスの案を、本物のテーブルに当てずに比べるスクリプト。DB が動いているサーバーで実行する。
テーブルを一時テーブルに写し、案ごとに SQL を実行して、読んだ行の数と EXPLAIN を並べる。

```bash
cat > /tmp/q.sql <<'SQL'
# 1 行 1 文。テーブル名の代わりに {t} と書く
SELECT * FROM {t} WHERE start_at >= 1701324000 AND end_at <= 1701388800 FOR UPDATE;
UPDATE {t} SET slot = slot - 1 WHERE start_at >= 1701324000 AND end_at <= 1701388800;
SQL
script/index-check/index-check.sh --table=reservation_slots --queries=/tmp/q.sql \
  --index='start_at, end_at' --index='end_at, start_at' --bare
```

```text
インデックス                SQL  type   key        rows(推定)  読んだ行
（主キーだけ）               1    ALL    NULL             8606      8762
start_at, end_at            1    ALL    NULL             8947      8762
end_at, start_at            1    range  （案）             143        20
```

- 比べる起点は、既定では今のテーブルのインデックス。`--bare` を付けると主キー以外を外し、主キーだけの状態から比べる。インデックスを当てた後のテーブルで案を比べるなら `--bare` を付ける（付けないと、当てたインデックスを使った結果になる）。
- 案は 1 つずつ起点に足して測る。案どうしを組み合わせた結果は出ない。
- UPDATE、DELETE、`FOR UPDATE` も `BEGIN` と `ROLLBACK` で挟むので、一時テーブルの中身は変わらない。元のテーブルは `READ COMMITTED` で写すので、ロックを取らない。
- 一時テーブルはこの接続の中だけにあり、終わると消える。ただし、テーブルを丸ごと写すので、行数の多いテーブルではディスクと時間を使う。ベンチ中には実行しない。
- DB 名は `script/deploy/deploy.env` の `DB_NAME`。DB だけのサーバーでリポジトリが無いときは、スクリプトを写して `--db=<DB 名>` を付ける。`sudo mysql` で入れることが前提。
- 読んだ行は、ストレージエンジンが返した行の数（`Handler_read_*` の増え方）。Index Condition Pushdown で絞った分は数えないので、インデックスの中で辿った件数はもう少し多い。
- 範囲の条件があるなら、案の列の順と、試す値（データのどの位置か）を変えて比べる。複合インデックスで辿る範囲を決めるのは先頭の列の条件だけなので、同じ案でも、値の位置で全件の走査に変わる。

---
name: dora-g3-app-logic
description: ISUCON の G3（アプリのロジック。旧 G2）。外部コマンド、N+1、LIMIT、プリペアドステートメント、不要なロック、SELECT *、SQLite のトランザクションと実行計画、使わないクエリ、回数の多い小さなクエリ、もとのコードの無駄
---

G3 は、アプリのコードの問題である（旧 G2）。直すとクエリの形が変わるので、[dora-G2-safe-improvements](dora-G2-safe-improvements.md) に戻ってインデックスを見直す。
共通の凡例、前提構成は [dora-isucon-common](dora-isucon-common.md) にある。

## どこを見るか

1. **外部コマンドの実行**
   - バッククォート、system、popen、Open3、exec.Command を grep する。
   - private-isu ではパスワードのハッシュ計算に openssl を fork していた。
2. **N+1 クエリと LIMIT のない全件取得**
   - JOIN を使ったときは、EXPLAIN ANALYZE で駆動表を確認する。
   - オプティマイザが逆の表を選ぶことがあり、STRAIGHT_JOIN で直した。
3. **プリペアドステートメントの使い方**
   - pt-query-digest に ADMIN PREPARE / ADMIN CLOSE STMT が多ければ、毎回 3 往復している。
   - Ruby なら mysql2-cs-bind の xquery、Go なら `interpolateParams=true`。バイナリを含む INSERT は注意する。
4. **不要な排他ロック**
   - ファイルロック、`SELECT ... FOR UPDATE`、グローバルな mutex で、読み取りまで直列になっていないか。
5. **`SELECT *` で大きな列を読んでいないか**
6. **SQLite の書き込みがトランザクションに入っているか**
   - autocommit だと 1 文ごとにジャーナルを fsync する。vmstat の wa と top の jbd2 が目印。
   - 1 トランザクションにまとめると、読み取りのファイルロックも外せるようになる。
7. **引いた結果の一部しか使っていないクエリ**
   - isucon12 では、ID しか使わない tenant の SELECT と、スライスの容量にしか使わない大会の一覧があった。
8. **回数の多い小さなクエリ**
   - 1 回 0.1ms でも、毎リクエスト走るなら回数で効く（isucon12 では SELECT tenant が 7.7 万回で MySQL の 60%）。
9. **もとのコードの無駄な処理**
   - 結果が決まっている場合の計算（isucon12 では、未完了の大会は 0 円なのに集計していた）。
10. **SQLite の実行計画**
    - `EXPLAIN QUERY PLAN` の `SEARCH ... (列=?)` の括弧の中だけがインデックスで絞れている。
    - 駆動表を固定したいときは、相関サブクエリで書く。

## 採用した変更

### private-isu

| 変更 | 状態 | 構成依存 | 効果・注意 |
|---|---|---|---|
| 外部コマンド（`openssl dgst` を呼ぶバッククォート）を `OpenSSL::Digest::SHA512.hexdigest` に置き換え | 採用 | — | 1 回 10.9ms → 0.0072ms。保存済みのハッシュと一致することを確認した |
| `db.prepare().execute()` → mysql2-cs-bind の `db.xquery` | 採用 | — | 1 クエリあたり PREPARE / EXECUTE / CLOSE の 3 往復が 1 往復になった。**バイナリの imgdata と UTF-8 の body を同時に埋め込むと Encoding::CompatibilityError になるので、画像の INSERT だけは prepare のまま** |
| posts の一覧に LIMIT を付け、users と JOIN | 採用 | — | **オプティマイザが users を駆動表に選び 9817 行を読んでいた → STRAIGHT_JOIN で 20 行** |
| users の N+1 を IN でまとめる / comments の N+1 を IN + ROW_NUMBER() でまとめる | 採用 | — | 8.7k → 17k → 33k |
| GET /posts/:id の `SELECT *` をやめる | 採用 | — | エンドポイントは約 1 割速くなったが、CPU が上限でスコアは伸びない |
| `RUBY_YJIT_ENABLE=1` | 採用 | — | Ruby 4.0.7 で使える。メモリが約 180MB → 204MB |

### isucon12-qualify

| 対象 | 変更 | 状態 | 構成依存 | 効果・注意 |
|---|---|---|---|---|
| MySQL | go-sql-driver/mysql の `InterpolateParams = true` | 採用 | — | private-isu の xquery と同じく、PREPARE / EXECUTE / CLOSE の 3 往復を 1 往復に |
| SQLite | 書き込みを 1 トランザクションにまとめ、複数行の INSERT にする | 採用 | SQLite | 1,912 → 3,276。autocommit は 1 文ごとにジャーナルを fsync する。プレースホルダの上限 32,766 個に収まるよう 1,000 行ずつに分けた |
| SQLite | 読み取りの flock（ファイルロック）を外す | 採用 | SQLite | 3,276 → 3,835。更新を 1 トランザクションにした後なら、SELECT 1 本は一貫した時点を見る。go-sqlite3 の既定の busy_timeout は 5 秒 |
| SQLite | JOIN を、大会を駆動表にした相関サブクエリに書き直す | 採用 | SQLite | 4,578 → 5,250。JOIN だと `(tenant_id)` だけで引き、テナントの全スコア（167 万行）を読んでいた（222ms → 3ms）。N+1 を直したときに Claude が入れた退行だった |
| SQLite | 参加者ごとの最新行を `GROUP BY` + `MAX(row_num)`（bare column）で選び、並べ替えと LIMIT も SQL で | 採用 | SQLite | ウィンドウ関数（282ms）より速い（147ms）。G4 の全件キャッシュに置き換わった |
| app | 引いた結果の一部しか使わないクエリをやめる | 採用 | — | ID しか使わない tenant の SELECT、容量にしか使わない大会の一覧があった |
| app | 未完了の大会の課金を集計しない | 採用 | — | もとのコードでも 0 円なのに、SELECT を 2 本実行していた |
| app | `sqlite3` コマンドの fork をドライバでのスキーマ実行に置き換える | 採用 | — | private-isu の外部コマンドと同じ |
| app | JSON を goccy/go-json でエンコード（echo の `JSONSerializer`） | 採用（効果は誤差） | — | json がアプリの CPU の 7%。nginx が頭打ちの原因で差が出なかった |

### isucon11-qualify

| 対象 | 変更 | 状態 | 構成依存 | 効果・注意 |
|---|---|---|---|---|
| app | trend の N+1（1 + 性格 25 + ISU 79 = 105 本）を 2 本に。ISU ごとの最新は相関サブクエリで ID を取って JOIN | 採用 | — | **N+1 のコストは、1 本の速さより接続を取り直す回数で決まった**（1 本 1ms でも、取得ごとに 15ms 待てば 105 本で 1.6 秒）。直すとスコアは 19,436 → 4,458 に下がった。trend が通るようになり、ベンチマーカーがユーザーを増やしたため（`dora-feedback_keep-bugfix-when-load-grows`） |
| app | go-sql-driver/mysql の `interpolateParams=true` | 採用 | — | MariaDB 10.3 でも効いた。ADMIN PREPARE（DB の 24.9%）が消え、4,458 → 5,879 |
| app | 1 行ずつの INSERT を、全件を検証してから複数行の 1 本に | 採用 | — | 13.8 万回・54.7 秒 → 1.6 万回・12.4 秒。8,480 → 10,869。不正な行が 1 件でもあれば何も入れない点は、元のトランザクションの Rollback と同じ |
| app | 全件読んで Go で絞る取得に、結果が変わらない条件のときだけ LIMIT | 採用 | — | **先に access.log で実際の呼ばれ方を数える**（約 8 割が 3 つのレベルすべての指定）。その条件なら全行が合うので LIMIT を付けても同じ。24,939 → 31,134 |

## 完了条件

上位のエンドポイントに N+1 と不要なロックが残っていない。

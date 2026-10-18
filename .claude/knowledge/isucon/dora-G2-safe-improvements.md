---
name: dora-g2-safe-improvements
description: ISUCON の G2（前提に依存しない確実な改善。旧 G1）。インデックス（MySQL、SQLite、/initialize で作り直すならスキーマのファイル）、明らかな初期設定の誤り（開発モード、ワーカー 1、デバッグ出力は G1 の直後に外す）、SQLite の WAL
---

G2 は、クエリの形にだけ依存し、他の何かが決まらなくても入れてよい改善である（旧 G1）。MySQL の耐久性の設定は [dora-G1-base-conf](dora-G1-base-conf.md) に移した。
共通の凡例、前提構成は [dora-isucon-common](dora-isucon-common.md) にある。

## どこを見るか

1. **インデックスがないテーブル**
   - `SHOW CREATE TABLE` と EXPLAIN で Table scan を探す。SQLite なら `EXPLAIN QUERY PLAN` で `SCAN` を探す。
   - private-isu では comments(post_id) がなく、これだけで 30 倍になった。
2. **明らかな初期設定の誤り**
   - アプリの実行モード（RACK_ENV が development のままなど）。development だとテンプレートを毎回読み直し、余計なミドルウェアが入る。
   - ワーカー数が 1 のまま（unicorn の worker_processes など）。
   - デバッグ用のログ出力（Go の echo なら `e.Debug`、ログレベル、`middleware.Logger()`）。
   - **G1 の直後、クエリのチューニングより先に見る**。アプリのリクエストログはチューニングに使わない（集計は nginx の LTSV を alp で見る）のに、CPU と計測の経路を食う。G7 まで待たない（下の isucon11-qualify）。

## 採用した設定・変更

### インデックス（private-isu）

webapp/sql/indexes.sql に置いた（down -v で作り直しても適用される）。

| 対象 | インデックス | 効果 |
|---|---|---|
| comments | `(post_id, created_at)` | 1 位のクエリが 1 回あたり 10 万行を読んでいた → スコア 127 → 3,957 |
| posts | `(created_at)`、`(user_id, created_at)` | 一覧とユーザーページの並べ替え |
| comments | `(user_id)` | ユーザーページのコメント数の集計が 25.7ms → 0.025ms |

### 明らかな初期設定の誤り（private-isu）

| 対象 | 設定 | 状態 | 構成依存 | 理由・根拠 |
|---|---|---|---|---|
| app | `RACK_ENV=production` | 採用 | — | development だとテンプレートを毎回読み直していた。44k → 53k |
| app | unicorn `worker_processes 1 → 4` | 採用 | 同一ホスト | 3,938 → 6,091。1 つのワーカーが DB を待っている間、CPU が遊んでいた。1 のままなのは誤りなので G2 で直すが、最適な数は G6 で決め直す |

### isucon12-qualify

| 対象 | 設定・変更 | 状態 | 構成依存 | 理由・根拠 |
|---|---|---|---|---|
| SQLite | DSN に `_journal_mode=WAL&_synchronous=NORMAL`。`/initialize` で `-wal` と `-shm` も消す | 採用 | SQLite | 3,835 → 4,578。wa 7% → 3%。古い `-wal` が新しい `.db` に重なるとデータが壊れる |
| SQLite | テーブルのインデックス（大会、参加者、スコア） | 採用 | SQLite | `EXPLAIN QUERY PLAN` で `SCAN` を探す。インデックスは `sql/tenant/10_schema.sql`、初期データ、現在の DB の 3 か所に入れる |
| app | Go のデバッグ設定を外す（`e.Debug=false`、ログレベル ERROR、`middleware.Logger()` を外す） | 採用 | — | リクエストログは nginx のアクセスログで足りる |

### isucon11-qualify

| 対象 | 設定・変更 | 状態 | 構成依存 | 理由・根拠 |
|---|---|---|---|---|
| MariaDB | `isu_condition` に `(jia_isu_uuid, timestamp)` | 採用 | — | 1 位のクエリが平均 3.6 万行を読み、DB の時間の 80.7%。1,365 / 1,468 → 13,506。**`/initialize` がスキーマのファイルからテーブルを作り直すので、ALTER ではなくスキーマのファイル（`sql/0_Schema.sql`）に書く**。sqldef を使うときも同じファイルを正にする |
| app | echo の開発用のログ設定を外す（`e.Debug = true`、`SetLevel(DEBUG)`、`middleware.Logger()` → ERROR だけ） | 採用 | — | 下の 4 点。5,879 → 8,480 |

開発用のログ設定を外した理由（isucon11-qualify）:

- **チューニングに使っていない**: リクエストの集計は nginx の LTSV を alp で見ていて、アプリのリクエストログはどこにも使っていなかった。
- **重い**: 毎秒 1,000 行を超える JSON を journal に書き、systemd-journald が CPU を 37.5%（2 vCPU の約 2 割）使っていた。journal はディスクも 1.3GB 使っていた。
- **計測を壊す**: journald が 30 秒ごとに最大 10 万行を捨て（`journalctl -u systemd-journald | grep Suppressed`）、同じ経路に出していた接続プールの統計とエラーの集計が欠けた。外すのが遅れたので、それまでの計測も欠けていた可能性がある。
- **副作用**: echo の `e.Debug = true` は JSON をインデント付きで返す。外すとバイト単位の比較が合わなくなるので、回帰の確認は JSON として比べる。

## 完了条件

上位のクエリに Table scan（SQLite なら `SCAN`）が残っていない。明らかな誤りを直した。
G3 の変更でクエリの形が変わったら、G2 に戻ってインデックスを見直す。

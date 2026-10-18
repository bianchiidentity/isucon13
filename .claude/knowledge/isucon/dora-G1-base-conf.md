---
name: dora-g1-base-conf
description: ISUCON の G1（どの環境でも最初に入れる設定）。script/base-conf/apply.sh で、自動アップデートの停止、計測ツール、nginx の LTSV と fd の上限、MySQL の耐久性の設定とスロークエリログを一度に入れる。入れない設定とその理由
---

G1 は、どの問題でも、工程の最初に必ず入れる設定である。2026-10-18 に新設した。値を計測して決める設定（G6）とは分け、構成に依存せず、入れて困ることがほぼないものだけを選んだ。
共通の凡例、前提構成は [dora-isucon-common](dora-isucon-common.md) にある。

## スクリプト

- 置き場所: このリポジトリの `script/base-conf/`
- 使い方: 各サーバーに clone し、`sudo script/base-conf/apply.sh --dry-run` で差分を見てから `sudo script/base-conf/apply.sh`。`--revert` で nginx と MySQL を戻す
- 何度実行しても同じ結果になる。入っていないミドルウェアの段は飛ばす
- `nginx -t` が通らないとき、MySQL が起動しないときは、自動で元に戻して止まる
- nginx.conf の元のファイルは、初回だけ `/var/backups/isucon-base-conf/` に保存する

## 入れる設定

| 対象 | 設定 | 置き方 | 根拠 |
|---|---|---|---|
| OS | unattended-upgrades と apt-daily のタイマーを止める | systemctl | isucon12 で 236 個が勝手に更新され、MySQL が再起動した |
| ツール | alp、pt-query-digest | apt と GitHub | G0 の集計に使う |
| nginx | LTSV（`$upstream_addr`、`$connection`、`$connection_requests`、`$ssl_session_reused` 入り）、`buffer=64k flush=1s` | `conf.d/isucon.conf` を追加。nginx.conf の元の access_log はコメントアウト（残すと 2 行ずつ記録される） | alp で集計するため。`$upstream_addr` は複数台にしたとき、どの app が応答したかを見るため（2026-10-18 に追加、未検証） |
| nginx | `worker_rlimit_nofile 65535`、`worker_connections 4096`（小さいときだけ上げる） | nginx.conf を書き換え（conf.d から書けない場所） | 1024 のままだと Too many open files で 500、768 だと worker_connections are not enough（private-isu） |
| nginx | `worker_processes` が数字なら `auto` | 同上 | 1 などに固定されているのは、ワーカー 1 と同じ明らかな誤り（2026-10-18 に追加、未検証） |
| MySQL | `skip-log-bin`、`innodb_flush_log_at_trx_commit = 0`、`innodb_doublewrite = OFF` | `mysql.conf.d/zz-isucon.cnf`（mysqld.cnf より後に読ませるため zz-） | レプリケーションもバックアップも不要。失うのはプロセスが落ちたときの最大 1 秒分だけ（private-isu、isucon12 で採用） |
| MySQL | `max_connections = 1024` | 同上 | Go の database/sql は SetMaxOpenConns を設定しないと接続数に上限がなく、既定の 151 を超えると Too many connections になる。使っていない接続はメモリをほぼ使わない（2026-10-18 に追加、未検証） |
| MySQL | `slow_query_log = ON`、`long_query_time = 0` | 同上 | 最初はボトルネックを探すので ON から始める（2026-10-18 のユーザー判断）。G7 で OFF にする |

## 入れない設定と、入れる時期

| 設定 | 時期 | 理由 |
|---|---|---|
| open_file_cache | G6 | 同じパスのファイルを書き換えるアプリで、最大 60 秒古い内容を返しうる。効いたのはファイル操作が遅い virtiofs の環境だけ。静的ファイルが重いと計測でわかってから、worker_rlimit_nofile とセットで入れる |
| buffer_pool、アプリのワーカー数とコネクションプール | G6 | サーバーの台数とメモリで決める |
| skip-name-resolve、O_DIRECT、innodb_redo_log_capacity、client_max_body_size | G6 | 理由は [dora-G6-resources-params](dora-G6-resources-params.md) の「G1 に入れなかった候補」 |
| etag、expires | G4 | ベンチマーカーの実装次第 |
| upstream の keepalive | G5 | upstream の定義は問題ごとのサイト設定にある |
| performance_schema の停止、スロークエリログの OFF | G7 | 計測に使う |
| カーネルのパラメータ | G6 | 2 回の演習とも、詰まりのカウンタが 0 で効かなかった |

## 注意

- **G1 の後は、deploy の `conf/` を直す。** `script/deploy/collect-conf.sh` で設定を集めた後は `conf/default/` が正になり、base-conf のファイルを直しても次の `./deploy` で戻される。
- 失敗したら、そこで止める（nginx の段で止まれば MySQL の段は実行しない）。動かないときに全部を実行して複数の箇所を壊さないため（2026-10-18 のユーザー判断）。
- 自動アップデートが apt のロックを持っていることがあるので、apt-get は `DPkg::Lock::Timeout=120` で待つ。
- MySQL が再起動する。アプリがソケットをコンテナにマウントしているなら、アプリも再起動する（`dora-aws-env-pitfalls`）。
- server ブロックに独自の access_log があると LTSV にならない。apply.sh がそのファイルを表示するので、手で直す。
- すでに nginx.conf に `log_format ltsv` や同じディレクティブがあると、二重になって `nginx -t` が失敗し、自動で戻る（チューニング済みの isucon12 の app で dry-run して確認）。まっさらなサーバーなら起きない。
- MariaDB 10.3.34（isucon11-qualify の AMI、Ubuntu 20.04）で適用して確認済み（2026-10-18）。`mariadb.conf.d/zz-isucon.cnf` に置かれ、5 項目とも意図どおりの値になった。MySQL がコンテナで動いている問題では、MySQL の段を手で入れる。
- 検証: Ubuntu 22.04 のコンテナ（nginx 1.18、MySQL 8.0.46）で、適用、2 回目、失敗時の巻き戻し、revert を確認。実機（isucon12 の app）では dry-run のみ。

## 完了条件

全サーバーで apply.sh を実行し、`nginx -t` と MySQL の値（apply.sh が表示する）を確かめた。ベンチが通り、alp とスロークエリの集計が結果のディレクトリに残る。G0 のベースラインと比べたスコアを記録した。

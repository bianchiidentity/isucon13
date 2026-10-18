---
name: dora-g0-measurement
description: ISUCON の G0（計測・運用の基盤と仕様の把握）。alp、スロークエリの集計、プロファイラ、bench スクリプト、CPU の見方、スコアの内訳、ベンチマーカーの fd の上限、接続プールの待ち（db.Stats）、journald が捨てたログ
---

G0 は、ベンチを 1 コマンドで回して結果を残す仕組みと、仕様の把握。ログの出力設定（LTSV、スロークエリログ）と自動アップデートの停止は、2026-10-18 から [dora-G1-base-conf](dora-G1-base-conf.md) の apply.sh が行う。
共通の凡例、前提構成、回帰確認は [dora-isucon-common](dora-isucon-common.md) にある。

## どこを見るか

- nginx の LTSV のログを alp で集計する。
  - `-m` でパスのパラメータをまとめる（private-isu では /posts/:id、/@user、/image/:id）。
- MySQL のスロークエリログを pt-query-digest で集計する。
  - G1 の base-conf は、最初から全クエリ（`long_query_time=0`）を記録する。G7 で OFF にする。
- MySQL 以外の DB（SQLite など）はスロークエリログに出ない。
  - アプリ側でクエリの時間を記録するか、プロファイラ（Go なら pprof、fgprof）で見る。
- bench.sh で、ログのローテート、ベンチマーク、alp、pt-query-digest を一度に実行する。結果は日時のディレクトリに保存する。
- ベンチ中に各プロセスの CPU を見る（`top`、`docker stats`、vmstat）。どこが上限に張り付いているかで、次に触る場所が決まる。
- プロファイラは環境変数で有効にし、bench.sh に組み込む（isucon12-qualify では `PROFILE=1` で pprof を 30 秒）。
  - ハンドラ別の cum% を見る。自分で書いたクエリの退行（JOIN が全件読み）も、これで見つかった。
- top で nginx とアプリの CPU の比率を見る。
  - CPU に余裕がある回では伸びるのに、最低スペックで伸びないなら、アプリ以外（nginx の TLS など）が頭打ちの原因になっている。
- ベンチマーカーのスコアの内訳（isucon12 なら ScoreTable）で、点の重みを確かめる。
  - isucon12 では 10 点のエンドポイントが全体の約 3 分の 1 を稼いでいた。
- エンドポイントの応答時間に比べて DB の時間（pt-query-digest）が小さければ、DB の外で待っている。
  - 接続プールの空き待ちは、スロークエリにも CPU のプロファイルにも出ない。Go なら `db.Stats()` の WaitCount と WaitDuration の差分を 10 秒ごとに出すと見える。
  - isucon11 では、接続 10 本が使い切られ、1 回の取得で約 15ms 待っていた。trend の 105 本のクエリで 1.6 秒になり、タイムアウトの原因だった。
- アプリのログが journald に捨てられていないかを確かめる（`journalctl -u systemd-journald | grep Suppressed`）。
  - 捨てられると、同じ経路に出す計測（エラーの集計、接続プールの統計）も欠ける。原因はたいてい開発用のリクエストログで、G2 で外す（[dora-G2-safe-improvements](dora-G2-safe-improvements.md)）。
- スロークエリログは全件記録だと 1 回で 100MB を超える。集計の結果だけを残し、元のログは消す。
  - pt-query-digest は t3 のクレジット切れで約 2 分半かかる。journal のように時間窓で集めるものは、pt-query-digest より先に集める。

## 採用した設定・変更

| 対象 | 設定・変更 | 状態 | 構成依存 | 理由・根拠 |
|---|---|---|---|---|
| nginx | `log_format ltsv` + `access_log ... ltsv` | 採用 → G1 の base-conf に移した | — | alp で集計するため |
| MySQL | スロークエリログ（`long_query_time=0`） | 採用 → G1 の base-conf に移した | — | 演習では普段 OFF にし、計測時だけ `SET GLOBAL slow_query_log = ON` にしていた。base-conf では最初から ON |
| app | 環境変数を設定したときだけ `net/http/pprof` を開き、bench.sh の `PROFILE=1` で 30 秒のプロファイルを取る | 採用 | — | SQLite はスロークエリログに出ない。自分で書いたクエリの退行（[dora-G3-app-logic](dora-G3-app-logic.md)）をこれで見つけた（isucon12） |
| nginx | LTSV に `$connection`、`$connection_requests`、`$ssl_session_reused` を足す | 採用 → G1 の base-conf に入れた | — | TLS のセッション再利用が 0 件とわかり、ssl_session_cache を見送れた（isucon12） |
| app | 環境変数を設定したときだけ、`db.Stats()` の WaitCount / WaitDuration の差分を 10 秒ごとに標準エラーへ出す（bench.sh が dbstats.txt に保存） | 採用 | — | 接続プールの待ちを見るため（isucon11）。pprof と同じ instrument.go に置いた |
| ベンチマーカー | 実行するユーザーの `ulimit -n 65536` | 採用・**必須** | 自前の bench | 既定の 1,024 のままだと、アプリが速くなった途端に `socket: too many open files` で失格になった（isucon12） |
| OS | unattended-upgrades と apt-daily のタイマーを止める | 採用・**必須** → G1 の base-conf に移した | t3 | `apt-get update` を引き金に 236 個のパッケージが更新され、計測が汚れ、MySQL が再起動した（isucon12） |

## 完了条件

ベンチを 1 コマンドで回せ、alp と DB のクエリ集計が結果のディレクトリに残る。マニュアルの要点が進捗ファイルにある。ベースラインのスコアを記録した。
alp と集計の出力は、G1 の base-conf を入れると揃う。ベースラインのスコアは、base-conf を入れる前に測る。

---
name: dora-g5-topology
description: ISUCON の G5（サーバー構成・接続経路。旧 G4）。複数台への振り分け、UNIX ドメインソケット、upstream の keepalive、ファイルの共有
---

G5 は、サーバーの台数の配分と、プロセス間の接続経路である（旧 G4）。何が重いか（[dora-G4-data-cache](dora-G4-data-cache.md) まで）が決まらないと、分け方を決められない。
共通の凡例、前提構成は [dora-isucon-common](dora-isucon-common.md) にある。

## どこを見るか

- G4 までで、どのプロセスが CPU やメモリを使うかを把握してから分け方を決める。
- 同じホストに残すプロセスの間は、UNIX ドメインソケットでつなぐ（nginx → app、app → MySQL）。
- 別のホストへ振り分けるときは、nginx の upstream に `keepalive` + `proxy_http_version 1.1` + `Connection ""` を付ける。app 側が keep-alive に対応しているかを先に確かめる（unicorn は非対応）。
- アプリがローカルのファイル（画像、SQLite など）を使っているなら、振り分けた先からも同じデータが見えるかを確かめる。
- 1 台の CPU が上限で計測にならないときは、G5 を前倒しにする（ユーザーに理由を説明する）。

## 採用した設定・変更

private-isu は 1 台、isucon12 は app 1 台なので、台数の配分は検討していない。ここにあるのは、同じホストにいることを利用した接続経路の変更である。

| 対象 | 設定 | 状態 | 構成依存 | 理由・根拠 |
|---|---|---|---|---|
| nginx → app | unicorn へ UNIX ドメインソケットで proxy_pass | 採用 | 同一ホスト | TIME_WAIT が nginx 2829 / app 6479 → 0 / 0。スコアは約 +10%（private-isu） |
| app → MySQL | UNIX ドメインソケットで接続（`ISUCONP_DB_SOCKET`） | 採用 | 同一ホスト | mysql2 は socket を指定しても host が localhost でないと TCP を使う（private-isu）。isucon12 でも採用。コンテナにソケットをマウントすると、MySQL の再起動で見えなくなる（`dora-aws-env-pitfalls`） |
| nginx → app | upstream の `keepalive 32` + `proxy_http_version 1.1` + `Connection ""` | 採用（効かない） | unicorn | unicorn は keep-alive 非対応で、毎回 `Connection: close` を返す。勉強のために残した。ソケットではなく TCP で別ホストへ振り分けるときに重要になる（private-isu） |
| nginx → app | upstream の `keepalive 64`（Go） | 採用 | — | Go は keep-alive に対応しているので効く（isucon12） |
| app | app コンテナの `cpus: "1"` の上限を変える | 未実施 | — | 本番の制約を模しているかもしれないので、練習の条件次第（private-isu） |
| nginx | HTTP/2 | 対象外 | — | private-isu のベンチマーカーは平文の HTTP/1.1 |

## 完了条件

各サーバーの役割が決まり、進捗ファイルの「環境」に書いた。

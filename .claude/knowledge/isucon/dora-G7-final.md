---
name: dora-g7-final
description: ISUCON の G7（最終調整。旧 G6）。アクセスログ・スロークエリログ・performance_schema の停止と、再起動試験
---

G7 は、計測できなくなる変更と、再起動試験である（旧 G6）。すべての計測が終わってから行う。
共通の凡例、前提構成は [dora-isucon-common](dora-isucon-common.md) にある。

## どこを見るか

- アクセスログ、スロークエリログ、performance_schema を止める。
  - ここで止めるのは、計測に使うログだけ。アプリのリクエストログやデバッグ出力は計測に使わないので、G7 を待たずに G2 で外す（[dora-G2-safe-improvements](dora-G2-safe-improvements.md)、isucon11-qualify で journald が CPU 37.5%）。
  - スロークエリログは G1 の base-conf が ON にしている。`SET GLOBAL slow_query_log = OFF` にし、`zz-isucon.cnf` も OFF にする（再起動後も OFF のままにするため）。
- 再起動して、ベンチが通り、データが残っていることを確かめる。
  - アプリが MySQL より先に起動しても動くか（コンテナにソケットをマウントしていると見えなくなる。`dora-aws-env-pitfalls`）。

## 採用した設定

| 対象 | 設定 | 状態 | 構成依存 | 理由・根拠 |
|---|---|---|---|---|
| nginx | `access_log off` | **却下** | — | 最終計測のときだけ検討する案。alp が使えなくなる（private-isu） |
| MySQL | `--performance-schema=OFF` | 採用 | 規模 | メモリが 605MB → 309MB。private-isu と isucon12 では早めに入れたが、計測に使うなら最後まで残す |
| MySQL | スロークエリログを OFF | 採用 | — | 全クエリの記録は MySQL の負荷になる。G1 で ON から始めた分を、ここで止める |

## 完了条件

再起動後にベンチが通り、データが残っていることを確かめた。

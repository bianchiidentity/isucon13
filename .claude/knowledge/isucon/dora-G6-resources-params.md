---
name: dora-g6-resources-params
description: ISUCON の G6（リソース配分・細かいパラメータ。旧 G5）。nginx（open_file_cache、バッファ、etag、keepalive_requests）、MySQL（buffer_pool、max_connections）、SQLite（cache_size、mmap）、カーネル、GOGC の採用・却下と根拠
---

G6 は、台数、CPU、メモリ、データ量が決まってから値を決めるパラメータである（旧 G5）。[dora-G5-topology](dora-G5-topology.md) で構成を決めるまで調整しない。
どの環境でも最初に入れる設定（fd の上限、worker_connections など）は [dora-G1-base-conf](dora-G1-base-conf.md) にある。共通の凡例、前提構成は [dora-isucon-common](dora-isucon-common.md) にある。

## どこを見るか

- nginx
  - open_file_cache と worker_rlimit_nofile は**必ずセットにする**（worker_rlimit_nofile は G1 で入る）。
  - アクセスログのバッファ（G1 で `buffer=64k flush=1s` が入る）。
  - client_body_buffer_size（error.log の temporary file 警告を見る）。
- MySQL
  - buffer_pool はサーバーのメモリとデータ量から決める。同じホストのアプリと Claude Code が使う分を差し引く。
  - max_connections は、app の台数 × コネクションプールの上限で見積もる。
- アプリ
  - ワーカー数やコネクションプールは、サーバーごとの CPU とメモリを見て決める。
- カーネル
  - 先に ListenOverflows、ListenDrops、TCPTimeWaitOverflow、TCPBacklogDrop を見る。0 なら変えても効かない。

## nginx

| 設定 | 状態 | 構成依存 | 理由・根拠 |
|---|---|---|---|
| `access_log ... buffer=64k flush=1s` | 採用 → G1 の base-conf に入れた | virtiofs | 外すと 170k → 118k（-31%）。ログの書き込みが重い環境だった（private-isu） |
| `open_file_cache max=20000 inactive=60s` + `open_file_cache_valid 60s` | 採用（G1 には入れない） | virtiofs | 外すと 170k → 113k（-34%）（private-isu）。EBS の EC2 では効果を測っていない（isucon12 でも入れた）。同じパスのファイルを書き換えるアプリでは、最大 60 秒古い内容を返しうる |
| `worker_rlimit_nofile 65535` | 採用・**必須** → G1 の base-conf に入れた | — | open_file_cache がファイル記述子を持ち続けるので、1024 のままだと `socket() failed (24: Too many open files) while connecting to upstream` で 500 が出た（fail 405）。**open_file_cache と必ずセットにする** |
| `worker_connections 4096` | 採用 → G1 の base-conf に入れた | — | 1024 だと `worker_connections are not enough` の warn が出た |
| `multi_accept on` | 採用（効果は不明） | — | 外した回のほうが高かった（210k）。1 回ずつの計測なので判断できない |
| `tcp_nopush on` | 採用（効果は不明） | — | 外しても下がらなかった |
| `client_body_buffer_size 2m` | 採用 | — | 画像の投稿で「client request body is buffered to a temporary file」が 2327 件 → 0 件。値は投稿されるボディの大きさ次第。isucon12 では警告が 0 件で入れなかった |
| `proxy_buffers 16 16k` | 採用（効果は不明） | — | HTML が最大約 34KB。upstream の一時ファイル警告が数件あった。isucon12 では警告が 0 件で入れなかった |
| `etag off` | 採用 | — | 交互に計測し、2 組とも off のほうが高かった（private-isu） |
| `keepalive_requests 10000` | **却下** | — | 1 接続あたり約 60 リクエストで、初期値の 1000 に届かない。誤って試したため取り消した |
| `open_file_cache_errors on` | 見送り | — | location の分割で代替した。新しく投稿された画像を 60 秒間「ない」と返すリスクがある |
| `listen 80 reuseport` | 未実施 | — | multi_accept の効果が不明なので、比べる候補 |
| gzip | 見送り | 同一ホスト | 転送量はボトルネックではなく、nginx の CPU を使うだけ。ネットワーク越しのベンチなら再検討 |
| `server_tokens off` | 未実施 | — | 効果はほぼ測れない |
| `ssl_session_cache` | 見送り | ベンチマーカー | `$ssl_session_reused` で再利用 0 件。ベンチマーカーが再利用を試みない（isucon12） |
| HTTP/2 を切る、点の高いリクエストを優先する | **演習では実施しない** | — | 実サービスではやらない対策（ユーザー判断、`dora-feedback_no-benchmark-only-hacks-in-practice`）。本番当日には検討する。最低スペックでは nginx が CPU の約 45% を使い、頭打ちの原因だった（isucon12） |

## MySQL

| 設定 | 状態 | 構成依存 | 理由・根拠 |
|---|---|---|---|
| `--innodb-buffer-pool-size=256M` | **却下** | 規模、同一ホスト | 初期値 128MB のまま。画像を除いたデータは 11MB。ただし buffer_pool_reads が 89 万回あった（SELECT * で画像を読んでいた期間を含む）。DB 専用のサーバーを置くなら、メモリに合わせて決め直す（private-isu） |
| `max_connections`、`thread_cache_size`、`table_open_cache` など | 対象外 | 規模 | アプリの接続はワーカー数ぶん（4 本）で、問題がない。app が複数台になれば台数 × プール数で見直す。2026-10-18 から max_connections は G1 で 1024 にする |
| TLS | 対象外 | — | Ssl_accepts 0（もともと TLS を使っていない） |

## G1 に入れなかった候補（2026-10-18 の base-conf のセルフレビュー）

どれも演習では試していない。入れるなら、計測して決める。

| 対象 | 設定 | G1 に入れなかった理由 | 入れるときの判断 |
|---|---|---|---|
| MySQL | `skip-name-resolve` | `'isucon'@'localhost'` のユーザーに `127.0.0.1` の TCP でつなぐアプリが入れなくなる。ISUCON ではこの組み合わせが多い | 複数台にして、別のサーバーから TCP でつなぐとき。ユーザーの host を IP か `%` にしてから入れる |
| MySQL | `innodb_flush_method = O_DIRECT` | OS のキャッシュを使わなくなる。buffer_pool が既定の 128MB のままだと、読み込みがかえって遅くなる | buffer_pool をデータ量より大きくしたときに一緒に入れる |
| MySQL | `innodb_redo_log_capacity`（8.0.30 以降。既定 100MB）を 1GB などに | 効くのは書き込みが多い問題だけ | スロークエリやディスクの I/O で、書き込みの待ちが目立つとき |
| nginx | `client_max_body_size`（既定 1MB） | 必要な値はアップロードの大きさで決まる。配られた設定に入っていることが多い | error.log に `client intended to send too large body` が出たとき。G0 で一度確かめる |

## SQLite、アプリ（isucon12-qualify）

| 対象 | 設定 | 状態 | 構成依存 | 理由・根拠 |
|---|---|---|---|---|
| SQLite | `_cache_size=-8000`（8MB） | 採用（効果は誤差） | — | 下がらないので入れた |
| SQLite | `mmap_size` | 見送り | — | DSN では指定できず、ドライバの登録（ConnectHook）が要る |
| app | テナント DB の `SetMaxIdleConns(16)` | 採用 | SQLite | 接続の使い回し（[dora-G4-data-cache](dora-G4-data-cache.md)）と一緒に入れた |
| app | GOGC | 未実施 | — | メモリの確保が 10〜12%、GC が 3〜5% |

## カーネル

計測時の TCP の詰まりを示すカウンタ（ListenOverflows、ListenDrops、TCPTimeWaitOverflow、TCPBacklogDrop）は、private-isu でも isucon12（TCPSynRetrans も）でもすべて 0 で、効果は見込めないと判断した。複数台構成でサーバー間の TCP が増えると、結論が変わりうる。

| 項目 | private-isu の値 | 提案 | 状態 |
|---|---|---|---|
| `net.ipv4.ip_local_port_range` | 32768–60999 | 1024–65535 | 未実施 |
| `net.ipv4.tcp_tw_reuse` | 2 | 1 | 未実施（コンテナ間の通信は loopback ではないので、2 では効かない） |
| `net.ipv4.tcp_max_syn_backlog` | 512 | 4096 | 未実施 |
| `net.core.somaxconn` | 4096 | — | 変更不要 |
| `vm.swappiness` / THP | 60 / madvise | — | 変更不要 |

- 設定する場所: net.* は compose の `sysctls:` に書く。vm.* と THP は colima の VM で設定する。本番は /etc/sysctl.conf。
- DPDK: 不要と判断した。パケット処理はボトルネックではない。ポーリングで CPU を 1 つ占有する。nginx・MySQL・Ruby がそのままでは動かない。

## 完了条件

各サーバーの CPU とメモリを見て、ワーカー数、プール、DB のメモリを決めた。

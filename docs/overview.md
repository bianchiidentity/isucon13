# サイトの全体像（ISUPipe）

作成: 2026-10-18 15:54（JST）。参考実装をチューニング前の状態で読んだ。行番号は `webapp/go/*.go` の初期状態（`abf06c5`）のもの。サーバーの数字（行数、プロセス、設定）は app1（192.168.0.11）で調べた。

参考: [ISUCON13 当日マニュアル](https://github.com/isucon/isucon13/blob/main/docs/cautionary_note.md)、[ISUPipe アプリケーションマニュアル](https://github.com/isucon/isucon13/blob/main/docs/isupipe.md)、[ベンチマーカーのシナリオ](https://github.com/isucon/isucon13/tree/main/bench/scenario)。

この環境は matsuu/aws-isucon の AMI なので、本番の `*.u.isucon.dev` が `*.u.isucon.local` に置き換わっている。以下では `u.isucon.local` と書く。

## 1. サイトの概要

ISUPipe は、ライブ配信のサービスである。配信者ごとにサブドメイン（`<ユーザー名>.u.isucon.local`）を持ち、配信に関する API はそのドメインに送られる。サブドメインの名前解決のために、アプリ自身が DNS サーバー（PowerDNS）を運用している。

| 登場人物 | できること |
|---|---|
| 視聴者 | 配信を探して入り、ライブコメントを投稿する（チップ付きのものがある）。リアクションを送る。スパムを報告する |
| 配信者 | 配信を予約する（時間帯ごとの枠に上限がある）。報告を見て NG ワードを登録する（モデレーション） |
| DNS 水責め攻撃者 | ベンチ中に、ランダムなサブドメインを大量に引く |

主なデータは、ユーザー（アイコン、テーマ）、ライブ配信（タグ、予約枠）、ライブコメント（チップ）、リアクション、スパム報告、NG ワードである。

実装は Go 1.21、echo v4、sqlx、MySQL 8.0.35。セッションは gorilla/sessions の Cookie ストアに入れ、DB は使わない。PowerDNS は MySQL のバックエンド（DB `isudns`）で動く。フロントエンドは SPA で、ビルド済みのファイルが `webapp/public/` にある（`index.html` と `assets/` の 24 ファイル）。映像とサムネイルは運営の `media.xiii.isucon.dev` から配信され、チューニングの対象ではない。

## 2. 採点と制約

当日マニュアルの「スコア計算」「負荷走行について」「DNS サーバーについて」と、アプリのマニュアルから抜き出した。

- 採点: スコアは、負荷走行の間に投げ銭（チップ）として送られた ISUCOIN の合計。サーバーとベンチで差があれば、ベンチの値を使う
    - チップは `POST /api/livestream/:id/livecomment` の `tip` で送られる。送るのは視聴者のシナリオ（`viewer.go` の `BasicViewerScenario`）だけ
    - 初回ベンチの `result.json` は「売上: 1527」と出す
- 負荷走行の流れとタイムアウト

| 段階 | 時間 | 1 リクエストのタイムアウト |
|---|---|---|
| `POST /api/initialize` | 1 回 | 42 秒 |
| 整合性チェック | 数秒〜数十秒 | 20 秒 |
| 負荷テスト | 60 秒 | 20 秒 |
| 最終チェック | 数秒〜数十秒 | 10 秒 |

- 失格と fail
    - 初期化か整合性チェックに失敗すると即 fail
    - 負荷テストの終了時点で未完了のリクエストは切断され、スコアにも検証にも影響しない
    - 名前解決で、ポータルに登録した 3 台以外の IP が返ると、ベンチはエラーにする
- `/initialize`: `../sql/init.sh` を実行する（`main.go:109`）
    - 12 テーブルを `TRUNCATE` して初期データを入れ直す。テーブルは作り直さない
    - 最後に `pdns/init_zone.sh` を呼び、DNS のゾーンを入れ直す。A レコードのアドレスは `env.sh` の `ISUCON13_POWERDNS_SUBDOMAIN_ADDRESS`
    - レスポンスの言語名（Go の実装は `language`、マニュアルは `lang`）が空だと失敗になる
- 反映の猶予: アイコンを更新したら、2 秒以内に `icon_hash` と `GET /api/user/:username/icon` の両方に反映する（MUST）
    - アプリのマニュアルは「一部 API には猶予がある」と書き、詳細を当日の gist に譲っている。書かれていたのはこれだけだった
- アイコンの 304: リクエストに `If-None-Match: "<icon_hash>"` があり、ハッシュが一致するときだけ 304 を返してよい（MAY）。条件付きでないリクエストに 304 を返してはいけない
- パスワード: bcrypt のアルゴリズムとコスト（`bcrypt.MinCost`）を変えてはいけない
- DNS の仕様
    - UDP の 53 番だけ。TCP へのフォールバックはない。A レコードだけを返し、CNAME は辿らない
    - 名前解決のタイムアウトは 2 秒。負荷走行の間はリトライしない
    - TTL を付けると、ベンチはその秒数だけ結果をキャッシュする。初期のレコードはすべて TTL 0
    - 負荷走行の間、DNS 水責め攻撃が来る。並列数は 2 から始まり、失敗率 1% 未満で最大 15 まで上がる（`benchmarker.go` の `loadAttackCoordinator`）
- 追試: 全サーバーを再起動した後に負荷走行する。fail か、最終スコアの 75% 以下なら失格。上位のチームには、書き込んだデータが再起動後に読めるかの確認もある
- 変えてはいけないもの: envcheck と `aws-env-isucon-subdomain-address` の関連ファイル、isuadmin ユーザー
    - この AMI では、どちらのサービスも disabled
    - セキュリティグループの SSH、HTTPS、DNS（UDP/53）も変えない

## 3. メインのユーザージャーニー

ベンチは、配信者と視聴者を 1 人ずつ登録し、ログインしてアイコンを送ってから、クライアントのプールに入れる（`benchmarker.go` の `runClientProviders`）。負荷テストの間は、次のシナリオを並列に回し続ける。配信に関する API は、配信者のサブドメインに送る（`client.go:131` の `setStreamerURL`）。そのため、リクエストのたびに DNS を引く（TTL 0）。

```text
準備（全員）
1. ユーザー登録            POST /api/register        （pdnsutil でサブドメインを追加）
2. ログイン                POST /api/login
3. アイコンを送る          POST /api/icon
```

```text
配信を見る（視聴者、BasicViewerScenario）。スコアになるのはこの流れだけ
1. （100 人に 1 人）アイコンを変える    POST /api/icon
2. （10 人に 1 人）トップページを見る   GET  /api/user/:自分/icon
                                        GET  /api/livestream/search?limit=N
                                        GET  /api/livestream/search?tag=...
                                        GET  /api/user/:name/icon（配信者ごと、If-None-Match 付き）
3. （10 人に 1 人）配信者のプロフィール GET  /api/user/:name/theme、/icon、/statistics、/livestream
4. 配信に入る                           POST /api/livestream/:id/enter
                                        GET  /api/livestream/:id/statistics
                                        GET  /api/livestream/:id/livecomment?limit=10
                                        GET  /api/livestream/:id/reaction?limit=10
5. （10 人に 1 人）配信の統計を見る     GET  /api/livestream/:id/statistics
6. 配信の時間数だけ繰り返す
   a. コメントを読む（limit なし）      GET  /api/livestream/:id/livecomment
                                        GET  /api/user/:name/icon（最大 11 件）
   b. チップ付きのコメントを送る        POST /api/livestream/:id/livecomment
   c. リアクションを読んで送る          GET / POST /api/livestream/:id/reaction
7. 配信から出る                         DELETE /api/livestream/:id/exit
```

```text
配信を予約する（配信者、BasicStreamerColdReserveScenario）
1. （一部）アイコンを変える              POST /api/icon
2. タグを 5 つ選んで予約する             POST /api/livestream/reservation
```

```text
モデレーションする（配信者、BasicStreamerModerateScenario）
1. 自分の配信の一覧                      GET  /api/livestream
2. 配信ごとに管理画面を見る              GET  /api/livestream/search?limit=N
                                         GET  /api/livestream/:id/ngwords
                                         GET  /api/livestream/:id/report
3. 報告ごとに NG ワードを登録する        POST /api/livestream/:id/moderate
```

ほかに、次のシナリオが走る。

- スパムの投稿（`ViewerSpamScenario`）: NG ワードを含むコメントを送る。モデレーション済みなら 400 が期待値
- スパムの報告（`BasicViewerReportScenario`）: `POST /api/livestream/:id/livecomment/:livecomment_id/report`
- 攻めたモデレーション（`AggressiveStreamerModerateScenario`）: 報告に無い NG ワードを登録し続け、`ng_words` を増やす
    - ベンチのコメントには「`ng_words` が嵩むことに気づいたら対策してもらう想定」とある

## 4. エンドポイント一覧

ルーティングは `main.go:132-183` にあり、27 本ある。「認証」の「ログイン」は、Cookie のセッションを `verifyUserSession`（`user_handler.go:377`）で確かめるもの。どのハンドラもトランザクションを張り、`fillUserResponse` などの組み立ての関数で `users`、`themes`、`icons`、`livestreams`、`livestream_tags`、`tags` を読む。読むテーブルの列には、ハンドラ自身が読むものだけを書いた。組み立ての関数が読むものは、「組み立て」の列に関数の名前で書いた。

| メソッド | パス | ハンドラ | 内容 | 認証 | 読むテーブル | 書くテーブル | 組み立て |
|---|---|---|---|---|---|---|---|
| POST | `/api/initialize` | `main.go:109 initializeHandler` | `init.sh` で DB と DNS を初期化 | なし | - | 全テーブル、isudns | - |
| GET | `/api/tag` | `top_handler.go:25 getTagHandler` | タグの一覧 | なし | tags | - | - |
| GET | `/api/user/:username/theme` | `top_handler.go:57 getStreamerThemeHandler` | 配信者のテーマ | ログイン | users、themes | - | - |
| POST | `/api/livestream/reservation` | `livestream_handler.go:70 reserveLivestreamHandler` | 配信の予約 | ログイン | reservation_slots（FOR UPDATE） | reservation_slots、livestreams、livestream_tags | Livestream |
| GET | `/api/livestream/search` | `livestream_handler.go:173 searchLivestreamsHandler` | 配信の検索（タグ、または新しい順に limit 件） | なし | tags、livestream_tags、livestreams | - | Livestream × 件数 |
| GET | `/api/livestream` | `livestream_handler.go:240 getMyLivestreamsHandler` | 自分の配信の一覧 | ログイン | livestreams | - | Livestream × 件数 |
| GET | `/api/user/:username/livestream` | `livestream_handler.go:277 getUserLivestreamsHandler` | ユーザーの配信の一覧 | ログイン | users、livestreams | - | Livestream × 件数 |
| GET | `/api/livestream/:livestream_id` | `livestream_handler.go:395 getLivestreamHandler` | 配信の詳細 | ログイン | livestreams | - | Livestream |
| GET | `/api/livestream/:livestream_id/livecomment` | `livecomment_handler.go:68 getLivecommentsHandler` | コメントの一覧（新しい順、limit は任意） | ログイン | livecomments | - | Livecomment × 件数 |
| POST | `/api/livestream/:livestream_id/livecomment` | `livecomment_handler.go:161 postLivecommentHandler` | コメントの投稿（チップ、スパム判定） | ログイン | livestreams、ng_words | livecomments | Livecomment |
| POST | `/api/livestream/:livestream_id/reaction` | `reaction_handler.go:86 postReactionHandler` | リアクションの投稿 | ログイン | - | reactions | Reaction |
| GET | `/api/livestream/:livestream_id/reaction` | `reaction_handler.go:36 getReactionsHandler` | リアクションの一覧（新しい順、limit は任意） | ログイン | reactions | - | Reaction × 件数 |
| GET | `/api/livestream/:livestream_id/report` | `livestream_handler.go:434 getLivecommentReportsHandler` | 報告の一覧（配信者だけ） | ログイン（配信者本人） | livestreams、livecomment_reports | - | LivecommentReport × 件数 |
| GET | `/api/livestream/:livestream_id/ngwords` | `livecomment_handler.go:122 getNgwords` | NG ワードの一覧 | ログイン | ng_words | - | - |
| POST | `/api/livestream/:livestream_id/livecomment/:livecomment_id/report` | `livecomment_handler.go:256 reportLivecommentHandler` | スパムの報告 | ログイン | livestreams、livecomments | livecomment_reports | LivecommentReport |
| POST | `/api/livestream/:livestream_id/moderate` | `livecomment_handler.go:331 moderateHandler` | NG ワードの登録と、当てはまる過去のコメントの削除 | ログイン（配信者本人） | livestreams、ng_words、livecomments（全件） | ng_words、livecomments（DELETE） | - |
| POST | `/api/livestream/:livestream_id/enter` | `livestream_handler.go:321 enterLivestreamHandler` | 視聴の開始 | ログイン | - | livestream_viewers_history | - |
| DELETE | `/api/livestream/:livestream_id/exit` | `livestream_handler.go:361 exitLivestreamHandler` | 視聴の終了 | ログイン | - | livestream_viewers_history（DELETE） | - |
| POST | `/api/register` | `user_handler.go:208 registerHandler` | ユーザー登録と DNS のレコードの追加 | なし | - | users、themes、isudns（`pdnsutil add-record`） | User |
| POST | `/api/login` | `user_handler.go:277 loginHandler` | ログインして Cookie にセッションを書く | なし | users | - | - |
| GET | `/api/user/me` | `user_handler.go:166 getMeHandler` | 自分の情報 | ログイン | users | - | User |
| GET | `/api/user/:username` | `user_handler.go:342 getUserHandler` | ユーザーの情報 | ログイン | users | - | User |
| GET | `/api/user/:username/statistics` | `stats_handler.go:62 getUserStatisticsHandler` | ユーザーの統計（順位、視聴者数、リアクション数、コメント数、チップ、好きな絵文字） | ログイン | users（全件）、livestreams、reactions、livecomments、livestream_viewers_history | - | - |
| GET | `/api/user/:username/icon` | `user_handler.go:88 getIconHandler` | アイコンの画像（無ければ `NoImage.jpg`） | なし | users、icons | - | - |
| POST | `/api/icon` | `user_handler.go:119 postIconHandler` | アイコンの更新（DELETE して INSERT） | ログイン | - | icons | - |
| GET | `/api/livestream/:livestream_id/statistics` | `stats_handler.go:202 getLivestreamStatisticsHandler` | 配信の統計（順位、視聴者数、最大チップ、リアクション数、報告数） | ログイン | livestreams（全件）、reactions、livecomments、livestream_viewers_history、livecomment_reports | - | - |
| GET | `/api/payment` | `payment_handler.go:13 GetPaymentResult` | チップの総額 | なし | livecomments（SUM） | - | - |

組み立ての関数と、1 回に発行するクエリの数（T はその配信のタグの数）は次のとおり。

| 関数 | 場所 | 読むもの | クエリの数 |
|---|---|---|---|
| User（`fillUserResponse`） | `user_handler.go:401` | themes、icons（画像の全体を読んで SHA256 を計算） | 2 |
| Livestream（`fillLivestreamResponse`） | `livestream_handler.go:487` | users と User、livestream_tags、tags × T | 4 + T |
| Livecomment（`fillLivecommentResponse`） | `livecomment_handler.go:425` | users と User、livestreams と Livestream | 8 + T |
| Reaction（`fillReactionResponse`） | `reaction_handler.go:144` | Livecomment と同じ | 8 + T |
| LivecommentReport（`fillLivecommentReportResponse`） | `livecomment_handler.go:456` | users と User、livecomments と Livecomment | 12 + T |

## 5. アプリのアーキテクチャ

3 台とも同じ構成で、1 台の中で全部が動く。ベンチは `--nameserver` と `--webapp` に向けた 1 台（今は app1）だけを使う。

```text
+-----------+  DNS UDP :53                  +------------------- app1 (192.168.0.11) -----------------+
|   bench   | ----------------------------> | +----------+  TCP :3306 (isudns)                         |
| .0.100    |                               | | PowerDNS | ---------------------------+                |
|           |  HTTPS :443 (TLSv1.3)         | +----------+                            v                |
|           | ----------------------------> | +-------+  HTTP :8080  +--------+   +-------+            |
+-----------+   Host: <name>.u.isucon.local | | nginx | -----------> | isupipe|-->| MySQL |            |
                                            | +-------+   /api       |  (Go)  |   | 8.0   |            |
                                            |     |                  +--------+   +-------+            |
                                            |     | other paths          |  exec      ^                |
                                            |     v                      v            |                |
                                            |  public/            +-----------+       |                |
                                            |  (SPA)              | pdnsutil  | ------+                |
                                            |                     | init.sh   |  (isudns / isupipe)    |
                                            |                     +-----------+                        |
                                            +----------------------------------------------------------+
app2 (.12) と app3 (.13) は同じ構成で、今はベンチから使われていない
```

- nginx: `worker_processes auto`、`worker_connections 768`。upstream の keepalive の設定は無い。アクセスログは既定の形式で `/var/log/nginx/access.log`
- isupipe（`isupipe-go.service`）: `/home/isucon/webapp/go/isupipe` を isucon ユーザーで動かす。`env.sh` を読む
    - DB の接続プールは `SetMaxOpenConns(10)`（`main.go:100`）
    - `e.Debug = true`、ログのレベルは DEBUG、`middleware.Logger()` で全リクエストを記録する（`main.go:123-125`）
    - 外部コマンド: `/api/register` で `pdnsutil add-record`、`/api/initialize` で `init.sh`（中で mysql クライアントを 9 回と `pdnsutil load-zone`）
- MySQL 8.0.35: `127.0.0.1:3306` だけで待ち受ける。設定は Ubuntu の既定のまま（`mysqld.cnf` に独自の項目は無い）。DB は `isupipe`（アプリ）と `isudns`（PowerDNS）
- PowerDNS: `gmysql` のバックエンドで `isudns` を読む。UDP と TCP の 53 番、API は `127.0.0.1:8081`
    - キャッシュはすべて 0（`cache-ttl`、`query-cache-ttl`、`negquery-cache-ttl`）。問い合わせのたびに MySQL を引く
    - `log-dns-queries=yes`、`loglevel=7`、`log-dns-details=yes`

nginx の振り分け（`/etc/nginx/sites-enabled/isupipe.conf`）

| server_name | パス | 行き先 |
|---|---|---|
| `u.isucon.local`、`*.u.isucon.local`（443） | `/api` | `http://localhost:8080`（`Host` を渡す） |
| 同上 | それ以外 | `/home/isucon/webapp/public/` のファイル、無ければ `/index.html` |
| `_`（443、default_server） | `/` | `/var/www/html`（ボット避け、期限切れの証明書） |
| `_`（80） | `/` | `/var/www/html` |

## 6. テーブルのスキーマ

スキーマは `webapp/sql/initdb.d/10_schema.sql`。`isupipe` には 12 テーブルがあり、外部キーは 1 つも無い。関係はすべて列名とハンドラのクエリから推定した。インデックスは、主キー以外に `users.name`、`tags.name`（どちらも UNIQUE）、`ng_words.word` の 3 つだけ。

行数の左は初期データ（`initial_*.sql` の行を数えた値）、右は初回ベンチの 1 回の後（`SELECT COUNT(*)`）。

```text
                    +---------------------------+
                    | users      1,000 / 1,170  |
                    +---------------------------+
                    | PK id              BIGINT |
                    | UQ name           VARCHAR |
                    |    display_name   VARCHAR |
                    |    password       VARCHAR |
                    |    description       TEXT |
                    +---------------------------+
                      | 1         | 1        | 1
          +-----------+           |          +-----------------+
          | 1 (推定)              | N (推定)                   | 1 (推定)
+-------------------------+  +---------------------------+  +---------------------------+
| themes  1,000 / 1,170   |  | livestreams 7,495 / 7,567 |  | icons         0 / 163     |
+-------------------------+  +---------------------------+  +---------------------------+
| PK id            BIGINT |  | PK id              BIGINT |  | PK id              BIGINT |
|    user_id       BIGINT |  |    user_id         BIGINT |  |    user_id         BIGINT |
|    dark_mode    BOOLEAN |  |    title          VARCHAR |  |    image         LONGBLOB |
+-------------------------+  |    description       TEXT |  +---------------------------+
                             |    playlist_url   VARCHAR |
                             |    thumbnail_url  VARCHAR |
                             |    start_at        BIGINT |
                             |    end_at          BIGINT |
                             +---------------------------+
```

`livestreams` を中心にした関係。どれも `livestream_id` で配信につながり、`user_id` で書いた人につながる（推定）。

```text
+------------------------------+        +----------------------------+
| livestream_tags              |  N   1 | tags            103 / 103  |
|            10,966 / 11,248   |--------| PK id               BIGINT |
| PK id                 BIGINT |        | UQ name            VARCHAR |
|    livestream_id      BIGINT |        +----------------------------+
|    tag_id             BIGINT |
+------------------------------+
        | N (推定)
        |       +---------------------------------+
        +-------| livestreams                     |
        1       +---------------------------------+
                  | 1            | 1            | 1             | 1
                  | N (推定)     | N (推定)     | N (推定)      | N (推定)
+------------------------+ +-----------------------+ +---------------------+ +---------------------+
| livecomments           | | reactions             | | ng_words            | | livestream_viewers_ |
|        1,000 / 1,202   | |       1,000 / 1,178   | |   14,337 / 14,354   | | history       0 / 9 |
| PK id           BIGINT | | PK id          BIGINT | | PK id        BIGINT | | PK id        BIGINT |
|    user_id      BIGINT | |    user_id     BIGINT | |    user_id   BIGINT | |    user_id   BIGINT |
|    livestream_id BIGINT| |    livestream_id      | |    livestream_id    | |    livestream_id    |
|    comment     VARCHAR | |    emoji_name VARCHAR | | IDX word    VARCHAR | |    created_at       |
|    tip          BIGINT | |    created_at  BIGINT | |    created_at       | +---------------------+
|    created_at   BIGINT | +-----------------------+ +---------------------+
+------------------------+
        | 1
        | N (推定)
+-----------------------------+   +-----------------------------+
| livecomment_reports  0 / 41 |   | reservation_slots           |
| PK id                BIGINT |   |             8,759 / 8,759   |
|    user_id           BIGINT |   | PK id                BIGINT |
|    livestream_id     BIGINT |   |    slot                     |
|    livecomment_id    BIGINT |   |    start_at          BIGINT |
|    created_at        BIGINT |   |    end_at            BIGINT |
+-----------------------------+   +-----------------------------+
```

- `livestream_tags.tag_id` → `tags.id`、`livecomment_reports.livecomment_id` → `livecomments.id`（推定）
- `ng_words.user_id` は配信者。スパム判定は `(user_id, livestream_id)` で引く（`livecomment_handler.go:201`）
- `reservation_slots` は 1 時間ごとの予約枠で、2023-11-25 01:00 から 2024-11-24 00:00（UTC）までの 8,759 行。`slot` の初期値は 0〜5。他のテーブルとは時刻の範囲でつながる
- `reactions`、`livestream_viewers_history`、`livecomment_reports` の `user_id` は、操作したユーザー（推定）

`isudns`（PowerDNS）には 7 テーブルがあり、使うのは `domains` と `records`。`records` は初回ベンチの後で 1,450 行（SOA 1、NS 1、A 1,448）。初期のゾーンファイルの A レコードは 1,278 行で、残りは登録したユーザーの分。

```text
+---------------------------------+
| records (isudns)   1,450 rows   |
+---------------------------------+
| PK id                    BIGINT |
| IDX domain_id               INT |
|     name                VARCHAR |
|     type                VARCHAR |
|     content             VARCHAR |
|     ttl                     INT |
| IDX ordername           VARCHAR |
+---------------------------------+
```

## 7. リクエストの共通処理

どのリクエストも、echo のミドルウェアを 2 つ通る（`main.go:125-128`）。

1. `middleware.Logger()`: リクエストごとにアクセスログを書く
2. `session.Middleware(cookieStore)`: Cookie `SESSIONID` を、gorilla/sessions の Cookie ストアで復号する。秘密鍵は `ISUCON13_SESSION_SECRETKEY`（無ければ固定の値）

ログインが要るハンドラは、先頭で `verifyUserSession`（`user_handler.go:377`）を呼ぶ。

1. セッションを取り出す。失敗したら 401
2. `EXPIRES` が無ければ 403、`USERID` が無ければ 401
3. 今が `EXPIRES` を過ぎていたら 401（ログインから 1 時間）

セッションは Cookie の中だけにあるので、確かめるのに DB は引かない。ユーザー名やユーザー ID は、セッションの値をそのまま使う。

| どのリクエストでも毎回かかるもの | 対象 |
|---|---|
| アクセスログ（`middleware.Logger`）、DEBUG のログ（`e.Debug = true`） | 全部 |
| Cookie のセッションの復号と HMAC の検証 | 全部（ログインが要らないものも、ミドルウェアは通る） |
| `BeginTxx` と `Commit`（読むだけのハンドラも） | `/api/initialize` 以外の全部 |
| User の組み立て（`themes` と `icons` を引き、アイコンの画像の全体を読んで SHA256） | ユーザー、配信、コメント、リアクション、報告を返すもの全部 |
| DNS の問い合わせ（サブドメインを MySQL で引く。TTL 0 なので毎回） | 配信者のサブドメインに送るもの全部（ベンチの側） |

## 8. 通信の流れ

どの図も、最初の数行は 7 節の共通処理（ログ、セッションの復号、`verifyUserSession`、`BEGIN`）。

### コメントを読んで、チップ付きで送る（スコアになる流れ）

ベンチは、配信の時間数だけこれを繰り返す。`GET` に limit は付かないので、配信のコメントを全部返す。

```text
bench         PowerDNS      nginx         app                               MySQL
  |  A? <owner>.u.isucon.local |            |                                  |
  |------------>|-- SELECT records -------------------------------------------->|
  |<------------|  192.168.0.11             |                                  |
  |  GET /api/livestream/:id/livecomment    |                                  |
  |-------------------------->|------------>|-- BEGIN ------------------------>|
  |                           |             |-- SELECT livecomments WHERE      |
  |                           |             |   livestream_id = ? (full scan)->|
  |                           |             |   for each comment (C rows):     |
  |                           |             |     users, themes, icons,        |
  |                           |             |     livestreams, users, themes,  |
  |                           |             |     icons, livestream_tags,      |
  |                           |             |     tags x T  (8 + T queries) -->|
  |                           |             |-- COMMIT ----------------------->|
  |<--------------------------|<------------|  200 (C comments)                |
  |  A? <owner>.u.isucon.local (again)      |                                  |
  |  POST /api/livestream/:id/livecomment   |                                  |
  |-------------------------->|------------>|-- SELECT livestreams ----------->|
  |                           |             |-- SELECT ng_words WHERE          |
  |                           |             |   user_id, livestream_id ------->|
  |                           |             |   for each NG word (W rows):     |
  |                           |             |     SELECT ... LIKE ------------>|
  |                           |             |-- INSERT livecomments ---------->|
  |                           |             |-- fill: 8 + T queries ---------->|
  |                           |             |-- COMMIT ----------------------->|
  |<--------------------------|<------------|  201                             |
```

1 回の GET は 2 + C × (8 + T) 本、POST は 4 + W + (8 + T) 本のクエリを発行する。

### 配信に入る（視聴の最初）

```text
bench         nginx         app                                 MySQL
  |  POST .../enter           |                                    |
  |------------>|------------>|-- INSERT livestream_viewers_history>|
  |<------------|<------------|  200                               |
  |  GET .../statistics       |                                    |
  |------------>|------------>|-- SELECT livestreams WHERE id ---->|
  |             |             |-- SELECT * FROM livestreams ------>|  (all 7,500+ rows)
  |             |             |   for each livestream:             |
  |             |             |     COUNT reactions JOIN --------->|
  |             |             |     SUM tip JOIN livecomments ---->|
  |             |             |-- COUNT viewers, MAX tip,          |
  |             |             |   COUNT reactions, COUNT reports ->|
  |<------------|<------------|  200                               |
  |  GET .../livecomment?limit=10, GET .../reaction?limit=10       |
  |------------>|------------>|-- 10 x (8 + T) queries each ------>|
  |<------------|<------------|                                    |
```

`GET /api/livestream/:id/statistics` は、配信の数（7,500 以上）× 2 本の集計を発行する。

### ユーザー登録（準備）

```text
bench         nginx         app                     MySQL        pdnsutil
  |  POST /api/register       |                        |              |
  |------------>|------------>|-- BEGIN -------------->|              |
  |             |             |-- INSERT users ------->|              |
  |             |             |-- INSERT themes ------>|              |
  |             |             |-- exec add-record ------------------->|
  |             |             |                        |<-- INSERT ---| (isudns)
  |             |             |-- fill: themes, icons->|              |
  |             |             |-- COMMIT ------------->|              |
  |<------------|<------------|  201                   |              |
```

`pdnsutil` はリクエストごとに新しいプロセスとして起動する。

## 気づいたこと

- コメント、リアクション、報告の一覧は、1 件ごとにユーザーと配信を組み立て直す（`livecomment_handler.go:105-113`、`reaction_handler.go:69-77`）。1 件 8 + T 本
- 視聴者のシナリオは、コメントの一覧を limit なしで取る（`viewer.go` の `client.GetLivecomments` に option が無い）
- `fillUserResponse` は、アイコンの画像を DB から全部読んで、毎回 SHA256 を計算する（`user_handler.go:407-417`）
- `getIconHandler` は条件付き GET を見ず、常に 200 で画像を返す（`user_handler.go:88-117`）
- `GET /api/livestream/:id/statistics` は全配信 × 2 本、`GET /api/user/:username/statistics` は全ユーザー × 2 本の集計を発行する（`stats_handler.go:237-253`、`stats_handler.go:96-122`）
- `moderateHandler` は、配信の NG ワードごとに `SELECT * FROM livecomments`（全件）を取り、コメントごとに DELETE を発行する（`livecomment_handler.go:390-414`）
- `postLivecommentHandler` のスパム判定は、NG ワード 1 つにつき 1 本の SELECT を発行する（`livecomment_handler.go:205-222`）
- `ng_words` は初期で 14,337 行あり、攻めたモデレーションのシナリオで増え続ける
- `searchLivestreamsHandler` のタグ検索は、配信 1 件ごとに `SELECT * FROM livestreams WHERE id = ?` を発行する（`livestream_handler.go:200-207`）
- `reserveLivestreamHandler` は、`reservation_slots` を範囲で `FOR UPDATE` した後、枠ごとにもう一度 SELECT する（`livestream_handler.go:109-122`）
- `livecomments`、`reactions`、`livestream_tags`、`icons`、`themes`、`livestreams` などに、`livestream_id` や `user_id` のインデックスが無い
- `isudns.records` には、PowerDNS の標準スキーマ（`/usr/share/doc/pdns-backend-mysql/schema.mysql.sql`）にある `nametype_index (name, type)` が無い。問い合わせのたびに名前で引く
- PowerDNS のキャッシュがすべて 0 で、問い合わせのログ（`log-dns-queries`、`loglevel=7`）が有効になっている
- レコードの TTL はすべて 0 で、ベンチは名前解決の結果をキャッシュしない
- 初回ベンチの失敗は、DNS（UDP 53）の i/o timeout と `GET /api/livestream/search` のタイムアウトだった（`/tmp/result.json`）
- `/api/register` は、トランザクションの中で `pdnsutil` を外部コマンドとして実行する（`user_handler.go:259`）
- 接続プールの上限は 10 本（`main.go:100`）

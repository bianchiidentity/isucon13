# E2E ベースライン（ISUPipe 初期実装）

初期実装の画面を Playwright のアサーションで固定したもの。改修後に再実行して、画面が壊れていないかを確かめる。

## 実行方法

```sh
cd e2e
npm install            # 初回のみ
npx playwright test    # 14 本、初期実装で約 45 秒
npx playwright show-report   # 失敗時の詳細（トレース・スクショ）
```

接続先は環境変数で上書きできる。

| 変数 | 既定値 |
|---|---|
| `E2E_PIPE_URL` | `https://pipe.u.isucon.local` |
| `E2E_USER_URL` | `https://test001.u.isucon.local` |

前提:
- `/etc/hosts` で 2 つのホストがサーバを向いていること
- `POST /api/initialize` 済みで、初期データが入っていること（未投入だとログインに失敗する）

ログインには初期データの `test001` / `test` を使う（`webapp/sql/initial_users.sql`）。

## カバーしているページ

| ホスト | パス | ロール | 動的パラメータ | 待つ要素 | アサーション |
|---|---|---|---|---|---|
| pipe | `/` | 未ログイン | - | 「ログインが必要です」 | 未ログイン表示、配信中、カードが 1 件以上 |
| pipe | `/account/login` | 未ログイン | - | Username 欄 | 入力欄、ログインボタン、新規登録リンク |
| pipe | `/account/signup` | 未ログイン | - | 入力欄 | Username / Description / Login ID / Password、登録ボタン |
| pipe | `/account/login` → `/` | 未ログイン→test001 | - | ヘッダのユーザー名 | UI からログインでき、トップに遷移する |
| pipe | `/console` | 未ログイン | - | 「ログインが必要です」 | 配信一覧の見出し |
| test001 | `/user` | 未ログイン | - | 「ログインが必要です」 | 統計欄のラベル |
| pipe | `/` | test001 | - | カード | ヘッダのユーザー名、配信中、カードが 1 件以上 |
| pipe | `/search?q=DIY` | test001 | タグ `DIY` | カード | 「検索結果 DIY」、カードが 1 件以上 |
| pipe | `/console` | test001 | - | 配信タイトル | 配信一覧、test001 の配信「映画レビュー！最新映画の感想を語る」 |
| pipe | `/console`（モーダル） | test001 | - | ダイアログ | 予約配信の作成モーダルの入力欄。Esc で閉じる |
| pipe | `/console/live/999` | test001 | 配信 999（test001 の配信） | タイトル | タイトル、説明、NG Word、NG ワード「精神鍛錬術」、通報されたコメント |
| pipe | `/watch/999` | test001 | 配信 999 | タイトル、関連配信 | タイトル、説明、配信者名、Related Live、送信ボタン |
| test001 | `/user` | test001 | ユーザー test001 | 統計（最大 150 秒） | プロフィール「社内検証用」、配信タイトル、統計の書式（ランキング N 位など） |
| test001 | `/user`（モーダル） | test001 | - | ダイアログ | アイコン変更モーダル。Esc で閉じる |

期待値には、ベンチで変わらないデータを使っている:
- **test001 は検証用ユーザで、ベンチは使わない**。配信 999 のタイトル・説明・NG ワード、プロフィール文は固定
- トップ・検索・関連配信の一覧は、新しい順に並ぶのでベンチが予約した配信で入れ替わる。「カードが 1 件以上ある」ことだけを見る
- ユーザーの統計（ランキング・コメント数など）はベンチで変わるので、書式だけを見る

## カバーしていないもの

- 更新系の操作すべて: ログイン以外の送信（新規登録、予約配信の作成、コメント・リアクション・チップの送信、NG ワード追加、通報、アイコン変更）。モーダルは開いて閉じるだけ
- `/api/initialize`
- 他のユーザーのサブドメイン（`<username>.u.isucon.local`）。関連配信やカードのリンク先は `https://<owner>.u.isucon.local/watch/:id` で、`/etc/hosts` に無いので開けない
- 統計の具体的な値

## 初期実装の癖（テストが落ちたときの切り分け用）

- **statistics API が非常に遅い**。`/api/livestream/:id/statistics` と `/api/user/:name/statistics` は単発でも 7 秒前後、ページから並列で叩かれると 1 本 40〜60 秒かかる。トップは配信 10 件分、視聴ページは関連配信約 100 件分を一斉に叩く
- **HTTP/1.1 の接続枠が詰まる**。上のせいでブラウザの 1 ホスト 6 本の接続が埋まり、次の `page.goto` や API 呼び出しが数十秒〜数分待たされる。そのため:
  - ログインは基本的に `page.request` で API から行う（`apiLogin`）。UI ログインは専用の 1 本だけ
  - `page.goto` は `waitUntil: 'commit'` にし、表示要素の出現で待つ
  - 画面遷移で打ち切られたリクエスト（`net::ERR_ABORTED`）はエラーとして数えない（`fixtures.ts`）
- **未ログインでは `GET /api/user/me` が 403** を返し、ブラウザが `console.error` を出す。トップでは未ログインでも statistics を叩いて 403 になる。どちらも初期実装の挙動なので、guest のテストに限ってエンドポイントを絞って許可している
- **視聴ページと配信管理ページは、開くだけで `POST /api/livestream/:id/enter`**（視聴履歴の INSERT、StrictMode で 2 回）を送る。exit はアンマウント時の `DELETE .../exit` で、タブを閉じても送られない。放置すると「N人が視聴中」が増え続けるので、テストの最後に後片付けをしている:
  - 配信管理: ヘッダのロゴ（SPA の Link）で画面を離れ、exit を発火させる
  - 視聴: 関連配信の statistics で接続が埋まり exit が数分待たされるので、`page.request.delete` で exit を直接叩く
- ロゴやカードのリンクは絶対 URL（`https://pipe.u.isucon.local/` など）
- 「ログインが必要です」のモーダルは背後を aria-hidden にするので、未ログイン時はヘッダのボタンをロールで取れない
- 配信のサムネイルと動画は外部の `media.xiii.isucon.dev` から読む

## 改修後の確認方法

1. `npx playwright test` が全部通ること。落ちたら `npx playwright show-report` で、失敗したアサーションと `problems` の添付（HTTP エラー・JS 例外）を見る
2. `git status e2e/screenshots` で変わった画面を開いて目視する

スクショは比較せず、上書き保存するだけ。次の 3 枚は、カードごとの statistics（「N人視聴」）が届くタイミングで**毎回変わる**ので、差分が出ても気にしなくてよい:
`pipe-guest-top.png`, `pipe-streamer-top.png`, `test001-streamer-user.png`

動画プレーヤーは再生位置で毎回変わるので、撮影前に止めて非表示にしている（`hideVideo`）。

statistics を高速化すると、カードの「N人視聴」がスクショ時点で埋まるようになり、上の 3 枚が安定して変わる。これは改善による変化で、劣化ではない。

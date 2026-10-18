# 偵察: ページ・認証・ホストを洗い出す

目的は「どのホストの、どのパスを、どのロールで開くと、何が表示されるか」の一覧を作ること。
ソースを読むのが最速。見つからなければビルド済みバンドルや実機から辿る。

## 目次
1. フロントエンドの所在
2. ルーティング（ページ一覧）
3. ホスト / サブドメインの分岐
4. 認証
5. 各ページが叩く API と表示内容
6. ベンチマーカーは宝の山

## 1. フロントエンドの所在

```sh
ls; find . -name package.json -not -path '*/node_modules/*' | head
find . -name index.html -not -path '*/node_modules/*' | head   # ビルド済み静的ファイル
grep -rn "root\|try_files\|location" <nginx設定> | head          # どのディレクトリを配信しているか
```

ISUCON ではソース（`frontend/`）とビルド成果物（`public/`, `webapp/public/`）が両方あることが多い。
ソースがなくビルド済み JS しかない場合は、バンドルを grep する:

```sh
grep -oE '"/[a-z_/:.-]*"' public/js/app.*.js | sort -u        # ルートや API パス候補
grep -oE "path:\s*\"[^\"]*\"" public/js/app.*.js | sort -u
```

## 2. ルーティング

| フレームワーク | 見る場所 |
|---|---|
| Vue Router | `src/router/*.ts` の `routes` |
| React Router | `createBrowserRouter`, `<Route path=` を grep |
| Next.js | `pages/` or `app/` ディレクトリ構造がそのままパス |
| Nuxt | `pages/` |
| SvelteKit | `src/routes/` |
| サーバサイドテンプレート (Go/Ruby 等) | ハンドラ登録 (`e.GET(`, `r.HandleFunc(`, `get '/'`) と `templates/` |

`:id` のような動的パラメータを持つページは、後で具体的な ID が必要になるのでメモしておく。
catch-all のリダイレクト（`/:catchall(.*)` → `/` 等）や、未ログイン時のリダイレクトも挙動として記録する。

## 3. ホスト / サブドメインの分岐

マルチテナント問題ではホスト名で表示するアプリ自体が変わることがある。例:

```ts
if (location.hostname.split('.')[0] === 'admin') createApp(AdminApp)... else createApp(TenantApp)...
```

`location.host`, `hostname`, `subdomain` を grep。ホストごとにページ一覧を分けて扱う。
ローカルからアクセスできるホスト名は `/etc/hosts` を確認し、足りなければユーザーに追加してもらう（勝手に編集しない）。

## 4. 認証

優先順位: **UI のログインフォームをそのまま使う** > API を直接叩いて cookie を得る > トークンを自前で生成する。
E2E の目的は「ユーザー操作として壊れていないか」なので、フォーム経由が一番価値が高く、実装変更にも強い。

見つけ方:
- ログイン画面の `<form>` / `submit` ハンドラ → 送信先エンドポイント（`/login`, `/auth/...`, `/api/session` 等）
- ロール切替ボタン（例: 「管理者モードに切り替える」）
- ログイン ID / パスワード: `initial_data/`, SQL ダンプ, ベンチマーカーのフィクスチャ, README, 当日マニュアル。
  パスワードがハッシュ化されていてわからない場合、ベンチのデータ生成コードに平文があることが多い
- 外部 IdP 風の仕組み（JWT を別サービスが署名する等）: そのサービスが実機で動いているか curl で確認。
  動いていなければベンチマーカーのトークン生成コードを Node で再現し、`context.addCookies` で注入する

確認は curl で行う:
```sh
curl -sk -i -X POST -d 'id=xxx' https://<host>/<login-endpoint> | head   # Set-Cookie が返るか
```

## 5. 各ページが叩く API と表示内容

ページコンポーネントごとに:
- 呼んでいる API（`axios.get`, `fetch(`）
- 表示している見出し・テーブルのカラム名・ボタン文言
- ローディング表示（「読み込み中…」等）→ これが消えて実データが出たことを待つ必要がある
- ページングや「さらに読み込む」
- **押すと状態が変わるボタン**（追加・削除・完了・失格・CSV 入稿など）→ テストでは押さない

## 6. ベンチマーカーは宝の山

`bench/` があれば必ず見る:
- ログイン方法とトークン生成（認証の再現に使える）
- 整合性チェック（validation）: 「この初期テナントの請求額は X」など、**正解値がハードコードされている**ことが多い。
  これはアサーションの期待値としてそのまま使える
- 静的ファイルのチェック: どのパスが配信されるべきかのリスト

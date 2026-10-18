# isucon13

## スクリプト

- [リモートへの Codex CLI 導入](script/setup-codex/README.md)

## Discord の main push 通知

Discord の通知先チャンネルの「連携サービス → ウェブフック」で Webhook を作成し、URL をコピーする。
[Actions secrets](https://github.com/bianchiidentity/isucon13/settings/secrets/actions) に
`DISCORD_WEBHOOK_URL` という Repository secret として登録すると、main への push（PR のマージを含む）を通知する。
URL は投稿用の認証情報なので、リポジトリへ書き込まない。

通知内容は実行者・コミット概要（最大5件）・差分リンク。デプロイ完了を意味しない。
Secret 未登録の場合は送信をスキップする。
登録後は Actions の「Notify Discord of main push」から「Run workflow」でテスト送信できる。

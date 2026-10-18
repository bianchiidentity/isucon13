# リモートへの Codex CLI 導入

手元の Mac / Linux から SSH で接続し、Linux サーバーの `isucon` ユーザーへ Codex CLI を導入する。EC2 以外でも使える。

## 使い方

リポジトリのルートで実行する。SSH 設定の Host alias を使う場合:

```bash
bash script/setup-codex/setup-codex-ec2.sh isu1
```

接続ユーザーと鍵を明示する場合:

```bash
SSH_USER=ubuntu SSH_KEY=~/.ssh/example.pem \
  bash script/setup-codex/setup-codex-ec2.sh example.com
```

| 環境変数 | 既定値 | 内容 |
|---|---|---|
| `SSH_HOST` | なし | 接続先。コマンド引数を優先し、どちらもなければ対話入力 |
| `SSH_USER` | SSH の設定に従う | 接続ユーザー |
| `SSH_KEY` | SSH の設定・ssh-agent に従う | 手元の秘密鍵のパス |
| `INSTALL_USER` | `isucon` | サーバー上の導入先ユーザー |

接続先はホスト名・IPv4・SSH alias に対応する。EC2 のホスト名は省略せず指定する。ポートや踏み台は `~/.ssh/config` に設定する。

## 必要なものと変更内容

- 手元に Bash と SSH、サーバーに Bash・curl・CA 証明書が必要。
- 導入先ユーザーは作成済みであること。接続ユーザーが異なる場合、そのユーザーへ `sudo -n -iu` で切り替えられること。
- サーバーから公式インストーラーと配布先へ HTTPS 接続できること。

[公式の導入方法](https://learn.chatgpt.com/docs/codex/cli)のインストーラーを一時ファイルへ取得し、`~/.local/bin` を指定して実行する。再実行時もインストーラーを実行するため、バージョンは固定しない。

導入先ユーザーの `.bashrc`・`.profile` と、既に存在する `.bash_profile`・`.bash_login` の先頭に PATH 設定を追加する。同じ行が先頭にある場合は追加しない。最後にバージョン表示と、新しい Bash ログインシェルからの PATH を確認する。

SSH のホスト鍵確認は通常の設定に従う。秘密鍵や Codex の認証情報は転送・保存しない。鍵やトークンをこのディレクトリへ置かず、導入後のログインはサーバー上で各自行う。

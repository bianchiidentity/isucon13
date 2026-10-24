# setup

各サーバーで最初に 1 回行う準備。[`join.sh`](../setup-repo/README.md) で全台を同じリポジトリの状態にした後に、各台で実行する。

```bash
cd ~/isucon13
sudo script/setup/setup.sh --git-user=<GitHub のユーザー名> --dry-run  # 行うことを確かめる
sudo script/setup/setup.sh --git-user=<GitHub のユーザー名>
```

`--git-user` には、その台を使う人の GitHub のユーザー名を渡す。

| 行うこと | 理由 |
|---|---|
| OS の自動アップデートを止める（base-conf と同じ） | setup-tools が apt を使うので、その前に止める。動いたままだと `apt-get update` を引き金に数百のパッケージが更新され、MySQL が再起動した（isucon12） |
| `/etc/hosts` に `127.0.1.1 <ホスト名>` を足す（引けなければ） | 無いと sudo のたびに「unable to resolve host」が出る（isucon13 の AMI） |
| [`setup-tools.sh`](../setup-tools/README.md) でツールを入れる | graphviz、sysstat、jq、版を固定した mysqldef |
| isucon の git の作者（`user.name`、`user.email`）を `--git-user` の人にする | サーバー上でのコミットに記録される。メールアドレスは GitHub の noreply（`<ID>+<ユーザー名>@users.noreply.github.com`）にし、コミットをその人のアカウントに結び付ける。ID は GitHub の API の応答を jq で読む。push の認証（deploy key）とは別 |

- 何度実行しても同じ結果になる。台を使う人が替わったら、`--git-user` を変えて実行し直す。
- GitHub の API（`api.github.com`）でユーザーの ID を引く。名前を間違えると止まる。
- ベンチ中に実行しない。setup-tools の apt が CPU とディスクを使う。

## 当日の最初の順番

1. 1 台目で鍵を作り、deploy key に登録して、webapp をリポジトリに入れる（[setup-repo](../setup-repo/README.md) の「1 台目」）
2. 1 台目で `join.sh` を 1 回実行し、全台を同じリポジトリの状態にする
3. 各台で `setup.sh` を実行する
4. base-conf を入れる（[base-conf](../base-conf/README.md)）

入れないもの: base-conf（誰がいつ入れるかを別に決める）、Claude Code や Codex（手元から [`setup-codex`](../setup-codex/README.md) で入れる）、タイムゾーン（AMI は UTC。変えるとログの時刻がずれるので、そのままにする）、pprotein。

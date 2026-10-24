# setup-repo

当日の最初に、全台を同じリポジトリの状態（`/home/isucon/isucon13` の clone と、`/home/isucon/webapp` からそこへのリンク）にする。1 人が 1 台目（isu1）で行い、ほかの人は何もしなくてよい。

## 1 台目

リポジトリは private なので、clone の前に deploy key が要る。鍵は 1 つを全台で共有し、サーバー間の ssh（`./deploy --server=`）にも使う。

1. isu1 の isucon で鍵を作る。

   ```bash
   sudo -iu isucon
   ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
   cat ~/.ssh/id_ed25519.pub
   ```

2. リポジトリの管理者が、GitHub の Settings > Deploy keys に公開鍵を登録する。**Allow write access にチェックを付ける**（サーバーから push するため）。
3. clone して、webapp をリポジトリに入れる（[deploy の README](../deploy/README.md#webapp-をリポジトリに入れる) の「1 台目」）。

   ```bash
   git clone git@github.com:<owner>/<repo>.git ~/isucon13
   ```

   - `.gitignore` に生成物（ビルドしたバイナリ、依存のライブラリ）を入れる。元の `webapp/.gitignore` が除外していたもの（isucon13 では `/public/`）も確かめる。
   - 使わない言語の実装は消してよい。
   - base-conf を入れる前に、`script/deploy/collect-conf.sh` で素の設定を集めておくと、base-conf の差分が残る。
4. commit して push する。

## 2 台目以降

isu1 で 1 回実行する。手元から `ssh -A` で isu1 に入り、ログインしたユーザー（isucon に切り替えない）で実行する。

```bash
sudo --preserve-env=SSH_AUTH_SOCK /home/isucon/isucon13/script/setup-repo/join.sh \
  isu1=192.168.0.11 isu2=192.168.0.12 isu3=192.168.0.13
```

- 名前=IP（プライベート IP）を、isu1 自身も含めて全台ぶん並べる。名前は `./deploy --server=` と `conf/<名前>/`、`roles.env` に使う。各台の `/etc/isucon-server-name` にも書き、前半の `./deploy` はそこから名前を読む（AWS のホスト名は使わない）。
- ほかの台への最初の接続には、転送した手元の鍵を使う。ログインのユーザーが ubuntu でなければ `--login=isucon` などを付ける。`--dry-run` で、行うことだけを表示する。
- isu1 の HEAD が push 済みである必要がある。ほかの台は GitHub から同じコミットを取る。
- リポジトリが public なら止まる。レギュレーションで、競技が終わるまで内容を公開・共有できないため（認証なしの https で読めるかで確かめる）。public のリポジトリで過去問を演習するときは `--allow-public` を付ける。
- 何度実行しても同じ結果になる。台を後から足すときも、全台を並べて実行し直す。

各台で行うこと:

| 台 | 行うこと |
|---|---|
| 全台 | `/etc/isucon-server-name` にその台の名前を書く |
| 全台 | isucon の `~/.ssh/config` に全台の名前と IP を書く（印の行で囲んだ範囲を毎回書き直す）。どの台からでも `./deploy --server=` を実行できる |
| isu1 | 共有の鍵を自分の `authorized_keys` に足す（どの台から `./deploy --server=` を実行しても isu1 に入れるように。isu1 から自分への ssh にも使う） |
| ほか | isucon に、deploy key と、ほかの台からの ssh 用の `authorized_keys`、GitHub の `known_hosts` を置く。isu1 と同じブランチ・コミットで clone する。アプリを止め、`/home/isucon/webapp` を `webapp.orig` に移してリンクにし、git に入れなかったもの（ビルドしたバイナリなど）を `webapp.orig` から写して、アプリを起動し直す（止まっていた台は起動しない） |

終わったら、各台で [`setup.sh`](../setup/README.md) を実行する。`./deploy` の mysql の段は、setup.sh が入れる mysqldef を使う。全台の差分は、base-conf と collect-conf の後に `./deploy --server=isu1,isu2,isu3 --dry-run` で確かめる（[当日の最初の順番](../setup/README.md#当日の最初の順番)）。

## 2 回目以降

各台の clone は、`./deploy --server=` が isu1 の HEAD に合わせる。1 台だけに反映するときは、その台で `git pull` してから `./deploy`。

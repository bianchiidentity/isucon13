# deploy

リポジトリの内容（Go のコード、nginx と MySQL の設定、DB のスキーマ）をサーバーに反映する。入口はリポジトリ直下の `./deploy`。
前半（1 人 1 台）は `./deploy`、後半（複数台）は `./deploy --server=isu1,isu2,isu3`。オプションは `./deploy --help`。

## 考え方

- **リポジトリが正。** サーバーは「リポジトリにあるべき状態」に合わせる。前半の `./deploy` は、そのサーバーの作業ツリーをそのまま反映する（コミットしていない変更も入る）。後半の `--server` は、push 済みの HEAD だけを反映する。設定は `conf/default/`（全サーバー共通）と `conf/<サーバー名>/`（そのサーバーだけ）に、置き先と同じパスで持つ。
- **何を反映するかは役割で決まる。** `roles.env` にサーバーごとの役割（nginx、app、mysql）を書く。書いていないサーバーは全部入りなので、前半は何も書かなくてよい。`--server` は「どこに」だけを決める。
- **問題ごとの値は `deploy.env` だけ。** サービス名、ビルドのコマンド、DB、スキーマのファイル。当日、実物を見て書き換える。
- **スキーマは sqldef。** `/initialize` が流す SQL ファイルを正とし、今の DB との差分だけを当てる。DROP が出たら止まる。

## 特性

| 特性 | 内容 |
|---|---|
| 冪等 | 何度実行しても同じ状態になる。途中で失敗しても止めても、もう一度実行すればそろう（reload の前に止まった場合も、反映待ちの印でやり直す）。前の版に戻すときは、前のコミットに戻してから実行する |
| 失敗したら止める | `nginx -t` や MySQL の起動に失敗したら、その段の設定を戻して止まる。後ろの段は実行しない |
| 並列 | `--server` では 2 段で反映する。1 段目は mysql の役割のサーバー、2 段目は残り。段の中は並列で、1 段目が失敗したら 2 段目に進まない。`--serial` で 1 台ずつ |
| 同じコミット | `--server` では、実行したサーバーの HEAD（push 済みであること）を各サーバーが fast-forward で取り込む。違えば止まる |
| 副作用のない dry-run | `--dry-run` は差分を表示するだけ。`--server` でも各サーバーの作業ツリーを動かさない（一時的な worktree で比べる） |
| 同時実行の防止 | 1 台のサーバーで 2 つの deploy が同時に動かないよう、ロックを取る |
| 版の記録 | 最後に、反映したコミット（リポジトリと、別の git なら webapp も）を記録する。`./bench` がそれを結果に写すので、どの版を測ったかが残る |

## 実行する前に

### アイコン検索の索引を反映する（Issue #17）

`icons(user_id)` はリポジトリ内の `webapp/sql/initdb.d/10_schema.sql` に定義している。
サーバーでコードを更新した後、通常の `./deploy` で MySQL の段が差分を適用する。
索引だけを反映するときは次を実行する（MySQL の役割を持つサーバーで実行）。

```bash
./deploy --only=mysql --dry-run
./deploy --only=mysql
```

`mysqldef` が表示する差分で `icons_user_id` の追加を確認する。既存 DB に他の差分が
ある場合は、それも表示・適用の対象になる。意図しない DROP があれば既定で停止する。
反映済みなら再実行時に同じ索引を追加しない。初期化は TRUNCATE のため索引を保持し、
DB を新規作成する場合もスキーマ定義から作成される。
確認には `SHOW INDEX FROM isupipe.icons;` と
`EXPLAIN SELECT image FROM isupipe.icons WHERE user_id = 1;` を使う。

### 必要な条件

- 実行するユーザー（リポジトリの持ち主。普通は isucon）が、パスワードなしで sudo できる。
- 各サーバーが GitHub から fetch できる。`--server` では、実行したサーバーで push まで済ませておく。
- `--server` では、全サーバーで、リポジトリが同じパスにある。実行したサーバーから `ssh <サーバー名>` で鍵だけで入れる（`~/.ssh/config` の `Host isu1` など）。
- `roles.env` のサーバー名と、`--server` に渡す名前が同じ。
- mysql の役割のサーバーで、sqldef を入れるためにインターネットにつながる（初回だけ）。`deploy.env` の DB ユーザーが、ALTER できる。

### 実行すると毎回起きること

- アプリを再起動する（メモリ上のキャッシュは消える）。MySQL は cnf が変わったときだけ再起動する。そのため、**ベンチの最中に実行しない**。ベンチがエラーになる。
- 再起動の後、journald がログを捨てていたら警告する（捨てられると、アプリのログからエラーを数えても欠ける）。
- ログのローテートはしない（`./bench` が計測のたびに行う）。

### 複数人で使うとき

- 1 台のサーバーで同時に実行すると、後から始めたほうが待つ（60 秒待っても終わらなければ止まる）。
- 複数人が別々に `--server` を実行すると、台ごとに後から反映したほうが勝ち、サーバーごとに違うコミットが入りうる。後半は、反映する人を 1 人に決める。
- 後半は、`--server` の対象のサーバーで直接作業しない。deploy がブランチと作業ツリーを切り替える。サーバー上で書き換えた変更があると、取り込みが止まる。
- **後半は、1 台だけに反映するときも `--server=isu1` のように名前を付ける。** 付けないと、役割を引く名前がホスト名（`ip-192-168-0-11` など）になって `roles.env` に見つからず、全部入りとして MySQL や nginx の段まで実行する。

## コードの読み方

```
deploy                    入口（script/deploy/deploy.sh を呼ぶだけ）
script/lib/common.sh      deploy と bench で共有（log、die、roles_of など）
script/deploy/
  deploy.sh               引数の解析と全体の流れ。ここから読む
  lib/conf.sh             conf/ の反映、巻き戻し、マニフェスト、反映待ちの印
  lib/steps.sh            各段（共通の設定 → MySQL → nginx → app）、journald の確認、反映した版の記録
  lib/remote.sh           --server のときの、ssh での並列の反映
  deploy.env              問題ごとの値
  roles.env               サーバーごとの役割
  collect-conf.sh         サーバーの今の設定を conf/ に集める
```

- **流れは 2 通り。** `--server` がなければ、`deploy.sh` の `deploy_local` がそのサーバーで各段を実行する。あれば、`remote::fan_out` が各サーバーに ssh し、そこで `./deploy --local --name=<サーバー名>` を実行させる。つまり各サーバーで動くのは、いつも `deploy_local`。
- **関数名の接頭辞が、ファイルとまとまりを表す。** `conf::` と `pending::` は conf.sh、`step::`、`mysql::`、`app::`、`journald::`、`deployed::` は steps.sh、`remote::` は remote.sh。グローバル変数も同じ接頭辞（`CONF_`、`STEP_`、`REMOTE_`）。
- **各段は `step::<名前>`。** `run_step` が役割と `--only` を見て呼ぶ。段を足すときは、steps.sh に `step::<名前>` を書き、`deploy_local` に `run_step <名前>` を足す。
- **サーバー上に残るもの。**

  | 場所 | 中身 |
  |---|---|
  | `/var/backups/isucon-deploy/<日時>/` | 書き換えたり消したりする前のファイル。失敗したときの巻き戻しに使う |
  | `/var/lib/isucon-deploy/manifest` | deploy が新しく作ったファイルの一覧。conf/ から消えたら、サーバーからも消すため（もとからあったファイルは消さない） |
  | `/var/lib/isucon-deploy/pending/<段>` | 反映待ちの印。ファイルを変えてから reload / restart が終わるまでの間だけある |
  | `/var/lib/isucon-deploy/deployed` | 最後に反映した版（日時、段、リポジトリと webapp のコミット、未コミットの変更の有無） |
  | `/tmp/isucon-deploy/<日時>/` | `--server` のときの、サーバーごとのログ |

## 当日の準備

1. 各サーバーにリポジトリを clone し、`deploy.env` を実物に合わせる。`SCHEMA_FILE` は、初期化のスクリプト（`init.sh` など）が流す SQL。
2. G1 の base-conf を入れた後に `collect-conf.sh` で設定を集めて commit し、`./deploy --dry-run` で差分が出ないことを確かめる。
3. 後半に入るとき、上の「必要な条件」をそろえ、`roles.env` を書く。構成の変更そのもの（MySQL の bind-address やユーザー、アプリの DB のホスト）は手で行い、結果を `conf/` に書く。

## webapp をリポジトリに入れる

deploy はリポジトリ内の `webapp/go` をビルド・実行する。webapp が別の git（`/home/isucon/webapp`）にある場合は、先にリポジトリへ取り込む。後半に入る前、できれば当日の最初に、次の手順で入れる。リポジトリは isucon ユーザーで、`/home/isucon` の下に clone しておく（ubuntu のホームに置くと、持ち主と sudo の扱いがずれる）。

1 台目（isucon ユーザーで）:

```bash
cd ~/isucon13
sudo systemctl stop <APP_SERVICE>
mv /home/isucon/webapp ./webapp
ln -s ~/isucon13/webapp /home/isucon/webapp   # systemd、docker compose、deploy.env のパスを変えずに済む
mv webapp/.git ~/webapp.git.bak                # 入れ子の git は commit できない。履歴が要らなければ消してよい
du -sh webapp/* webapp/*/* | sort -h | tail    # 大きいファイル（初期データ、DB のファイル）を探す
vi .gitignore                                  # ビルドしたバイナリと、大きいデータを足す
git add -A && git commit -m 'webapp を入れる' && git push
sudo systemctl start <APP_SERVICE>
```

2 台目以降:

```bash
cd ~/isucon13 && git pull
sudo systemctl stop <APP_SERVICE>
mv /home/isucon/webapp /home/isucon/webapp.orig
ln -s ~/isucon13/webapp /home/isucon/webapp
# .gitignore にしたデータは git では届かないので、元の webapp から移す（例: SQLite のファイル）
cp -a /home/isucon/webapp.orig/<データのディレクトリ> ~/isucon13/webapp/
sudo systemctl start <APP_SERVICE>
```

## 注意

- ビルドしたバイナリは `.gitignore` に入れる。commit すると、他のサーバーで git の取り込みが止まる。
- schema.sql に初期データの INSERT が混ざっている問題では、CREATE 文だけのファイルに分けて `SCHEMA_FILE` にする。大きいテーブルの ALTER は、`/initialize` のタイムアウトに注意する。
- `--only=mysql` で MySQL を再起動しても、アプリは再起動しない。アプリが MySQL のソケットをコンテナにマウントしている問題では、アプリも再起動する。

## ソースと実行バイナリの確認（Issue #29）

`APP_DIR` は `$REPO_DIR/webapp/go`。別ディレクトリの古いソースをビルドしない。
app 段では `go build -buildvcs=true` のコミット情報を HEAD と比較し、Go ソースと
依存定義のハッシュを `/var/lib/isucon-deploy/app-source-sha256` に保存する。
ローカル作業ツリーの変更も反映でき、未コミットの有無はビルド情報に記録する。

systemd の `/etc/systemd/system/isupipe-go.service.d/zz-isucon-deploy.conf` で
WorkingDirectory と ExecStart をリポジトリ内へ向け、daemon-reload 後に再起動する。
EnvironmentFile など既存 unit の設定は引き継ぐ。相対パスの初期化 SQL・画像・DNS の
ゾーンもリポジトリ内のものを使用する。ビルド失敗・版不一致なら再起動前に停止する。
再起動後は MainPID の `/proc/<PID>/exe` とビルド成果物の SHA256 を比較する。

```bash
./deploy --only=app
./deploy-check --version
```

`--version` は初期化・HTTP リクエスト・再起動を行わず、HEAD とビルド版、ビルド後の
ソース変更、実行中バイナリとの一致を検証する。Go と systemd・procfs のあるサーバーで
実行する。app を反映した deploy 記録にはバイナリパス・PID・SHA256・Go ビルド情報を残す。
pprotein の Snapshot の Git 情報だけで稼働版を判断せず、この記録と照合する。

初回は `./deploy-check --version` が記録なしで失敗するため app 段を実行する。
`--dry-run` はビルド・drop-in 作成・再起動を行わない。
元の unit の起動先へ戻す場合は、この drop-in を削除して daemon-reload・再起動する。

## 一覧の N+1 と検索索引の反映

`perf/develop-batch-and-indexes` の変更では、配信検索・配信者別一覧・コメント・
リアクション・報告のレスポンスを同じトランザクション内で一括取得する。
統計のコメント数・チップ・視聴履歴も配信ごとの取得をやめて集計し、予約枠の
ロック後の再 SELECT と、タグごとの INSERT をまとめる。
NG 語判定は MySQL のパラメータ同士の LIKE を維持し、128件ごとの組合せで判定する。

スキーマには配信者別一覧、タグ別検索、コメント／リアクションの配信別時刻順、
視聴履歴、報告、配信別 NG 語、予約枠の開始／終了時刻の非ユニーク索引を追加している。
コード更新後、通常の `./deploy` でスキーマとアプリの両方を反映する。
`./deploy --only=mysql --dry-run` で DDL を確認できる。DDL・アプリ再起動はベンチ外で行う。

Go の通常テストは `cd webapp/go && go test ./...`。
MySQL での旧実装比較・SQL回数・NG語・同時予約・EXPLAINの確認には、使い捨ての
`_perf_test` で終わる名前の DB を作り、`10_schema.sql` の USE をその DB 名へ
置き換えて読み込んでから、次のように実行する。

```bash
cd webapp/go
ISUCON_PERF_TEST_DSN='user:password@tcp(127.0.0.1:3306)/isupipe_perf_test?parseTime=true' go test -v ./...
```

統合テストはこの専用 DB のデータを削除・作成する。本番 DB には向けない。
環境変数が未指定なら MySQL 統合テストはスキップされる。

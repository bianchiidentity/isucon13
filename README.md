# ISUCON13

## 公式ドキュメント

- [レギュレーション](https://isucon.net/archives/57768216.html)
- [当日マニュアル](https://github.com/isucon/isucon13/blob/main/docs/cautionary_note.md)
- [アプリケーションマニュアル（ISUPipe）](https://github.com/isucon/isucon13/blob/main/docs/isupipe.md)

## チームの文書

- [サイトの全体像](docs/overview.md): 採点と制約、ジャーニー、エンドポイント、構成、ER 図、共通処理、通信の流れ

## スクリプト

| 入口 | 用途 |
|---|---|
| [`script/setup-repo/join.sh`](script/setup-repo/README.md) | 1 台目と同じリポジトリの状態を、ほかのサーバーに作る（deploy key、clone、webapp のリンク） |
| [`script/setup/setup.sh`](script/setup/README.md) | 各サーバーで最初に 1 回行う準備（自動アップデートの停止、/etc/hosts、setup-tools、git の作者）。当日の最初の順番もここ |
| [`script/base-conf/apply.sh`](script/base-conf/README.md) | 競技の開始直後に入れる設定（自動アップデートの停止、計測ツール、nginx と MySQL の設定） |
| [`script/setup-tools/setup-tools.sh`](script/setup-tools/README.md) | ツール（graphviz、sysstat、jq、版を固定した mysqldef）。setup.sh が呼ぶ |
| [`./deploy`](script/deploy/README.md) | リポジトリのコードと設定をサーバーに反映する |
| [`./deploy-check`](script/deploy-check/README.md) | 変更の前後で応答が変わっていないかを確かめる |

## デプロイ

最初に一度だけ、`script/deploy/deploy.env` に問題ごとの値（サービス名、ビルド、DB、スキーマ）を書き、base-conf を入れた後に `script/deploy/collect-conf.sh` でサーバーの設定を `conf/` に集めてコミットする。`script/deploy-check/paths.txt` には、比べるリクエストを書く。

変更のたびに、次の順で実行する。

```bash
./deploy-check --before   # 変更の前の応答を保存する
# コードや conf/ を変更する
./deploy --dry-run        # 差分を確かめる
./deploy                  # 反映する（複数台では、push してから ./deploy --server=isu1,isu2,isu3）
./deploy-check --after    # 保存した応答と比べる。違えば差分を出して終了コード 1
```

ベンチの最中には、どちらも実行しない（アプリの再起動と `/initialize` でベンチが壊れる）。

## Claude のスキルとナレッジ

| 場所 | 用途 |
|---|---|
| [`dora-isucon-overview`](.claude/skills/dora-isucon-overview/SKILL.md) | 問題のサイトの全体像（エンドポイント、構成、ER 図など）を 1 つの文書にまとめる |
| [`dora-isucon-tuning`](.claude/skills/dora-isucon-tuning/SKILL.md) | チューニングの進め方 |
| [`.claude/knowledge/isucon/`](.claude/knowledge/isucon/README.md) | 過去問の演習で得たナレッジ（ジャンル G0〜G7）。自動では読み込まれない |

# ISUCON13

## 公式ドキュメント

- [レギュレーション](https://isucon.net/archives/57768216.html)
- [当日マニュアル](https://github.com/isucon/isucon13/blob/main/docs/cautionary_note.md)
- [アプリケーションマニュアル（ISUPipe）](https://github.com/isucon/isucon13/blob/main/docs/isupipe.md)

## スクリプト

| 入口 | 用途 |
|---|---|
| [`script/base-conf/apply.sh`](script/base-conf/README.md) | 競技の開始直後に入れる設定（自動アップデートの停止、計測ツール、nginx と MySQL の設定） |
| [`./deploy`](script/deploy/README.md) | リポジトリのコードと設定をサーバーに反映する |
| [`./deploy-check`](script/deploy-check/README.md) | 変更の前後で応答が変わっていないかを確かめる |

## Claude のスキルとナレッジ

| 場所 | 用途 |
|---|---|
| [`dora-isucon-overview`](.claude/skills/dora-isucon-overview/SKILL.md) | 問題のサイトの全体像（エンドポイント、構成、ER 図など）を 1 つの文書にまとめる |
| [`dora-isucon-tuning`](.claude/skills/dora-isucon-tuning/SKILL.md) | チューニングの進め方 |
| [`.claude/knowledge/isucon/`](.claude/knowledge/isucon/README.md) | 過去問の演習で得たナレッジ（ジャンル G0〜G7）。自動では読み込まれない |

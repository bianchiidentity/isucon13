# ISUCON のナレッジ

過去問の演習（private-isu、isucon12 予選、isucon11 予選）で得た、チューニングのナレッジ。チューニングのジャンル（G0〜G7）ごとに 1 ファイルで、各ファイルに「どこを見るか」「採用・却下した設定と変更、その根拠」「完了条件」を書いている。

| ファイル | 中身 |
|---|---|
| [dora-isucon-common](dora-isucon-common.md) | 全ジャンルの共通部分。ジャンルの番号、表の凡例と「構成依存」の略号、演習の前提構成、変更のたびの回帰確認。**ほかのファイルの表を読む前に見る** |
| [dora-G0-measurement](dora-G0-measurement.md) | G0 計測・運用の基盤と仕様の把握 |
| [dora-G1-base-conf](dora-G1-base-conf.md) | G1 どの環境でも最初に入れる設定（`script/base-conf/`） |
| [dora-G2-safe-improvements](dora-G2-safe-improvements.md) | G2 前提に依存しない確実な改善（インデックス、明らかな初期設定の誤り） |
| [dora-G3-app-logic](dora-G3-app-logic.md) | G3 アプリのロジック（N+1、ロック、外部コマンドなど） |
| [dora-G4-data-cache](dora-G4-data-cache.md) | G4 データの持ち方・キャッシュ |
| [dora-G5-topology](dora-G5-topology.md) | G5 サーバー構成・接続経路 |
| [dora-G6-resources-params](dora-G6-resources-params.md) | G6 リソース配分・細かいパラメータ |
| [dora-G7-final](dora-G7-final.md) | G7 最終調整 |

## 読むときの注意

- **Claude Code は、このディレクトリを自動では読み込まない。** スキルや CLAUDE.md から「読む」と指示したときだけ読む。
- **値をそのまま流用しない。** 表の「構成依存」に印がある行は、その演習の構成だから出た結論である。構成が違う問題では計測し直して決める。
- **「却下」は人が判断して却下したもの。** 次の演習でも、許可なく試さない。
- `dora-aws-env-pitfalls` のようにコードの形で書いた名前は、まだこのリポジトリにないナレッジ（環境の落とし穴、進め方のフィードバック）を指す。

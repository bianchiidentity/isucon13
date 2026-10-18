---
name: dora-isucon-common
description: ISUCON のナレッジ（dora-G0〜G7）の共通部分。ジャンルの新旧の番号、状態の凡例と構成依存の略号、過去の演習の前提構成、変更のたびの回帰確認、CPU が上限のときの考え方、未解決の事項
---

ISUCON のチューニングのナレッジは、ジャンルごとのファイル（[dora-G0-measurement](dora-G0-measurement.md)〜[dora-G7-final](dora-G7-final.md)）に分けてある。各ファイルには「どこを見るか」（チェックリスト）と「何を入れたか」（パラメータと変更の採用・却下、根拠）の両方を書く。ここは全ジャンルに共通する部分である。
進め方（ジャンルの順番、対策の選び方、改善サイクル）は dora-isucon-tuning スキルにある。
もとになった演習: 2026-10-10〜11 の private-isu（スコア 373 → 約 19 万）、2026-10-11 の isucon12-qualify（最低スペックで 1,912 → 約 44,000）、2026-10-18 の isucon11-qualify（クレジットありで 1,468 → 31,134、進行中）。

## ジャンルの番号（2026-10-18 に変更）

2026-10-18 に、どの環境でも最初に入れる設定（G1）を新設し、それより後ろの番号を 1 つずつずらした。**2026-10-18 より前の演習の記録（作業ログ、進捗ファイル、サーバー上の git のコミットメッセージ）は旧番号のまま**である。

| 新 | 旧 | ジャンル | ファイル |
|---|---|---|---|
| G0 | G0 | 計測・運用の基盤と仕様の把握 | [dora-G0-measurement](dora-G0-measurement.md) |
| G1 | なし | どの環境でも最初に入れる設定（base-conf） | [dora-G1-base-conf](dora-G1-base-conf.md) |
| G2 | G1 | 前提に依存しない確実な改善 | [dora-G2-safe-improvements](dora-G2-safe-improvements.md) |
| G3 | G2 | アプリのロジック | [dora-G3-app-logic](dora-G3-app-logic.md) |
| G4 | G3 | データの持ち方・キャッシュ | [dora-G4-data-cache](dora-G4-data-cache.md) |
| G5 | G4 | サーバー構成・接続経路 | [dora-G5-topology](dora-G5-topology.md) |
| G6 | G5 | リソース配分・細かいパラメータ | [dora-G6-resources-params](dora-G6-resources-params.md) |
| G7 | G6 | 最終調整 | [dora-G7-final](dora-G7-final.md) |

旧 G0 の自動アップデートの停止、LTSV、スロークエリログの設定と、旧 G1 の MySQL の耐久性の設定は、新しい G1 に移した。

## 表の読み方

- **「却下」はユーザーが明示的に却下したもの。次回も、ユーザーの許可なく適用・試行しない**。
- 状態の凡例: 採用 / 却下（ユーザー判断）/ 見送り（Claude が提案段階で不要と判断）/ 未実施（提案のみ）/ 対象外。
- 計測値は環境のばらつき（private-isu では同じ設定で 140k〜200k）が大きいので、目安として扱う。
- 「構成依存」の列に印がある行は、下の前提構成だから出た結論である。構成が違う問題では、値をそのまま使わず、計測し直して決める。

構成依存の列の略号:

- 同一ホスト: nginx・app・DB が同じホストにいることが前提
- virtiofs: colima のファイル共有が遅いことが前提
- unicorn: unicorn の挙動（keep-alive 非対応など）が前提
- 規模: データ量や接続数が小さいことが前提
- SQLite: アプリがテナントごとの SQLite を使うことが前提（isucon12-qualify）
- t3: AWS t3 の CPU クレジット（最低スペックで 1 vCPU あたり 20%）での計測が前提
- ベンチマーカー: そのベンチマーカーの挙動（TLS のセッションを再利用しないなど）が前提
- 自前の bench: 演習でベンチマーカーを自分のインスタンスで動かすことが前提
- —: 構成に依存しない

## 前提構成: private-isu

- サーバー: 1 台（Intel Mac 4 コア上の colima VM、Docker Compose）
  - nginx・app・MySQL・memcached が同じホストにいる
  - ファイル共有は virtiofs で、ファイル操作が重い（推測）
- アプリ: Ruby + unicorn、ワーカー 4、app コンテナに `cpus: "1"` の上限
- データ: 画像を除くと約 11MB。初期データの画像は DB の BLOB
- ベンチマーカー: 同じホストから平文の HTTP/1.1
- 記録: private-isu の演習（2026-10-10〜11）

## 前提構成: isucon12-qualify

- サーバー: AWS t3.medium（2 vCPU、4GB、CPU クレジット standard）× 2。app と bench
  - app に nginx・Go アプリ・MySQL 8.0・SQLite が同居。アプリは docker compose（`go run`、network_mode host）
- アプリ: Go 1.18（echo、sqlx、mattn/go-sqlite3 v1.14.13）
- データ: MySQL に共通のデータ（tenant、visit_history 322 万行）、テナントごとの SQLite に大会・参加者・スコア（100 ファイル、466MB、player_score 372 万行）
- ベンチマーカー: 別のインスタンスから HTTPS + HTTP/2。RSA 2048 の証明書
- 計測: 最低スペック（クレジット切れ、st 40〜60）の回を比べる。ベースライン 1,912 → 最終 約 44,000
- 記録: isucon12-qualify の演習（2026-10-11）

## 前提構成: isucon11-qualify

- サーバー: AWS t3.medium（2 vCPU、4GB、CPU クレジット standard）× 2。app と bench（bench のインスタンスのアプリ一式は停止）
  - app に nginx・Go アプリ・MariaDB 10.3.34 が同居。アプリは systemd でビルド済みのバイナリを起動
- アプリ: Go 1.16（echo、sqlx）。JIA（外部 API）のモックが 5000 番にある
- データ: `isu_condition` が初期 618 行から、ベンチ中に数万行に増える。ISU のアイコンは DB の LONGBLOB
- ベンチマーカー: 別のインスタンスから HTTPS + HTTP/2。サービスの評判（タイムアウトの多さ）でユーザーの増加が止まる
- 計測: クレジットありの回どうしで比べた。ベースライン 1,365 / 1,468 → 31,134（2026-10-18 時点）
- 記録: isucon11-qualify の演習（2026-10-18）

## 変更するたびに確認すること

- **レスポンスの回帰確認**
  - /initialize の後に、主要なページや API のレスポンスを、トークンなど毎回変わる部分を除いて保存する。
  - 変更後に比較する。API の JSON は cmp ではなく、JSON として読んで比べる（整形の違いで外れる。isucon11 で echo の `e.Debug` を外したとき）。
  - 静的ファイルは、ステータス、Content-Type、本文のハッシュの 3 つで比べる（nginx に移すと charset が変わる）。
  - キャッシュを入れたときは、キャッシュが空の 1 回目と、キャッシュから返す 2 回目の両方を比べる。
- **スコアが下がったら、負荷の量も比べる**
  - ユーザーの増加の通知、登録の件数、書き込みの回数。ボトルネックを直すとベンチマーカーが負荷を増やし、次のボトルネックが出て、一時的に下がることがある（isucon11 の trend）。
  - 負荷が増えて下がったなら、取り消さずに次のボトルネックを直す（`dora-feedback_keep-bugfix-when-load-grows`）。
- **ベンチの fail が 0 であること**
- **アプリのログに error や exception がないこと**
- **キャッシュの無効化を実際に試す**
  - 例: コメントを投稿した直後に件数が増えるか。
  - 例: /initialize で元に戻るか。
- **ハッシュの計算方法を変えたとき**
  - 保存済みのユーザーでログインできるかを確かめる（private-isu では mary / marymary）。
- **速くなった直後のエラーは、ベンチマーカー側の上限を疑う**
  - fd の上限（`socket: too many open files`）、`dial tcp` のタイムアウト。アプリのログに 500 がなければ、まず疑う。

## CPU の上限に張り付いたら

- アプリ側の CPU を減らす候補: YJIT、HTML の部品のキャッシュ、テンプレートの軽量化。
- 1 台の CPU が上限で計測にならないなら、G5（台数の配分）を前倒しにする。
- compose の `cpus` の上限を変えるかは、練習の条件次第なのでユーザーに聞く。
- 実サービスではやらない対策（点の高いリクエストの優先、HTTP/2 を切るなど）は、演習では提案に「本番向け」と分けて書き、実施しない（`dora-feedback_no-benchmark-only-hacks-in-practice`）。

## 未解決（isucon12-qualify）

- 最も負荷が高い回（バーストで 18 万点、ワーカー 237）の終わりに `dial tcp ... i/o timeout` が 13 件出た。app の待ち行列のあふれは 0、SYN-ACK の再送 38、bench の TCPTimeouts 602。原因は未確認
- ベンチマーカーの ScoreTable の合計（45,832）と、表示されたスコア（40,945）が合わない。採点の仕組みは確かめていない

## 環境ごとの落とし穴

- AWS（t3）: `dora-aws-env-pitfalls`
- 手元の Mac（colima）: `dora-local-env-pitfalls`

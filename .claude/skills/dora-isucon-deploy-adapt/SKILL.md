---
name: dora-isucon-deploy-adapt
description: ISUCON の当日の最初に、リポジトリの deploy（script/deploy の deploy.env とスクリプト）を問題の構成に合わせるスキル。overview のアーキテクチャとサーバーの実物（systemd の unit、docker compose、nginx、DB、初期化のスクリプト）を調べ、deploy.env の値を埋め、前提（Go を systemd で動かす、ホストの MySQL に DB が 1 つ、前段は nginx）が外れていればスクリプトを直し、dry-run と 1 回の反映で確かめる。「deploy を問題に合わせて」「deploy.env を書いて」「デプロイを使えるようにして」と言われたとき、または dora-isucon-overview の後、base-conf の前に使う。
---

# deploy を問題に合わせる

当日の最初（ベースラインのベンチを待つ間）に、1 台目で deploy を問題の構成に合わせる。この後に base-conf と collect-conf が続き、全員が `./deploy` を使い始めるので、ここで外すと全員の反映が止まる。

**何を確かめ、何を直すかは、リポジトリの `script/deploy/README.md` の「問題に合わせる」節が正である。** このスキルは進め方だけを決める。節の表を書き換えたくなったら、このスキルではなく README を直す。

## 手順

1. **README の「問題に合わせる」節を読む。** `deploy.env` の値の表、前提が外れるときの表、終わったと言える条件。
2. **構成を把握する。**
   - `docs/overview.md`（`dora-isucon-overview` の出力）があれば、アーキテクチャの節を読む。
   - 無ければ、またはそれだけで値が決まらなければ、1 台目の実物を読む。**読むだけにする**（再起動しない、ファイルを書き換えない）。

     ```bash
     systemctl list-units --type=service --state=running
     systemctl cat <アプリの unit>              # User、WorkingDirectory、ExecStart、Environment、EnvironmentFile
     sudo docker ps; ls /home/isucon/webapp     # compose で動いていないか
     sudo nginx -T | grep -nE 'server_name|proxy_pass|root|upstream|access_log'
     ss -tlnp
     systemctl list-unit-files | grep -E 'mysql|mariadb'
     cat /home/isucon/env.sh; ls /home/isucon/webapp/sql   # DB の接続先、初期化のスクリプトとスキーマ
     ```

3. **判定してユーザーに報告し、GO を待つ。** 次の 2 つの表にする。
   - `deploy.env` の値ごとに、今の値、新しい値、根拠（上のコマンドの出力の該当行）。
   - 前提の表の行ごとに、当てはまるか外れるか。外れるなら、直すところと直し方（コードの差分の案）。
   - 根拠の無い値は推測で埋めず、「分からない」と書いて、どう確かめるかを添える。
4. **直す。** `deploy.env`（先頭の「isucon13 の想定」のコメントも、今の問題に書き換える）、`COLLECT_PATHS`、外れた前提のスクリプト。
5. **確かめる。** README の「終わったと言える条件」の 1 と 2。
   - `./deploy --dry-run` は何度実行してもよい。
   - **`./deploy --only=app` はアプリを再起動するので、ベンチの最中でないかをユーザーに確かめてから実行する**（ベンチは挙手制）。
   - 失敗したら、4 に戻る。dry-run を通すために、確かめる処理を外して済ませない。外すなら、理由をユーザーに説明して GO を得る。
6. **commit・push する。** チームの決まりどおり、ブランチを切って PR にする。PR には 3 の表と、5 の結果を書く。
7. **報告する。** 変えた値とコード、確かめた結果、残っていること（base-conf の後の collect-conf と、`./deploy --server=<全台> --dry-run`）。

## 守ること

- **2 と 3 では、サーバーを変えない。** 変えるのは 4 以降で、GO の後。
- **前の問題の値を残さない。** `deploy.env` の値は、全部を今の問題の実物で確かめる。前の問題と同じ値でも、確かめたことを 3 の表に書く。
- **構成を変えない。** ここで行うのは deploy を今の構成に合わせることだけ。台の分け方や DB の移し替えは、チューニング（G5）で行う。

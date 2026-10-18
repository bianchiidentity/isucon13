# setup-tools

base-conf が入れない計測と運用のツールを入れるスクリプト。base-conf の後に、各サーバーで実行する。

```bash
cd ~/isucon13
sudo script/setup-tools/setup-tools.sh --dry-run  # 入れるものを確かめる
sudo script/setup-tools/setup-tools.sh
```

| ツール | 使う場面 |
|---|---|
| graphviz | `go tool pprof -http` や svg で、プロファイルをグラフにする。`bench.sh` の `-top` には要らない |
| sysstat | `pidstat`（プロセスごとの CPU の推移）、`iostat`、`mpstat` |
| mysqldef（`v3.11.26` に固定） | `./deploy` がスキーマの差分を当てる。入っていなければ `./deploy` が latest を入れるので、版を揃えたいときに先に入れる |

- 何度実行しても同じ結果になる。mysqldef の版が違えば入れ替える。
- sysstat の定期収集（10 分ごと）は止める。計測に混ざるため。
- ベンチ中に実行しない。apt が CPU とディスクを使う。

入れないもの: サーバー間の ssh の鍵と config、サーバーから git push する認証（鍵を扱うので別に用意する）、pprof（アプリのコードに `net/http/pprof` を入れる）。

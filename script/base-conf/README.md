# base-conf

どの ISUCON の問題でも、競技の開始直後に入れてよい設定と、それを適用するスクリプト。
過去問の演習（private-isu、isucon12 予選）で採用し、サーバーの構成に依存しないものだけを入れた。

## 使い方

各サーバーで実行する。

```bash
git clone https://github.com/bianchiidentity/isucon13.git ~/isucon13
cd ~/isucon13
sudo script/base-conf/apply.sh --dry-run  # 変わる内容を diff で確かめる
sudo script/base-conf/apply.sh            # 適用する
sudo script/base-conf/apply.sh --revert   # nginx と MySQL の設定を元に戻す
```

- 何度実行しても同じ結果になる。2 回目以降は MySQL を再起動しない。
- 入っていないミドルウェアの段は飛ばす。MySQL をコンテナで動かしている問題では、MySQL の段を手で入れる。
- nginx.conf の元のファイルは、初回だけ `/var/backups/isucon-base-conf/` に保存する。
- `nginx -t` が通らないとき、MySQL が起動しないときは、自動で元に戻して止まる。

## 入れる設定

| 対象 | 設定 | ファイル |
|---|---|---|
| OS | 自動アップデートを止める | `apply.sh` |
| ツール | alp、pt-query-digest | `apply.sh` |
| nginx | LTSV のアクセスログ（alp 用。応答した app のアドレス入り） | `conf/nginx/isucon.conf` → `/etc/nginx/conf.d/` |
| nginx | worker_processes auto（数字なら）、worker_rlimit_nofile 65535、worker_connections 4096、元の access_log を外す | `apply.sh` が nginx.conf を書き換える |
| MySQL | binlog の無効化、`innodb_flush_log_at_trx_commit=0`、doublewrite OFF、max_connections 1024、スロークエリログ（全クエリ） | `conf/mysql/zz-isucon.cnf` → `/etc/mysql/mysql.conf.d/` |

入れないもの: buffer_pool、アプリのワーカー数やコネクションプール（サーバーの台数とメモリで決める）、skip-name-resolve（`localhost` のユーザーに TCP でつなぐアプリが入れなくなる）、O_DIRECT（buffer_pool と一緒に決める）、client_max_body_size（問題による）、performance_schema の停止（計測に使うので最後に）、etag や expires（ベンチマーカー次第）、open_file_cache（ファイルを書き換えるアプリで古い内容を返しうる）、カーネルのパラメータ（演習では効かなかった）。

## 適用した後

- **G1 の後は、deploy の `conf/` を直す。** `script/deploy/collect-conf.sh` で設定を集めた後は、`conf/default/` が正になる。base-conf のファイルを直しても、次の `./deploy` で `conf/default/` の中身に戻される。
- アプリが MySQL のソケットをコンテナにマウントしているなら、MySQL の再起動の後にアプリも再起動する。
- server ブロックに独自の access_log があると LTSV にならない。`apply.sh` がそのファイルを表示するので、手で直す。
- スロークエリログは全クエリを記録するので、MySQL の負荷になる。最終調整で `SET GLOBAL slow_query_log = OFF` にし、zz-isucon.cnf も OFF にする。

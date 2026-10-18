# PowerDNS の検索インデックス

PowerDNS が使う `isudns.records` に非ユニークの複合インデックス
`nametype_index (name, type)` を追加する。名前のみ、名前と種別の検索を高速化する。

## 反映

PowerDNS 用 MySQL が動くホストで、リポジトリのルートから実行する。
ベンチ実行中を避けて適用する。

```sh
sudo mysql < webapp/pdns/add_indexes.sql
```

同等の可視インデックスがあればスキップするため、手動追加済みの環境にも再適用できる。
接続先はローカル MySQL、対象 DB は `isudns`。アプリ用の `isupipe` には適用しない。
別ホストの MySQL を使う構成では、接続先と認証を指定して適用する。

索引は MySQL の再起動後も残る。`init_zone.sh` は `pdnsutil load-zone` で
ゾーンのデータを入れ直すため、初期化のたびに DDL を実行する必要はない。
DB やテーブルを再作成した場合は、この SQL を再適用する。

## 確認

```sql
SHOW INDEX FROM isudns.records;

EXPLAIN
SELECT content, ttl, prio, type, domain_id, disabled, name, auth
FROM isudns.records
WHERE disabled = 0 AND name = 'u.isucon.local' AND domain_id = 1;

EXPLAIN
SELECT content, ttl, prio, type, domain_id, disabled, name, auth
FROM isudns.records
WHERE disabled = 0 AND name = 'u.isucon.local' AND type = 'A';

EXPLAIN
SELECT content, ttl, prio, type, domain_id, disabled, name, auth
FROM isudns.records
WHERE disabled = 0 AND name = 'u.isucon.local' AND domain_id = 1 AND type = 'A';
```

`key` が追加した索引を選び、推定 `rows` が減ることを確認する。
SQL をもう一度適用してスキップされることも確認する。
存在する名前・存在しない名前、A・SOA の DNS 応答、および登録直後と初期化後の
名前解決を確認し、IP・TTL・レコード内容が変わらないことを確かめる。
初期化・MySQL 再起動後も `SHOW INDEX` で索引の維持を確認する。
最後に同条件の成功ベンチで対象 SQL の時間・RowsExamined、DNS 失敗数とスコアを比較する。

-- PowerDNS 用 DB に適用する。既存の (name, type) 索引があれば再作成しない。
SET @has_nametype_index = (
    SELECT COUNT(*)
    FROM information_schema.statistics AS first_column
    INNER JOIN information_schema.statistics AS second_column
        ON second_column.table_schema = first_column.table_schema
        AND second_column.table_name = first_column.table_name
        AND second_column.index_name = first_column.index_name
    WHERE first_column.table_schema = 'isudns'
        AND first_column.table_name = 'records'
        AND first_column.seq_in_index = 1
        AND first_column.column_name = 'name'
        AND first_column.sub_part IS NULL
        AND first_column.is_visible = 'YES'
        AND second_column.seq_in_index = 2
        AND second_column.column_name = 'type'
        AND second_column.sub_part IS NULL
);

SET @add_nametype_index = IF(
    @has_nametype_index > 0,
    'SELECT ''records(name, type) index already exists'' AS message',
    'ALTER TABLE isudns.records ADD INDEX nametype_index (name, type)'
);
PREPARE add_nametype_index FROM @add_nametype_index;
EXECUTE add_nametype_index;
DEALLOCATE PREPARE add_nametype_index;

INSERT INTO test_keyspace.test_table(key, ref, val, lst) VALUES (1, 'a', 'foo', ['a', 'b', 'c']) USING TIMESTAMP 100;
UPDATE test_keyspace.test_table USING TIMESTAMP 200 SET lst += ['d'] WHERE key = 1 AND ref = 'a';
SELECT * FROM test_keyspace.test_table WHERE key = 1;
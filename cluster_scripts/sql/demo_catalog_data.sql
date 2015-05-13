INSERT INTO shard_name SELECT 'kv' || generate_series(1, 3) AS name;

INSERT INTO shard_instance (hostname, shard_name)
  SELECT 'localhost', name FROM shard_name;
INSERT INTO shard_instance (hostname, port, shard_name)
  SELECT 'localhost', 5433, name FROM shard_name;

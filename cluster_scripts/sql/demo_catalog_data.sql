INSERT INTO shard_name SELECT 'kv' || generate_series(1, 12) AS name;

INSERT INTO shard_instance (hostname, shard_name)
  SELECT 'localhost', name FROM shard_name;

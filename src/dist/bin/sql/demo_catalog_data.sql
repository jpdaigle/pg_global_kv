INSERT INTO shard_name SELECT 'kv' || generate_series(1, 2) AS name;

INSERT INTO catalog_instance(hostname, port)
  VALUES ('localhost', 5432), ('localhost', 5433), ('localhost', 5435);

INSERT INTO shard_instance (hostname, shard_name)
  SELECT 'localhost', name FROM shard_name;
INSERT INTO shard_instance (hostname, port, shard_name)
  SELECT 'localhost', 5433, name FROM shard_name;
INSERT INTO shard_instance (hostname, port, shard_name)
  SELECT 'localhost', 5435, name FROM shard_name;

INSERT INTO expiry_to_interval (namespace, policy, time_length)
  VALUES ('DEFAULT', 'EXPIRY_1', '2 days'), ('DEFAULT', 'EXPIRY_2', '10 days'), ('DEFAULT', 'EXPIRY_3', '1 month'), ('DEFAULT', 'EXPIRY_4', '3 months'),('DEFAULT', 'EXPIRY_5', '7 months'), ('DEFAULT', 'EXPIRY_6', '13 months'), ('DEFAULT', 'EXPIRY_7', '25 months');

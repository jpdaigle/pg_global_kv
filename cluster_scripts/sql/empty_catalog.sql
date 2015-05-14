CREATE TABLE shard_name (
  name text PRIMARY KEY
);

CREATE TABLE catalog_instance (
  hostname    text   NOT NULL,
  port        int    NOT NULL DEFAULT 5432
);

CREATE TABLE shard_instance (
  instance_id SERIAL NOT NULL,
  hostname    text   NOT NULL,
  port        int    NOT NULL DEFAULT 5432,
  shard_name  text   REFERENCES shard_name(name)
);

CREATE VIEW replication_topology AS
  SELECT
    shard_name,
    inst.instance_id id,
    inst.hostname,
    inst.port,
    source.instance_id source_id,
    source.hostname source_hostname,
    source.port source_port
  FROM shard_instance inst JOIN shard_instance source USING (shard_name)
  WHERE inst.instance_id <> source.instance_id;


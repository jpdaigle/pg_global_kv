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
  shard_name  text   REFERENCES shard_name(name) INITIALLY DEFERRED
);

CREATE TABLE statistics_to_collect (
  remote_schema_name text      NOT NULL,
  remote_table_name  text      NOT NULL,
  target_table       regclass  NOT NULL
);

CREATE TABLE last_config_push (
  ts timestamp with time zone NOT NULL
);
CREATE UNIQUE INDEX last_config_push_single_row ON last_config_push ((true));

INSERT INTO last_config_push SELECT now();

CREATE FUNCTION kv_config.notify_config_push() RETURNS trigger AS $$
BEGIN
  NOTIFY config_push;
  RETURN NEW;
END
$$ LANGUAGE plpgsql;
CREATE TRIGGER notify_config_push BEFORE INSERT OR UPDATE OR DELETE ON last_config_push FOR EACH ROW EXECUTE PROCEDURE kv_config.notify_config_push();

CREATE FUNCTION kv_config.push_to_remote_table(
  server_name text,
  remote_schema_name text,
  table_name text
) RETURNS void AS $$
DECLARE
  remote_table_name text;
BEGIN
  remote_table_name = kv_config.ensure_foreign_table(server_name, remote_schema_name, table_name);
  EXECUTE format('DELETE FROM %s', remote_table_name);
  EXECUTE format('INSERT INTO %s SELECT * FROM %I', remote_table_name, table_name);
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION kv_config.push_catalog_changes() RETURNS void AS $$
DECLARE
  server_name text;
  conf_push_table text;
BEGIN
  UPDATE last_config_push SET ts = now();
  FOR server_name IN
    SELECT kv_config.ensure_foreign_server(hostname, port, 'kv_catalog') FROM catalog_instance
    WHERE NOT(hostname = (SELECT hostname FROM kv_config.my_info)
      AND port = (SELECT setting::int FROM pg_settings WHERE name = 'port'))
  LOOP
    PERFORM kv_config.ensure_user_mapping(server_name);
    PERFORM kv_config.push_to_remote_table(server_name, 'public', 'shard_name');
    PERFORM kv_config.push_to_remote_table(server_name, 'public', 'catalog_instance');
    PERFORM kv_config.push_to_remote_table(server_name, 'public', 'shard_instance');
    PERFORM kv_config.push_to_remote_table(server_name, 'public', 'statistics_to_collect');
    conf_push_table =  kv_config.ensure_foreign_table(server_name, 'public', 'last_config_push');
    EXECUTE format('UPDATE %s SET ts = now()', conf_push_table);
  END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION kv_config.stats_table_for_pg_catalog(catalog_table_name text) RETURNS VOID AS $$
BEGIN
  EXECUTE format('CREATE TABLE kv_stats.%I(server_name text NOT NULL, ts timestamp with time zone NOT NULL, LIKE pg_catalog.%1$I)', catalog_table_name);
  INSERT INTO statistics_to_collect VALUES ('pg_catalog', catalog_table_name, format('kv_stats.%I', catalog_table_name));
END;
$$ LANGUAGE plpgsql;

DO $$ BEGIN
  PERFORM kv_config.stats_table_for_pg_catalog('pg_stat_user_tables');
  PERFORM kv_config.stats_table_for_pg_catalog('pg_statio_user_tables');
  PERFORM kv_config.stats_table_for_pg_catalog('pg_stat_user_indexes');
  PERFORM kv_config.stats_table_for_pg_catalog('pg_statio_user_indexes');
  PERFORM kv_config.stats_table_for_pg_catalog('pg_stat_user_functions');
  CREATE TABLE kv_stats.peer_status_raw (
    server_name text NOT NULL,
    ts timestamp with time zone NOT NULL,
    peer int,
    min_horizon timestamp with time zone  NOT NULL
  );
  INSERT INTO statistics_to_collect VALUES ('kv', 'peer_status_from', 'kv_stats.peer_status_raw');
  CREATE VIEW kv_stats.peer_status AS
    SELECT server_name, ts, hostname, port, min_horizon
    FROM kv_stats.peer_status_raw
    JOIN shard_instance ON (shard_instance.instance_id = peer_status_raw.peer);

END $$;

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

CREATE VIEW local_replication_topology AS
  SELECT replication_topology.*
  FROM replication_topology
  JOIN pg_settings ON (pg_settings.name = 'port' AND replication_topology.port = setting::int)
  JOIN kv_config.my_info USING (hostname);

CREATE OR REPLACE FUNCTION kv_stats.update_statistics() RETURNS VOID AS $$
DECLARE
  shard record;
  cleanup_table regclass;
  server_name text;
  stats_table record;
  remote_stats_table text;
BEGIN

  FOR cleanup_table IN SELECT target_table FROM statistics_to_collect
  LOOP
    EXECUTE format('DELETE FROM %s', cleanup_table); 
  END LOOP;
  FOR shard IN
    SELECT hostname, port, shard_name
    FROM shard_instance JOIN kv_config.my_info USING (hostname)
                        JOIN pg_settings ON (pg_settings.name = 'port' AND shard_instance.port = setting::int)
  LOOP
    server_name = kv_config.ensure_foreign_server(shard.hostname, shard.port, shard.shard_name);
    PERFORM kv_config.ensure_user_mapping(server_name);
    FOR stats_table IN SELECT * FROM statistics_to_collect LOOP 
      remote_stats_table = kv_config.ensure_foreign_table(server_name, stats_table.remote_schema_name, stats_table.remote_table_name);
      EXECUTE format('INSERT INTO %s (SELECT %L, statement_timestamp(), * FROM %s)', stats_table.target_table, server_name, remote_stats_table);
    END LOOP;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

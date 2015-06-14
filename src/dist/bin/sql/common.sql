CREATE SCHEMA kv;
CREATE SCHEMA kv_config;
CREATE SCHEMA kv_remotes;
CREATE SCHEMA kv_stats;


-----------------------------------------
-- Check Dependencies
-----------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name='postgres_fdw') THEN
    CREATE EXTENSION IF NOT EXISTS postgres_fdw;
  ELSE
    RAISE 'Dependancy postgres_fdw not available';
  END IF;
END; $$;


CREATE TABLE kv_config.my_info (
  instance_id   int,
  hostname      text   NOT NULL
);
CREATE UNIQUE INDEX my_info_single_row ON kv_config.my_info ((true));
GRANT SELECT ON kv_config.my_info TO PUBLIC;

CREATE FUNCTION kv_config.ensure_foreign_server(hostname text, port int, dbname text) RETURNS text AS $$
DECLARE
  server_name text := format('%s_%s_%s', hostname, port, dbname);
BEGIN
  -- TODO: we are trusting naming conventions here.  Truthfully we should check the srvoptions column and make sure
  -- they are the same but that would require parsing that field apart.
  IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_foreign_server WHERE srvname = server_name) THEN
    EXECUTE format('CREATE SERVER %I FOREIGN DATA WRAPPER postgres_fdw OPTIONS
                    (host %L, port %L, dbname %L)', server_name, hostname, port, dbname);
  END IF;
  RETURN server_name;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION kv_config.ensure_user_mapping(server_name text) RETURNS VOID AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_user_mappings m
                         JOIN pg_roles r ON (r.oid = m.umuser)
			 WHERE m.srvname = server_name AND r.rolname = current_user) THEN
    -- TODO: this only works because kv_replicationd is SUPERUSER
    EXECUTE format('CREATE USER MAPPING FOR CURRENT_USER SERVER %I', server_name);
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION kv_config.ensure_foreign_table(
  server_name text,
  remote_schema text,
  remote_table_name text,
  table_def text DEFAULT NULL,
  local_table_name text DEFAULT NULL
) RETURNS text AS $$
BEGIN
  IF local_table_name IS NULL THEN
    local_table_name = format('%s_%s_%s', server_name, remote_schema, remote_table_name);
  END IF;

  IF EXISTS(SELECT 1 FROM information_schema.foreign_tables
    WHERE foreign_table_name = local_table_name
    AND foreign_server_name = server_name)
  THEN
    RETURN format('kv_remotes.%I', local_table_name);
  END IF;

  IF table_def IS NULL THEN
    table_def = kv_config.get_remote_table_def(server_name, remote_schema, remote_table_name);
  END IF;

  --TODO: this does not check that the definition is the same
  EXECUTE format('CREATE FOREIGN TABLE kv_remotes.%I(%s) SERVER %I OPTIONS (schema_name %L, table_name %L)',
                  local_table_name, table_def, server_name, remote_schema, remote_table_name);
  RETURN format('kv_remotes.%I', local_table_name);
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION kv_config.column_definitions_for(
  schema_name text,
  table_name text,
  column_table regclass,
  out table_def text
) AS $$
BEGIN
  EXECUTE format($q$ SELECT string_agg(
    column_name || ' ' ||  CASE WHEN data_type = 'USER-DEFINED' THEN 'text' ELSE data_type END,
  ', ') FROM %s WHERE table_schema = %L AND table_name = %L $q$, column_table, schema_name, table_name) INTO table_def;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION kv_config.get_remote_table_def(
  server_name text,
  schema_name text,
  table_name text
) RETURNS text AS $$
DECLARE
  remote_inf_colums text;
BEGIN
  remote_inf_colums = kv_config.ensure_foreign_table(server_name, 'information_schema', 'columns',
    kv_config.column_definitions_for('information_schema', 'columns', 'information_schema.columns'));
  RETURN kv_config.column_definitions_for(schema_name, table_name, remote_inf_colums);
END;
$$ LANGUAGE plpgsql;

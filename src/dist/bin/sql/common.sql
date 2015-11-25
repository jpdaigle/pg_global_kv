CREATE SCHEMA kv;
COMMENT On SCHEMA kv IS 'This is where all the data lives in a data node';

CREATE SCHEMA kv_config;
COMMENT ON SCHEMA kv_config IS 'Config values and a bunch of functions around foreign tables live here';

CREATE SCHEMA kv_remotes;
COMMENT ON SCHEMA kv_remotes IS 'All the foreign tables end up in this schema';

CREATE SCHEMA kv_stats;
COMMENT ON SCHEMA kv_stats IS 'kv store specific stats go here';


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
COMMENT ON TABLE kv_config.my_info IS
$$This table allows the shard to know its own identity.  Its used in many places.
Note: Port value isn't in this table because its inferred$$;
COMMENT ON COLUMN kv_config.my_info.instance_id IS 'In a shard instance this is the peer column on t_kv.  In a catalog this is null';
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
COMMENT ON FUNCTION kv_config.ensure_foreign_server(hostname text, port int, dbname text) IS
'Basically CREATE IF NOT EXISTS of a server that we will need in the future';

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
COMMENT ON FUNCTION kv_config.ensure_user_mapping(server_name text) IS
'Same as above but for user mappings';

CREATE FUNCTION kv_config.ensure_foreign_table(
  server_name text,
  remote_schema text,
  remote_table_name text,
  table_def text DEFAULT NULL,
  local_table_name text DEFAULT NULL
) RETURNS text AS $$
BEGIN
  -- The way that we progmatically generate this might get to too long for NAMEDATALEN
  -- We'll allow you to override if need be.
  -- Did not truncate name because we could get name collisions and these could cause silent bugs.
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
COMMENT ON FUNCTION kv_config.ensure_foreign_table(text, text, text, text, text) IS
'This is the magic function.  You just tell it about the name of table that you want from a particular server and it just
figures out the table definition and creates and tells you where is it is.';

CREATE FUNCTION kv_config.column_definitions_for(
  schema_name text,
  table_name text,
  column_table regclass,
  out table_def text
) AS $$
BEGIN
  -- Note: information_schema doesn't know about enums and json so they get down cast to text.  kv.replicate will cast them
  -- back to the right types.
  EXECUTE format($q$ SELECT string_agg(
    column_name || ' ' ||  CASE WHEN data_type = 'USER-DEFINED' THEN 'text' ELSE data_type END,
  ', ') FROM %s WHERE table_schema = %L AND table_name = %L $q$, column_table, schema_name, table_name) INTO table_def;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION kv_config.column_definitions_for(text, text, regclass, out text) IS
$$Takes an information schema table (perhaps local, perhaps a foreign table) and figures out the column definitions$$;

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
COMMENT ON FUNCTION kv_config.get_remote_table_def(text, text, text) IS
$$Get the definition of a remote table, using the information_schema from the remote side.  The only challenge is you need
a foreign table referencing the information schema of the remote side.  We have a bootstrapping problem, so we'll concede
and make a simple assumption: that the remote information_schema.columns looks enough like our information_schema.columns
in order to create a foreign table of it.  So yes we recurse into ensure_foreign_table, but this time with a table definition$$;

CREATE TYPE kv.expiration_policy AS ENUM ('NO_EXPIRE', 'EXPIRY_1', 'EXPIRY_2', 'EXPIRY_3', 'EXPIRY_4', 'EXPIRY_5', 'EXPIRY_6', 'EXPIRY_7');
-- Allows for distinct key namespaces in the same server 
CREATE TYPE kv.namespace         AS ENUM ('DEFAULT', 'INSIGHT', 'CTR');  -- TODO: namespaces belong in config, but we need to roll this out, 
                                                                  --       hard code for now. 


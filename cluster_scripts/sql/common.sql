CREATE SCHEMA kv;
CREATE SCHEMA kv_config;
CREATE SCHEMA kv_remotes;


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

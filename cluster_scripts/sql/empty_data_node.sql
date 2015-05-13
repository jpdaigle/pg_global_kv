\i sql/common.sql

CREATE FUNCTION kv_config.ensureRemoteShardConnection(hostname text, port int) RETURNS VOID AS $$
BEGIN
END;
$$ LANGUAGE plpgsql;

CREATE TABLE kv_config.my_info (
  instance_id   int    NOT NULL,
  hostname      text   NOT NULL
);
CREATE UNIQUE INDEX my_info_single_row ON kv_config.my_info ((true));

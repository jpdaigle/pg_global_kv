\i sql/common.sql


CREATE TABLE kv_config.my_info (
  instance_id   int    NOT NULL,
  hostname      text   NOT NULL
);
CREATE UNIQUE INDEX my_info_single_row ON kv_config.my_info ((true));

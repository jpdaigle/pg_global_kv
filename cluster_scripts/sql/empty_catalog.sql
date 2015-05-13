
CREATE TABLE shard_name (
  name text PRIMARY KEY
);

CREATE TABLE shard_instance (
  instance_id SERIAL NOT NULL,
  hostname    text   NOT NULL,
  port        int    NOT NULL DEFAULT 5432,
  shard_name  text   REFERENCES shard_name(name)
);


/*
CREATE TABLE ip_addresses (
  hostname    text  PRIMARY KEY,
  ip          inet  NOT NULL
);
*/

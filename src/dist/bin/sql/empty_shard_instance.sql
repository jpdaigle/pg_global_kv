-----------------------------------------
-- ACL
-----------------------------------------
GRANT USAGE ON SCHEMA kv, kv_config TO kv_client;

-----------------------------------------
-- Types
-----------------------------------------

-- Limits the reasonable values for keys
CREATE DOMAIN kv.key AS text
       COLLATE "C" --Force C collate strings for performance
       NOT NULL
       CHECK ( char_length(VALUE) < 63 );  -- TODO, what should we enforce here?  Using NAMEDATALEN-1 for now
                                           -- but it may be worth enforcing some structure on keys.  (Part of config?)

-- Possible diagnostic values that can be returned as the result of a put operation.
CREATE TYPE put_result AS ENUM ('UPDATE', 'INSERT', 'CONFLICT');


-----------------------------------------
-- Tables
-----------------------------------------
CREATE TABLE kv.t_kv (
  namespace  kv.namespace             NOT NULL         DEFAULT 'DEFAULT',
  peer       int                      NOT NULL,
  ts         timestamp with time zone NOT NULL         DEFAULT now(),
  expiration kv.expiration_policy     NOT NULL         DEFAULT 'NO_EXPIRE',

  -- Variable width fields placed last for easy of readablity and performance
  key        kv.key                   NOT NULL,
  value      json                     /* NULLABLE, for soft deletes */
);
COMMENT ON TABLE kv.t_kv IS 'Main data table for the key value store';

-- Primary access pattern
ALTER TABLE kv.t_kv ADD PRIMARY KEY (namespace, key);

-- Needed for replication
CREATE INDEX ON kv.t_kv(ts);

-- Makes cleaning soft deletes performant
CREATE INDEX ON kv.t_kv(ts) WHERE value IS NULL;

-- ACL
GRANT SELECT, INSERT, UPDATE ON kv.t_kv TO kv_client;
GRANT SELECT, INSERT, UPDATE, DELETE ON kv.t_kv TO kv_replicationd;

-- View in public namespace for debugging
CREATE VIEW public.vw_kv AS (SELECT * FROM kv.t_kv);


-- Reviewers: can I get a better name for these two tables that follow?
CREATE TABLE kv.peer_status_from (
  peer        int                       PRIMARY KEY,
  min_horizon timestamp with time zone  NOT NULL
);

-- TODO write to this table
CREATE TABLE kv.peer_status_to (
  peer        int                       PRIMARY KEY,
  min_horizon timestamp with time zone  NOT NULL
);

GRANT SELECT, INSERT, UPDATE ON kv.peer_status_from, kv.peer_status_to TO kv_replicationd;

-----------------------------------------
-- API functions
-----------------------------------------
CREATE FUNCTION kv.get(in ns text, in k text, out v json) AS
$$
BEGIN
  SELECT value INTO v FROM kv.t_kv WHERE namespace = ns::kv.namespace AND key=k::kv.key;
END
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kv.put(
  ns         text,
  k          text,
  v          text,
  expiration text
) RETURNS text AS $$
BEGIN
  RETURN kv._put(ns::kv.namespace, k::kv.key, v::json, expiration::kv.expiration_policy, now(), (SELECT instance_id FROM kv_config.my_info));
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kv.delete(ns text, k text) RETURNS text AS $$
BEGIN
  RETURN kv._put(ns::kv.namespace, k::kv.key, null, 'NO_EXPIRE', now(), (SELECT instance_id FROM kv_config.my_info));
END;
$$
LANGUAGE plpgsql;
COMMENT ON FUNCTION kv.delete(text, text) IS
'Delete is just a put of null.  This soft delete allows replication to carry the delete through out the parade.
kv.clean_up_nulls() will clean these up.';


CREATE OR REPLACE FUNCTION kv.patch_numeric(
  ns         text,
  k          text,
  v          text,
  expiration text
) RETURNS text AS $$
BEGIN
  RETURN kv._patch_numeric(ns::kv.namespace, k::kv.key, v::json, expiration::kv.expiration_policy, now(), (SELECT instance_id FROM kv_config.my_info));
END;
$$
LANGUAGE plpgsql;

-----------------------------------------
-- Internal functions
-----------------------------------------
CREATE FUNCTION kv._put(
  ns         kv.namespace,
  k          kv.key,
  v          json,
  expire     kv.expiration_policy,
  tstamp     timestamp with time zone,
  peer_num   int
) RETURNS put_result AS $$
DECLARE
  iteration_count int;
BEGIN
  FOR iteration_count IN 1..5 LOOP
    -- first try to update the key
    UPDATE kv.t_kv
      SET value = v, expiration = expire, ts = tstamp, peer = peer_num
      WHERE namespace = ns AND key = k AND ts <= tstamp;

    IF found THEN
      RETURN 'UPDATE';
    END IF;

    -- TODO consistent tie breakers.
    -- Right now we have a short coming.  If the same key is written in two data centers at the exact same microsecond,
    -- then it is undefined what row will be taken on either side.  This could cause node divergence.  The proper way to
    -- fix it is to break that tie with peer_num.  It doesn't matter which we choose, we just need to choose the same thing
    -- on every server.  Considering the current use case it isn't that big of a deal, and I don't want to mess with how fiddly
    -- that would be right now.
    
    -- not there, so try to insert the key
    -- if someone else inserts the same key concurrently,
    -- we could get a unique-key failure
    BEGIN
      INSERT INTO kv.t_kv(namespace, key, value, expiration, ts, peer) VALUES (ns, k, v, expire, tstamp, peer_num);
      RETURN 'INSERT';
    EXCEPTION WHEN unique_violation THEN
      -- do nothing
    END;

    -- No update or insert?  That means it was a ts conflict.
    IF ts > tstamp FROM kv.t_kv WHERE namespace = ns AND key = k THEN
      RETURN 'CONFLICT';
    END IF;
  END LOOP;

  -- If we got here we tried 5 times and failed.  That should be impossible (at most we should ever make two passes
  -- through this code).  It is an unexpected case but sending the database into an infinite loop is really a bad idea.
  -- Lets raise an error; because failing a single request is far better than bringing the server down.
  RAISE 'Upsert failed!  Completely unexpected. Is there high concurrency on this single row?';
END;
$$
LANGUAGE plpgsql;

CREATE FUNCTION kv._patch_numeric(
  ns         kv.namespace,
  k          kv.key,
  v          json,
  expire     kv.expiration_policy,
  tstamp     timestamp with time zone,
  peer_num   int
) RETURNS put_result AS $$
DECLARE
  iteration_count int;
BEGIN
  FOR iteration_count IN 1..5 LOOP
    -- first try to update the key
    -- if the key exists, merge the new json file with the old one
    UPDATE kv.t_kv
      SET value = kv._json_patch_numeric(value , v), expiration = expire, ts = tstamp, peer = peer_num
    WHERE namespace = ns AND key = k AND ts <= tstamp;
      
    IF found THEN
      RETURN 'UPDATE';
    END IF;

    -- if not, insert new key-value pair
    BEGIN
      INSERT INTO kv.t_kv(namespace, key, value, expiration, ts, peer) VALUES (ns, k, v, expire, tstamp, peer_num);
      RETURN 'INSERT';
    EXCEPTION WHEN unique_violation THEN
      -- do nothing
    END;
  END LOOP;

  -- If we got here we tried 5 times and failed.  That should be impossible (at most we should ever make two passes
  -- through this code).  It is an unexpected case but sending the database into an infinite loop is really a bad idea.
  -- Lets raise an error; because failing a single request is far better than bringing the server down.
  RAISE 'Upsert failed!  Completely unexpected. Is there high concurrency on this single row?';
END;
$$
LANGUAGE plpgsql;


-- combining two jsons
CREATE FUNCTION kv._json_patch_numeric(
  v_old   json,
  v_new   json
) RETURNS json AS 
$$
DECLARE 
  v_final json;
BEGIN
  SELECT concat('{', string_agg(to_json("key") || ':' || "value", ','), '}')::json
  FROM (
    SELECT key, SUM(value::int) AS value
    FROM 
    (
      SELECT * from json_each_text("v_old")
        UNION ALL
      SELECT * from json_each_text("v_new")
    ) as "results" 
    -- We are doing key deletion inside of patch.  This code only works because:
    --   json null != sql null
    -- This select rows where it is not the case that the key exists and the key is set to null.
    WHERE NOT ((v_new->key) IS NOT NULL AND (v_new->>key) IS NULL)
    GROUP BY key
  ) AS "final_results"
  INTO v_final;
  RETURN v_final;
END;
$$
LANGUAGE plpgsql;

-- TODO this function won't work until we start populating peer_status_to
CREATE FUNCTION kv.clean_up_nulls() RETURNS VOID AS $$
DECLARE
  horizon timestamp with time zone;
BEGIN
  SELECT min(min_horizon) INTO horizon FROM
    (SELECT min_horizon FROM kv.min_horizons_to_remotes
     UNION ALL
     SELECT min_horizon FROM kv.min_horizons_from_remotes) f;
  DELETE FROM t_kv WHERE ts < horizon AND payload IS NULL;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kv.queue_deletes(out to_delete int, out snapshot_ts timestamptz) AS $$
DECLARE
  rec RECORD;
  predicates text[];
  where_clause text;
BEGIN
  FOR rec IN (SELECT namespace, policy, time_length from expiry_to_interval) LOOP
    predicates = predicates || format(' (k.namespace = %L::kv.namespace AND k.expiration = %L::kv.expiration_policy and k.ts < %L) ', rec.namespace, rec.policy, now()-rec.time_length);

  END LOOP;
  
  where_clause = 'WHERE ' || array_to_string(predicates, ' OR ');

  EXECUTE format('CREATE TEMP TABLE keys_to_delete AS (SELECT k.namespace, k.key from kv.t_kv k %s LIMIT 100000)', where_clause);
  EXECUTE format('CREATE TEMP TABLE keys_to_delete_now (namespace kv.namespace, key kv.key) ON COMMIT DELETE ROWS');
  to_delete = (SELECT COUNT(1) from keys_to_delete);    
  snapshot_ts = now();
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kv.delete_keys(in amt int, in snapshot_ts timestamptz, out deleted int, out done boolean) AS $$
BEGIN

  EXECUTE format('INSERT INTO keys_to_delete_now SELECT namespace, key from keys_to_delete LIMIT %s', amt);

  WITH to_delete_now AS 
  (SELECT namespace, key from keys_to_delete_now) 
  DELETE FROM keys_to_delete k 
  USING to_delete_now n 
  WHERE k.key = n.key
  AND k.namespace = n.namespace;

  WITH to_delete_now AS 
  (SELECT namespace, key from keys_to_delete_now) 
  DELETE FROM kv.t_kv k 
  USING to_delete_now n 
  WHERE k.ts < snapshot_ts
  AND k.key = n.key
  AND k.namespace = n.namespace;

  deleted = (SELECT COUNT(1) from keys_to_delete_now);
  done = count(1) = 0 FROM keys_to_delete;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION kv_config.ensureRemoteShardConnection(hostname text, port int, dbname text) RETURNS text AS $$
DECLARE
  server_name text;
BEGIN
  server_name = kv_config.ensure_foreign_server(hostname, port, dbname);
  PERFORM kv_config.ensure_user_mapping(server_name);
  RETURN kv_config.ensure_foreign_table(server_name, 'kv', 't_kv');
END;
$$ LANGUAGE plpgsql;



GRANT ALL ON FOREIGN DATA WRAPPER postgres_fdw TO kv_replicationd;
CREATE FUNCTION kv.replicate(remote_table regclass, peer_id int) RETURNS VOID AS $$
DECLARE
  dbname text := $exec$ || quote_literal(peer_name) || $exec$ ;
  horizon timestamp with time zone;
  buffer_ts timestamp with time zone := now() - interval '1 second';
BEGIN
  SELECT min_horizon INTO horizon FROM kv.peer_status_from WHERE peer = peer_id;

  IF horizon IS NULL THEN
    INSERT INTO kv.peer_status_from VALUES( peer_id, now());
    horizon = now();
  END IF;

  IF buffer_ts > horizon + '5 seconds' THEN
    buffer_ts = horizon + '5 seconds';
  END IF;
  
  EXECUTE format('SELECT kv._put(namespace::kv.namespace, key::kv.key, value, expiration::kv.expiration_policy, ts, peer)
                    FROM %s WHERE ts > %L AND ts <= %L AND peer = %L',
		  remote_table, horizon, buffer_ts, peer_id);
  UPDATE kv.peer_status_from SET min_horizon = buffer_ts WHERE peer = peer_id;
END;
$$ LANGUAGE plpgsql;
    

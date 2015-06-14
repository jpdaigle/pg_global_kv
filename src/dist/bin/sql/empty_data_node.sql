-----------------------------------------
-- Types
-----------------------------------------

-- Allows for distinct key namespaces in the same server
CREATE TYPE kv.namespace         AS ENUM ('DEFAULT');

-- TODO are these values correct
CREATE TYPE kv.expiration_policy AS ENUM ('NO_EXPIRE', 'EXPIRY_1', 'EXPIRY_2', 'EXPIRY_3', 'EXPIRY_4', 'EXPIRY_5', 'EXPIRY_6', 'EXPIRY_7');

-- Limits the reasonable values for keys
CREATE DOMAIN kv.key AS text
       COLLATE "C"
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

-- View in public namespace for debugging
CREATE VIEW public.vw_kv AS (SELECT * FROM kv.t_kv);

CREATE TABLE kv.peer_status_from (
  peer        int                       PRIMARY KEY,
  min_horizon timestamp with time zone  NOT NULL
);

CREATE TABLE kv.peer_status_to (
  peer        int                       PRIMARY KEY,
  min_horizon timestamp with time zone  NOT NULL
);

-- This is really the information the admin cares about.  Its broken out into
-- two tables above to make concurrency work better.
CREATE VIEW vw_peer_status AS (
  SELECT peer, kv.peer_status_from.min_horizon as from_horizon, kv.peer_status_to.min_horizon AS to_horizon
  FROM kv.peer_status_from JOIN kv.peer_status_to USING (peer)  --TODO join kv.local_shard_instances
);

-----------------------------------------
-- API functions
-----------------------------------------
CREATE FUNCTION kv.get(in ns text, in k text, out v json) AS
$$
BEGIN
  SELECT value INTO v FROM kv.t_kv WHERE namespace = ns AND key=k;
END
$$
LANGUAGE plpgsql;

-- TODO: retype as text?
CREATE OR REPLACE FUNCTION kv.put(
  ns         kv.namespace,
  k          kv.key,
  v          json,
  expiration kv.expiration_policy
) RETURNS put_result AS $$
BEGIN
  RETURN kv._put(ns, k, v, expiration, now(), (SELECT instance_id FROM kv_config.my_info));
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION kv.delete(ns kv.namespace, k kv.key) RETURNS put_result AS $$
BEGIN
  RETURN kv._put(ns, k, null, 'NO_EXPIRE', now(), (SELECT instance_id FROM kv_config.my_info));
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

CREATE FUNCTION kv_config.ensureRemoteShardConnection(hostname text, port int, dbname text) RETURNS text AS $$
DECLARE
  server_name text;
BEGIN
  server_name = kv_config.ensure_foreign_server(hostname, port, dbname);
  PERFORM kv_config.ensure_user_mapping(server_name);
  RETURN kv_config.ensure_foreign_table(server_name, 'kv', 't_kv');
END;
$$ LANGUAGE plpgsql;

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

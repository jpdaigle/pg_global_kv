# Postgres Global Key Value Store
## Introduction
Ultimately, `pg_global_kv` is an exercise in pragmatism.  We needed a way to store user session state and personalization data in a highly scalable multmaster manner.  We tried a NoSQL solution but we couldn't get it to perform stably in production.   

We turned to our data center workhorse, Postgres, at the release we were comfortable running in production, 9.3, and built a new replication technology on top of it with minimal code.

Once built, we realized had a scalable rock solid tool that just worked.  It doesn't do everything and management is still pretty manual, but its also simple enough that you could sit down and read the entire thing in just a couple of hours.

## High level design
At the core of `pg_global_kv` is a put function which implements upsert.  (yes, 9.5 has native upsert, but this is built on 9.3).  Its the standard `pl/pgsql` upsert from the docs with one major modification.  Do not assume that your update wins unconditionally.  Check the timestamp column as well and compare to `now()`.  In pseudocode (actual implementation is different because concurrency),

    FOR 1..max_tries LOOP
      SELECT WHERE key
      IF count = 0 THEN
        INSERT
      ELSE IF ts < now() THEN
        UPDATE
      ELSE
        DO NOTHING
      END IF
    END LOOP

Clients call `kv.put()` to insert data into the kv store.  What is interesting about `pg_global_kv` is that it also uses uses the put function for replication.  It makes some concessions about replication consistency in exchange for performance.

Consitency considerations:

* A single key will always transition from consistent state to consistent state.
* Eventually a single key will always converge to the same value on every server.
* If key A is written and then key B is written they might not be played back in that order.

With these conciderations you can do a logical multimaster replication without a log table and without consulting the WAL.  Instead you can replicate directly off the data storage table using the timestamp column as the guide.  With the postgres foriegn data wrapper its fairly straig forward to do.  Again in vaguely related pseudocode:
    
    min_horizon_so_far = epoch
    LOOP
      max_ts = now() - statement_timeout * 2
      SELECT kv.put(*) FROM foreign_table
        WHERE peer = other_servers_id
	  AND ts > min_so_far AND ts <= max_ts
      min_horizon_so_far = max_ts
    END LOOP

Unfortunately you can't implement that loop in pure `pl/pgsql` because you need to enter and exit a transaction in order for the rows to become visible.  In >= 9.4 you could use, dynamic background workers, but in 9.3 you need a very simple companion daemon which just calls the replication function in a loop.

The other important concept is this `max_ts`.  Its crticial for making this replication strategy work.  Assuming all transaction has settled, you can just pull over time ranges repeatedly.  However, concider the following situation:

    Time 1: Put call begins with now() =  1
    Time 2: Replication runs for the window 1..2
    Time 3: Put call commits
    Time 4: Replication runs for the window 3..4

In this case, you have stranded this put call because you assumed that all work for timestamp <= 2 what complete.  To avoid this case the kv store requires an aggressive `statement_timeout` of 1 second and waits 2 seconds before trying to replicate a row to be completely confident that there are no inflight transactions which will be come visible after `max_ts`.

## Definitions

__Parade__: This is the term that we are adopting to mean the entire collection of machines in multiple data centers that are part of the key value store.  This is what would be a "cluster", but "PostgreSQL has historically used that term for a different and confusing purpose."  Parade was chosen because it is a group of elephants.  Credit: Kyle Samson.

__Zone__: Normally synonymous with data center.

__Postgres Instance__: A single Postgres postmaster. _There is no technical reason why there cannot be more than one postgres instance per host; in fact this is the most convenient way to develop.  However, for simplicity the rest of this document assumes postgres instance and host are synonymous._

__Node__: Synonymous with a physical Postgres database.  Redefining this term here because logically the key value store is a 'database' and its likely to get confusing.

__Catalog__: Each postgres instance that is part of the parade has a catalog node/database.  The catalog node contains a full copy of where everything is in the parade, as well as statistics tables about all the shard instances in its Postgres instance.

__Shard__: Shards are a user defined division of key space (usually by hash).  Each shard is represented by a shard instance in each zone.

__Shard Instance__: A shard instance is a postgres node/database; it is the instantiation of a shard in a zone.  It has a full copy of all of the data in a zone plus or minus replication lag.

__postgres_fdw__: It is the foreign data wrapper that allows a postgres database to talk to another postgres database.  Its primary importance for the key value store is that it is the mechanism used to enable replication.

__Replicationd__: Is a daemon provided by the package to trigger replication cycles.  It is fairly lightweight because all of the real work is done in PL/pgSQL.  The external daemon is required because as of Postgres 9.3 

------------------------------------------------------

## Installation
### Requirements
Tested on CentOS and OSX (minus init.d scripts).  Requires at least Postgres 9.3 and Java 1.8.

### Instructions
On every machine in the parade, run `./install.sh` which will build and install into `/opt/pg_global_kv` and also install the appropriate`/etc/init.d/` script.  Be sure to set up the proper `pg_hba.conf` to allow internode connectivity.  Particularly:

* Initial setup needs the `ADMIN_USER` (default postgres) to be able to connect from the host you are running setup commands.
* User `kv_replicationd` must be able to connect to everything.
* User `kv_client` is used to connect to parade.  Allow access to all shards from the desried locations.

`postgresql.conf` shound contain the following settings:

    -- Required for replication guarentees
    statement_timeout = '1s'
    -- Option but major performance boost
    synchronous_commit = off

All the scripts you will need will be in `/opt/pg_global_kv/bin/`.  In that directory you will find `config.sh` make sure those values are what you intend before proceeding.

After running the install script select one machine and run `./create_first_catalog.sh`.  It will give you a psql command to connect to that first catalog database.   In that database set up the proper configuration into the tables.  Example setup:

    -- Note if in dev mode there will be dummy data already in these tables.
    
    INSERT INTO catalog_instance VALUES ('tmtest01n.ndmad2'), ('tmtest02n.ndmad2');
    INSERT INTO shard_name SELECT 'kv' || generate_series(1,12);
    INSERT INTO shard_instance (hostname, port, shard_name)
        SELECT hostname, port, name FROM catalog_instance CROSS JOIN shard_name;
    UPDATE kv_config.my_info SET hostname = 'tmtest01n.ndmad2';
    INSERT INTO expiry_to_interval (namespace, policy, time_length)
         VALUES ('DEFAULT', 'EXPIRY_1', '2 days'),
                ('DEFAULT', 'EXPIRY_2', '10 days'),
                ('DEFAULT', 'EXPIRY_3', '1 month'),
                ('DEFAULT', 'EXPIRY_4', '3 months'),
                ('DEFAULT', 'EXPIRY_5', '7 months'),
                ('DEFAULT', 'EXPIRY_6', '13 months'),
                ('DEFAULT', 'EXPIRY_7', '25 months');
    

Then run `./setup_parade.sh`.  This will log into all the servers configured and setup all of the appropriate databases, and push the config to the entire parade.

All that remains is to run `service pg_global_kv start` on each of hosts.  Replication should auto configure itself and now be running.  Statistics about system health can be found in `kv_stats` schema in the `$PRIMARY_CATALOG_DATABASE` (normally `kv_catalog`) database on each host.

-------------------------------------------------------

## User API Functions

    -- kv.get(namespace, key)
    kv1=# SELECT kv.get('DEFAULT', 'key');
     get
    -----
    
    (1 row)
    
    -- kv.put(namespace, key, value, expiration_policy) 
    kv1=# SELECT kv.put('DEFAULT', 'key', '{"Hello": "World"}', 'NO_EXPIRE');
      put
    --------
     INSERT
    (1 row)
    
    kv1=# SELECT kv.get('DEFAULT', 'key');
            get
    --------------------
     {"Hello": "World"}
    (1 row)
    
    kv1=# SELECT kv.put('DEFAULT', 'key', '{"foo": "bar"}', 'NO_EXPIRE');
      put
    --------
     UPDATE
    (1 row)
    
    kv1=# SELECT kv.get('DEFAULT', 'key');
          get
    ----------------
     {"foo": "bar"}
    (1 row)
    
    -- kv.delete(namespace, key)
    -- Due to soft delete, this actually returns that it updated the key
    kv1=# SELECT kv.delete('DEFAULT', 'key');
     delete
    --------
     UPDATE
    (1 row)
    
    kv1=# SELECT kv.get('DEFAULT', 'key');
     get
    -----
    
    (1 row)

    -- kv.patch_numeric(namespace, key, numeric_offsets, expiration_policy)
    kv1=# SELECT kv.patch_numeric('DEFAULT', 'p_n_example', '{"a":1, "b":-5, "c": 0}', 'NO_EXPIRE');
     patch_numeric
    ---------------
     INSERT
    (1 row)
    
    kv1=# SELECT kv.get('DEFAULT', 'p_n_example');
               get
    -------------------------
     {"a":1, "b":-5, "c": 0}
    (1 row)
    
    -- Setting a json key to null explicity erases it.  Not mentioning a json key leaves it untouched
    kv1=# SELECT kv.patch_numeric('DEFAULT', 'p_n_example', '{"a":1, "b":-5, "c": null}', 'NO_EXPIRE');
     patch_numeric
    ---------------
     UPDATE
    (1 row)
    
    kv1=# SELECT kv.get('DEFAULT', 'p_n_example');
           get
    -----------------
     {"b":-10,"a":2}
    (1 row)


-------------------------------------------------------

## Design

### Basic Design
Each host has a postgres instance and an instance of replicationd.

In each postgres server there is a catalog database.  This catalog database has complete view of the configuration of the entire parade.  The postgres function `kv_config.push_catalog_changes()` pushes the current state of your catalog throughout the parade and will (TODO) notify all of the  replicationd daemons to reload their config.

When replicationd starts up it connects to the catalog database and selects from a view named `local_replication_topology`.  This view tells it what `shard_instances` live locally and where it needs to pull from.  It uses this information to construct instances of `ReplicationTask` each on their own thread.  In the current mesh topology this means it creates

    number of local shard instances * peers of each of those shards

`ReplicationTask`s, each with there own postgres connection.  On startup, each of these connections attempt to create the foreign tables needed to complete replication.  Once this is done, replication just repeatedly calls `kv.replicate` to pull from that peer.

#### Expiry Daemon
The expiry daemon enforces expiry.  Every 5 minutes it will select the next shard.  It will connect to that shard and find the next group of items that have expired.  It will then delete those rows in a throttled manner.  Expiry is enforce independently on each machine.  Postgres 

### High Availability
For now high availability within each zone is assumed to be accomplished via Postgres' physical streaming replication.


-------------------------------------------------------
## Development
TODO

## Project TODO List
_Listed in no particular order_

* Write automated tests.
* Replicationd should reload it config when the `config_push` notification is sent by `kv_config.push_catalog_changes()`.
* Rethink schema naming conventions in PL/pgSQL.  Choices don't feel very consistent.
* Log4j doesn't have an actual config.  Better logging is generally needed.
* `statement_timeout` should be explicitly on the `kv_client` user instead of requiring you to set it in postgresql.conf

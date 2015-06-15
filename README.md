# Postgres Global Key Value Store
This repository contains the set of utilities needed to create a globally distibruted multi-master key value store on top of a postgres server.

## Definitions

__Parade__: This is the term that we are adopting to mean the entire collection of machines in multiple data centers that are part of the key value store.  This is what would be a "cluster", but "PostgreSQL has historically used that term for a different and confusing purpose."  Parade was chosen because it is a group of elephants.  I blame Kyle Samson.

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
The following should be installed (and running) before trying to use pg_global_kv:

* centos 6
* java 1.8
* postgres 9.3

### Instructions
On every machine in the parade, run `./install.sh` which will build and install into `/opt/pg_global_kv` and also install the appropriate`/etc/init.d/` script.  Be sure to set up the proper pg_hba.conf to allow internode connectivity.  Particularly:

* Initial setup needs the ADMIN_USER (default postgres) to be able to connect from the host you are running setup commands.
* User kv_replicationd must be able to connect to everything.
* User kv_client is used to connect to parade.  Allow access to all shards from the desried locations.

All the scripts you will need will be in `/opt/pg_global_kv/bin/`.  In that directory you will find `config.sh` make sure those values are what you intend before proceeding.

After running the install script select one machine and run `./create_first_catalog.sh`.  It will give you a psql command to connect to that first catalog database.   In that database set up the proper configuration into the tables.  Example setup:

    INSERT INTO catalog_instance VALUES ('tmtest01n.ndmad2'), ('tmtest02n.ndmad2');
    INSERT INTO shard_name SELECT 'kv' || generate_series(1,12);
    INSERT INTO shard_instance (hostname, port, shard_name)
        SELECT hostname, port, name FROM catalog_instance CROSS JOIN shard_name;
    UPDATE kv_config.my_info SET hostname = 'tmtest01n.ndmad2';
    

Then run `./setup_parade.sh`.  This will log into all the servers configured and setup all of the appropriate databases, and push the config to the entire parade.

All that remains is to run `service pg_global_kv start` on each of hosts.  Replication should auto configure itself and now be running.  Statistics about system health can be found in `kv_stats` schema in the `$PRIMARY_CATALOG_DATABASE` (normally `kv_catalog`) database on each host.

-------------------------------------------------------

## Design

### Basic Design
Each host has a postgres instance and an instance of replicationd.

In each postgres server there is a catalog database.  This catalog database has complete view of the configuration of the entire parade.  The postgres function `kv_config.push_catalog_changes()` pushes the current state of your catalog throughout the parade and will (TODO) notify all of the  replicationd daemons to reload their config.

When replicationd starts up it connects to the catalog database and selects from a view named `local_replication_topology`.  This view tells it what shard_instances live locally and where it needs to pull from.  It uses this information to construct instances of `ReplicationTask` each on their own thread.  In the current mesh topology this means it creates

    number of local shard instances * peers of each of those shards

`ReplicationTask`s, each with there own postgres connection.  On startup, each of these connections attempt to create the foreign tables needed to complete replication.  Once this is done, replication just repeatedly calls `kv.replicate` to pull from that peer.


### High Availability
For now high availability within each zone is assumed to be accomplished via Postgres' physical streaming replication.


-------------------------------------------------------
## Development
TODO

## Project TODO List
_Listed in no particular order_

* Write automated tests.
* Replicationd should reload it config when the `config_push` notification is sent by `kv_config.push_catalog_changes()`.
* Replicationd should enforce expiry.
* Replicationd should clean up nulls/deletes.
* Rethink schema naming conventions in PL/pgSQL.  Choices don't feel very consistent.
* Dynamic throttling of replication, (see the sleep in `ReplicationTask.java`)
* Log4j doesn't have an actual config.  Better logging is generally needed.

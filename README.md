# Postgres Global Key Value Store
This repository contains the set of utilities needed to create a globablly distibruted multimaster key value store on top of a postgres server.

### Requirements
The followling should be installed (and running) before trying to use pg_global_kv:

* centos 6
* java >=1.8
* postgres >= 9.3
* gradle


### Installing
On every machine where postgres will be running, run `./install.sh` which will build and install into `/opt/pg_global_kv` and also install the appropriate`/etc/init.d/` script.  Be sure to set up the proper pg_hba.conf to allow internode connectivity.  TODO: explain proper connectivity.

All the scripts you will need will be in `/opt/pg_global_kv/bin/`.  In that directory you will find `config.sh` make sure those values are what you intend before proceeding.

After running the install script select one machine and run `./create_first_catalog.sh`.  It will give you a psql command to connect to that first catalog database.   In that database set up the proper configuration into the tables.

Then run `./setup_cluster.sh`.  This will log into all the servers configured and setup all of the appropriate databases, and push the config to the entire cluster.

All that remains is to run `service pg_global_kv start` on each of hosts.  Replication auto configure itself and now be running.  Statistics about system health can be found in `kv_stats` schema in the `$PRIMARY_CATALOG_DATABASE` (normally `kv_catalog`) database on each host.
package com.tripadvisor.postgres.pg_global_kv;

import org.skife.jdbi.v2.DBI;
import org.skife.jdbi.v2.Handle;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

public class Replicationd
{
    public static void main(String[] args) throws ClassNotFoundException
    {
        //Bootstrap the postgres driver
        Class.forName("org.postgresql.Driver");

        String catalogConString = "jdbc:postgresql://localhost/kv_catalog?" +
                "user=kv_replicationd&ApplicationName=replicationd_init_and_stats";

        if(args.length >= 1)
        {
            catalogConString = args[0];
        }

        DBI dbi = new DBI(catalogConString);
        Handle h = dbi.open();


        ExecutorService executor = Executors.newCachedThreadPool();
        List<Future<Object>> jobFutures = new ArrayList<>();


        h.createQuery(
                "SELECT shard_name, id, hostname, port, source_id, source_hostname, source_port FROM local_replication_topology"
        ).forEach(row -> {
            String appName = String.format("repl_task_%s_%s", row.get("hostname"), row.get("port"));
            DBI shardDBI = new DBI(String.format("jdbc:postgresql://%s:%s/%s?" +
                            "user=kv_replicationd&ApplicationName=%s",
                    row.get("hostname"), row.get("port"), row.get("shard_name"), appName));

            ReplicationTask task = new ReplicationTask(
                    shardDBI,
                    (String)  row.get("shard_name"),
                    (Integer) row.get("source_id"),
                    (String)  row.get("source_hostname"),
                    (Integer) row.get("source_port")
            );
            jobFutures.add(executor.submit(task));
        });

        // Create the statistics polling thread
        jobFutures.add(executor.submit(new StatsTask(dbi)));

        executor.shutdown();

        //TODO reload config on NOTIFY config_push



    }

}

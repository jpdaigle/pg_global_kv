package com.tripadvisor.postgres.pg_kv_daemon;

import org.skife.jdbi.v2.DBI;
import org.skife.jdbi.v2.Handle;
import org.skife.jdbi.v2.util.IntegerMapper;

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

        DBI dbi = new DBI("jdbc:postgresql://localhost/kv_stats");
        Handle h = dbi.open();


        ExecutorService executor = Executors.newCachedThreadPool();
        List<Future<Object>> jobFutures = new ArrayList<>();


        h.createQuery("SELECT hostname, port, shard_name FROM kv.local_shard_instances").forEach(row -> {
            DBI shardDBI = new DBI(String.format("jdbc:postgresql://%s:%s/%s",
                    row.get("hostname"), row.get("port"), row.get("shard_name")));

            List<Integer> peersForReplication = shardDBI.withHandle(shardHandle -> shardHandle.createQuery(
                        "SELECT instance_id FROM kv.local_shard_instances " +
                                "WHERE shard_name = current_database() AND instance_id <> (SELECT id FROM kv.my_instance_id)")
                        .map(IntegerMapper.FIRST)
                        .list()
            );

            for (int peerId: peersForReplication) {
                jobFutures.add(
                        executor.submit(new ReplicationTask(shardDBI, peerId))
                );
            }
        });





    }

}

package com.tripadvisor.postgres.pg_kv_daemon;

import org.skife.jdbi.v2.DBI;

import java.util.concurrent.Callable;

/**
 * Created by mkelly on 5/13/15.
 */
public class ReplicationTask implements Callable<Object>
{


    public ReplicationTask(DBI shardDBI, int replicateFromInstance)
    {
    }

    @Override
    public Object call() throws Exception
    {
        return null;
    }
}

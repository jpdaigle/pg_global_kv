package com.tripadvisor.postgres.pg_global_kv;

import com.google.common.util.concurrent.Uninterruptibles;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.skife.jdbi.v2.*;
import org.skife.jdbi.v2.sqlobject.Bind;
import org.skife.jdbi.v2.sqlobject.SqlBatch;
import org.skife.jdbi.v2.sqlobject.SqlUpdate;
import org.skife.jdbi.v2.util.IntegerMapper;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.TimeUnit;

/**
 * Main workhorse of replication.
 *
 * It starts by ensuring a remote config.
 *
 * After that it just enters a tight loop and calling the replication function (which does all the work)
 * Importantly it retries if it gets an error.
 */
public class ExpirationTask implements Callable<Object>
{
    private final static Logger LOGGER = LogManager.getLogger();

    private final DBI m_shardDBI;
    private final List<Map<String, Object>> m_deleteData;



    public ExpirationTask(DBI shardDBI, List<Map<String, Object>> deleteData)
    {
        m_shardDBI = shardDBI;
        m_deleteData = deleteData;
    }

    @Override
    public Object call() throws Exception
    {
        while(true)
        {
            try (Handle handle = m_shardDBI.open())
            {
                ExpiryDataBatcher edb = handle.attach(ExpiryDataBatcher.class);
                edb.createExpiryToIntervalTable();
                List<Object> namespaces = new ArrayList<>();
                List<Object> policies = new ArrayList<>();
                List<Object> timeLengths = new ArrayList<>();
                m_deleteData.forEach(row -> {
                    namespaces.add(row.get("namespace"));
                    policies.add(row.get("policy"));
                    timeLengths.add(row.get("time_length"));
                });
                edb.insertData(namespaces, policies, timeLengths);
                int toDelete = handle.createQuery("SELECT kv.queue_deletes()").map(IntegerMapper.FIRST).first();
                while(toDelete > 0)
                {
                    toDelete = handle.createQuery("SELECT kv.delete_keys(1000)").map(IntegerMapper.FIRST).first();
                }
            }
            catch (Exception e)
            {
                LOGGER.error(e);
            }
            Uninterruptibles.sleepUninterruptibly(5, TimeUnit.SECONDS);
        }
    }

    public static interface ExpiryDataBatcher
    {
        @SqlBatch("insert into expiry_to_interval (namespace, policy, time_length) values (CAST(:namespace as kv.namespace), CAST(:policy as kv.expiration_policy), :time_length)")
        void insertData(@Bind("namespace") List<Object> namespaces,
                        @Bind("policy") List<Object> policies,
                        @Bind("time_length") List<Object> timeLengths);
        
        @SqlUpdate("CREATE TEMP TABLE expiry_to_interval (namespace kv.namespace, policy kv.expiration_policy, time_length interval)")
        void createExpiryToIntervalTable();
    }

}

package com.tripadvisor.postgres.pg_global_kv;

import com.google.common.util.concurrent.Uninterruptibles;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.skife.jdbi.v2.*;
import org.skife.jdbi.v2.sqlobject.Bind;
import org.skife.jdbi.v2.sqlobject.SqlBatch;
import org.skife.jdbi.v2.sqlobject.SqlUpdate;
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

    private final List<DBI> m_shardDBIs;
    private final List<Map<String, Object>> m_deleteData;



    public ExpirationTask(List<DBI> shardDBIs, List<Map<String, Object>> deleteData)
    {
        m_shardDBIs = shardDBIs;
        m_deleteData = deleteData;
    }

    @Override
    public Object call() throws Exception
    {
        while(true)
        {
            for(DBI shardDBI : m_shardDBIs)
            {
                LOGGER.info("Starting Shard");
                try (Handle handle = shardDBI.open())
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
                    Map<String, Object> row = handle.createQuery("SELECT to_delete, where_clause FROM kv.queue_deletes()").first();
                    int toDelete = (Integer) row.get("to_delete");
                    String whereClause = (String) row.get("where_clause");
                    boolean done = toDelete == 0;
                    while(!done)
                    {
                        Map<String, Object> results = handle.createQuery("SELECT deleted, done FROM kv.delete_keys(:max_to_delete, :where_clause)")
                                .bind("max_to_delete", 1000)
                                .bind("where_clause", whereClause)
                                .first();
                        done = (Boolean) results.get("done");
                    }
                }
                catch (Exception e)
                {
                    LOGGER.error(e);
                }
                LOGGER.info("Finished Shard, Waiting");
                Uninterruptibles.sleepUninterruptibly(5, TimeUnit.MINUTES);
            }
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

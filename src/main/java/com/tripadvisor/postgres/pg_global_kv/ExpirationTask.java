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
import java.sql.Timestamp;

/**
 * Main workhorse of expiration.
 *
 * It calls into each shard and runs a batched delete process.
 * It then waits 5 minutes between each shard to allow for checkpointing
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
                try (Handle handle = shardDBI.open())
                {
                    LOGGER.info("Starting Shard " + handle.getConnection().getCatalog());
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
                    Map<String, Object> row = handle.createQuery("SELECT to_delete, snapshot_ts FROM kv.queue_deletes()").first();
                    int toDelete = (Integer) row.get("to_delete");
                    Timestamp snapshotTs = (Timestamp) row.get("snapshot_ts");
                    boolean done = toDelete == 0;
                    while(!done)
                    {
                        Map<String, Object> results = handle.createQuery("SELECT deleted, done FROM kv.delete_keys(:max_to_delete, :snapshot_ts)")
                                .bind("max_to_delete", 1000)
                                .bind("snapshot_ts", snapshotTs)
                                .first();
                        done = (Boolean) results.get("done");
                        Uninterruptibles.sleepUninterruptibly(50, TimeUnit.MILLISECONDS);
                    }
                    handle.update("SELECT kv.clean_up_nulls()");
                    LOGGER.info("Finished Shard " + handle.getConnection().getCatalog());
                }
                catch (Exception e)
                {
                    LOGGER.error(e);
                }
                Uninterruptibles.sleepUninterruptibly(5, TimeUnit.MINUTES);
            }
        }
    }

    public interface ExpiryDataBatcher
    {
        @SqlBatch("insert into expiry_to_interval (namespace, policy, time_length) values (CAST(:namespace as kv.namespace), CAST(:policy as kv.expiration_policy), :time_length)")
        void insertData(@Bind("namespace") List<Object> namespaces,
                        @Bind("policy") List<Object> policies,
                        @Bind("time_length") List<Object> timeLengths);
        
        @SqlUpdate("CREATE TEMP TABLE expiry_to_interval (namespace kv.namespace, policy kv.expiration_policy, time_length interval)")
        void createExpiryToIntervalTable();
    }

}

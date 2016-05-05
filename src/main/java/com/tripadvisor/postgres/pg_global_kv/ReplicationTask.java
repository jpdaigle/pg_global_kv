// Copyright (c) 2016 TripAdvisor
// Licensed under the PostgreSQL License
// https://opensource.org/licenses/postgresql
package com.tripadvisor.postgres.pg_global_kv;

import com.google.common.util.concurrent.Uninterruptibles;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.skife.jdbi.v2.*;
import org.skife.jdbi.v2.exceptions.CallbackFailedException;
import org.skife.jdbi.v2.util.StringMapper;

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
public class ReplicationTask implements Callable<Object>
{

    private final static Logger LOGGER = LogManager.getLogger();

    private final DBI m_shardDBI;
    private final String m_shardName;
    private final int m_sourceId;
    private final String m_sourceHost;
    private final int m_sourcePort;



    public ReplicationTask(DBI shardDBI, String shardName, int sourceId, String sourceHost, int sourcePort)
    {
        m_shardDBI = shardDBI;
        m_shardName = shardName;
        m_sourceId = sourceId;
        m_sourceHost = sourceHost;
        m_sourcePort = sourcePort;
    }

    @Override
    public Object call() throws Exception
    {
        try
        {
            Map<String, Object> tables = m_shardDBI.withHandle(this::ensureRemoteConfig);
            LOGGER.info(tables);
            long cycleCount = 0;
            // Outer loop for reconnecting on error
            while(true)
            {
                try (Handle handle = m_shardDBI.open())
                {
                    Update replicationQuery = handle.createStatement("SELECT kv.replicate(:table, :source_id);")
                            .bind("table", tables.get("remote_t_kv"))
                            .bind("source_id", m_sourceId);

                    Update pushPeerStatus = handle.createStatement("SELECT kv.update_remote_peer_status(:table, :source_id);")
                            .bind("table", tables.get("remote_peer_status_to"))
                            .bind("source_id", m_sourceId);

                    // This is the main replication loop.
                    while (true)
                    {
                        replicationQuery.execute();
                        if(cycleCount++ % 100 == 0)
                        {
                            pushPeerStatus.execute();
                        }
                        // TODO dynamic throttling
                        Uninterruptibles.sleepUninterruptibly(10, TimeUnit.MILLISECONDS);
                    }

                }
                catch (Exception e)
                {
                    // We'll log number of shards times number of peers of these errors every 5 seconds
                    // if the server is down.  This shouldn't be too much to spam in the logs, but maybe
                    // we should think about using a log4j burst filter.
                    LOGGER.error("Replication error", e);
                    // TODO configurable
                    Uninterruptibles.sleepUninterruptibly(5, TimeUnit.SECONDS);
                }
            }

        }
        catch (CallbackFailedException e)
        {
            // ensureRemoteConfig won't fail because of a lack of connectivity to the remote end
            // (it only sets everything up).  If we got here then something is very, very wrong.
            // Lets just die and let a human debug.
            LOGGER.error("Unable to ensure valid connection config to remote server", e);
            System.exit(1);
        }

        return null;
    }

    private Map<String, Object> ensureRemoteConfig(Handle h)
    {
        return h.createQuery("SELECT * FROM kv_config.ensureRemoteShardConnection(:host, :port, :dbname)")
                .bind("host", m_sourceHost)
                .bind("port", m_sourcePort)
                .bind("dbname", m_shardName)
                .first();
    }


    @Override
    public String toString()
    {
        return "ReplicationTask{" +
                "m_shardDBI=" + m_shardDBI +
                ", m_shardName='" + m_shardName + '\'' +
                ", m_sourceId=" + m_sourceId +
                ", m_sourceHost='" + m_sourceHost + '\'' +
                ", m_sourcePort=" + m_sourcePort +
                '}';
    }
}

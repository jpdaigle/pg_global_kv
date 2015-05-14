package com.tripadvisor.postgres.pg_kv_daemon;

import com.google.common.util.concurrent.Uninterruptibles;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.skife.jdbi.v2.*;
import org.skife.jdbi.v2.exceptions.CallbackFailedException;
import org.skife.jdbi.v2.util.StringMapper;

import java.util.concurrent.Callable;
import java.util.concurrent.TimeUnit;

/**
 * Created by mkelly on 5/13/15.
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
            String table = m_shardDBI.withHandle(this::ensureRemoteConfig);

            // Outer loop for reconnecting on error
            while(true)
            {
                try (Handle handle = m_shardDBI.open())
                {
                    Update update = handle.createStatement("SELECT kv.replicate(:table, :source_id);")
                            .bind("table", table)
                            .bind("source_id", m_sourceId);

                    // This is the main replication loop.
                    while (true)
                    {
                        update.execute();
                        Uninterruptibles.sleepUninterruptibly(100, TimeUnit.MILLISECONDS);
                    }

                }
                catch (Exception e)
                {
                    LOGGER.error("Replication error", e);
                    Uninterruptibles.sleepUninterruptibly(5, TimeUnit.SECONDS);
                }
            }

        }
        catch (CallbackFailedException e)
        {
            LOGGER.error("Unable to ensure valid connection config to remote server", e);
        }




        System.out.println(toString());
        return null;
    }

    private String ensureRemoteConfig(Handle h)
    {
        return h.createQuery("SELECT kv_config.ensureRemoteShardConnection(:host, :port, :dbname)")
                .bind("host", m_sourceHost)
                .bind("port", m_sourcePort)
                .bind("dbname", m_shardName)
                .map(StringMapper.FIRST).first();
    }



    @Override
    public String toString()
    {
        return "ReplicationTask{" +
                "m_shardDBI=" + m_shardDBI +
                ", m_sourceId=" + m_sourceId +
                ", m_sourceHost='" + m_sourceHost + '\'' +
                ", m_sourcePort=" + m_sourcePort +
                '}';
    }
}

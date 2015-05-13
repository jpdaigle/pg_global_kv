package com.tripadvisor.postgres.pg_kv_daemon;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.skife.jdbi.v2.DBI;
import org.skife.jdbi.v2.Handle;
import org.skife.jdbi.v2.OutParameters;
import org.skife.jdbi.v2.exceptions.CallbackFailedException;

import java.util.concurrent.Callable;

/**
 * Created by mkelly on 5/13/15.
 */
public class ReplicationTask implements Callable<Object>
{

    private final static Logger LOGGER = LogManager.getLogger();

    private final DBI m_shardDBI;
    private final int m_sourceId;
    private final String m_sourceHost;
    private final int m_sourcePort;



    public ReplicationTask(DBI shardDBI, int sourceId, String sourceHost, int sourcePort)
    {
        m_shardDBI = shardDBI;
        m_sourceId = sourceId;
        m_sourceHost = sourceHost;
        m_sourcePort = sourcePort;
    }

    @Override
    public Object call() throws Exception
    {
        try
        {
            m_shardDBI.withHandle(this::ensureRemoteConfig);
        }
        catch (CallbackFailedException e)
        {
            LOGGER.error("Unable to ensure valid connection config to remote server", e);
        }


        System.out.println(toString());
        return null;
    }

    private OutParameters ensureRemoteConfig(Handle h)
    {
        return h.createCall("{call kv_config.ensureRemoteShardConnection(:host, :port)}")
                .bind("host", m_sourceHost)
                .bind("port", m_sourcePort)
                .invoke();
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

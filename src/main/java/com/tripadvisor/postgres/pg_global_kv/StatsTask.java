package com.tripadvisor.postgres.pg_global_kv;

import com.google.common.util.concurrent.Uninterruptibles;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.skife.jdbi.v2.DBI;
import org.skife.jdbi.v2.Handle;
import org.skife.jdbi.v2.Update;

import java.util.concurrent.Callable;
import java.util.concurrent.TimeUnit;

/**
 * Created by mkelly on 5/14/15.
 */
public class StatsTask implements Callable<Object>
{
    private final static Logger LOGGER = LogManager.getLogger();

    private final DBI m_catalogDBI;

    public StatsTask(DBI catalogDBI)
    {
        m_catalogDBI = catalogDBI;
    }


    @Override
    public Object call() throws Exception
    {
        // Outer loop for reconnecting on error
        while(true)
        {
            try (Handle handle = m_catalogDBI.open())
            {
                Update update = handle.createStatement("SELECT kv_stats.update_statistics();");

                while (true)
                {
                    update.execute();
                    Uninterruptibles.sleepUninterruptibly(1, TimeUnit.SECONDS);
                }

            }
            catch (Exception e)
            {
                LOGGER.error("Stats collection error", e);
                Uninterruptibles.sleepUninterruptibly(5, TimeUnit.SECONDS);
            }
        }
    }
}

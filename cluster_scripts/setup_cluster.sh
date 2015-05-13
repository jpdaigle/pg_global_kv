#! /bin/bash
set -e
source config.sh

$PSQL_CATALOG -c 'COPY (SELECT * FROM shard_instance) TO stdout' |
while read ID HOSTNAME PORT SHARD_NAME; do
  util/create_node.sh $HOSTNAME $PORT $SHARD_NAME <(echo "
    \i sql/empty_data_node.sql
    INSERT INTO kv_config.my_info(instance_id, hostname) VALUES ($ID, '$HOSTNAME');
  ")
done


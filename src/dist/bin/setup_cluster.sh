#! /bin/bash
set -e
source config.sh

$PSQL_CATALOG -c 'COPY (SELECT hostname, port FROM catalog_instance
                  EXCEPT SELECT hostname, inet_server_port() FROM kv_config.my_info) TO stdout' |
while read HOSTNAME PORT; do
  util/create_node.sh $HOSTNAME $PORT $PRIMARY_CATALOG_DATABASE sql/empty_catalog.sql
done

$PSQL_CATALOG -c 'SELECT kv_config.push_catalog_changes()'

$PSQL_CATALOG -c 'COPY (SELECT * FROM shard_instance) TO stdout' |
while read ID HOSTNAME PORT SHARD_NAME; do
  util/create_node.sh $HOSTNAME $PORT $SHARD_NAME <(echo "
    \i sql/empty_data_node.sql
    UPDATE kv_config.my_info SET instance_id=$ID;
  ")
done


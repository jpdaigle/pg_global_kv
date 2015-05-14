#! /bin/bash

# This script is a convenience script for doing the initial setup of a node
# regardless of node type

set -e

HOST=$1
PORT=$2
DATABASE=$3
SETUP_SQL=$4

PSQL_GLOBAL="psql -h $HOST -p $PORT -U $ADMIN_USER"

if $RECREATE_EXISITING_NODES; then
  $PSQL_GLOBAL -c "DROP DATABASE IF EXISTS $DATABASE;"
fi

$PSQL_GLOBAL -c "CREATE DATABASE $DATABASE;"

PSQL_SHARD="psql -h $HOST -p $PORT -U $ADMIN_USER $DATABASE -1 -v ON_ERROR_STOP=1"

$PSQL_SHARD -f sql/common.sql
$PSQL_SHARD -c "INSERT INTO kv_config.my_info(hostname) VALUES ('$HOST');"
$PSQL_SHARD -f $SETUP_SQL

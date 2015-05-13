#! /bin/bash
set -e

source config.sh

./util/create_node.sh $PRIMARY_CATALOG_HOST $PRIMARY_CATALOG_PORT $PRIMARY_CATALOG_DATABASE sql/empty_catalog.sql

$PSQL_CATALOG -1f sql/demo_catalog_data.sql

echo
echo "Log into the catalog db and configure everything properly:"
echo "  $PSQL_CATALOG"
echo "Then run ./setup_cluster.sh"

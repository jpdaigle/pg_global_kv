#! /bin/bash

# Fix working dir
cd $(dirname $0)

./gradlew clean
sudo rm -rf /opt/pg_global_kv

#! /bin/bash

# Fix working dir
cd $(dirname $0)

./gradlew install
rm build/install/pg_global_kv/bin/pg_global_kv.bat
sudo rsync -a build/install/pg_global_kv /opt/

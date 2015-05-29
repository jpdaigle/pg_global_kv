#! /bin/bash

# Fix working dir
cd $(dirname $0)

./gradlew install
rm build/install/pg_kv_deamon/bin/pg_kv_deamon.bat
sudo rsync -a build/install/pg_kv_deamon /opt/

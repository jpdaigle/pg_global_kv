#! /bin/bash

# Fix working dir
cd $(dirname $0)

NAME=$(cat settings.gradle | awk '/rootProject.name/ {print $3}' | tr -d "'")

# Gradle install, just builds the dir build/install/pg_global_kv
./gradlew install
rm build/install/${NAME}/bin/${NAME}.bat
sudo rsync -a build/install/${NAME} /opt/

if [ -d /etc/init.d ]; then
  rm -f /etc/init.d/${NAME}
  ln -s /opt/${NAME}/etc/init.d/${NAME} /etc/init.d/${NAME}
fi

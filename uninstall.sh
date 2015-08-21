#! /bin/bash

# Fix working dir
cd $(dirname $0)

NAME=$(cat settings.gradle | awk '/rootProject.name/ {print $3}' | tr -d "'")

if [ -d /etc/init.d ]; then
  service ${NAME} stop
  rm -f /etc/init.d/${NAME}
fi

./gradlew clean
sudo rm -rf /opt/pg_global_kv

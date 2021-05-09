#!/bin/bash

KEYCLOAK_CONTAINER=$(docker ps -aqf "name=keycloak_keycloak")
KEYCLOAK_BACKUPS_CONTAINER=$(docker ps -aqf "name=keycloak_backups")

echo "--> All available database backups:"

for entry in $(docker container exec -it $KEYCLOAK_BACKUPS_CONTAINER sh -c "ls /srv/keycloak-postgres/backups/")
do
  echo "$entry"
done

echo "--> Copy and paste the backup name from the list above to restore database and press [ENTER]
--> Example: keycloak-postgres-backup-YYYY-MM-DD_hh-mm.gz"
echo -n "--> "

read SELECTED_DATABASE_BACKUP

echo "--> $SELECTED_DATABASE_BACKUP was selected"

echo "--> Stopping service..."
docker stop $KEYCLOAK_CONTAINER

echo "--> Restoring database..."
docker exec -it $KEYCLOAK_BACKUPS_CONTAINER sh -c 'PGPASSWORD="$(echo $POSTGRES_PASSWORD)" dropdb -h postgres -p 5432 keycloakdb -U keycloakdbuser \
&& PGPASSWORD="$(echo $POSTGRES_PASSWORD)" createdb -h postgres -p 5432 keycloakdb -U keycloakdbuser \
&& PGPASSWORD="$(echo $POSTGRES_PASSWORD)" gunzip -c /srv/keycloak-postgres/backups/'$SELECTED_DATABASE_BACKUP' | PGPASSWORD=$(echo $POSTGRES_PASSWORD) psql -h postgres -p 5432 keycloakdb -U keycloakdbuser'
echo "--> Database recovery completed..."

echo "--> Starting service..."
docker start $KEYCLOAK_CONTAINER

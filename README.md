# Keycloak with Let's Encrypt in a Docker Compose

Install the Docker Engine by following the official guide: https://docs.docker.com/engine/install/

Install the Docker Compose by following the official guide: https://docs.docker.com/compose/install/

Run `keycloak-restore-database.sh` to restore database if needed.

Deploy Keycloak server with a Docker Compose using the command:

`docker-compose -f keycloak-traefik-letsencrypt-docker-compose.yml -p keycloak up -d`

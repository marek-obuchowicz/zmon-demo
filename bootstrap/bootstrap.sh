#!/bin/bash

# abort on error
set -e

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root!"
    exit
fi


function run_docker () {
    name=$1
    shift 1
    echo "Starting Docker container ${name}.."
    # ignore non-existing containers
    docker kill $name &> /dev/null || true
    docker rm -f $name &> /dev/null || true
    docker run --restart "on-failure:10" --net zmon-demo -d --name $name $@
}

function get_latest () {
    name=$1
    # REST API returns tags sorted by time
    tag=$(curl --silent https://registry.opensource.zalan.do/teams/stups/artifacts/$name/tags | jq .[].name -r | tail -n 1)
    echo "$name:$tag"
}

function wait_port () {
    until nc -w 5 -z $1 $2; do
        echo "Waiting for TCP port $1:${2}.."
        sleep 3
    done
}

echo "Retrieving latest versions.."
REPO=registry.opensource.zalan.do/stups
POSTGRES_IMAGE=$REPO/postgres:9.4.5-1
REDIS_IMAGE=$REPO/redis:3.0.5
CASSANDRA_IMAGE=$REPO/cassandra:2.1.5-1
ZMON_KAIROSDB_IMAGE=$REPO/zmon-kairosdb:0.1.6
ZMON_EVENTLOG_SERVICE_IMAGE=$REPO/$(get_latest zmon-eventlog-service)
ZMON_CONTROLLER_IMAGE=$REPO/$(get_latest zmon-controller)
ZMON_SCHEDULER_IMAGE=$REPO/$(get_latest zmon-scheduler)
ZMON_WORKER_IMAGE=$REPO/$(get_latest zmon-worker)

USER_ID=$(id -u daemon)

# first we pull all required Docker images to ensure they are ready
for image in $POSTGRES_IMAGE $REDIS_IMAGE $CASSANDRA_IMAGE $ZMON_KAIROSDB_IMAGE \
    $ZMON_EVENTLOG_SERVICE_IMAGE $ZMON_CONTROLLER_IMAGE $ZMON_SCHEDULER_IMAGE $ZMON_WORKER_IMAGE; do
    echo "Pulling image ${image}.."
    docker pull $image
done

for i in zmon-controller zmon-eventlog-service; do
    if [ ! -d /workdir/$i ]; then
        wget https://github.com/zalando/$i/archive/master.zip -O /workdir/$i.zip
        mkdir -p /workdir/$i
        unzip /workdir/$i.zip -d /workdir/$i
        rm /workdir/$i.zip
    fi
done

# set up PostgreSQL
export PGHOST=zmon-postgres
export PGUSER=postgres
export PGPASSWORD=$(makepasswd --chars 32)
export PGDATABASE=local_zmon_db

echo "zmon-postgres:5432:*:postgres:$PGPASSWORD" > ~/.pgpass
chmod 600 ~/.pgpass

run_docker zmon-postgres -e POSTGRES_PASSWORD=$PGPASSWORD $POSTGRES_IMAGE
wait_port zmon-postgres 5432

cd /workdir/zmon-controller/zmon-controller-master/database/zmon
psql -c "CREATE DATABASE $PGDATABASE;" postgres
psql -c 'CREATE EXTENSION IF NOT EXISTS hstore;'
psql -c "CREATE ROLE zmon WITH LOGIN PASSWORD '--secret--';" postgres
find -name '*.sql' | sort | xargs cat | psql

psql -f /workdir/zmon-eventlog-service/zmon-eventlog-service-master/database/eventlog/00_create_schema.sql

# set up Redis
run_docker zmon-redis $REDIS_IMAGE
wait_port zmon-redis 6379

# set up Cassandra
run_docker zmon-cassandra $CASSANDRA_IMAGE
wait_port zmon-cassandra 9160

# set up KairosDB
run_docker zmon-kairosdb \
    -e "CASSANDRA_HOST_LIST=zmon-cassandra:9160" \
    $ZMON_KAIROSDB_IMAGE

wait_port zmon-kairosdb 8083

run_docker zmon-eventlog-service \
    -u $USER_ID \
    -e SERVER_PORT=8081 \
    -e MEM_JAVA_PERCENT=10 \
    -e POSTGRESQL_HOST=$PGHOST \
    -e POSTGRESQL_USER=$PGUSER -e POSTGRESQL_PASSWORD=$PGPASSWORD \
    $ZMON_EVENTLOG_SERVICE_IMAGE

SCHEDULER_TOKEN=$(makepasswd --string=0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ --chars 32)
BOOTSTRAP_TOKEN=$(makepasswd --string=0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ --chars 32)

run_docker zmon-controller \
    -u $USER_ID \
    -e SERVER_PORT=8080 \
    -e SERVER_SSL_ENABLED=false \
    -e SERVER_USE_FORWARD_HEADERS=true \
    -e MANAGEMENT_PORT=8079 \
    -e MANAGEMENT_SECURITY_ENABLED=false \
    -e MEM_JAVA_PERCENT=25 \
    -e SPRING_PROFILES_ACTIVE=github \
    -e ZMON_OAUTH2_SSO_CLIENT_ID=${ZMON_OAUTH2_SSO_CLIENT_ID:-64210244ddd8378699d6} \
    -e ZMON_OAUTH2_SSO_CLIENT_SECRET=${ZMON_OAUTH2_SSO_CLIENT_SECRET:-48794a58705d1ba66ec9b0f06a3a44ecb273c048} \
    -e ZMON_AUTHORITIES_SIMPLE_ADMINS=* \
    -e POSTGRES_URL=jdbc:postgresql://$PGHOST:5432/local_zmon_db \
    -e POSTGRES_PASSWORD=$PGPASSWORD \
    -e REDIS_HOST=zmon-redis \
    -e REDIS_PORT=6379 \
    -e ZMON_EVENTLOG_URL=http://zmon-eventlog-service:8081/ \
    -e ZMON_KAIROSDB_URL=http://zmon-kairosdb:8083/ \
    -e PRESHARED_TOKENS_${SCHEDULER_TOKEN}_UID=zmon-scheduler \
    -e PRESHARED_TOKENS_${SCHEDULER_TOKEN}_EXPIRES_AT=1758021422 \
    -e PRESHARED_TOKENS_${BOOTSTRAP_TOKEN}_UID=zmon-demo-bootstrap \
    -e PRESHARED_TOKENS_${BOOTSTRAP_TOKEN}_EXPIRES_AT=1758021422 \
    $ZMON_CONTROLLER_IMAGE

until curl http://zmon-controller:8080/index.jsp &> /dev/null; do
    echo 'Waiting for ZMON Controller..'
    sleep 3
done

psql -f /workdir/bootstrap/initial.sql

# now configure some initial checks and alerts
echo -e "url: http://zmon-controller:8080/api/v1\ntoken: $BOOTSTRAP_TOKEN" > ~/.zmon-cli.yaml
for f in /workdir/bootstrap/check-definitions/*.yaml; do
    zmon check-definitions update $f
done
for f in /workdir/bootstrap/entities/*.yaml; do
    zmon entities push $f
done
for f in /workdir/bootstrap/alert-definitions/*.yaml; do
    zmon alert-definitions create $f
done

run_docker zmon-worker \
    -u $USER_ID \
    -e WORKER_REDIS_SERVERS=zmon-redis:6379 \
    -e WORKER_KAIROSDB_HOST=zmon-kairosdb \
    $ZMON_WORKER_IMAGE

run_docker zmon-scheduler \
    -u $USER_ID \
    -e MEM_JAVA_PERCENT=20 \
    -e SCHEDULER_REDIS_HOST=zmon-redis \
    -e SCHEDULER_URLS_WITHOUT_REST=true \
    -e SCHEDULER_ENTITY_SERVICE_URL=http://zmon-controller:8080/ \
    -e SCHEDULER_OAUTH2_STATIC_TOKEN=$SCHEDULER_TOKEN \
    -e SCHEDULER_CONTROLLER_URL=http://zmon-controller:8080/ \
    $ZMON_SCHEDULER_IMAGE

wait_port zmon-scheduler 8085

# Finally start our Apache 2 webserver (reverse proxy)
# TODO: this will not work locally
run_docker zmon-httpd \
    -p 80:80 -p 443:443 \
    -v /etc/letsencrypt/:/etc/letsencrypt/ \
    zmon-demo-httpd -DSSL

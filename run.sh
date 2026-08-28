#!/usr/bin/with-contenv bashio

CONFIG_PATH=/data/options.json

# LoRaWAN Addon Startup Script
bashio::log.info "Starting LoRaWAN Addon"

# Get Region from Options
REGION=$(bashio::config 'region')
echo "Region: $REGION"

# Copy the appropriate global configuration file based on the region
CONFIG_FILE="/etc/lora/sx1302_hal/packet_forwarder/global_conf.json.sx1250.${REGION}.USB"
TARGET_FILE="/etc/lora/sx1302_hal/packet_forwarder/global_conf.json"

if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "$TARGET_FILE"
    bashio::log.info "Copied $CONFIG_FILE to $TARGET_FILE"
else
    bashio::log.error "Configuration file for region $REGION not found"
    exit 1
fi

# Update chirpstack-gateway-bridge.toml with the appropriate region values
CS_REGION=""
case "$REGION" in
    US915)
        CS_REGION="us915_1"
        ;;
    EU868)
        CS_REGION="eu868"
        ;;
    AS923)
        CS_REGION="as923"
        ;;
    *)
        bashio::log.error "Unsupported region: $REGION"
        exit 1
        ;;
esac

sed -i "s|event_topic_template=.*|event_topic_template=\"${CS_REGION}/gateway/{{ .GatewayID }}/event/{{ .EventType }}\"|g" /etc/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml
sed -i "s|command_topic_template=.*|command_topic_template=\"${CS_REGION}/gateway/{{ .GatewayID }}/command/#\"|g" /etc/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml

bashio::log.info "Updated chirpstack-gateway-bridge.toml with region $CS_REGION"

# Set User Limits on File Descriptor Values
# start-stop-daemon wasn't working with --background without this
ulimit -n 65536

# Persistent PostgreSQL data directory
PGDATA_DEFAULT="/var/lib/postgresql/13/main"
PGDATA_PERSIST="/data/postgresql"

if [ ! -d "${PGDATA_PERSIST}/base" ]; then
    bashio::log.info "Initializing persistent PostgreSQL database"

    mkdir -p "${PGDATA_PERSIST}"
    cp -a "${PGDATA_DEFAULT}/." "${PGDATA_PERSIST}/"

    chown -R postgres:postgres "${PGDATA_PERSIST}"
    chmod 700 "${PGDATA_PERSIST}"
else
    bashio::log.info "Using existing persistent PostgreSQL database"
fi

# Replace the container's temporary PostgreSQL data directory
# with the persistent Home Assistant /data directory
rm -rf "${PGDATA_DEFAULT}"
ln -s "${PGDATA_PERSIST}" "${PGDATA_DEFAULT}"

# Start PostgreSQL
service postgresql start

# Initialize ChirpStack DB only on first run
if ! psql -U postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='chirpstack'" \
    | grep -q 1; then

    bashio::log.info "Creating ChirpStack PostgreSQL database"
    psql -U postgres -f pg_setup.sql
else
    bashio::log.info "ChirpStack PostgreSQL database already exists"
fi

# start redis
service redis-server start

# service mosquitto start
/usr/sbin/mosquitto -d
sleep 5

# start chirpstack-gateway-bridge
service chirpstack-gateway-bridge start

# start chirpstack
service chirpstack start

# start lora_pkt_fwd
service lora-pkt-fwd start

# run chripstack api script
sleep 5
/create-chirpstack-api-key.sh

# get gateway deployment info
LATITUDE=$(bashio::config 'latitude')
LONGITUDE=$(bashio::config 'longitude')
ALTITUDE=$(bashio::config 'altitude')

# add gateway to chirpstack
python3 add-gateway.py --latitude $LATITUDE --longitude $LONGITUDE --altitude $ALTITUDE

# keep the container running
while true; do
    sleep 1
done

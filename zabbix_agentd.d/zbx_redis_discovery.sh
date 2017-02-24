#!/bin/bash
DISCOVERY_TYPE=$1
# USE FIRST ARGUMENT TO UNDERSTAND WHICH DISCOVERY TO PERFORM
shift
IFS=$'\n'
PASSWORDS=( "$@" )
LIST=$(ps -eo uname,args | grep -v grep | grep redis-server | tr -s [:blank:] ":")
REDIS_CLI=$(whereis -b redis-cli | cut -d":" -f2 | tr -d [:space:])
INFOCMD=INFO
CONFCMD=CONFIG
SLOWCMD=SLOWLOG

if [ "$DISCOVERY_TYPE" == "info" ]; then
    echo "USAGE: ./zbx_redis_discovery.sh where"
    echo "general - argument generate report with discovered instances"
    echo "stats - generates report for avalable commands"
    echo "replication - generates report for avalable slaves"
    exit 1
fi

# CHECK REDIS INSTANCE AVAILABILITY
is_redis_unavailability() {
    local HOST=$1
    local PORT=$2
    local PASSWORD=$3
    local ALIVE=$($REDIS_CLI -h $HOST -p $PORT -a "$PASSWORD" ping)
    if [[ $ALIVE != "PONG" ]]; then
        return 0
    else
        return 1
    fi
}

# PROBE DISCOVERED REDIS INSTACES - TO GET INSTANCE NAME#
discover_redis_instance() {
    local HOST=$1
    local PORT=$2
    local PASSWORD=$3

    local INSTANCE=$(hostname)-$($REDIS_CLI -h $HOST -p $PORT -a "$PASSWORD" ${INFOCMD} | grep config_file  | sed 's/.conf//g' | rev | cut -d "/" -f1 | rev | tr -d [:space:] | tr [:lower:] [:upper:])
    local INSTANCE_RDB_PATH=$($REDIS_CLI -h $HOST -p $PORT -a "$PASSWORD" ${CONFCMD} get *"dir" | cut -d " " -f2 | sed -n 2p)
    local INSTANCE_RDB_FILE=$($REDIS_CLI -h $HOST -p $PORT -a "$PASSWORD" ${CONFCMD} get *"dbfilename" | cut -d " " -f2 | sed -n 2p)

    echo $INSTANCE
}

# PROBE DISCOVERED REDIS INSTACES - TO GET RDB DATABASE#
discover_redis_rdb_database() {
    local HOST=$1
    local PORT=$2
    local PASSWORD=$3

    local INSTANCE_RDB_PATH=$($REDIS_CLI -h $HOST -p $PORT -a "$PASSWORD" ${CONFCMD} get *"dir" | cut -d " " -f2 | sed -n 2p)
    local INSTANCE_RDB_FILE=$($REDIS_CLI -h $HOST -p $PORT -a "$PASSWORD" ${CONFCMD} get *"dbfilename" | cut -d " " -f2 | sed -n 2p)

    echo $INSTANCE_RDB_PATH/$INSTANCE_RDB_FILE
}

discover_redis_avalable_commands() {
    local HOST=$1
    local PORT=$2
    local PASSWORD=$3

    local REDIS_COMMANDS=$($REDIS_CLI -h $HOST -p $PORT -a "$PASSWORD" ${INFOCMD} all | grep cmdstat | cut -d":" -f1)

    ( IFS=$'\n'; echo "${REDIS_COMMANDS[*]}" )
}

discover_redis_avalable_slaves() {
    local HOST=$1
    local PORT=$2
    local PASSWORD=$3

    local REDIS_SLAVES=$($REDIS_CLI -h $HOST -p $PORT -a "$PASSWORD" ${INFOCMD} all | grep ^slave | cut -d ":" -f1 | grep [0-1024])

    ( IFS=$'\n'; echo "${REDIS_SLAVES[*]}" )
}

# GENERATE ZABBIX DISCOVERY JSON REPONSE #
generate_general_discovery_json() {
    local HOST=$1
    [ "$ALL_FLAG" == 'TRUE' ] && HOST='*'
    local PORT=$2
    local INSTANCE=$3
    local RDB_PATH=$4
  
    printf "{\"{#HOST}\":\"%s\",\"{#PORT}\":\"%s\",\"{#INSTANCE}\":\"%s\",\"{#RDB_PATH}\":\"%s\"}," "$HOST" "$PORT" "$INSTANCE" "$RDB_PATH"

}

# GENERATE ZABBIX DISCOVERY JSON REPONSE #
generate_commands_discovery_json() {
    local HOST=$1
    [ "$ALL_FLAG" == 'TRUE' ] && HOST='*'
    local PORT=$2
    local COMMAND=$3
    local INSTANCE=$4

    printf "{\"{#HOST}\":\"%s\",\"{#PORT}\":\"%s\",\"{#COMMAND}\":\"%s\",\"{#INSTANCE}\":\"%s\"}," "$HOST" "$PORT" "$COMMAND" "$INSTANCE"
}

# GENERATE ZABBIX DISCOVERY JSON REPONSE #
generate_replication_discovery_json() {
    local HOST=$1
    [ "$ALL_FLAG" == 'TRUE' ] && HOST='*'
    local PORT=$2
    local SLAVE=$3
    local INSTANCE=$4

    printf "{\"{#HOST}\":\"%s\",\"{#PORT}\":\"%s\",\"{#SLAVE}\":\"%s\",\"{#INSTANCE}\":\"%s\"}," "$HOST" "$PORT" "$SLAVE" "$INSTANCE"
}


# GENERATE ALL REPORTS REQUIRED FOR REDIS MONITORING #
generate_redis_stats_report() {
    local HOST=$1
    local PORT=$2
    local PASSWORD=$3

    local REDIS_REPORT=$(stdbuf -oL $REDIS_CLI -h $HOST -p $PORT -a "$PASSWORD" ${INFOCMD} all &> /tmp/redis-$HOST-$PORT)
    local REDIS_SLOWLOG_LEN=$(stdbuf -oL $REDIS_CLI -h $HOST -p $PORT -a "$PASSWORD" ${SLOWCMD} len | cut -d " " -f2 &> /tmp/redis-$HOST-$PORT-slowlog-len; $REDIS_CLI -h $HOST -p $PORT -a $PASSWORD ${SLOWCMD} reset > /dev/null  )
    local REDIS_SLOWLOG_RAW=$(stdbuf -oL $REDIS_CLI -h $HOST -p $PORT -a "$PASSWORD" ${SLOWCMD} get &> /tmp/redis-$HOST-$PORT-slowlog-raw)
    local REDIS_MAX_CLIENTS=$(stdbuf -oL $REDIS_CLI -h $HOST -p $PORT -a "$PASSWORD" ${CONFCMD} get *"maxclients"* | cut -d " " -f2 | sed -n 2p &> /tmp/redis-$HOST-$PORT-maxclients)
}

# MAIN LOOP #

echo -n '{"data":['
for s in $LIST; do
    HOST=$(echo $s | cut -d":" -f3)
    HOST=${HOST#\*}
    ALL_FLAG=${HOST:-'TRUE'}
    HOST=${HOST:-'127.0.0.1'}
    PORT=$(echo $s | cut -d":" -f4)

    # TRY PASSWORD PER EACH DISCOVERED INSTANCE
    if [[ ${#PASSWORDS[@]} -ne 0 ]]; then
        for (( i=0; i<${#PASSWORDS[@]}; i++ ));
        do
            PASSWORD=${PASSWORDS[$i]}
            is_redis_unavailability $HOST $PORT $PASSWORD && continue
            INSTANCE=$(discover_redis_instance $HOST $PORT $PASSWORD)
            RDB_PATH=$(discover_redis_rdb_database $HOST $PORT $PASSWORD)
            COMMANDS=$(discover_redis_avalable_commands $HOST $PORT $PASSWORD)
            SLAVES=$(discover_redis_avalable_slaves $HOST $PORT $PASSWORD)

            if [[ -n $INSTANCE ]]; then

                # DECIDE WHICH REPORT TO GENERATE FOR DISCOVERY
                if [[ $DISCOVERY_TYPE == "general" ]]; then
                    generate_redis_stats_report $HOST $PORT $PASSWORD
                    generate_general_discovery_json $HOST $PORT $INSTANCE $RDB_PATH
                elif [[ $DISCOVERY_TYPE == "stats" ]]; then
                    for COMMAND in ${COMMANDS}; do
                        generate_commands_discovery_json $HOST $PORT $COMMAND $INSTANCE
                    done
                elif [[ $DISCOVERY_TYPE == "replication" ]]; then
                    for SLAVE in ${SLAVES}; do
                        generate_replication_discovery_json $HOST $PORT $SLAVE $INSTANCE
                    done
                else
                    echo "Smooking :)"
                fi

                break
            fi
        done
    else
        is_redis_unavailability $HOST $PORT "" && continue
        INSTANCE=$(discover_redis_instance $HOST $PORT "")
        RDB_PATH=$(discover_redis_rdb_database $HOST $PORT "")
        COMMANDS=$(discover_redis_avalable_commands $HOST $PORT "")
        SLAVES=$(discover_redis_avalable_slaves $HOST $PORT "")

        if [[ -n $INSTANCE ]]; then

            # DECIDE WHICH REPORT TO GENERATE FOR DISCOVERY
            if [[ $DISCOVERY_TYPE == "general" ]]; then
                generate_redis_stats_report $HOST $PORT ""
                generate_general_discovery_json $HOST $PORT $INSTANCE $RDB_PATH
            elif [[ $DISCOVERY_TYPE == "stats" ]]; then
                for COMMAND in ${COMMANDS}; do
                    generate_commands_discovery_json $HOST $PORT $COMMAND $INSTANCE
                done
            elif [[ $DISCOVERY_TYPE == "replication" ]]; then
                for SLAVE in ${SLAVES}; do
                    generate_replication_discovery_json $HOST $PORT $SLAVE $INSTANCE
                done
            else
                echo "Smooking :)"
            fi

        fi
    fi
    unset
done | sed -e 's:\},$:\}:'
echo -n ']}'
echo ''
unset IFS

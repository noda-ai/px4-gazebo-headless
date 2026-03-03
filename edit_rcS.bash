#!/bin/bash

function is_docker_vm {
    getent ahostsv4 host.docker.internal >/dev/null 2>&1
    return $?
}

function get_vm_host_ip {
    if ! is_docker_vm; then
        echo "ERROR: this is not running from a docker VM!"
        exit 1
    fi

    # Original VM host IP: returns IPv6 address (fdc4:f303:9324::254), unsuppored by mavlink server
    # See also https://github.com/JonasVautherin/px4-gazebo-headless/issues/54
    # See https://github.com/docker/for-mac/issues/7332
    # echo "$(getent hosts host.docker.internal | awk '{ print $1 }')"

    # This generates an IPv4 address (192.168.65.254) which points to the host machine (Macbook)
    echo "$(dig host.docker.internal +short)"
}

function get_px4_client_ip {
    # Generates an IPv4 address (172.19.0.1) which points to the PX4 client Docker container
    # TODO investigate more robust networking options: if PX4 client container restarts, the IP will change, requiring this simulator to obtain the new IP and restart the mavsdk server
    # If PX4_CLIENT_HOST is set, use it
    # If not, use 127.0.0.1
    if [ -n "$PX4_CLIENT_HOST" ]; then
        echo "$(dig $PX4_CLIENT_HOST +short)"
    else
        get_vm_host_ip
    fi
}

function get_host_ip {
    echo "$(ip route | awk '/default/ { print $3 }')"
}

function build_hadean_inject {
    IFS=":" read -r HADEAN_DIS_IP HADEAN_DIS_PORT <<< "$DIS_IP"

    local LAT_INJECT=""
    if [ -n "${HADEAN_DIS_IP}" ]; then
        LAT_INJECT="<lat>${lat}</lat>"
    fi

    local LON_INJECT=""
    if [ -n "${HADEAN_DIS_IP}" ]; then
        LON_INJECT="<lon>${lon}</lon>"
    fi

    local IP_INJECT=""
    if [ -n "${HADEAN_DIS_IP}" ]; then
        IP_INJECT="<ip>${HADEAN_DIS_IP}</ip>"
    fi

    local PORT_INJECT=""
    if [ -n "${HADEAN_DIS_PORT}" ]; then
        PORT_INJECT="<port>${HADEAN_DIS_PORT}</port>"
    fi


    local -a VEHICLE_INJECTS=()
    for (( i=0; i<count_drones; i++ )); do
        NAME_PARAM=" name=\"${name_drone}_${i}\""
        ENUM_PARAM=" dis_enum=\"${enum_drone}\""
        VEHICLE_INJECTS+=("<vehicle ${NAME_PARAM}${ENUM_PARAM}></vehicle>")
    done

    local VEHICLES_INJECT=""
    printf -v VEHICLES_INJECT '%s' "${VEHICLE_INJECTS[@]}"

    echo -e "${LAT_INJECT}${LON_INJECT}${IP_INJECT}${PORT_INJECT}${VEHICLES_INJECT}"
}

OPTIND=1

while getopts "a:q:l:o:i:c:n:e:" opt; do
    case "$opt" in
    a)  IP_API=$OPTARG # Unused Leftover
        ;;
    q)  IP_QGC=$OPTARG # Unused Leftover
        ;;
    l)  lat=$OPTARG
        ;;
    o)  lon=$OPTARG
        ;;
    i)  ip_dis=$OPTARG
        ;;
    c)  count_drones=$OPTARG
        ;;
    n)  name_drone=$OPTARG
        ;;
    e)  enum_drone=$OPTARG
        ;;
    esac
done

unset OPTIND

# Broadcast doesn't work with docker from a VM (macOS or Windows), so we default to the vm host (host.docker.internal)
if is_docker_vm; then
    VM_HOST=$(get_vm_host_ip)
    PX4_CLIENT_HOST=$(get_px4_client_ip)
    DIS_IP="${ip_dis:-${VM_HOST}}"
    echo "VM host IP: ${VM_HOST}"
    echo "PX4 client IP: ${PX4_CLIENT_HOST}"
    echo "DIS target IP: ${DIS_IP}"
    QGC_PARAM=${QGC_PARAM:-"-t ${VM_HOST}"}
    API_PARAM=${API_PARAM:-"-t ${PX4_CLIENT_HOST}"}
else
    HOST=$(get_host_ip)
    echo "Host IP: ${HOST}"
    QGC_PARAM=${QGC_PARAM:-"-t ${HOST}"}
    API_PARAM=${API_PARAM:-"-t ${HOST}"}
    DIS_IP=${DIS_IP:-"${HOST}"}
fi


CONFIG_FILE=${FIRMWARE_DIR}/build/etc/init.d-posix/px4-rc.mavlink
HADEAN_LOADER=${FIRMWARE_DIR}/Tools/simulation/gz/models/custom/hadean-loader.sdf
HADEAN_INJECT=$(build_hadean_inject)

echo "QGroundControl access from ${QGC_PARAM}"
echo "MAVSDK access from ${API_PARAM}"
echo "DIS target from ${DIS_IP}"

sed -i "s/mavlink start \-x \-u \$udp_gcs_port_local -r 4000000/mavlink start -x -u \$udp_gcs_port_local -r 4000000 ${QGC_PARAM}/" ${CONFIG_FILE}
sed -i "s/mavlink start \-x \-u \$udp_offboard_port_local -r 4000000/mavlink start -x -u \$udp_offboard_port_local -r 4000000 ${API_PARAM}/" ${CONFIG_FILE}
sed -i "s|</plugin>|${HADEAN_INJECT}</plugin>|" ${HADEAN_LOADER}
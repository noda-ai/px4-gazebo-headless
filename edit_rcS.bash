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
    local LAT_INJECT=""
    if [ -n "${DIS_IP}" ]; then
        LAT_INJECT="<lat>${lat}</lat>"
    fi

    local LON_INJECT=""
    if [ -n "${DIS_IP}" ]; then
        LON_INJECT="<lon>${lon}</lon>"
    fi

    local IP_INJECT=""
    if [ -n "${DIS_IP}" ]; then
        IP_INJECT="<ip>${DIS_IP}</ip>"
    fi

    local PORT_INJECT=""
    if [ -n "${DIS_PORT}" ]; then
        PORT_INJECT="<port>${DIS_PORT}</port>"
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

while getopts "a:q:l:o:i:p:c:n:e:" opt; do
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
    p)  port_dis=$OPTARG
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
    DIS_PORT="${port_dis:-3000}"
    echo "VM host IP: ${VM_HOST}"
    echo "PX4 client IP: ${PX4_CLIENT_HOST}"
    echo "DIS target IP: ${DIS_IP}"
    echo "DIS target Port: ${DIS_PORT}"
    QGC_PARAM=${QGC_PARAM:-"-t ${VM_HOST}"}
    API_PARAM=${API_PARAM:-"-t ${PX4_CLIENT_HOST}"}
else
    HOST=$(get_host_ip)
    echo "Host IP: ${HOST}"
    QGC_PARAM=${QGC_PARAM:-"-t ${HOST}"}
    API_PARAM=${API_PARAM:-"-t ${HOST}"}
    DIS_IP=${ip_dis:-"${HOST}"}
    DIS_PORT=${port_dis:-3000}
fi

RCS_CONFIG_FILE=${FIRMWARE_DIR}/build/etc/init.d-posix/rcS
CONFIG_FILE=${FIRMWARE_DIR}/build/etc/init.d-posix/px4-rc.mavlink
HADEAN_LOADER=${FIRMWARE_DIR}/Tools/simulation/gz/models/custom/hadean-loader.sdf
HADEAN_INJECT=$(build_hadean_inject)

# TODO parameterize
MODEL_FILE=${FIRMWARE_DIR}/Tools/simulation/gz/models/x500/model.sdf
BASE_MODEL_FILE=${FIRMWARE_DIR}/Tools/simulation/gz/models/x500_base/model.sdf

echo "QGroundControl access from ${QGC_PARAM}"
echo "MAVSDK access from ${API_PARAM}"
echo "DIS target from ${DIS_IP}:${DIS_PORT}"

printf 'param set COM_DL_LOSS_T 160\nparam set COM_OBC_LOSS_T 80\nparam set COM_OF_LOSS_T 16\nparam set COM_RC_LOSS_T 16' >> "${RCS_CONFIG_FILE}"
sed -i "s/mavlink start \-x \-u \$udp_gcs_port_local -r 4000000/mavlink start -x -u \$udp_gcs_port_local -r 4000000 ${QGC_PARAM}/" ${CONFIG_FILE}
sed -i "s/mavlink start \-x \-u \$udp_offboard_port_local -r 4000000/mavlink start -x -u \$udp_offboard_port_local -r 4000000 ${API_PARAM}/" ${CONFIG_FILE}
sed -i "s|</plugin>|${HADEAN_INJECT}</plugin>|" ${HADEAN_LOADER}
sed -i "s|<rotorVelocitySlowdownSim>10</rotorVelocitySlowdownSim>|<rotorVelocitySlowdownSim>100</rotorVelocitySlowdownSim>|" ${MODEL_FILE}
sed -i "s|<update_rate>250</update_rate>|<update_rate>250</update_rate>|" ${BASE_MODEL_FILE}

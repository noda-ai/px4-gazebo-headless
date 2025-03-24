#!/bin/bash

function is_docker_vm {
    getent hosts host.docker.internal >/dev/null 2>&1
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

# Broadcast doesn't work with docker from a VM (macOS or Windows), so we default to the vm host (host.docker.internal)
if is_docker_vm; then
    VM_HOST=$(get_vm_host_ip)
    PX4_CLIENT_HOST=$(get_px4_client_ip)
    echo "VM host IP: ${VM_HOST}"
    echo "PX4 client IP: ${PX4_CLIENT_HOST}"
    QGC_PARAM=${QGC_PARAM:-"-t ${VM_HOST}"}
    API_PARAM=${API_PARAM:-"-t ${PX4_CLIENT_HOST}"}
else
    HOST=$(get_host_ip)
    echo "Host IP: ${HOST}"
    QGC_PARAM=${QGC_PARAM:-"-t ${HOST}"}
    API_PARAM=${API_PARAM:-"-t ${HOST}"}
fi

CONFIG_FILE=${FIRMWARE_DIR}/build/etc/init.d-posix/px4-rc.mavlink

echo "QGroundControl access from ${QGC_PARAM}"
echo "MAVSDK access from ${API_PARAM}"

sed -i "s/mavlink start \-x \-u \$udp_gcs_port_local -r 4000000/mavlink start -x -u \$udp_gcs_port_local -r 4000000 ${QGC_PARAM}/" ${CONFIG_FILE}
sed -i "s/mavlink start \-x \-u \$udp_offboard_port_local -r 4000000/mavlink start -x -u \$udp_offboard_port_local -r 4000000 ${API_PARAM}/" ${CONFIG_FILE}

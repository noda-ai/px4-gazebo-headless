#!/bin/bash

function show_help {
    echo ""
    echo "Usage: ${0} [-h | -v VEHICLE | -w WORLD] [HOST_API | HOST_QGC HOST_API]"
    echo ""
    echo "Run a headless px4-gazebo simulation in a docker container. The"
    echo "available vehicles and worlds are the ones available in PX4"
    echo "(i.e. when running e.g. \`make px4_sitl gazebo_iris__baylands\`)"
    echo ""
    echo "  -h    Show this help"
    echo "  -v    Set the vehicle (default: gz_x500)"
    echo "  -w    Set the world (default: default)"
    echo ""
    echo "  <HOST_API> is the host or IP to which PX4 will send MAVLink on UDP port 14540"
    echo "  <HOST_QGC> is the host or IP to which PX4 will send MAVLink on UDP port 14550"
    echo ""
    echo "By default, MAVLink is sent to the host."
}

function get_ip {
    output=$(getent hosts "$1" | awk '{print $1}')
    if [ -z $output ];
    then
        # No output, assume IP
        echo $1
    else
        # Got IP, use it
        echo $output
    fi
}

OPTIND=1 # Reset in case getopts has been used previously in the shell.

vehicle=${PX4_GZ_VEHICLE:-gz_x500}
world=${PX4_GZ_WORLD:-default}

while getopts "h?v:w:" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    v)  vehicle=$OPTARG
        ;;
    w)  world=$OPTARG
        ;;
    esac
done

shift $((OPTIND-1))

# Rely on environment variables for offboard API (MAVSDK) IP address, QGroundControl IP address, and PX4 instance ID
if [ -n "${IP_API}" ]; then
    IP_API=$(get_ip "${IP_API}")
fi

if [ -n "${IP_QGC}" ]; then
    IP_QGC=$(get_ip "${IP_QGC}")
fi

# Number of drones to spawn in the simulator
NUM_DRONES=${NUM_DRONES:-1}

# Start Xvfb in background
Xvfb :99 -screen 0 1600x1200x24+32 &
${SITL_RTSP_PROXY}/build/sitl_rtsp_proxy &


source ${WORKSPACE_DIR}/edit_rcS.bash ${IP_API} ${IP_QGC} &&

# Adapted from https://github.com/PX4/PX4-Autopilot/blob/main/Tools/simulation/sitl_multiple_run.sh
n=0
while [ $n -lt $NUM_DRONES ]; do
    working_dir="$PX4_BUILD_DIR/instance_$n"
    [ ! -d "$working_dir" ] && mkdir -p "$working_dir"

    pushd "$working_dir" &>/dev/null
    echo "starting instance $n in $(pwd)"
    # PX4_GZ_MODEL_POSE (x, y, z, roll, pitch, yaw) should be unique for each instance to avoid collisions on initialization
    HEADLESS=1 PX4_SIM_MODEL=${vehicle} PX4_GZ_WORLD=${world} PX4_GZ_MODEL_POSE="$(($n + 1)),0,0,0,0,0" ${PX4_BUILD_DIR}/bin/px4 -d -i $n &
    popd &>/dev/null
        
    # Increased sleep time between subsequent instance launches
    echo "Sleeping 10 seconds before launching next instance..."
    sleep 10
    
    n=$(($n + 1))
done

# Wait for all PX4 instances to finish
wait
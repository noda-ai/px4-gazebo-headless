#!/bin/bash

function show_help {
    echo ""
    echo "Usage: ${0} [-h | -v VEHICLE | -e ENUM | -c COUNT | -w WORLD | -l LATITUDE | -o LONGITUDE | -i DIS_IP | -p DIS_PORT] [HOST_API | HOST_QGC HOST_API]"
    echo ""
    echo "Run a headless px4-gazebo simulation in a docker container. The"
    echo "available vehicles and worlds are the ones available in PX4"
    echo "(i.e. when running e.g. \`make px4_sitl gazebo_iris__baylands\`)"
    echo ""
    echo "  -h    Show this help"
    echo "  -v    Set the vehicle (default: gz_x500)"
    echo "  -e    Set the DIS Entity Type Enumeration (default: 1.2.0.50.1.0.0)"
    echo "  -c    Set the vehicle count (default: 1)"
    echo "  -w    Set the world (default: default)"
    echo "  -l    Set the Latitude for the vehicles (default: 50.78398504070213 (Portsmouth))"
    echo "  -o    Set the Longitude for the vehicles (default: -1.2890323096956389 (Portsmouth))"
    echo "  -i    Set the IP address the DIS packets will be sent to (default: IP_DIS variable or Docker host ip)"
    echo "  -p    Set the Port the DIS packets will be set to (default: 3000)"
    echo ""
    echo "  <HOST_API> is the host or IP to which PX4 will send MAVLink on UDP port 14540"
    echo "  <HOST_QGC> is the host or IP to which PX4 will send MAVLink on UDP port 14550"
    echo ""
    echo "By default, MAVLink is sent to the host."
}

function get_ip {
    output=$(getent hosts "$1" | head -1 | awk '{print $1}')
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

vehicle=gz_x500
enum=1.2.0.50.1.0.0
NUM_DRONES=${NUM_DRONES:-1}
world=${PX4_GZ_WORLD:-default}
lat=${LATITUDE:-50.78398504070213}
lon=${LONGITUDE:--1.2890323096956389}
# IP_DIS handled in edit_rcS
PORT_DIS=3000

while getopts "h?v:e:c:w:l:o:i:p:" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    v)  vehicle=$OPTARG
        ;;
    e)  enum=$OPTARG
        ;;
    c)  NUM_DRONES=$OPTARG
        ;;
    w)  world=$OPTARG
        ;;
    l)  lat=$OPTARG
        ;;
    o)  lon=$OPTARG
        ;;
    i)  IP_DIS=$OPTARG
        ;;
    p)  PORT_DIS=$OPTARG
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

if [ -n "${IP_DIS}" ]; then
    IP_DIS=$(get_ip "${IP_DIS}")
fi

# Start Xvfb in background
Xvfb :99 -screen 0 1600x1200x24+32 &
${SITL_RTSP_PROXY}/build/sitl_rtsp_proxy &


# Trims "gz_" out of $vehicle. TODO: verify this is consistent behavior in px4
# TODO: a cleaner option would be to embed per-vehicle logic in vehicle models themselves
#   or at least just embed a unique identifier
vehicle_gz_name="${vehicle:3}"

source ${WORKSPACE_DIR}/edit_rcS.bash -a "${IP_API}" -q "${IP_QGC}" -l "${lat}" -o "${lon}" -i "${IP_DIS}" -p "$PORT_DIS" -c "${NUM_DRONES}" -n "${vehicle_gz_name}" -e "${enum}" &&

# ── Simulation tolerance params ──────────────────────────────────
# Inject param overrides directly into the PX4 SITL startup script
# so they run before preflight checks. Appended after the FCONFIG
# block to act as a guaranteed fallback.
POSIX_RCS=${FIRMWARE_DIR}/build/etc/init.d-posix/rcS

# Simulation tolerance — relax preflight checks for heavy sim loads
cat >> "$POSIX_RCS" <<'SIM_PARAMS'

# --- Injected by entrypoint.sh: relax preflight + disable auto-RTL ---
param set COM_ARM_IMU_ACC 3.0
param set EKF2_ABL_LIM 0.8
param set COM_ARM_WO_GPS 1
# Disable PX4 automatic RTL — battery/link-loss handled by external orchestrator
param set COM_LOW_BAT_ACT 0
param set NAV_DLL_ACT 0
SIM_PARAMS

# Simulated battery drain (SIM_BAT_DRAIN seconds); falls back to airframe default when unset
if [ -n "${SIM_BAT_DRAIN}" ]; then
    cat >> "$POSIX_RCS" <<BAT_DRAIN
param set SIM_BAT_MIN_PCT 0
param set SIM_BAT_DRAIN ${SIM_BAT_DRAIN}
BAT_DRAIN
fi

echo "Injected sim tolerance params into rcS"

# Source PX4's Gazebo environment setup (sets up model/plugin paths)
GZ_ENV_FILE="${FIRMWARE_DIR}/build/rootfs/gz_env.sh"
if [ -f "$GZ_ENV_FILE" ]; then
    echo "Sourcing Gazebo environment from: ${GZ_ENV_FILE}"
    . "$GZ_ENV_FILE"
else
    echo "WARNING: gz_env.sh not found at ${GZ_ENV_FILE}, setting paths manually"
    export PX4_GZ_MODELS=${FIRMWARE_DIR}/Tools/simulation/gz/models
    export PX4_GZ_WORLDS=${FIRMWARE_DIR}/Tools/simulation/gz/worlds
    export PX4_GZ_PLUGINS=${FIRMWARE_DIR}/build/src/modules/simulation/gz_plugins
    export GZ_SIM_RESOURCE_PATH=$GZ_SIM_RESOURCE_PATH:$PX4_GZ_MODELS:$PX4_GZ_WORLDS
    export GZ_SIM_SYSTEM_PLUGIN_PATH=$GZ_SIM_SYSTEM_PLUGIN_PATH:$PX4_GZ_PLUGINS
fi

export PX4_HOME_LAT=${lat}
export PX4_HOME_LON=${lon}
export PX4_HOME_ALT=0

# Resolve world file path
world_file="${PX4_GZ_WORLDS}/${world}.sdf"

# Start Gazebo server first (before PX4 instances)
echo "Starting Gazebo with world: ${world_file}"
echo "GZ_SIM_RESOURCE_PATH: ${GZ_SIM_RESOURCE_PATH}"
echo "GZ_SIM_SYSTEM_PLUGIN_PATH: ${GZ_SIM_SYSTEM_PLUGIN_PATH}"
gz sim --verbose=1 -r -s "${world_file}" &
GZ_PID=$!

# Wait for Gazebo to be fully ready using PX4's method
# First wait for any world to appear, then get its name from the topic
echo "Waiting for Gazebo world to be ready..."
GZ_STARTUP_TIMEOUT=${GZ_STARTUP_TIMEOUT:-120}
elapsed=0

# Function to check if scene info service is available
check_scene_info() {
    local wname=$1
    SERVICE_INFO=$(gz service -i --service "/world/${wname}/scene/info" 2>&1)
    if echo "$SERVICE_INFO" | grep -q "Service providers"; then
        return 0
    else
        return 1
    fi
}

# Function to get world name from running Gazebo
get_world_name() {
    gz topic -l 2>/dev/null | grep -m 1 -e "^/world/.*/clock" | sed 's/\/world\///g; s/\/clock//g'
}

world_name=""
while [ $elapsed -lt $GZ_STARTUP_TIMEOUT ]; do
    # Try to get world name from Gazebo topics
    if [ -z "$world_name" ]; then
        world_name=$(get_world_name)
    fi

    # If we have a world name, check if it's fully ready
    if [ -n "$world_name" ] && check_scene_info "$world_name"; then
        echo "Gazebo world '${world_name}' is ready after ${elapsed}s"
        break
    fi

    sleep 1
    elapsed=$((elapsed + 1))
    if [ $((elapsed % 10)) -eq 0 ]; then
        echo "Still waiting for Gazebo... (${elapsed}s/${GZ_STARTUP_TIMEOUT}s)"
    fi
done

if [ $elapsed -ge $GZ_STARTUP_TIMEOUT ]; then
    echo "ERROR: Gazebo failed to start within ${GZ_STARTUP_TIMEOUT}s"
    exit 1
fi

# Export world name for PX4 to use
export PX4_GZ_WORLD=${world_name}

# Start sim speed controller API
export GZ_WORLD_NAME=${world_name}
python3 -u ${WORKSPACE_DIR}/sim_speed_controller.py &

# Additional delay to ensure physics is stable
sleep 2

# ── Launch PX4 instances ─────────────────────────────────────────
# SIM_DRONE_DELAYS: comma-separated per-drone spawn delays (seconds).
# Example: "0,0,600,900" → drones 0,1 immediate, drone 2 at 10min, drone 3 at 15min.
IFS=',' read -ra DRONE_DELAYS <<< "${SIM_DRONE_DELAYS:-}"

launch_px4_instance() {
    local n=$1
    local working_dir="$PX4_BUILD_DIR/instance_$n"
    [ ! -d "$working_dir" ] && mkdir -p "$working_dir"

    pushd "$working_dir" &>/dev/null
    echo "starting instance $n in $(pwd)"

    HEADLESS=1 PX4_SIM_MODEL=${vehicle} PX4_GZ_WORLD=${world} PX4_GZ_MODEL_POSE="$(($n + 1)),0,0,0,0,0" ${PX4_BUILD_DIR}/bin/px4 -d -i $n &
    popd &>/dev/null
}

# Launch each drone: immediate or delayed in background
for n in $(seq 0 $(($NUM_DRONES - 1))); do
    delay="${DRONE_DELAYS[$n]:-0}"
    if [ "$delay" -gt 0 ] 2>/dev/null; then
        (
            echo "Drone $n will spawn after ${delay}s"
            sleep "$delay"
            echo "=== Spawning drone $n ==="
            launch_px4_instance "$n"
        ) &
    else
        launch_px4_instance "$n"
        echo "Sleeping 10 seconds before next instance..."
        sleep 10
    fi
done

gz service -s /world/${world_name}/create \
--reqtype gz.msgs.EntityFactory \
--reptype gz.msgs.Boolean \
--timeout 5000 \
--req "sdf_filename: \"${PX4_GZ_MODELS}/custom/hadean-loader.sdf\""

# Start respawn watchdog (monitors landed drones and restarts them)
if [ "${SIM_RESPAWN_ENABLED:-1}" = "1" ]; then
    export GZ_WORLD_NAME=${world_name}
    bash ${WORKSPACE_DIR}/respawn_watchdog.sh &
    echo "Respawn watchdog started"
fi

# Wait for all PX4 instances to finish
wait

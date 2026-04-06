#!/bin/bash
# Respawn watchdog: monitors PX4 instances for landed+disarmed state,
# kills the old process, removes the Gazebo model, and relaunches PX4
# with a fresh battery.
#
# Runs as a background process alongside PX4 instances.
# Requires: PX4_BUILD_DIR, FIRMWARE_DIR, vehicle, world env vars set by entrypoint.sh

POLL_INTERVAL=${RESPAWN_POLL_S:-30}
COOLDOWN=${RESPAWN_COOLDOWN_S:-60}
STARTUP_GRACE=${RESPAWN_STARTUP_GRACE_S:-120}
NUM_DRONES=${NUM_DRONES:-3}
WORLD_NAME="${GZ_WORLD_NAME:-default}"

# Track last respawn/launch time per instance
declare -A last_respawn
WATCHDOG_START=$(date +%s)

# Track which drones have been seen airborne (alt > 5m) at least once
declare -A seen_airborne

echo "[respawn_watchdog] Started — polling every ${POLL_INTERVAL}s, startup grace ${STARTUP_GRACE}s"

while true; do
    sleep "$POLL_INTERVAL"

    for n in $(seq 0 $(($NUM_DRONES - 1))); do
        log_file="${PX4_BUILD_DIR}/rootfs/${n}/log/latest/log.ulg"
        instance_dir="${PX4_BUILD_DIR}/instance_${n}"

        # Find the PX4 process for this instance
        pid=$(pgrep -f "px4.*-i ${n}$" | head -1)
        if [ -z "$pid" ]; then
            continue  # PX4 not running (delayed spawn or not started)
        fi

        # Check if "Disarmed by landing" appeared in recent stderr output.
        # PX4 SITL logs to stderr; check the instance's rootfs for the commander log.
        # Simpler: check if the process's /proc/fd/2 has the disarm message recently.
        # Most reliable: check via the PX4 parameters or telemetry.
        #
        # Pragmatic approach: check if PX4's internal commander state shows disarmed
        # by looking at the last few lines of the instance's stderr capture.
        #
        # Since PX4 runs as a background daemon, its stderr goes to the container's
        # combined output. We can't easily separate per-instance. Instead, use the
        # Gazebo model's position — if it's near the home position and altitude < 1m,
        # the drone has landed.
        model_name="x500_${n}"
        # gz model -p outputs multi-line: parse the XYZ line for the Z coordinate
        # Format: "    [X Y Z]"
        pose_line=$(gz model -m "$model_name" -p 2>/dev/null | grep '^\s*\[' | head -1)
        if [ -z "$pose_line" ]; then
            continue  # Model not found (not spawned yet)
        fi

        # Extract Z (3rd value inside brackets): "    [0.98 0.04 -0.01]" → -0.01
        alt=$(echo "$pose_line" | tr -d '[]' | awk '{print $3}')
        if [ -z "$alt" ]; then
            continue
        fi

        # Track if this drone has ever been airborne
        is_high=$(echo "$alt" | awk '{print ($1 > 5.0) ? 1 : 0}')
        if [ "$is_high" = "1" ]; then
            seen_airborne[$n]=1
        fi

        # Only consider "landed" if the drone was previously airborne
        # (prevents respawning drones that are still on the ground at startup)
        if [ "${seen_airborne[$n]:-0}" != "1" ]; then
            continue  # Never been airborne — skip
        fi

        # Check if altitude is near ground (< 0.5m = landed)
        is_landed=$(echo "$alt" | awk '{print ($1 < 0.5) ? 1 : 0}')
        if [ "$is_landed" != "1" ]; then
            continue  # Still airborne
        fi

        # Check cooldown
        now=$(date +%s)
        last=${last_respawn[$n]:-0}
        elapsed=$(($now - $last))
        if [ "$elapsed" -lt "$COOLDOWN" ]; then
            continue  # Recently respawned, skip
        fi

        echo "[respawn_watchdog] Instance $n ($model_name) landed (alt=${alt}m) — respawning"

        # 1. Kill the PX4 process (Gazebo model stays — PX4 reconnects on restart)
        kill "$pid" 2>/dev/null
        sleep 2
        kill -9 "$pid" 2>/dev/null
        sleep 1

        # 2. Clean up mission state but keep params and the Gazebo model
        rm -f "${PX4_BUILD_DIR}/rootfs/${n}/dataman" 2>/dev/null

        # 3. Relaunch PX4 — it reconnects to the existing Gazebo model
        working_dir="$PX4_BUILD_DIR/instance_$n"
        [ ! -d "$working_dir" ] && mkdir -p "$working_dir"
        pushd "$working_dir" &>/dev/null
        echo "[respawn_watchdog] Relaunching instance $n"
        HEADLESS=1 PX4_SIM_MODEL=${vehicle} PX4_GZ_WORLD=${world} \
            PX4_GZ_MODEL_POSE="$(($n + 1)),0,0,0,0,0" \
            ${PX4_BUILD_DIR}/bin/px4 -d -i $n &
        popd &>/dev/null

        last_respawn[$n]=$now
        # Reset airborne tracking — don't respawn again until this
        # drone has been seen flying (prevents kill loop for grounded drones)
        unset seen_airborne[$n]
        echo "[respawn_watchdog] Instance $n respawned (airborne tracking reset)"

        # Wait for PX4 to stabilize before checking other instances
        sleep 15
    done
done

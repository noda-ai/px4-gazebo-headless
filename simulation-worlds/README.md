# Simulation Worlds for PX4 Drone Simulations

## Overview

In this directory, we manage **SDF** (Simulation Description Format) files used by **Gazebo** when starting up PX4 drone simulations.  
An **SDF file** defines the environment in which the simulation runs — including elements like ground planes, objects, and importantly for PX4, the initial **geographic home position** (latitude and longitude).

Right now, our focus is on using simple SDF files to set different starting **home locations** for our drones based on mission needs.

---

## What is an SDF File?

In the context of **Gazebo**, an SDF file is an XML-based file format that describes the simulation world, robots, sensors, and environmental elements.  
Specifically for PX4, SDF files can include `<plugin>` tags that tell the PX4 Autopilot where the simulated drone should spawn — including its **latitude**, **longitude**, **altitude**, and **heading**.

The simulator reads these values at startup to correctly initialize GPS positioning and other location-based behaviors.

---

## Current Structure

```PlainText
simulation-worlds/
├── base-template.sdf
├── camp-roberts/
│   └── default.sdf
├── rhode-island/
│   └── default.sdf
└── README.md
```

- `base-template.sdf`  
  - A basic world file. It is identical to the default world that ships with Gazebo, with no modifications.  
  - This can serve as a starting point for new worlds.

- `camp-roberts/default.sdf`  
  - A world file specifying a home location corresponding to **Camp Roberts** (customized lat/long).

- `rhode-island/default.sdf`  
  - A world file specifying a home location corresponding to **Rhode Island** (customized lat/long).

> **Note:** The only current difference between `camp-roberts` and `rhode-island` worlds is the **latitude and longitude** values.

---

## Adding a New Home Location

If you need to add a new starting location:

1. **Copy** `base-template.sdf` into a new folder inside `simulation-worlds/`.
2. **Rename** it to `default.sdf`.
3. **Modify** the appropriate lat/lon values under the `<plugin>` section, typically within the `gazebo_ros_p3d` or PX4 GPS plugins.
4. **Commit** the new folder and file.

Example:

```bash
mkdir simulation-worlds/arizona-test-site
cp simulation-worlds/base-template.sdf simulation-worlds/arizona-test-site/default.sdf
# Edit default.sdf to update latitude/longitude
```

---

## Future Plans

Over time, we plan to **expand** these SDF files beyond just specifying home locations.  
Examples of future enhancements:

- Add **landmarks** or **obstacles** for vision-based testing.
- Simulate **complex environments** like cities, forests, or maritime settings.
- Add **custom ground textures** or **wind environments** for more realistic simulations.

Each world can evolve independently based on mission requirements or testing needs.

---

## Summary

- Use a new `.sdf` file whenever you need a new **home location**.
- Keep modifications **isolated** by world.
- Base new files on `base-template.sdf` unless you have additional features in mind.

Happy flying! ✈️

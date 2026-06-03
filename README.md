# F-4E Phantom Recon Script for DCS World

A mission Lua script that simulates a Cold War RF-style reconnaissance workflow for the Heatblur F-4E Phantom II.

The script does **not** create live battlefield marks. The crew exposes “film” during a photo pass, returns to base, stops taxiing, and only then receives processed intelligence marks on the F10 map after a configurable delay.

## Concept

1. F-4E carries the AN/ASQ-T50 TCTS ACMI pod as the visual recon/recording store.
2. Pilot or WSO uses the F10 menu command: `Phantom Recon > Expose Recon Film`.
3. Script scans a radius around the aircraft, default `3 NM`.
4. Detected vehicles and statics are stored silently.
5. Aircraft lands and stops taxiing.
6. After `5 minutes`, the stored contacts appear as coalition F10 map marks.

This gives the Phantom a believable reconnaissance loop:

> Ingress → photo pass → survive → recover → process film → brief the strike package.

## Important limitation

The Heatblur manual lists the AN/ASQ-T50 TCTS ACMI pod as a store, but it is currently visual-only and has no real in-game function. Because of that, the script cannot depend on a real camera or pod system. It tries to detect the pod through DCS scripting, but this may not always work because visual-only stores may not be exposed consistently.

Default behavior is therefore:

```lua
pod = {
    mode = "warn"
}
```

This means:

- The script tries to detect `ASQ`, `T50`, `TCTS`, or `ACMI` in the aircraft stores.
- If detection fails, recon is still allowed, but the crew gets a warning.
- If you want to force the pod check, set `mode = "strict"`.
- If you do not want pod checking, set `mode = "off"`.

## Files

```text
F4E_Phantom_Recon.lua
README.md
```

## Installation

In DCS Mission Editor:

1. Add your player/client F-4E aircraft.
2. Add the AN/ASQ-T50 TCTS ACMI pod to the loadout if you want the visual recon-store requirement.
3. Create a trigger:

```text
MISSION START → DO SCRIPT FILE → F4E_Phantom_Recon.lua
```

4. Start the mission.
5. Enter the F-4E slot.
6. Use:

```text
F10 → Other → Phantom Recon → Expose Recon Film
```

## Default recon envelope

The aircraft must be airborne and inside this envelope:

| Parameter | Default |
|---|---:|
| Radius | 3 NM |
| Minimum altitude | 500 ft AGL |
| Maximum altitude | 12,000 ft AGL |
| Minimum speed | 300 kt |
| Maximum speed | 620 kt |
| Photo cooldown | 20 sec |
| Film processing delay | 5 min |
| Stopped speed threshold | 2 kt |

These values are intentionally broad enough for DCS gameplay while still forcing a Phantom-ish photo pass.

## What gets detected

By default, the script detects:

- Enemy ground vehicles
- Enemy static objects

By default, it does **not** detect:

- Friendly units
- Neutral objects
- Aircraft
- Ships
- Scenery/map buildings not placed as DCS static objects

Relevant config block:

```lua
detect = {
    vehicles = true,
    statics = true,
    friendlies = false,
    enemies = true,
    neutral = false,
    requireLineOfSight = false,
}
```

To literally mark every coalition’s vehicles/statics, change to:

```lua
friendlies = true,
enemies = true,
neutral = true,
```

## Vehicle mark mode

Default mode is one mark per detected vehicle group:

```lua
unitMarkMode = "group"
```

This avoids turning the F10 map into a porcupine.

Use this for one mark per vehicle:

```lua
unitMarkMode = "object"
```

Static objects are always marked individually.

## Recovery behavior

Default behavior allows processing anywhere the aircraft is landed and stopped:

```lua
recovery = {
    requireZone = false,
}
```

For stricter gameplay, require friendly recovery zones:

```lua
recovery = {
    requireZone = true,
    blueZones = { "RECON_RECOVERY_BLUE" },
    redZones = { "RECON_RECOVERY_RED" },
}
```

Then create circular trigger zones in the Mission Editor:

```text
RECON_RECOVERY_BLUE
RECON_RECOVERY_RED
```

Place them over the airbases, parking areas, or intelligence-processing locations where film development is allowed.

## Processing delay

Default:

```lua
processingDelaySec = 300
```

That is 5 minutes after the aircraft has landed and stopped taxiing.

If the aircraft starts moving again before the timer completes, the timer resets by default:

```lua
mustRemainStopped = true
```

## Map marks

After processing, the script creates coalition F10 marks like:

```text
RECCE PHOTO CONTACT
Class: Vehicle group
Type: T-72B
Count: 4
Observed side: RED
Source: F-4E / AN-ASQ-T50 recce abstraction
Processed: 14:32
Accuracy: approx +/- 100 m
```

The marks include a configurable random offset:

```lua
markAccuracyMeters = 100
```

Set it to `0` for exact marks.

## ASQ-T50 pod options

### Default, recommended

```lua
pod = {
    mode = "warn"
}
```

This is safest for multiplayer servers because the script keeps working even if DCS does not expose the visual pod to Lua.

### Strict pod requirement

```lua
pod = {
    mode = "strict"
}
```

Recon only works if the pod is detected or the unit is manually whitelisted.

### Manual whitelist

Use this if the aircraft definitely has the pod but DCS does not expose it:

```lua
manualUnitWhitelist = {
    ["Pontiac 1-1"] = true,
}
```

The key must match the aircraft unit name in the Mission Editor.

### Disable pod checking

```lua
pod = {
    mode = "off"
}
```

## Suggested mission usage

Good use cases:

- Recon Phantom finds convoy or SAM site.
- Phantom must survive and return.
- F10 map marks appear after processing.
- Strike package launches based on recovered intel.

For PvP, this avoids instant battlefield omniscience. The other team gets time to move before the marks appear.

## Known limitations

- This is not real RF-4 camera simulation.
- The F-4E is used as an RF-style gameplay abstraction.
- The AN/ASQ-T50 pod is visual-only in DCS.
- DCS mission scripting does not easily bind to a real cockpit camera button generically, so the script uses an F10 radio command.
- Only placed DCS units/statics are detected. Terrain scenery is not.
- Heavy missions with many objects may need a lower `maxContactsPerPhotoRun`.

## Quick tuning examples

### More forgiving training mode

```lua
minAglFt = 300
maxAglFt = 18000
minSpeedKts = 250
maxSpeedKts = 700
markAccuracyMeters = 0
```

### Harsher Cold War PvP mode

```lua
minAglFt = 500
maxAglFt = 8000
minSpeedKts = 420
maxSpeedKts = 620
markAccuracyMeters = 250
recovery = {
    requireZone = true,
    processingDelaySec = 600,
}
```

### Literal “mark everything” mode

```lua
detect = {
    vehicles = true,
    statics = true,
    friendlies = true,
    enemies = true,
    neutral = true,
    requireLineOfSight = false,
}
unitMarkMode = "object"
```

## License

Use and modify freely for DCS missions. Add a formal license file if publishing as a public GitHub repository.

# F-4E Phantom Recon Script for DCS World

A mission Lua script that simulates a Cold War RF-style reconnaissance workflow for the Heatblur F-4E Phantom II.

The script does **not** create live battlefield marks. The crew exposes “film” during a photo pass, returns to base, stops taxiing, and only then receives processed intelligence marks on the F10 map after a configurable delay.

## Concept

1. F-4E carries the AN/ASQ-T50 TCTS ACMI pod as the visual recon/recording store.
2. Pilot or WSO exposes film from the F10 menu: a single frame (`Expose Recon Film`) or a continuous `Camera Run ON/OFF`.
3. Each frame records a ground footprint around the aircraft, default `3 NM` radius, regardless of altitude.
4. Detected vehicles and statics are stored silently.
5. Aircraft lands and stops taxiing.
6. After `5 minutes`, the stored contacts appear as coalition F10 map marks.

If the aircraft is shot down, crashes, or the crew ejects, the film is lost with it.

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
F10 → Other → Phantom Recon → Expose Recon Film   (single frame, 20 s cooldown)
F10 → Other → Phantom Recon → Camera Run ON/OFF   (one frame every 2 s while in envelope)
F10 → Other → Phantom Recon → Film Status         (frames left, processing timer)
F10 → Other → Phantom Recon → Last Recon Report   (re-show the latest coalition report)
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
| Maximum bank angle | 30° |
| Film magazine | 60 frames |
| Camera run frame interval | 2 sec |
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

## Film magazine and camera runs

```lua
film = {
    frames = 60,                -- frames per sortie; 0 = unlimited
    cameraRunIntervalSec = 2,   -- one frame every N seconds while camera run is ON
    loseFilmWithAircraft = true -- film is destroyed on crash/death/ejection
},
```

A camera run only exposes frames while the aircraft is inside the envelope (altitude, speed, bank), so you can switch it on before the target and fly through. When the magazine is empty, the run stops automatically. The magazine is reloaded after processing, or on landing if nothing of interest was recorded.

Each physical vehicle is counted only once per sortie, however many frames it appears in.

## Photo quality by altitude

The lower the pass, the more the photo interpreters can tell. Each contact keeps the best quality it was photographed at during the sortie.

| AGL | Quality | Mark shows | Accuracy | Threat ring |
|---|---|---|---:|:---:|
| ≤ 3,000 ft | GOOD | Class and exact type (`Armour: T-72B`), exact count | ±50 m | yes |
| ≤ 7,000 ft | FAIR | Class only (`Armour`, `Air defence`, `Mechanised`, `Artillery`, `Soft-skin`), count range (`3-5`) | ±150 m | yes |
| above | POOR | `Vehicles`, count unknown | ±300 m | no |

Tiers are configurable under `detail.tiers`. Set `detail.enabled = false` to always show full detail with `markAccuracyMeters`.

## Air defence threat rings

Identified SAM and AAA sites get a red circle on the F10 map, sized by DCS unit attribute:

| Attribute | Radius |
|---|---:|
| LR SAM | 45 km |
| MR SAM | 25 km |
| SR SAM | 10 km |
| AAA | 3 km |

Override specific types with `threatRings.byType`, e.g. `["Kub 1S91 str"] = 24000`. Rings are replaced and expire together with their mark.

## Recon report

When film is processed, the whole coalition gets a text report with the air defence threats listed first and MGRS grids:

```text
RECON REPORT - Pontiac 1 - processed 14:32
1. Air defence: Kub 1S91 str x1 @ 38T KM 12345 67890 (GOOD) THREAT
2. Armour: T-72B x4 @ 38T KM 12410 67955 (GOOD)
3. Soft-skin x3-5 @ 38T KM 13020 68110 (FAIR)
```

Grids are taken from the mark position, so they include the same accuracy offset. Anyone in an F-4E can re-show it with `Last Recon Report`.

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

If the crew leaves the aircraft after processing has started, the film is handed to the ground crew and processing finishes without the jet (`handOffOnLeave = true`).

## Map marks

After processing, the script creates coalition F10 marks like:

```text
RECCE PHOTO CONTACT
Contact: Armour: T-72B
Count: 4
Observed side: RED
Photo quality: GOOD
Source: F-4E / AN-ASQ-T50 recce abstraction
Photographed: 14:21
Processed: 14:32
Accuracy: approx +/- 50 m
```

The marks include a configurable random offset:

```lua
markAccuracyMeters = 100
replaceOldMarks = true      -- a newer photo of the same contact replaces its old mark
markLifetimeSec = 0         -- auto-remove marks after N seconds; 0 = never
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

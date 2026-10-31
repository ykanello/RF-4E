--[[
===============================================================================
 F-4E Phantom Reconnaissance Script for DCS World
-------------------------------------------------------------------------------
 Simulates an RF-style Cold War reconnaissance workflow for the Heatblur F-4E:

   1. Crew exposes film from the F10 menu, either a single frame
      ("Expose Recon Film") or a continuous camera run ("Camera Run ON/OFF")
   2. Each frame records ground vehicles/statics within a ground footprint
      around the aircraft, default 3 NM
   3. Recorded contacts are stored silently on the film
   4. Aircraft must land and stop taxiing; film is lost if the aircraft is lost
   5. After a processing delay (default 5 min), F10 map marks are created

 Notes:
 - The Heatblur AN/ASQ-T50 TCTS ACMI pod is visual-only in DCS, so the script
   includes a defensive pod check. Use strict mode only if DCS exposes the pod
   reliably in your mission environment.
 - This script does not provide real image detection. It is a gameplay mechanic.

 Install:
   Mission Editor -> Trigger: MISSION START -> DO SCRIPT FILE
===============================================================================
]]

F4Recon = F4Recon or {}

F4Recon.config = {
    -- General
    scriptName = "F-4E Phantom Recon",
    scanIntervalSec = 5,
    firstMarkId = 74000,

    -- Aircraft type matching. Heatblur type names can vary by variant/update.
    -- Pattern matching below also accepts any type name containing "F-4E".
    validAircraft = {
        ["F-4E"] = true,
        ["F-4E-45MC"] = true,
    },

    -- Recon capture envelope
    reconRadiusNm = 3,              -- ground radius of the camera footprint
    photoCooldownSec = 20,          -- between single "Expose Recon Film" frames
    minAglFt = 500,
    maxAglFt = 12000,
    minSpeedKts = 300,
    maxSpeedKts = 620,
    maxBankDeg = 30,                -- cameras look down; steep banks ruin the frame

    -- Film magazine
    film = {
        frames = 60,                -- frames per sortie; 0 = unlimited
        cameraRunIntervalSec = 2,   -- one frame every N seconds while camera run is ON
        loseFilmWithAircraft = true -- film is destroyed on crash/death/ejection
    },

    -- Contact detection
    detect = {
        vehicles = true,
        statics = true,
        friendlies = false,
        enemies = true,
        neutral = false,

        -- If true, terrain must not block line of sight from aircraft to target.
        -- Default false because this script models a broad photo sweep abstraction.
        requireLineOfSight = false,
        losTargetHeightM = 2,
    },

    -- Vehicle mark behavior:
    --   "group"  = one mark per detected ground group, less clutter
    --   "object" = one mark per detected vehicle, literal but noisy
    unitMarkMode = "group",

    -- Mark realism / clutter control
    markAccuracyMeters = 100,       -- random offset around true contact location
    maxContactsPerPhotoRun = 80,    -- max new contacts per frame (anti-confetti)
    markReadOnly = true,
    replaceOldMarks = true,         -- newer photos of a contact replace its old mark
    markLifetimeSec = 0,            -- remove marks and rings after N seconds; 0 = never

    -- Photo interpretation quality by altitude. A contact keeps the best
    -- (lowest) tier it was photographed at during the sortie. First match wins.
    --   showType    = exact vehicle type(s) instead of a class like "Armour"
    --   showClass   = class like "Armour"/"Air defence"; false = just "Vehicles"
    --   countMode   = "exact", "approx" (range like 3-5) or "none"
    --   accuracyM   = random mark offset for this tier
    --   threatRing  = allow SAM/AAA threat rings from this tier
    detail = {
        enabled = true,
        tiers = {
            { maxAglFt = 3000,  name = "GOOD", showType = true,  showClass = true,  countMode = "exact",  accuracyM = 50,  threatRing = true },
            { maxAglFt = 7000,  name = "FAIR", showType = false, showClass = true,  countMode = "approx", accuracyM = 150, threatRing = true },
            { maxAglFt = 99999, name = "POOR", showType = false, showClass = false, countMode = "none",   accuracyM = 300, threatRing = false },
        },
    },

    -- Air defence threat rings drawn on the F10 map for identified SAM/AAA.
    threatRings = {
        enabled = true,
        -- Radius by DCS unit attribute, checked in this order (meters).
        byAttribute = {
            { attr = "LR SAM", radiusM = 45000 },
            { attr = "MR SAM", radiusM = 25000 },
            { attr = "SR SAM", radiusM = 10000 },
            { attr = "AAA",    radiusM = 3000 },
        },
        -- Optional exact overrides by unit type name, e.g. ["Kub 1S91 str"] = 24000
        byType = {},
        lineColor = { 1, 0, 0, 0.9 },
        fillColor = { 1, 0, 0, 0.10 },
        lineType = 1,
    },

    -- Text recon report shown to the coalition when film is processed.
    report = {
        enabled = true,
        maxLines = 15,
        displaySec = 60,
    },

    -- AN/ASQ-T50 ACMI pod check.
    -- mode values:
    --   "warn"   = try to detect pod; allow recon if not exposed by DCS API
    --   "strict" = require detected/whitelisted pod
    --   "off"    = no pod check
    pod = {
        mode = "warn",
        manualUnitWhitelist = {
            -- Example:
            -- ["Pontiac 1-1"] = true,
        },
        matchTerms = {
            "ASQ", "T50", "T-50", "TCTS", "ACMI",
        },
    },

    -- Recovery / processing
    recovery = {
        processingDelaySec = 300,   -- 5 minutes
        stoppedSpeedKts = 2,
        mustRemainStopped = true,

        -- If the crew leaves the aircraft after processing has started, the film
        -- is handed to the ground crew and processing continues without the jet.
        handOffOnLeave = true,

        -- If true, aircraft must be stopped inside one of the recovery zones below.
        -- Create circular trigger zones in Mission Editor if you enable this.
        requireZone = false,
        blueZones = { "RECON_RECOVERY_BLUE" },
        redZones = { "RECON_RECOVERY_RED" },
    },

    -- Player messages
    messages = {
        showReconEnvelopeFailures = true,
        showPhotoRunCount = false,  -- false prevents live intel leakage
        showProcessingCountdown = true,
    },
}

F4Recon.NM_TO_M = 1852
F4Recon.M_TO_FT = 3.280839895
F4Recon.MPS_TO_KT = 1.943844492

F4Recon.nextMarkId = F4Recon.nextMarkId or F4Recon.config.firstMarkId
F4Recon.groupState = F4Recon.groupState or {}
F4Recon.menuAdded = F4Recon.menuAdded or {}
F4Recon.markRegistry = F4Recon.markRegistry or {}  -- [coalition..key] = { mark=id, ring=id }
F4Recon.lastReport = F4Recon.lastReport or {}      -- [coalitionId] = report text

-- Contact classes, lower priority = listed first in reports.
F4Recon.CLASSES = {
    { name = "Air defence", priority = 1, attrs = { "LR SAM", "MR SAM", "SR SAM", "SAM SR", "SAM TR", "AAA", "Air Defence" } },
    { name = "Armour",      priority = 2, attrs = { "Tanks" } },
    { name = "Mechanised",  priority = 3, attrs = { "IFV", "APC" } },
    { name = "Artillery",   priority = 4, attrs = { "Artillery", "MLRS" } },
    { name = "Soft-skin",   priority = 5, attrs = { "Trucks", "Unarmed vehicles", "Cars" } },
}
F4Recon.DEFAULT_CLASS = { name = "Vehicle", priority = 6 }
F4Recon.STATIC_CLASS = { name = "Static object", priority = 7 }

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

function F4Recon.safeCall(fn, default)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return default
end

function F4Recon.outGroup(groupId, text, seconds)
    trigger.action.outTextForGroup(groupId, text, seconds or 10)
end

function F4Recon.outCoalition(coalitionId, text, seconds)
    trigger.action.outTextForCoalition(coalitionId, text, seconds or 10)
end

function F4Recon.round(n)
    return math.floor(n + 0.5)
end

function F4Recon.get2dDistance(a, b)
    local dx = a.x - b.x
    local dz = a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

function F4Recon.getGroundSpeedKts(unit)
    local v = unit:getVelocity()
    if not v then
        return 0
    end

    local mps = math.sqrt((v.x or 0) * (v.x or 0) + (v.z or 0) * (v.z or 0))
    return mps * F4Recon.MPS_TO_KT
end

function F4Recon.getAglM(unit)
    local p = unit:getPoint()
    local groundM = land.getHeight({ x = p.x, y = p.z })
    return p.y - groundM
end

function F4Recon.getAglFt(unit)
    return F4Recon.getAglM(unit) * F4Recon.M_TO_FT
end

-- Returns absolute bank angle in degrees and whether the aircraft is inverted.
function F4Recon.getBank(unit)
    local pos = F4Recon.safeCall(function() return unit:getPosition() end, nil)
    if not pos or not pos.z or not pos.y then
        return 0, false
    end

    local s = math.max(-1, math.min(1, pos.z.y or 0))
    local bank = math.abs(math.deg(math.asin(s)))
    local inverted = (pos.y.y or 1) < 0
    if inverted then
        bank = 180 - bank
    end
    return bank, inverted
end

function F4Recon.missionClock()
    local t = timer.getAbsTime and timer.getAbsTime() or timer.getTime()
    local h = math.floor(t / 3600) % 24
    local m = math.floor((t % 3600) / 60)
    return string.format("%02d:%02d", h, m)
end

function F4Recon.getCoalitionName(coalitionId)
    if coalitionId == coalition.side.BLUE then
        return "BLUE"
    elseif coalitionId == coalition.side.RED then
        return "RED"
    elseif coalitionId == coalition.side.NEUTRAL then
        return "NEUTRAL"
    end
    return "UNKNOWN"
end

function F4Recon.getState(groupId)
    if not F4Recon.groupState[groupId] then
        F4Recon.groupState[groupId] = {
            contacts = {},
            contactOrder = {},
            contactCount = 0,
            framesUsed = 0,
            lastPhotoTime = -999999,
            processingStartedAt = nil,
            handedOff = false,
            cameraOn = false,
            runFrames = 0,
            warnedPod = false,
            warnedRecoveryZone = false,
            unitName = nil,
            groupName = nil,
            coalitionId = nil,
        }
    end

    return F4Recon.groupState[groupId]
end

-- Clears exposed contacts. With newMagazine, also reloads film frames.
function F4Recon.resetFilm(state, newMagazine)
    state.contacts = {}
    state.contactOrder = {}
    state.contactCount = 0
    state.processingStartedAt = nil
    state.handedOff = false
    state.warnedRecoveryZone = false
    if newMagazine then
        state.framesUsed = 0
        state.cameraOn = false
        state.lastPhotoTime = -999999
    end
end

function F4Recon.framesLeft(state)
    local total = F4Recon.config.film.frames or 0
    if total <= 0 then
        return math.huge
    end
    return math.max(0, total - (state.framesUsed or 0))
end

function F4Recon.getPlayerUnitByGroupId(groupId)
    local sides = { coalition.side.BLUE, coalition.side.RED }

    for _, side in ipairs(sides) do
        local players = coalition.getPlayers(side) or {}
        for _, unit in ipairs(players) do
            if unit and Unit.isExist(unit) then
                local group = unit:getGroup()
                if group and group:getID() == groupId then
                    return unit
                end
            end
        end
    end

    return nil
end

function F4Recon.getUnitForState(groupId, state)
    if state.unitName then
        local unit = Unit.getByName(state.unitName)
        if unit and Unit.isExist(unit) then
            return unit
        end
    end

    return F4Recon.getPlayerUnitByGroupId(groupId)
end

function F4Recon.isValidF4(unit)
    if not unit or not Unit.isExist(unit) then
        return false
    end

    local typeName = unit:getTypeName() or ""
    if F4Recon.config.validAircraft[typeName] then
        return true
    end

    return string.find(typeName, "F%-4E") ~= nil
end

-- ---------------------------------------------------------------------------
-- Pod check
-- ---------------------------------------------------------------------------

function F4Recon.stringContainsPodTerm(value)
    if type(value) ~= "string" then
        return false
    end

    local upper = string.upper(value)
    for _, term in ipairs(F4Recon.config.pod.matchTerms or {}) do
        if string.find(upper, string.upper(term), 1, true) then
            return true
        end
    end

    return false
end

function F4Recon.hasAsqT50Pod(unit)
    local podCfg = F4Recon.config.pod

    if podCfg.mode == "off" then
        return true, "disabled"
    end

    if podCfg.manualUnitWhitelist and podCfg.manualUnitWhitelist[unit:getName()] then
        return true, "manual whitelist"
    end

    local ammo = F4Recon.safeCall(function() return unit:getAmmo() end, nil)
    if ammo then
        for _, item in ipairs(ammo) do
            local fields = {
                item.weapon_name,
                item.name,
            }

            if item.desc then
                fields[#fields + 1] = item.desc.displayName
                fields[#fields + 1] = item.desc.typeName
                fields[#fields + 1] = item.desc.name
                fields[#fields + 1] = item.desc.categoryName
            end

            for _, field in ipairs(fields) do
                if F4Recon.stringContainsPodTerm(field) then
                    return true, "detected"
                end
            end
        end
    end

    if podCfg.mode == "strict" then
        return false, "not detected"
    end

    return true, "not detected; allowed by warn mode"
end

-- ---------------------------------------------------------------------------
-- Contact filtering / storing
-- ---------------------------------------------------------------------------

function F4Recon.shouldDetectCoalition(objectCoalition, reconCoalition)
    local detect = F4Recon.config.detect

    if objectCoalition == reconCoalition then
        return detect.friendlies == true
    end

    if objectCoalition == coalition.side.NEUTRAL then
        return detect.neutral == true
    end

    return detect.enemies == true
end

function F4Recon.isGroundVehicle(unit)
    local desc = F4Recon.safeCall(function() return unit:getDesc() end, nil)
    if not desc then
        return false
    end

    return desc.category == Unit.Category.GROUND_UNIT
end

function F4Recon.hasLineOfSight(fromUnit, targetPoint)
    local detect = F4Recon.config.detect
    if not detect.requireLineOfSight then
        return true
    end

    local aircraftPoint = fromUnit:getPoint()
    local groundM = land.getHeight({ x = targetPoint.x, y = targetPoint.z })
    local target = {
        x = targetPoint.x,
        y = groundM + (detect.losTargetHeightM or 2),
        z = targetPoint.z,
    }

    return land.isVisible(aircraftPoint, target)
end

function F4Recon.unitHasAttr(unit, attr)
    return F4Recon.safeCall(function() return unit:hasAttribute(attr) end, false) == true
end

function F4Recon.classifyUnit(unit)
    for _, class in ipairs(F4Recon.CLASSES) do
        for _, attr in ipairs(class.attrs) do
            if F4Recon.unitHasAttr(unit, attr) then
                return class
            end
        end
    end
    return F4Recon.DEFAULT_CLASS
end

-- Threat radius in meters for SAM/AAA units, or 0.
function F4Recon.threatRadiusOf(unit)
    local cfg = F4Recon.config.threatRings
    if not cfg or not cfg.enabled then
        return 0
    end

    local typeName = unit:getTypeName() or ""
    if cfg.byType and cfg.byType[typeName] then
        return cfg.byType[typeName]
    end

    for _, entry in ipairs(cfg.byAttribute or {}) do
        if F4Recon.unitHasAttr(unit, entry.attr) then
            return entry.radiusM
        end
    end
    return 0
end

-- Tier index (1 = best) for a given AGL.
function F4Recon.tierIndexForAgl(aglFt)
    local tiers = F4Recon.config.detail.tiers
    for i, tier in ipairs(tiers) do
        if aglFt <= tier.maxAglFt then
            return i
        end
    end
    return #tiers
end

function F4Recon.getTier(contact)
    local detail = F4Recon.config.detail
    if not detail or not detail.enabled then
        return { name = "N/A", showType = true, showClass = true, countMode = "exact",
                 accuracyM = F4Recon.config.markAccuracyMeters, threatRing = true }
    end
    return detail.tiers[contact.tier or #detail.tiers]
end

function F4Recon.makeContactFromUnit(unit, photoClock)
    local point = unit:getPoint()
    local group = unit:getGroup()
    local groupName = "Unknown group"

    if group then
        groupName = group:getName() or groupName
    end

    local unitName = unit:getName() or groupName
    local key
    local label

    if F4Recon.config.unitMarkMode == "group" then
        key = "UNIT_GROUP:" .. groupName
        label = "Vehicle group"
    else
        key = "UNIT:" .. unitName
        label = "Vehicle"
    end

    return {
        key = key,
        memberName = unitName,
        category = "UNIT",
        label = label,
        name = unitName,
        groupName = groupName,
        typeName = unit:getTypeName() or "Unknown vehicle",
        coalitionId = unit:getCoalition(),
        point = { x = point.x, y = point.y, z = point.z },
        count = 1,
        photoClock = photoClock,
        class = F4Recon.classifyUnit(unit),
        threatRadiusM = F4Recon.threatRadiusOf(unit),
    }
end

function F4Recon.makeContactFromStatic(staticObj, photoClock)
    local point = staticObj:getPoint()
    local name = staticObj:getName() or "Unnamed static"

    return {
        key = "STATIC:" .. name,
        memberName = name,
        category = "STATIC",
        label = "Static object",
        name = name,
        groupName = name,
        typeName = staticObj:getTypeName() or "Unknown static",
        coalitionId = staticObj:getCoalition(),
        point = { x = point.x, y = point.y, z = point.z },
        count = 1,
        photoClock = photoClock,
        class = F4Recon.STATIC_CLASS,
        threatRadiusM = 0,
    }
end

-- Stores a contact on the film. Each physical object is counted only once,
-- no matter how many frames it appears in. Returns true for a new contact key.
function F4Recon.storeContact(state, contact)
    local existing = state.contacts[contact.key]

    if existing then
        existing.photoClock = contact.photoClock

        -- Keep the best photo quality and the most significant class/threat.
        if contact.tier and (not existing.tier or contact.tier < existing.tier) then
            existing.tier = contact.tier
        end
        if contact.class and contact.class.priority < existing.class.priority then
            existing.class = contact.class
        end
        if (contact.threatRadiusM or 0) > (existing.threatRadiusM or 0) then
            existing.threatRadiusM = contact.threatRadiusM
        end

        if existing.members[contact.memberName] then
            return false
        end

        -- New vehicle of an already-recorded group: average position, add to count.
        local oldCount = existing.count or 1
        local newCount = oldCount + 1

        existing.point.x = ((existing.point.x * oldCount) + contact.point.x) / newCount
        existing.point.y = ((existing.point.y * oldCount) + contact.point.y) / newCount
        existing.point.z = ((existing.point.z * oldCount) + contact.point.z) / newCount
        existing.count = newCount
        existing.members[contact.memberName] = true

        -- Mixed groups: list the type as mixed rather than the first vehicle seen.
        if existing.typeName ~= contact.typeName then
            existing.types = existing.types or { [existing.typeName] = true }
            existing.types[contact.typeName] = true
        end

        return false
    end

    contact.members = { [contact.memberName] = true }
    state.contacts[contact.key] = contact
    state.contactOrder[#state.contactOrder + 1] = contact.key
    state.contactCount = state.contactCount + 1
    return true
end

-- Searches a ground-level cylinder of reconRadiusNm around the aircraft.
-- A plain sphere would shrink the ground footprint as altitude increases.
function F4Recon.scanAroundAircraft(unit, state)
    local cfg = F4Recon.config
    local center = unit:getPoint()
    local radiusM = cfg.reconRadiusNm * F4Recon.NM_TO_M
    local aglM = math.max(0, F4Recon.getAglM(unit)) + 500  -- margin for terrain relief
    local searchRadius = math.sqrt(radiusM * radiusM + aglM * aglM)
    local reconCoalition = unit:getCoalition()
    local photoClock = F4Recon.missionClock()
    local tier = F4Recon.tierIndexForAgl(F4Recon.getAglFt(unit))
    local added = 0

    local function store(contact)
        contact.tier = tier
        return F4Recon.storeContact(state, contact)
    end

    local volume = {
        id = world.VolumeType.SPHERE,
        params = {
            point = center,
            radius = searchRadius,
        },
    }

    local function inFootprint(obj)
        local p = F4Recon.safeCall(function() return obj:getPoint() end, nil)
        return p and F4Recon.get2dDistance(center, p) <= radiusM, p
    end

    if cfg.detect.vehicles then
        world.searchObjects(Object.Category.UNIT, volume, function(obj)
            if added >= cfg.maxContactsPerPhotoRun then
                return false
            end

            if obj and Unit.isExist(obj) and F4Recon.isGroundVehicle(obj) then
                local inside, p = inFootprint(obj)
                if inside
                    and F4Recon.shouldDetectCoalition(obj:getCoalition(), reconCoalition)
                    and F4Recon.hasLineOfSight(unit, p) then
                    if store(F4Recon.makeContactFromUnit(obj, photoClock)) then
                        added = added + 1
                    end
                end
            end

            return true
        end)
    end

    if cfg.detect.statics then
        world.searchObjects(Object.Category.STATIC, volume, function(obj)
            if added >= cfg.maxContactsPerPhotoRun then
                return false
            end

            local exists = obj and F4Recon.safeCall(function() return obj:isExist() end, true)
            if exists then
                local inside, p = inFootprint(obj)
                local objectCoalition = F4Recon.safeCall(function() return obj:getCoalition() end, coalition.side.NEUTRAL)
                if inside
                    and F4Recon.shouldDetectCoalition(objectCoalition, reconCoalition)
                    and F4Recon.hasLineOfSight(unit, p) then
                    if store(F4Recon.makeContactFromStatic(obj, photoClock)) then
                        added = added + 1
                    end
                end
            end

            return true
        end)
    end

    return added
end

-- ---------------------------------------------------------------------------
-- Recon action
-- ---------------------------------------------------------------------------

-- Validates aircraft, pod and film. Returns unit, state or nil.
function F4Recon.prepareCamera(groupId)
    local unit = F4Recon.getPlayerUnitByGroupId(groupId)
    if not unit or not Unit.isExist(unit) then
        return nil
    end

    local group = unit:getGroup()
    if not group then
        return nil
    end

    local state = F4Recon.getState(groupId)

    -- A different airframe in this group means a new sortie: fresh magazine.
    if state.unitName and state.unitName ~= unit:getName() then
        F4Recon.resetFilm(state, true)
    end

    state.unitName = unit:getName()
    state.groupName = group:getName()
    state.coalitionId = group:getCoalition()

    if not F4Recon.isValidF4(unit) then
        F4Recon.outGroup(groupId, "Recon unavailable: aircraft is not an F-4E.", 10)
        return nil
    end

    local podOk, podStatus = F4Recon.hasAsqT50Pod(unit)
    if not podOk then
        F4Recon.outGroup(groupId, "Recon unavailable: AN/ASQ-T50 / ACMI pod not detected.", 10)
        return nil
    end

    if podStatus == "not detected; allowed by warn mode" and not state.warnedPod then
        state.warnedPod = true
        F4Recon.outGroup(
            groupId,
            "Recon pod warning: AN/ASQ-T50 was not exposed by DCS scripting. Recon allowed by WARN mode.",
            12
        )
    end

    if state.handedOff then
        F4Recon.outGroup(groupId, "Recon film is with the ground crew for processing.", 8)
        return nil
    end

    if F4Recon.framesLeft(state) <= 0 then
        F4Recon.outGroup(groupId, "Recon camera: film magazine empty. Land to reload.", 10)
        return nil
    end

    return unit, state
end

-- Returns true, or false plus a reason string.
function F4Recon.checkEnvelope(unit)
    local cfg = F4Recon.config

    if not unit:inAir() then
        return false, "aircraft is not airborne."
    end

    local aglFt = F4Recon.getAglFt(unit)
    local speedKts = F4Recon.getGroundSpeedKts(unit)
    local bank, inverted = F4Recon.getBank(unit)

    if inverted or bank > (cfg.maxBankDeg or 180) then
        return false, "bank too steep (" .. F4Recon.round(bank) .. " deg, max " .. cfg.maxBankDeg .. ")."
    end

    if aglFt < cfg.minAglFt or aglFt > cfg.maxAglFt or speedKts < cfg.minSpeedKts or speedKts > cfg.maxSpeedKts then
        return false,
            "outside camera envelope.\n" ..
            "Required: " .. cfg.minAglFt .. "-" .. cfg.maxAglFt .. " ft AGL, " ..
            cfg.minSpeedKts .. "-" .. cfg.maxSpeedKts .. " kt.\n" ..
            "Current: " .. F4Recon.round(aglFt) .. " ft AGL, " .. F4Recon.round(speedKts) .. " kt."
    end

    return true
end

function F4Recon.exposeFrame(unit, state)
    local added = F4Recon.scanAroundAircraft(unit, state)
    state.framesUsed = (state.framesUsed or 0) + 1
    state.processingStartedAt = nil
    return added
end

function F4Recon.takePhoto(groupId)
    local unit, state = F4Recon.prepareCamera(groupId)
    if not unit then
        return
    end

    local cfg = F4Recon.config
    local now = timer.getTime()
    if now - state.lastPhotoTime < cfg.photoCooldownSec then
        local wait = F4Recon.round(cfg.photoCooldownSec - (now - state.lastPhotoTime))
        F4Recon.outGroup(groupId, "Recon camera not ready. Wait " .. wait .. " seconds.", 8)
        return
    end

    local ok, reason = F4Recon.checkEnvelope(unit)
    if not ok then
        if cfg.messages.showReconEnvelopeFailures then
            F4Recon.outGroup(groupId, "Recon photo failed: " .. reason, 12)
        end
        return
    end

    local added = F4Recon.exposeFrame(unit, state)
    state.lastPhotoTime = now

    local msg = "Recon film exposed. Return to base, land, and stop for processing."
    if cfg.messages.showPhotoRunCount then
        msg = msg .. "\nNew contacts recorded: " .. added .. "."
    end
    if cfg.film.frames and cfg.film.frames > 0 then
        msg = msg .. "\nFrames remaining: " .. F4Recon.framesLeft(state) .. "."
    end

    F4Recon.outGroup(groupId, msg, 12)
end

-- Continuous camera run: one frame per interval while inside the envelope.
function F4Recon.cameraRunTick(groupId, now)
    local state = F4Recon.groupState[groupId]
    if not state or not state.cameraOn then
        return nil
    end

    local unit = F4Recon.getUnitForState(groupId, state)
    if not unit or not Unit.isExist(unit) or not unit:inAir() then
        F4Recon.stopCameraRun(groupId, state, "aircraft not airborne")
        return nil
    end

    if F4Recon.framesLeft(state) <= 0 then
        F4Recon.stopCameraRun(groupId, state, "film magazine empty")
        return nil
    end

    if F4Recon.checkEnvelope(unit) then
        F4Recon.exposeFrame(unit, state)
        state.runFrames = state.runFrames + 1
    end

    return now + (F4Recon.config.film.cameraRunIntervalSec or 2)
end

function F4Recon.stopCameraRun(groupId, state, reason)
    if not state.cameraOn then
        return
    end
    state.cameraOn = false
    state.lastPhotoTime = timer.getTime()

    local msg = "Camera run OFF"
    if reason then
        msg = msg .. " (" .. reason .. ")"
    end
    msg = msg .. ". Frames exposed this run: " .. state.runFrames .. "."
    if state.runFrames == 0 then
        msg = msg .. "\nNo frames taken: stay inside the camera envelope."
    end
    F4Recon.outGroup(groupId, msg, 10)
end

function F4Recon.toggleCameraRun(groupId)
    local existing = F4Recon.groupState[groupId]
    if existing and existing.cameraOn then
        F4Recon.stopCameraRun(groupId, existing, nil)
        return
    end

    local unit, state = F4Recon.prepareCamera(groupId)
    if not unit then
        return
    end

    if not unit:inAir() then
        F4Recon.outGroup(groupId, "Camera run unavailable: aircraft is not airborne.", 8)
        return
    end

    state.cameraOn = true
    state.runFrames = 0
    timer.scheduleFunction(F4Recon.cameraRunTick, groupId, timer.getTime() + 0.1)

    local msg = "Camera run ON. Frames are taken automatically while inside the envelope."
    if F4Recon.config.film.frames and F4Recon.config.film.frames > 0 then
        msg = msg .. "\nFrames remaining: " .. F4Recon.framesLeft(state) .. "."
    end
    F4Recon.outGroup(groupId, msg, 10)
end

function F4Recon.showFilmStatus(groupId)
    local state = F4Recon.getState(groupId)
    local lines = { "PHANTOM RECON - FILM STATUS" }

    local total = F4Recon.config.film.frames or 0
    if total > 0 then
        lines[#lines + 1] = "Frames: " .. F4Recon.framesLeft(state) .. " of " .. total .. " remaining"
    else
        lines[#lines + 1] = "Frames: unlimited"
    end

    lines[#lines + 1] = "Camera run: " .. (state.cameraOn and "ON" or "OFF")

    if state.contactCount > 0 then
        lines[#lines + 1] = "Film: exposed, awaiting processing"
    elseif (state.framesUsed or 0) > 0 then
        lines[#lines + 1] = "Film: exposed, nothing of interest recorded so far"
    else
        lines[#lines + 1] = "Film: unexposed"
    end
    -- Exact contact counts are deliberately hidden unless showPhotoRunCount is on.
    if F4Recon.config.messages.showPhotoRunCount and state.contactCount > 0 then
        lines[#lines] = lines[#lines] .. " (" .. state.contactCount .. " contacts)"
    end

    if state.processingStartedAt then
        local left = F4Recon.config.recovery.processingDelaySec - (timer.getTime() - state.processingStartedAt)
        lines[#lines + 1] = "Processing: " .. math.max(0, math.ceil(left / 60)) .. " min remaining" ..
            (state.handedOff and " (ground crew)" or "")
    end

    F4Recon.outGroup(groupId, table.concat(lines, "\n"), 12)
end

-- ---------------------------------------------------------------------------
-- Recovery / processing
-- ---------------------------------------------------------------------------

function F4Recon.isInsideNamedZone(unit, zoneName)
    local zone = trigger.misc.getZone(zoneName)
    if not zone then
        return false
    end

    local p = unit:getPoint()
    return F4Recon.get2dDistance(p, zone.point) <= zone.radius
end

function F4Recon.isInsideRecoveryZone(unit)
    local recovery = F4Recon.config.recovery
    if not recovery.requireZone then
        return true
    end

    local zones = {}
    if unit:getCoalition() == coalition.side.BLUE then
        zones = recovery.blueZones or {}
    elseif unit:getCoalition() == coalition.side.RED then
        zones = recovery.redZones or {}
    end

    for _, zoneName in ipairs(zones) do
        if F4Recon.isInsideNamedZone(unit, zoneName) then
            return true
        end
    end

    return false
end

function F4Recon.randomOffsetPoint(point, meters)
    local p = { x = point.x, y = point.y, z = point.z }

    if meters and meters > 0 then
        local angle = math.random() * 2 * math.pi
        local distance = math.random() * meters
        p.x = p.x + math.cos(angle) * distance
        p.z = p.z + math.sin(angle) * distance
    end

    local groundM = land.getHeight({ x = p.x, y = p.z })
    p.y = groundM + 10
    return p
end

function F4Recon.describeType(contact)
    if not contact.types then
        return contact.typeName
    end

    local names = {}
    for name in pairs(contact.types) do
        names[#names + 1] = name
    end
    table.sort(names)
    return "Mixed (" .. table.concat(names, ", ") .. ")"
end

function F4Recon.describeCount(contact, tier)
    local n = contact.count or 1
    if tier.countMode == "exact" then
        return tostring(n)
    elseif tier.countMode == "approx" then
        if n <= 2 then return "1-2"
        elseif n <= 5 then return "3-5"
        elseif n <= 10 then return "6-10"
        end
        return "10+"
    end
    return "unknown"
end

-- What the photo interpreters can say about a contact at its photo quality.
function F4Recon.describeContact(contact)
    local tier = F4Recon.getTier(contact)
    local what

    if contact.category == "STATIC" then
        what = tier.showType and contact.typeName or "Structure / static object"
    elseif tier.showType then
        what = F4Recon.describeType(contact)
        if contact.class and contact.class ~= F4Recon.DEFAULT_CLASS then
            what = contact.class.name .. ": " .. what
        end
    elseif tier.showClass and contact.class then
        what = contact.class.name
    else
        what = "Vehicles"
    end

    return {
        what = what,
        count = F4Recon.describeCount(contact, tier),
        quality = tier.name,
        accuracyM = tier.accuracyM or F4Recon.config.markAccuracyMeters or 0,
        showRing = tier.threatRing and (contact.threatRadiusM or 0) > 0,
    }
end

function F4Recon.toMgrs(point)
    return F4Recon.safeCall(function()
        local lat, lon = coord.LOtoLL(point)
        local m = coord.LLtoMGRS(lat, lon)
        return string.format("%s %s %05d %05d", m.UTMZone, m.MGRSDigraph,
            math.floor(m.Easting), math.floor(m.Northing))
    end, "n/a")
end

function F4Recon.removeRegistered(registryKey)
    local entry = F4Recon.markRegistry[registryKey]
    if not entry then
        return
    end
    for _, id in pairs(entry) do
        F4Recon.safeCall(function() trigger.action.removeMark(id) end, nil)
    end
    F4Recon.markRegistry[registryKey] = nil
end

-- Creates the F10 mark (and threat ring) for a contact. Returns the
-- description and mark point, which the recon report reuses.
function F4Recon.createMapMark(coalitionId, contact, sourceGroupName)
    local cfg = F4Recon.config
    local registryKey = tostring(coalitionId) .. "|" .. contact.key

    if cfg.replaceOldMarks then
        F4Recon.removeRegistered(registryKey)
    end

    local d = F4Recon.describeContact(contact)
    local point = F4Recon.randomOffsetPoint(contact.point, d.accuracyM)

    F4Recon.nextMarkId = F4Recon.nextMarkId + 1
    local markId = F4Recon.nextMarkId
    local entry = { mark = markId }

    local text =
        "RECCE PHOTO CONTACT\n" ..
        "Contact: " .. d.what .. "\n" ..
        "Count: " .. d.count .. "\n" ..
        "Observed side: " .. F4Recon.getCoalitionName(contact.coalitionId) .. "\n" ..
        "Photo quality: " .. d.quality .. "\n" ..
        "Source: F-4E / AN-ASQ-T50 recce abstraction\n" ..
        "Photographed: " .. (contact.photoClock or "unknown") .. "\n" ..
        "Processed: " .. F4Recon.missionClock() .. "\n" ..
        "Accuracy: approx +/- " .. tostring(d.accuracyM) .. " m"

    if d.showRing then
        text = text .. "\nThreat radius: approx " ..
            string.format("%.0f", contact.threatRadiusM / F4Recon.NM_TO_M) .. " NM"
    end

    trigger.action.markToCoalition(
        markId,
        text,
        point,
        coalitionId,
        cfg.markReadOnly,
        "Recon intel added from " .. (sourceGroupName or "F-4E")
    )

    if d.showRing and cfg.threatRings.enabled and trigger.action.circleToAll then
        F4Recon.nextMarkId = F4Recon.nextMarkId + 1
        entry.ring = F4Recon.nextMarkId
        local rc = cfg.threatRings
        F4Recon.safeCall(function()
            trigger.action.circleToAll(coalitionId, entry.ring, point, contact.threatRadiusM,
                rc.lineColor, rc.fillColor, rc.lineType, cfg.markReadOnly, "")
        end, nil)
    end

    F4Recon.markRegistry[registryKey] = entry

    if cfg.markLifetimeSec and cfg.markLifetimeSec > 0 then
        timer.scheduleFunction(function()
            if F4Recon.markRegistry[registryKey] == entry then
                F4Recon.removeRegistered(registryKey)
            end
            return nil
        end, nil, timer.getTime() + cfg.markLifetimeSec)
    end

    d.point = point
    return d
end

function F4Recon.buildReport(state, entries)
    local cfg = F4Recon.config.report
    table.sort(entries, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.order < b.order
    end)

    local lines = {
        "RECON REPORT - " .. tostring(state.groupName or "F-4E") ..
        " - processed " .. F4Recon.missionClock(),
    }

    if #entries == 0 then
        lines[#lines + 1] = "Nothing of interest recorded."
    end

    for i, e in ipairs(entries) do
        if i > (cfg.maxLines or 15) then
            lines[#lines + 1] = "... +" .. (#entries - i + 1) .. " more on F10 map"
            break
        end
        local line = i .. ". " .. e.d.what .. " x" .. e.d.count ..
            " @ " .. F4Recon.toMgrs(e.d.point) .. " (" .. e.d.quality .. ")"
        if e.d.showRing then
            line = line .. " THREAT"
        end
        lines[#lines + 1] = line
    end

    return table.concat(lines, "\n")
end

function F4Recon.processFilm(groupId, state)
    local coalitionId = state.coalitionId or coalition.side.BLUE
    local entries = {}

    for i, key in ipairs(state.contactOrder) do
        local contact = state.contacts[key]
        if contact then
            local d = F4Recon.createMapMark(coalitionId, contact, state.groupName)
            entries[#entries + 1] = {
                d = d,
                order = i,
                priority = contact.class and contact.class.priority or 99,
            }
        end
    end

    local reportCfg = F4Recon.config.report
    if reportCfg and reportCfg.enabled then
        local report = F4Recon.buildReport(state, entries)
        F4Recon.lastReport[coalitionId] = report
        F4Recon.outCoalition(coalitionId, report, reportCfg.displaySec or 60)
    else
        F4Recon.outCoalition(
            coalitionId,
            "Recon film processed. " .. #entries .. " contact mark(s) added to F10 map.",
            15
        )
    end

    env.info("F4Recon: processed " .. #entries .. " contacts for group " .. tostring(state.groupName or groupId))
    F4Recon.resetFilm(state, true)
end

function F4Recon.showLastReport(groupId)
    local state = F4Recon.getState(groupId)
    local unit = F4Recon.getPlayerUnitByGroupId(groupId)
    local coalitionId = (unit and unit:getCoalition()) or state.coalitionId
    local report = coalitionId and F4Recon.lastReport[coalitionId]
    F4Recon.outGroup(groupId, report or "No recon report available yet.", 45)
end

-- Landed with exposed frames but nothing recorded: just reload the magazine.
function F4Recon.reloadIfEmptyFilm(state, stopped)
    if stopped and state.contactCount == 0 and (state.framesUsed or 0) > 0 then
        state.framesUsed = 0
    end
end

function F4Recon.monitorRecovery(_, now)
    now = now or timer.getTime()
    local recovery = F4Recon.config.recovery

    for groupId, state in pairs(F4Recon.groupState) do
        if state.handedOff then
            -- Ground crew has the film; no aircraft needed.
            if state.processingStartedAt and now - state.processingStartedAt >= recovery.processingDelaySec then
                F4Recon.processFilm(groupId, state)
            end
        else
            local unit = F4Recon.getUnitForState(groupId, state)

            if unit and Unit.isExist(unit) then
                local group = unit:getGroup()
                if group then
                    state.coalitionId = group:getCoalition()
                end

                local speedKts = F4Recon.getGroundSpeedKts(unit)
                local stopped = (not unit:inAir()) and speedKts <= recovery.stoppedSpeedKts

                if state.contactCount > 0 then
                    local inRecoveryZone = F4Recon.isInsideRecoveryZone(unit)

                    if stopped and inRecoveryZone then
                        if not state.processingStartedAt then
                            state.processingStartedAt = now

                            if F4Recon.config.messages.showProcessingCountdown then
                                F4Recon.outGroup(
                                    groupId,
                                    "Recon aircraft stopped. Film processing started. Intel available in " ..
                                    tostring(math.ceil(recovery.processingDelaySec / 60)) .. " minutes.",
                                    12
                                )
                            end
                        elseif now - state.processingStartedAt >= recovery.processingDelaySec then
                            F4Recon.processFilm(groupId, state)
                        end
                    else
                        if recovery.requireZone and stopped and not inRecoveryZone and not state.warnedRecoveryZone then
                            state.warnedRecoveryZone = true
                            F4Recon.outGroup(groupId, "Recon film cannot be processed here: not inside a recovery zone.", 10)
                        end

                        if state.processingStartedAt and recovery.mustRemainStopped then
                            state.processingStartedAt = nil
                            F4Recon.outGroup(groupId, "Recon film processing interrupted. Stop taxiing to restart processing timer.", 10)
                        end
                    end
                else
                    F4Recon.reloadIfEmptyFilm(state, stopped)
                end
            else
                -- Unit briefly missing (slot transitions). Loss of the aircraft is
                -- handled by the event handler, so keep the film here.
                if recovery.mustRemainStopped then
                    state.processingStartedAt = nil
                end
            end
        end
    end

    return now + F4Recon.config.scanIntervalSec
end

-- ---------------------------------------------------------------------------
-- Events: film is lost with the aircraft, handed off when crew leaves
-- ---------------------------------------------------------------------------

F4Recon.eventHandler = F4Recon.eventHandler or {}

F4Recon.LOSS_EVENTS = {}
F4Recon.LEAVE_EVENTS = {}

function F4Recon.findStateByUnitName(unitName)
    if not unitName then
        return nil, nil
    end
    for groupId, state in pairs(F4Recon.groupState) do
        if state.unitName == unitName then
            return groupId, state
        end
    end
    return nil, nil
end

function F4Recon.eventHandler:onEvent(event)
    if not event or not event.initiator then
        return
    end

    local isLoss = F4Recon.LOSS_EVENTS[event.id]
    local isLeave = F4Recon.LEAVE_EVENTS[event.id]
    if not isLoss and not isLeave then
        return
    end

    local unitName = F4Recon.safeCall(function() return event.initiator:getName() end, nil)
    local groupId, state = F4Recon.findStateByUnitName(unitName)
    if not state then
        return
    end

    state.cameraOn = false

    if isLeave and F4Recon.config.recovery.handOffOnLeave
        and state.processingStartedAt and state.contactCount > 0 then
        state.handedOff = true
        state.unitName = nil
        F4Recon.outGroup(groupId, "Recon film handed to ground crew. Processing continues.", 10)
        return
    end

    if F4Recon.config.film.loseFilmWithAircraft and (isLoss or isLeave) and not state.handedOff then
        local hadFilm = state.contactCount > 0
        F4Recon.resetFilm(state, true)
        state.unitName = nil
        if hadFilm and isLoss then
            env.info("F4Recon: film lost with aircraft " .. tostring(unitName))
        end
    end
end

function F4Recon.registerEvents()
    local ev = world.event or {}
    for _, name in ipairs({ "S_EVENT_CRASH", "S_EVENT_DEAD", "S_EVENT_EJECTION",
                            "S_EVENT_PILOT_DEAD", "S_EVENT_UNIT_LOST" }) do
        if ev[name] then
            F4Recon.LOSS_EVENTS[ev[name]] = true
        end
    end
    if ev.S_EVENT_PLAYER_LEAVE_UNIT then
        F4Recon.LEAVE_EVENTS[ev.S_EVENT_PLAYER_LEAVE_UNIT] = true
    end

    if not F4Recon.eventsRegistered then
        world.addEventHandler(F4Recon.eventHandler)
        F4Recon.eventsRegistered = true
    end
end

-- ---------------------------------------------------------------------------
-- F10 menu registration
-- ---------------------------------------------------------------------------

function F4Recon.registerMenus(_, now)
    local sides = { coalition.side.BLUE, coalition.side.RED }

    for _, side in ipairs(sides) do
        local players = coalition.getPlayers(side) or {}

        for _, unit in ipairs(players) do
            if unit and Unit.isExist(unit) and F4Recon.isValidF4(unit) then
                local group = unit:getGroup()
                if group then
                    local groupId = group:getID()

                    if not F4Recon.menuAdded[groupId] then
                        local root = missionCommands.addSubMenuForGroup(groupId, "Phantom Recon")
                        missionCommands.addCommandForGroup(groupId, "Expose Recon Film", root, F4Recon.takePhoto, groupId)
                        missionCommands.addCommandForGroup(groupId, "Camera Run ON/OFF", root, F4Recon.toggleCameraRun, groupId)
                        missionCommands.addCommandForGroup(groupId, "Film Status", root, F4Recon.showFilmStatus, groupId)
                        missionCommands.addCommandForGroup(groupId, "Last Recon Report", root, F4Recon.showLastReport, groupId)

                        F4Recon.menuAdded[groupId] = true
                        F4Recon.outGroup(
                            groupId,
                            "Phantom Recon ready. F10 > Other > Phantom Recon.",
                            10
                        )

                        env.info("F4Recon: menu added for group " .. tostring(group:getName()))
                    end
                end
            end
        end
    end

    return (now or timer.getTime()) + F4Recon.config.scanIntervalSec
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

F4Recon.registerEvents()
timer.scheduleFunction(F4Recon.registerMenus, nil, timer.getTime() + 2)
timer.scheduleFunction(F4Recon.monitorRecovery, nil, timer.getTime() + 3)

env.info("F4Recon: script loaded.")

--[[
===============================================================================
 F-4E Phantom Reconnaissance Script for DCS World
-------------------------------------------------------------------------------
 Simulates an RF-style Cold War reconnaissance workflow for the Heatblur F-4E:

   1. F-4E crew uses F10 menu: "Expose Recon Film"
   2. Script scans a configurable radius around the aircraft, default 3 NM
   3. Detected vehicles/statics are stored silently as pending film
   4. Aircraft must land and stop taxiing
   5. After a 5 minute processing delay, F10 map marks are created

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
    reconRadiusNm = 3,
    photoCooldownSec = 20,
    minAglFt = 500,
    maxAglFt = 12000,
    minSpeedKts = 300,
    maxSpeedKts = 620,

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
    maxContactsPerPhotoRun = 80,    -- safety valve against map-mark confetti
    markReadOnly = true,

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

F4Recon.nextMarkId = F4Recon.config.firstMarkId
F4Recon.groupState = {}
F4Recon.menuAdded = {}

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

function F4Recon.getAglFt(unit)
    local p = unit:getPoint()
    local groundM = land.getHeight({ x = p.x, y = p.z })
    return (p.y - groundM) * F4Recon.M_TO_FT
end

function F4Recon.missionClock()
    local t = timer.getTime()
    if timer.getAbsTime then
        t = timer.getAbsTime()
    end

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
            lastPhotoTime = -999999,
            processingStartedAt = nil,
            warnedPod = false,
            warnedRecoveryZone = false,
            unitName = nil,
            groupName = nil,
            coalitionId = nil,
        }
    end

    return F4Recon.groupState[groupId]
end

function F4Recon.resetFilm(state)
    state.contacts = {}
    state.contactOrder = {}
    state.contactCount = 0
    state.processingStartedAt = nil
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

function F4Recon.makeContactFromUnit(unit)
    local point = unit:getPoint()
    local group = unit:getGroup()
    local groupName = "Unknown group"

    if group then
        groupName = group:getName() or groupName
    end

    local key
    local label

    if F4Recon.config.unitMarkMode == "group" then
        key = "UNIT_GROUP:" .. groupName
        label = "Vehicle group"
    else
        key = "UNIT:" .. (unit:getName() or groupName)
        label = "Vehicle"
    end

    return {
        key = key,
        category = "UNIT",
        label = label,
        name = unit:getName() or groupName,
        groupName = groupName,
        typeName = unit:getTypeName() or "Unknown vehicle",
        coalitionId = unit:getCoalition(),
        point = { x = point.x, y = point.y, z = point.z },
        count = 1,
    }
end

function F4Recon.makeContactFromStatic(staticObj)
    local point = staticObj:getPoint()
    local name = staticObj:getName() or "Unnamed static"

    return {
        key = "STATIC:" .. name,
        category = "STATIC",
        label = "Static object",
        name = name,
        groupName = name,
        typeName = staticObj:getTypeName() or "Unknown static",
        coalitionId = staticObj:getCoalition(),
        point = { x = point.x, y = point.y, z = point.z },
        count = 1,
    }
end

function F4Recon.storeContact(state, contact)
    local existing = state.contacts[contact.key]

    if existing then
        -- Average positions when aggregating a group.
        local oldCount = existing.count or 1
        local newCount = oldCount + 1

        existing.point.x = ((existing.point.x * oldCount) + contact.point.x) / newCount
        existing.point.y = ((existing.point.y * oldCount) + contact.point.y) / newCount
        existing.point.z = ((existing.point.z * oldCount) + contact.point.z) / newCount
        existing.count = newCount

        return false
    end

    state.contacts[contact.key] = contact
    state.contactOrder[#state.contactOrder + 1] = contact.key
    state.contactCount = state.contactCount + 1
    return true
end

function F4Recon.scanAroundAircraft(unit, state)
    local cfg = F4Recon.config
    local center = unit:getPoint()
    local radiusM = cfg.reconRadiusNm * F4Recon.NM_TO_M
    local reconCoalition = unit:getCoalition()
    local added = 0

    local volume = {
        id = world.VolumeType.SPHERE,
        params = {
            point = center,
            radius = radiusM,
        },
    }

    if cfg.detect.vehicles then
        world.searchObjects(Object.Category.UNIT, volume, function(obj)
            if added >= cfg.maxContactsPerPhotoRun then
                return false
            end

            if obj and Unit.isExist(obj) and F4Recon.isGroundVehicle(obj) then
                local objectCoalition = obj:getCoalition()
                if F4Recon.shouldDetectCoalition(objectCoalition, reconCoalition) and F4Recon.hasLineOfSight(unit, obj:getPoint()) then
                    local contact = F4Recon.makeContactFromUnit(obj)
                    if F4Recon.storeContact(state, contact) then
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

            local exists = F4Recon.safeCall(function() return obj:isExist() end, true)
            if obj and exists then
                local objectCoalition = F4Recon.safeCall(function() return obj:getCoalition() end, coalition.side.NEUTRAL)
                if F4Recon.shouldDetectCoalition(objectCoalition, reconCoalition) and F4Recon.hasLineOfSight(unit, obj:getPoint()) then
                    local contact = F4Recon.makeContactFromStatic(obj)
                    if F4Recon.storeContact(state, contact) then
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

function F4Recon.takePhoto(groupId)
    local unit = F4Recon.getPlayerUnitByGroupId(groupId)
    if not unit or not Unit.isExist(unit) then
        return
    end

    local group = unit:getGroup()
    if not group then
        return
    end

    local state = F4Recon.getState(groupId)
    state.unitName = unit:getName()
    state.groupName = group:getName()
    state.coalitionId = group:getCoalition()

    if not F4Recon.isValidF4(unit) then
        F4Recon.outGroup(groupId, "Recon unavailable: aircraft is not an F-4E.", 10)
        return
    end

    local podOk, podStatus = F4Recon.hasAsqT50Pod(unit)
    if not podOk then
        F4Recon.outGroup(groupId, "Recon unavailable: AN/ASQ-T50 / ACMI pod not detected.", 10)
        return
    end

    if podStatus == "not detected; allowed by warn mode" and not state.warnedPod then
        state.warnedPod = true
        F4Recon.outGroup(
            groupId,
            "Recon pod warning: AN/ASQ-T50 was not exposed by DCS scripting. Recon allowed by WARN mode.",
            12
        )
    end

    if not unit:inAir() then
        F4Recon.outGroup(groupId, "Recon photo failed: aircraft is not airborne.", 10)
        return
    end

    local now = timer.getTime()
    if now - state.lastPhotoTime < F4Recon.config.photoCooldownSec then
        local wait = F4Recon.round(F4Recon.config.photoCooldownSec - (now - state.lastPhotoTime))
        F4Recon.outGroup(groupId, "Recon camera not ready. Wait " .. wait .. " seconds.", 8)
        return
    end

    local aglFt = F4Recon.getAglFt(unit)
    local speedKts = F4Recon.getGroundSpeedKts(unit)
    local cfg = F4Recon.config

    if aglFt < cfg.minAglFt or aglFt > cfg.maxAglFt or speedKts < cfg.minSpeedKts or speedKts > cfg.maxSpeedKts then
        if cfg.messages.showReconEnvelopeFailures then
            F4Recon.outGroup(
                groupId,
                "Recon photo failed: outside camera envelope.\n" ..
                "Required: " .. cfg.minAglFt .. "-" .. cfg.maxAglFt .. " ft AGL, " ..
                cfg.minSpeedKts .. "-" .. cfg.maxSpeedKts .. " kt.\n" ..
                "Current: " .. F4Recon.round(aglFt) .. " ft AGL, " .. F4Recon.round(speedKts) .. " kt.",
                12
            )
        end
        return
    end

    local added = F4Recon.scanAroundAircraft(unit, state)
    state.lastPhotoTime = now
    state.processingStartedAt = nil

    local msg = "Recon film exposed. Return to base, land, and stop for processing."
    if cfg.messages.showPhotoRunCount then
        msg = msg .. "\nNew contacts recorded: " .. added .. "."
    end

    F4Recon.outGroup(groupId, msg, 12)
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

function F4Recon.isInsideRecoveryZone(unit, state)
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

function F4Recon.createMapMark(coalitionId, contact, sourceGroupName)
    F4Recon.nextMarkId = F4Recon.nextMarkId + 1

    local point = F4Recon.randomOffsetPoint(contact.point, F4Recon.config.markAccuracyMeters)
    local accuracy = F4Recon.config.markAccuracyMeters or 0

    local text =
        "RECCE PHOTO CONTACT\n" ..
        "Class: " .. contact.label .. "\n" ..
        "Type: " .. contact.typeName .. "\n" ..
        "Count: " .. tostring(contact.count or 1) .. "\n" ..
        "Observed side: " .. F4Recon.getCoalitionName(contact.coalitionId) .. "\n" ..
        "Source: F-4E / AN-ASQ-T50 recce abstraction\n" ..
        "Processed: " .. F4Recon.missionClock() .. "\n" ..
        "Accuracy: approx +/- " .. tostring(accuracy) .. " m"

    trigger.action.markToCoalition(
        F4Recon.nextMarkId,
        text,
        point,
        coalitionId,
        F4Recon.config.markReadOnly,
        "Recon intel added from " .. (sourceGroupName or "F-4E")
    )
end

function F4Recon.processFilm(groupId, state)
    local coalitionId = state.coalitionId or coalition.side.BLUE
    local marked = 0

    for _, key in ipairs(state.contactOrder) do
        local contact = state.contacts[key]
        if contact then
            F4Recon.createMapMark(coalitionId, contact, state.groupName)
            marked = marked + 1
        end
    end

    F4Recon.outCoalition(
        coalitionId,
        "Recon film processed. " .. marked .. " contact mark(s) added to F10 map.",
        15
    )

    env.info("F4Recon: processed " .. marked .. " contacts for group " .. tostring(state.groupName or groupId))
    F4Recon.resetFilm(state)
end

function F4Recon.monitorRecovery()
    local now = timer.getTime()
    local recovery = F4Recon.config.recovery

    for groupId, state in pairs(F4Recon.groupState) do
        if state.contactCount and state.contactCount > 0 then
            local unit = F4Recon.getUnitForState(groupId, state)

            if unit and Unit.isExist(unit) then
                local group = unit:getGroup()
                if group then
                    state.coalitionId = group:getCoalition()
                end

                local speedKts = F4Recon.getGroundSpeedKts(unit)
                local stopped = (not unit:inAir()) and speedKts <= recovery.stoppedSpeedKts
                local inRecoveryZone = F4Recon.isInsideRecoveryZone(unit, state)

                if stopped and inRecoveryZone then
                    if not state.processingStartedAt then
                        state.processingStartedAt = now

                        if F4Recon.config.messages.showProcessingCountdown then
                            F4Recon.outGroup(
                                groupId,
                                "Recon aircraft stopped. Film processing started. Intel available in " ..
                                tostring(math.floor(recovery.processingDelaySec / 60)) .. " minutes.",
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
                -- Aircraft no longer exists. Keep the film in state rather than deleting it,
                -- because server/client slot transitions can briefly hide units from scripting.
                state.processingStartedAt = nil
            end
        end
    end

    return now + F4Recon.config.scanIntervalSec
end

-- ---------------------------------------------------------------------------
-- F10 menu registration
-- ---------------------------------------------------------------------------

function F4Recon.registerMenus()
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
                        missionCommands.addCommandForGroup(
                            groupId,
                            "Expose Recon Film",
                            root,
                            F4Recon.takePhoto,
                            groupId
                        )

                        F4Recon.menuAdded[groupId] = true
                        F4Recon.outGroup(
                            groupId,
                            "Phantom Recon ready. F10 > Other > Phantom Recon > Expose Recon Film.",
                            10
                        )

                        env.info("F4Recon: menu added for group " .. tostring(group:getName()))
                    end
                end
            end
        end
    end

    return timer.getTime() + F4Recon.config.scanIntervalSec
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

timer.scheduleFunction(F4Recon.registerMenus, nil, timer.getTime() + 2)
timer.scheduleFunction(F4Recon.monitorRecovery, nil, timer.getTime() + 3)

env.info("F4Recon: script loaded.")

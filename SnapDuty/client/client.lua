-- SnapDuty/client/client.lua
-- Blip rendering + position heartbeat

if not Config then Config = {} end

local dutyBlips = {} -- [serverId] = { blip = blipId, dept = deptKey, callsign = callsign }
local myOnDuty = false
local CAN_SEE_DUTY_BLIPS = false

local function roleStyleFor(dept)
    local cfg = (Config.Departments or {})[dept] or {}
    return {
        sprite = cfg.blipIcon or 1,
        color  = cfg.blipColor or 1,
        label  = cfg.label or (dept or "Duty"),
        scale  = (cfg.blipScale and tonumber(cfg.blipScale)) or 0.85,
        short  = cfg.shortRange ~= nil and cfg.shortRange or true
    }
end

local function clearAllDutyBlips()
    for sid, entry in pairs(dutyBlips) do
        if entry and entry.blip and DoesBlipExist(entry.blip) then
            RemoveBlip(entry.blip)
        end
        dutyBlips[sid] = nil
    end
end

local function refreshBlipPermission()
    local ok, res = pcall(function()
        return lib.callback.await('snapduty:server:canSeeDutyBlips', false)
    end)

    CAN_SEE_DUTY_BLIPS = ok and res == true

    if not CAN_SEE_DUTY_BLIPS then
        clearAllDutyBlips()
    end
end

CreateThread(function()
    Wait(1500)
    refreshBlipPermission()
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    refreshBlipPermission()
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function()
    refreshBlipPermission()
end)

local function ensureCoordBlip(id, dept, coords, callsign)
    local entry = dutyBlips[id]
    local exists = entry and entry.blip and DoesBlipExist(entry.blip)

    if not exists then
        local style = roleStyleFor(dept)
        local blip = AddBlipForCoord(
            (coords and coords.x) or 0.0,
            (coords and coords.y) or 0.0,
            (coords and coords.z) or 0.0
        )

        SetBlipSprite(blip, style.sprite)
        SetBlipColour(blip, style.color)
        SetBlipScale(blip, style.scale)
        SetBlipAsShortRange(blip, style.short)

        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString(("[%s] %s"):format(style.label, callsign or tostring(id)))
        EndTextCommandSetBlipName(blip)

        dutyBlips[id] = { blip = blip, dept = dept, callsign = callsign }
        return blip
    else
        if entry.dept ~= dept or entry.callsign ~= callsign then
            local style = roleStyleFor(dept)
            SetBlipSprite(entry.blip, style.sprite)
            SetBlipColour(entry.blip, style.color)
            SetBlipScale(entry.blip, style.scale)
            SetBlipAsShortRange(entry.blip, style.short)

            BeginTextCommandSetBlipName("STRING")
            AddTextComponentString(("[%s] %s"):format(style.label, callsign or tostring(id)))
            EndTextCommandSetBlipName(entry.blip)

            entry.dept = dept
            entry.callsign = callsign
        end
        return entry.blip
    end
end

-- =====================
-- Server events
-- =====================

RegisterNetEvent("snapduty:addBlip", function(sourceId, department, callsign)
    if not CAN_SEE_DUTY_BLIPS then
        -- if a civ somehow receives events, nuke leftovers
        clearAllDutyBlips()
        return
    end

    local sid = tonumber(sourceId)
    if not sid then return end

    -- ask server for an initial position snapshot
    TriggerServerEvent("snapduty:requestPosition", sid)

    -- create placeholder blip at 0,0,0 until we receive coords
    ensureCoordBlip(sid, department, { x = 0.0, y = 0.0, z = 0.0 }, callsign)
end)

RegisterNetEvent("snapduty:updateBlipPosition", function(sourceId, coords, department)
    if not CAN_SEE_DUTY_BLIPS then
        clearAllDutyBlips()
        return
    end

    local sid = tonumber(sourceId)
    if not sid or not coords or coords.x == nil then return end

    local entry = dutyBlips[sid]
    local blip = ensureCoordBlip(sid, department, coords, entry and entry.callsign)
    if blip then
        SetBlipCoords(blip, coords.x, coords.y, coords.z)
    end
end)

RegisterNetEvent("snapduty:removeBlip", function(sourceId)
    if not CAN_SEE_DUTY_BLIPS then
        clearAllDutyBlips()
        return
    end

    local sid = tonumber(sourceId)
    if not sid then return end

    local entry = dutyBlips[sid]
    if entry and entry.blip and DoesBlipExist(entry.blip) then
        RemoveBlip(entry.blip)
    end
    dutyBlips[sid] = nil
end)

RegisterNetEvent("snapduty:clearAllBlips", function()
    clearAllDutyBlips()
end)

RegisterNetEvent("snapduty:client:setDuty", function(state)
    myOnDuty = state == true
end)

-- =========================================================
-- Duty command (client-side)
-- =========================================================

RegisterCommand((Config and Config.DutyCommand) or 'duty', function()
    TriggerServerEvent('snapduty:toggleDuty')
end, false)

-- =====================
-- Position heartbeat
-- =====================

CreateThread(function()
    while true do
        if myOnDuty then
            local ped = PlayerPedId()
            local coords = GetEntityCoords(ped)
            TriggerServerEvent("snapduty:updateMyPosition", { x = coords.x, y = coords.y, z = coords.z })
            Wait(1200)
        else
            Wait(2000)
        end
    end
end)

-- If blip ever disappears locally, ask server to resend position
CreateThread(function()
    while true do
        if CAN_SEE_DUTY_BLIPS then
            for id, entry in pairs(dutyBlips) do
                if not entry.blip or not DoesBlipExist(entry.blip) then
                    TriggerServerEvent("snapduty:requestForceCreate", id)
                end
            end
        else
            -- just in case anything slips through
            if next(dutyBlips) ~= nil then
                clearAllDutyBlips()
            end
        end
        Wait(5000)
    end
end)

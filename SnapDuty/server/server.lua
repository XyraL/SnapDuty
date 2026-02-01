local QBCore = exports['qb-core']:GetCoreObject()

local dutyTracker = {} -- [src] = { startTime, department, callsign, citizenid, name, afkPaused, afkStart }
local playerCoords = {} -- [src] = vector3
local lastBroadcast = 0

local USING_OX = (GetResourceState('oxmysql') == 'started')
local DB = {}
-- Which departments are allowed to see duty blips at all
-- Which departments are allowed to see duty blips
local BLIP_VIEW_DEPTS = {
    sast = true,
    fib  = true,
    ems  = true,
}

local function getCitizenIdFromSrc(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if Player and Player.PlayerData then
        return Player.PlayerData.citizenid
    end
    return nil
end

local function canSeeDutyBlips(src)
    local cid = getCitizenIdFromSrc(src)
    if not cid then return false end
    if not (SnapDuty and SnapDuty.Roster and SnapDuty.Roster.GetAllowedDepts) then return false end

    local depts = SnapDuty.Roster.GetAllowedDepts(cid) or {}
    for _, d in ipairs(depts) do
        if BLIP_VIEW_DEPTS[tostring(d)] then
            return true
        end
    end
    return false
end

local function sendAddBlipFiltered(unitSrc, dept, callsign)
    for _, sid in ipairs(GetPlayers()) do
        local viewer = tonumber(sid)
        if viewer and viewer > 0 and canSeeDutyBlips(viewer) then
            TriggerClientEvent("snapduty:addBlip", viewer, unitSrc, dept, callsign)
        end
    end
end

local function sendRemoveBlipFiltered(unitSrc)
    for _, sid in ipairs(GetPlayers()) do
        local viewer = tonumber(sid)
        if viewer and viewer > 0 and canSeeDutyBlips(viewer) then
            TriggerClientEvent("snapduty:removeBlip", viewer, unitSrc)
        end
    end
end

local function syncVisibleBlipsToPlayer(src)
    if not canSeeDutyBlips(src) then return end
    for unitSrc, info in pairs(dutyTracker or {}) do
        if info and info.department then
            TriggerClientEvent("snapduty:addBlip", src, unitSrc, info.department, info.callsign)
        end
    end
end

if USING_OX then
    DB.exec = function(sql, params) return exports.oxmysql:execute_async(sql, params or {}) end
    DB.query = function(sql, params) return exports.oxmysql:query_async(sql, params or {}) end
else
    DB.exec = function(sql, params)
        local p = promise.new()
        MySQL.Async.execute(sql, params or {}, function(_) p:resolve(true) end)
        return Citizen.Await(p)
    end
    DB.query = function(sql, params)
        local p = promise.new()
        MySQL.Async.fetchAll(sql, params or {}, function(rows) p:resolve(rows or {}) end)
        return Citizen.Await(p)
    end
end

local function notify(src, msg, typ)
    TriggerClientEvent('ox_lib:notify', src, {
        title = 'SnapDuty',
        description = msg,
        type = typ or 'inform',
        duration = 5500
    })
end

local function getPlayer(src)
    return QBCore.Functions.GetPlayer(src)
end

local function getCitizenId(src)
    local Player = getPlayer(src)
    return Player and Player.PlayerData and Player.PlayerData.citizenid or nil
end

local function getFullName(src)
    local Player = getPlayer(src)
    if Player and Player.PlayerData and Player.PlayerData.charinfo then
        local c = Player.PlayerData.charinfo
        return (c.firstname or "") .. " " .. (c.lastname or "")
    end
    return GetPlayerName(src) or ("Player " .. tostring(src))
end

local function isOnDuty(src)
    return dutyTracker[src] ~= nil
end

-- ==========================================================
-- Discord logging (clock in/out)
-- ==========================================================

local function sendDutyWebhook(dept, state, info)
    local cfg = (Config and Config.Departments and Config.Departments[dept]) or nil
    if not cfg then return end

    local webhook = cfg.webhook
    if not webhook or webhook == '' or webhook:find('YOUR_') then
        return
    end

    local title = state and 'Clocked In' or 'Clocked Out'
    local label = cfg.label or dept
    local callsign = (info and info.callsign) or ''
    local name = (info and info.name) or ''
    local cid = (info and info.citizenid) or ''
    local duration = (info and info.duration) or nil

    local desc = ("**%s** [%s]\n%s\nCID: %s"):format(label, callsign ~= '' and callsign or 'N/A', name ~= '' and name or 'Unknown', cid ~= '' and cid or 'Unknown')
    if duration and tonumber(duration) then
        local mins = math.floor((tonumber(duration) or 0) / 60)
        desc = desc .. ("\nSession: %dm"):format(mins)
    end

    local payload = {
        username = 'SnapDuty',
        embeds = {
            {
                title = title,
                description = desc,
                color = state and 5763719 or 15548997, -- green / red-ish
                thumbnail = cfg.thumbnail and { url = cfg.thumbnail } or nil,
                footer = { text = 'SnapDuty' },
                timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ')
            }
        }
    }

    PerformHttpRequest(webhook, function() end, 'POST', json.encode(payload), { ['Content-Type'] = 'application/json' })
end

local function deptFromJob(src, allowedDepts)
    local Player = getPlayer(src)
    if not Player or not Player.PlayerData or not Player.PlayerData.job then return nil end
    local jobName = tostring(Player.PlayerData.job.name or "")
    if jobName == "" then return nil end

    -- If their job name matches a dept key directly
    for _, d in ipairs(allowedDepts) do
        if jobName == d then return d end
    end

    -- Or matches any jobNames mapping
    local deps = (Config and Config.Departments) or {}
    for _, d in ipairs(allowedDepts) do
        local cfg = deps[d]
        if cfg and cfg.jobNames then
            for _, j in ipairs(cfg.jobNames) do
                if tostring(j) == jobName then return d end
            end
        end
    end

    return nil
end

-- ==========================================================
-- Client callbacks
-- ==========================================================

lib.callback.register('snapduty:client:selectDept', function(_, allowed)
    -- registered client-side; this is placeholder so lib knows the name exists
end)

lib.callback.register('snapduty:client:promptCallsign', function(_, current)
end)

lib.callback.register('snapduty:server:canSeeDutyBlips', function(src)
    -- reuse your server-side canSeeDutyBlips() function
    return canSeeDutyBlips(src) == true
end)

-- ==========================================================
-- Duty Toggle 
-- ==========================================================

local function jobMatchesDept(src, dept)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not Player.PlayerData or not Player.PlayerData.job then return false end

    local jobName = Player.PlayerData.job.name
    local cfg = Config and Config.Departments and Config.Departments[dept]
    if not cfg or not cfg.jobNames then
        return true -- if you didn't configure jobNames, don't block
    end

    for _, j in ipairs(cfg.jobNames) do
        if j == jobName then return true end
    end

    return false
end

local function setQBJobDuty(src, state)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    state = state == true

    -- Newer QBCore has SetJobDuty
    if Player.Functions and Player.Functions.SetJobDuty then
        Player.Functions.SetJobDuty(state)
        return
    end

    -- Fallback: some cores only update via SetJob (re-apply same job/grade with duty state)
    local job = Player.PlayerData.job
    if job and Player.Functions and Player.Functions.SetJob then
        -- Some QBCore builds: SetJob(name, grade, duty)
        Player.Functions.SetJob(job.name, job.grade.level or job.grade, state)
        return
    end

    -- Last-resort: set the metadata and trigger update (rarely needed)
    if Player.PlayerData and Player.PlayerData.job then
        Player.PlayerData.job.onduty = state
        TriggerClientEvent('QBCore:Client:OnJobUpdate', src, Player.PlayerData.job)
    end
end

local function toggleDuty(src)
    src = tonumber(src)
    if not src or src <= 0 then return end

    -- Off duty -> On duty
    if not isOnDuty(src) then
        local cid = getCitizenId(src)
        if not cid then return end

        local roster = SnapDuty and SnapDuty.Roster and SnapDuty.Roster.Get(cid) or nil
        if not roster then
            notify(src, "You are not on the SnapDuty roster.", "error")
            return
        end

        local allowedDepts = SnapDuty.Roster.GetAllowedDepts(cid)
        if #allowedDepts == 0 then
            notify(src, "You are not assigned to any department.", "error")
            return
        end

        local dept = roster.primary_dept
        if not dept or not SnapDuty.Roster.HasDept(cid, dept) then
            dept = nil
        end

        if not dept and #allowedDepts == 1 then
            dept = allowedDepts[1]
        end

        if not dept then
            dept = deptFromJob(src, allowedDepts)
        end

        -- If we picked a dept but the roster has no primary yet, remember it
        if dept and (not roster.primary_dept or roster.primary_dept == '') then
            if SnapDuty and SnapDuty.Roster and SnapDuty.Roster.SetPrimaryDept then
                SnapDuty.Roster.SetPrimaryDept(src, cid, tostring(dept))
            end
        end

        -- If still ambiguous, always prompt the player to pick (and remember it)
        if not dept and #allowedDepts > 1 then
            dept = lib.callback.await('snapduty:client:selectDept', src, allowedDepts)
            if dept and SnapDuty and SnapDuty.Roster and SnapDuty.Roster.SetPrimaryDept then
                SnapDuty.Roster.SetPrimaryDept(src, cid, tostring(dept))
            end
        end

        if not dept or not SnapDuty.Roster.HasDept(cid, dept) then
            notify(src, "Could not determine your department. Ask High Command to set a primary department.", "error")
            return
        end

        local callsign = roster.callsign
        if (Config and Config.RequireCallsign) and (not callsign or tostring(callsign) == "") then
            callsign = lib.callback.await('snapduty:client:promptCallsign', src, callsign or "")
            if not callsign or tostring(callsign) == "" then
                notify(src, "Callsign required to go on duty.", "error")
                return
            end
            SnapDuty.Roster.SetCallsign(src, cid, tostring(callsign))
        end

        local name = getFullName(src)

        dutyTracker[src] = {
            startTime = os.time(),
            department = dept,
            callsign = callsign or tostring(src),
            citizenid = cid,
            name = name,
            afkPaused = false,
            afkStart = nil
        }

        if jobMatchesDept(src, dept) then
            setQBJobDuty(src, true)
        end

        -- discord log
        sendDutyWebhook(dept, true, dutyTracker[src])

        notify(src, ("On Duty: %s [%s]"):format((Config.Departments[dept] and Config.Departments[dept].label) or dept, dutyTracker[src].callsign), "success")
        syncVisibleBlipsToPlayer(src)
        sendAddBlipFiltered(src, dept, dutyTracker[src].callsign)

        TriggerClientEvent("snapduty:client:setDuty", src, true)
        return
    end

    -- On duty -> Off duty
    local info = dutyTracker[src]
    if not info then return end

    local endTime = os.time()
    local seconds = endTime - (info.startTime or endTime)

    -- If AFK paused, subtract paused duration
    if info.afkPaused and info.afkStart then
        local paused = endTime - info.afkStart
        seconds = math.max(0, seconds - paused)
    end

    -- discord log
    sendDutyWebhook(info.department, false, {
        department = info.department,
        callsign = info.callsign,
        citizenid = info.citizenid,
        name = info.name,
        duration = seconds
    })

    notify(src, ("Off Duty: %s (%s)"):format(info.department or "dept", info.callsign or ""), "inform")
    dutyTracker[src] = nil
    playerCoords[src] = nil

    if info.department and jobMatchesDept(src, info.department) then
        setQBJobDuty(src, false)
    end

    sendRemoveBlipFiltered(src)

    TriggerClientEvent("snapduty:client:setDuty", src, false)
end

RegisterNetEvent('snapduty:toggleDuty', function()
    toggleDuty(source)
end)

RegisterCommand((Config and Config.DutyCommand) or "duty", function(src)
    toggleDuty(src)
end, false)

-- ==========================================================
-- Blip position updates
-- ==========================================================

RegisterNetEvent("snapduty:updateMyPosition", function(coords)
    local src = source
    if not dutyTracker[src] then return end
    if not coords or not coords.x then return end
    playerCoords[src] = coords
end)

RegisterNetEvent("snapduty:requestPosition", function(targetId)
    local src = source
    local tid = tonumber(targetId)
    if not tid then return end
    if not dutyTracker[tid] then return end
    -- send current coords to requester
    TriggerClientEvent("snapduty:updateBlipPosition", src, tid, playerCoords[tid] or { x = 0.0, y = 0.0, z = 0.0 }, dutyTracker[tid].department)
end)

RegisterNetEvent("snapduty:requestForceCreate", function(targetId)
    local src = source
    local tid = tonumber(targetId)
    if not tid then return end
    if not dutyTracker[tid] then return end
    TriggerClientEvent("snapduty:updateBlipPosition", src, tid, playerCoords[tid] or { x = 0.0, y = 0.0, z = 0.0 }, dutyTracker[tid].department)
end)

CreateThread(function()
    while true do
        for sid, info in pairs(dutyTracker) do
            if playerCoords[sid] then
                TriggerClientEvent("snapduty:updateBlipPosition", -1, sid, playerCoords[sid], info.department)
            end
        end
        Wait(1500)
    end
end)

CreateThread(function()
    local lastPos = {}
    local lastMoveAt = {}
    while true do
        for _, sid in ipairs(GetPlayers()) do
            local src = tonumber(sid)
            if dutyTracker[src] then
                local pos = playerCoords[src]
                if pos and pos.x then
                    local lp = lastPos[src]
                    if not lp or #(vector3(pos.x, pos.y, pos.z) - vector3(lp.x, lp.y, lp.z)) > 1.0 then
                        lastPos[src] = { x = pos.x, y = pos.y, z = pos.z }
                        lastMoveAt[src] = os.time()
                        if dutyTracker[src].afkPaused then
                            dutyTracker[src].afkPaused = false
                            dutyTracker[src].afkStart = nil
                        end
                    else
                        local lm = lastMoveAt[src] or os.time()
                        if (os.time() - lm) > 90 and not dutyTracker[src].afkPaused then
                            dutyTracker[src].afkPaused = true
                            dutyTracker[src].afkStart = os.time()
                        end
                    end
                end
            else
                lastPos[src] = nil
                lastMoveAt[src] = nil
            end
        end
        Wait(5000)
    end
end)

AddEventHandler("playerDropped", function()
    local src = source
    if dutyTracker[src] then
        local info = dutyTracker[src]
        local endTime = os.time()
        local seconds = endTime - (info.startTime or endTime)
        if info.afkPaused and info.afkStart then
            seconds = math.max(0, seconds - (endTime - info.afkStart))
        end

        -- discord log (disconnect counts as clock out)
        sendDutyWebhook(info.department, false, {
            department = info.department,
            callsign = info.callsign,
            citizenid = info.citizenid,
            name = info.name,
            duration = seconds
        })

        -- duty time tracking removed
        dutyTracker[src] = nil
        playerCoords[src] = nil
        TriggerClientEvent("snapduty:removeBlip", -1, src)
        TriggerClientEvent("snapduty:client:setDuty", src, false)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    if dutyTracker and dutyTracker[src] then
        dutyTracker[src] = nil
        playerCoords[src] = nil
        sendRemoveBlipFiltered(src)
    end
end)


print("^2[SnapDuty]^7 server.lua loaded (2.1.1)")

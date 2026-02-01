-- SnapDuty/server/roster.lua
-- Live roster cache + High Command management (ox_lib callbacks)

local QBCore = exports['qb-core']:GetCoreObject()
local USING_OX = (GetResourceState('oxmysql') == 'started')

local DB = {}
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

SnapDuty = SnapDuty or {}
SnapDuty.Roster = {
    cache = {},       -- [citizenid] = rosterRow
    loaded = false,
}

local function jsonDecodeSafe(s, fallback)
    if type(s) ~= 'string' or s == '' then return fallback end
    local ok, val = pcall(json.decode, s)
    if ok and val ~= nil then return val end
    return fallback
end

local function jsonEncodeSafe(v)
    local ok, out = pcall(json.encode, v)
    if ok then return out end
    return "[]"
end

local function getCitizenId(src)
    local Player = QBCore.Functions.GetPlayer(src)
    return Player and Player.PlayerData and Player.PlayerData.citizenid or nil
end

local function getPlayerNameSafe(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if Player and Player.PlayerData and Player.PlayerData.charinfo then
        local c = Player.PlayerData.charinfo
        return (c.firstname or "") .. " " .. (c.lastname or "")
    end
    return GetPlayerName(src) or ("Player " .. tostring(src))
end

local function isStaff(src)
    for _, perm in ipairs((Config and Config.StaffPerms) or { "admin", "god" }) do
        if QBCore.Functions.HasPermission(src, perm) then
            return true
        end
    end
    return false
end

local function audit(dept, actorSrc, targetCid, targetName, action, payload)
    local actorCid = actorSrc and getCitizenId(actorSrc) or nil
    local actorName = actorSrc and getPlayerNameSafe(actorSrc) or nil
    DB.exec([[
        INSERT INTO snapduty_roster_audit (dept, actor_cid, actor_name, target_cid, target_name, action, payload_json)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], { dept, actorCid, actorName, targetCid, targetName, action, jsonEncodeSafe(payload or {}) })
end

function SnapDuty.Roster.LoadAll()
    local rows = DB.query("SELECT * FROM snapduty_roster", {})
    for _, r in ipairs(rows) do
        local depts = jsonDecodeSafe(r.depts_json, {})
        local set = {}
        for _, d in ipairs(depts) do set[tostring(d)] = true end
        r.depts = set
        SnapDuty.Roster.cache[r.citizenid] = r
    end
    SnapDuty.Roster.loaded = true
    print(("^2[SnapDuty]^7 Loaded roster cache (%d entries)."):format(#rows))
end

function SnapDuty.Roster.Get(citizenid)
    if not citizenid then return nil end
    return SnapDuty.Roster.cache[citizenid]
end

function SnapDuty.Roster.HasDept(citizenid, dept)
    local row = SnapDuty.Roster.Get(citizenid)
    if not row or not row.depts then return false end
    return row.depts[tostring(dept)] == true
end

function SnapDuty.Roster.GetAllowedDepts(citizenid)
    local row = SnapDuty.Roster.Get(citizenid)
    if not row or not row.depts then return {} end
    local out = {}
    for d, ok in pairs(row.depts) do
        if ok then table.insert(out, d) end
    end
    table.sort(out)
    return out
end

local function upsertRoster(citizenid, name, callsign, primary_dept, deptsSet, is_hc, hc_dept, notes)
    local deptsArr = {}
    for d, ok in pairs(deptsSet or {}) do
        if ok then table.insert(deptsArr, d) end
    end
    table.sort(deptsArr)

    DB.exec([[
        INSERT INTO snapduty_roster (citizenid, name, callsign, primary_dept, depts_json, is_hc, hc_dept, notes)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            name = VALUES(name),
            callsign = VALUES(callsign),
            primary_dept = VALUES(primary_dept),
            depts_json = VALUES(depts_json),
            is_hc = VALUES(is_hc),
            hc_dept = VALUES(hc_dept),
            notes = VALUES(notes);
    ]], {
        citizenid,
        name,
        callsign,
        primary_dept,
        jsonEncodeSafe(deptsArr),
        tonumber(is_hc) or 0,
        hc_dept,
        notes
    })

    SnapDuty.Roster.cache[citizenid] = {
        citizenid = citizenid,
        name = name,
        callsign = callsign,
        primary_dept = primary_dept,
        depts_json = jsonEncodeSafe(deptsArr),
        depts = deptsSet or {},
        is_hc = tonumber(is_hc) or 0,
        hc_dept = hc_dept,
        notes = notes
    }
end

function SnapDuty.Roster.AddToDept(actorSrc, targetSrcOrCid, dept, callsign)
    local deptKey = tostring(dept)
    if not (Config and Config.Departments and Config.Departments[deptKey]) then
        return false, "Invalid department"
    end

    local targetCid, targetName
    if tonumber(targetSrcOrCid) then
        local tsrc = tonumber(targetSrcOrCid)
        targetCid = getCitizenId(tsrc)
        targetName = getPlayerNameSafe(tsrc)
        if not targetCid then return false, "Target not found" end
    else
        targetCid = tostring(targetSrcOrCid)
        targetName = targetCid
    end

    local row = SnapDuty.Roster.Get(targetCid) or { citizenid = targetCid, name = targetName, depts = {}, is_hc = 0 }
    row.depts = row.depts or {}
    row.depts[deptKey] = true
    row.name = row.name or targetName
    row.callsign = callsign or row.callsign
    row.primary_dept = row.primary_dept or deptKey

    upsertRoster(targetCid, row.name, row.callsign, row.primary_dept, row.depts, row.is_hc or 0, row.hc_dept, row.notes)
    audit(deptKey, actorSrc, targetCid, row.name, "add_member", { dept = deptKey, callsign = row.callsign })
    return true
end

function SnapDuty.Roster.RemoveFromDept(actorSrc, targetCid, dept)
    local deptKey = tostring(dept)
    local row = SnapDuty.Roster.Get(targetCid)
    if not row then return false, "Not in roster" end
    row.depts = row.depts or {}
    row.depts[deptKey] = nil

    if row.primary_dept == deptKey then
        row.primary_dept = nil
        for d, ok in pairs(row.depts) do
            if ok then row.primary_dept = d break end
        end
    end

    upsertRoster(row.citizenid, row.name, row.callsign, row.primary_dept, row.depts, row.is_hc or 0, row.hc_dept, row.notes)
    audit(deptKey, actorSrc, row.citizenid, row.name, "remove_member", { dept = deptKey })
    return true
end

function SnapDuty.Roster.SetCallsign(actorSrc, targetCid, callsign)
    local row = SnapDuty.Roster.Get(targetCid)
    if not row then return false, "Not in roster" end
    row.callsign = callsign
    upsertRoster(row.citizenid, row.name, row.callsign, row.primary_dept, row.depts or {}, row.is_hc or 0, row.hc_dept, row.notes)
    audit(row.primary_dept, actorSrc, row.citizenid, row.name, "set_callsign", { callsign = callsign })
    return true
end

function SnapDuty.Roster.SetPrimaryDept(actorSrc, targetCid, dept)
    local deptKey = tostring(dept)
    if not (Config and Config.Departments and Config.Departments[deptKey]) then
        return false, "Invalid department"
    end
    local row = SnapDuty.Roster.Get(targetCid)
    if not row then return false, "Not in roster" end

    row.depts = row.depts or {}
    if not row.depts[deptKey] then
        return false, "Target is not assigned to that department"
    end

    row.primary_dept = deptKey
    upsertRoster(row.citizenid, row.name, row.callsign, row.primary_dept, row.depts, row.is_hc or 0, row.hc_dept, row.notes)
    audit(deptKey, actorSrc, row.citizenid, row.name, "set_primary_dept", { primary_dept = deptKey })
    return true
end

function SnapDuty.Roster.SetHighCommand(actorSrc, targetSrcOrCid, dept, enabled)
    local deptKey = tostring(dept)
    if not (Config and Config.Departments and Config.Departments[deptKey]) then
        return false, "Invalid department"
    end

    local targetCid, targetName
    if tonumber(targetSrcOrCid) then
        local tsrc = tonumber(targetSrcOrCid)
        targetCid = getCitizenId(tsrc)
        targetName = getPlayerNameSafe(tsrc)
        if not targetCid then return false, "Target not found" end
    else
        targetCid = tostring(targetSrcOrCid)
        targetName = targetCid
    end

    local row = SnapDuty.Roster.Get(targetCid) or { citizenid = targetCid, name = targetName, depts = {} }
    row.depts = row.depts or {}

    if enabled then
        row.is_hc = 1
        row.hc_dept = deptKey
        row.depts[deptKey] = true
        row.primary_dept = row.primary_dept or deptKey
    else
        row.is_hc = 0
        row.hc_dept = nil
    end

    upsertRoster(row.citizenid, row.name, row.callsign, row.primary_dept, row.depts, row.is_hc, row.hc_dept, row.notes)
    audit(deptKey, actorSrc, row.citizenid, row.name, enabled and "grant_hc" or "revoke_hc", { hc_dept = deptKey })
    return true
end

function SnapDuty.Roster.GetHCDept(citizenid)
    local row = SnapDuty.Roster.Get(citizenid)
    if not row then return nil end
    if tonumber(row.is_hc) == 1 and row.hc_dept then return tostring(row.hc_dept) end
    return nil
end

function SnapDuty.Roster.GetDeptRoster(dept)
    local deptKey = tostring(dept)
    local out = {}

    for cid, row in pairs(SnapDuty.Roster.cache) do
        if row.depts and row.depts[deptKey] then
            table.insert(out, {
                citizenid = cid,
                name = row.name,
                callsign = row.callsign,
                primary_dept = row.primary_dept,

                -- existing flag: "HC of THIS dept"
                is_hc = (tonumber(row.is_hc) == 1 and tostring(row.hc_dept or '') == deptKey),

                -- NEW: always include which dept they are HC for (if any)
                hc_dept = row.hc_dept
            })
        end
    end

    table.sort(out, function(a, b)
        return (a.callsign or "") < (b.callsign or "")
    end)

    return out
end


function SnapDuty.Roster.GetAudit(dept, limit)
    limit = tonumber(limit) or 50
    local deptKey = tostring(dept)
    local rows = DB.query("SELECT * FROM snapduty_roster_audit WHERE dept = ? ORDER BY id DESC LIMIT ?", { deptKey, limit })
    return rows
end

CreateThread(function()
    Wait(1000)
    SnapDuty.Roster.LoadAll()
end)

-- ==========================
-- ox_lib callbacks
-- ==========================

lib.callback.register('snapduty:server:isStaff', function(src)
    return isStaff(src)
end)

-- NEW: richer scope for UI mode picking
lib.callback.register('snapduty:server:getMyScope', function(src)
    local cid = getCitizenId(src)
    return {
        isStaff = isStaff(src),
        hcDept = SnapDuty.Roster.GetHCDept(cid)
    }
end)

-- Keep for backwards compat (some older client code might call it)
lib.callback.register('snapduty:server:getMyHCDept', function(src)
    if isStaff(src) then
        return "__ALL__"
    end

    local cid = getCitizenId(src)
    return SnapDuty.Roster.GetHCDept(cid)
end)

lib.callback.register('snapduty:server:getDepartments', function(_)
    local out = {}
    for k, v in pairs((Config and Config.Departments) or {}) do
        table.insert(out, { key = k, label = v.label or k })
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end)

lib.callback.register('snapduty:server:getOnlinePlayers', function(_)
    local out = {}
    for _, sid in ipairs(GetPlayers()) do
        local src = tonumber(sid)
        local Player = QBCore.Functions.GetPlayer(src)
        if Player then
            table.insert(out, {
                id = src,
                citizenid = Player.PlayerData.citizenid,
                name = getPlayerNameSafe(src)
            })
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end)

lib.callback.register('snapduty:server:getDeptRoster', function(src, dept)
    local cid = getCitizenId(src)
    local hcDept = SnapDuty.Roster.GetHCDept(cid)

    if not isStaff(src) and not hcDept then
        return { ok = false, error = "Not High Command" }
    end

    if not isStaff(src) and tostring(dept) ~= hcDept then
        return { ok = false, error = "Not authorized for that department" }
    end

    return { ok = true, roster = SnapDuty.Roster.GetDeptRoster(dept) }
end)

lib.callback.register('snapduty:server:getDeptAudit', function(src, dept)
    local cid = getCitizenId(src)
    local hcDept = SnapDuty.Roster.GetHCDept(cid)

    if not isStaff(src) and not hcDept then
        return { ok = false, error = "Not High Command" }
    end

    if not isStaff(src) and tostring(dept) ~= hcDept then
        return { ok = false, error = "Not authorized for that department" }
    end

    return { ok = true, logs = SnapDuty.Roster.GetAudit(dept, 50) }
end)

-- Accept dept arg for admins; HC defaults to their hcDept
lib.callback.register('snapduty:server:addMember', function(src, targetPlayerId, callsign, dept)
    local actorCid = getCitizenId(src)
    local hcDept = SnapDuty.Roster.GetHCDept(actorCid)

    local targetDept = tostring(dept or hcDept)

    if not isStaff(src) and not hcDept then
        return { ok = false, error = "Not High Command" }
    end

    if not isStaff(src) and targetDept ~= hcDept then
        return { ok = false, error = "Not authorized for that department" }
    end

    local ok, err = SnapDuty.Roster.AddToDept(src, targetPlayerId, targetDept, callsign)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
end)

-- Accept dept arg for admins; HC defaults to their hcDept
lib.callback.register('snapduty:server:removeMember', function(src, targetCitizenId, dept)
    local actorCid = getCitizenId(src)
    local hcDept = SnapDuty.Roster.GetHCDept(actorCid)

    local targetDept = tostring(dept or hcDept)

    if not isStaff(src) and not hcDept then
        return { ok = false, error = "Not High Command" }
    end

    if not isStaff(src) and targetDept ~= hcDept then
        return { ok = false, error = "Not authorized for that department" }
    end

    local ok, err = SnapDuty.Roster.RemoveFromDept(src, tostring(targetCitizenId), targetDept)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
end)

-- Allow staff to edit anyone; HC only edits inside their dept
lib.callback.register('snapduty:server:setMemberCallsign', function(src, targetCitizenId, callsign)
    local actorCid = getCitizenId(src)
    local hcDept = SnapDuty.Roster.GetHCDept(actorCid)

    if not isStaff(src) and not hcDept then
        return { ok = false, error = "Not High Command" }
    end

    local row = SnapDuty.Roster.Get(tostring(targetCitizenId))
    if not row then return { ok = false, error = "Not in roster" } end

    if not isStaff(src) then
        if not (row.depts and row.depts[hcDept]) then
            return { ok = false, error = "Target not in your department roster" }
        end
    end

    local ok, err = SnapDuty.Roster.SetCallsign(src, tostring(targetCitizenId), callsign)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
end)

-- Staff can set any; HC only within their dept scope (and must be assigned)
lib.callback.register('snapduty:server:setMemberPrimaryDept', function(src, targetCitizenId, dept)
    local actorCid = getCitizenId(src)
    local hcDept = SnapDuty.Roster.GetHCDept(actorCid)
    local deptKey = tostring(dept)

    if not isStaff(src) and not hcDept then
        return { ok = false, error = "Not High Command" }
    end

    if not isStaff(src) and deptKey ~= hcDept then
        return { ok = false, error = "Not authorized for that department" }
    end

    local row = SnapDuty.Roster.Get(tostring(targetCitizenId))
    if not row then return { ok = false, error = "Not in roster" } end

    if not isStaff(src) then
        if not (row.depts and row.depts[hcDept]) then
            return { ok = false, error = "Target not in your department roster" }
        end
    end

    local ok, err = SnapDuty.Roster.SetPrimaryDept(src, tostring(targetCitizenId), deptKey)
    if not ok then return { ok = false, error = err } end
    return { ok = true }
end)

local function toBool(v)
    if v == true or v == 1 or v == "1" then return true end
    if type(v) == "string" then
        v = v:lower()
        if v == "true" or v == "yes" or v == "grant" or v == "enable" or v == "enabled" then
            return true
        end
    end
    return false
end

lib.callback.register('snapduty:server:adminSetHC', function(src, targetPlayerId, dept, enabled)
    if not isStaff(src) then return { ok = false, error = "Staff only" } end

    local allow = toBool(enabled)
    local ok, err = SnapDuty.Roster.SetHighCommand(src, targetPlayerId, dept, allow)
    if not ok then return { ok = false, error = err } end

    return { ok = true }
end)

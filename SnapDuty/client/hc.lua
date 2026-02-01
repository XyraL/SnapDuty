-- SnapDuty/client/hc.lua
-- High Command UI (ox_lib) + Admin mode

local function toast(msg, typ)
    lib.notify({
        title = 'SnapDuty',
        description = msg,
        type = typ or 'inform'
    })
end

local function deptLabel(dept)
    if Config and Config.Departments and Config.Departments[dept] and Config.Departments[dept].label then
        return Config.Departments[dept].label
    end
    return tostring(dept)
end

-- NEW: richer access state (Admin + HC safe)
local function getMyScope()
    return lib.callback.await('snapduty:server:getMyScope', false)
end

-- =========================
-- Audit
-- =========================
local function openAudit(dept, returnMenuId)
    local res = lib.callback.await('snapduty:server:getDeptAudit', false, dept)
    if not res or not res.ok then
        toast(res and res.error or "Failed to load audit.", "error")
        return
    end

    local options = {}
    for _, row in ipairs(res.logs or {}) do
        local when = row.created_at or ''
        local title = ("%s: %s"):format(row.action or "action", row.target_name or (row.target_cid or "target"))
        local desc = ("%s | %s"):format(when, row.actor_name or (row.actor_cid or "actor"))
        options[#options + 1] = { title = title, description = desc, icon = 'clipboard-list' }
    end

    if #options == 0 then
        options = {
            { title = 'No logs yet', description = 'Nothing recorded for this department.', icon = 'circle-info' }
        }
    end

    lib.registerContext({
        id = 'snapduty_hc_audit',
        title = ('Audit Log: %s'):format(deptLabel(dept)),
        menu = returnMenuId,
        options = options
    })
    lib.showContext('snapduty_hc_audit')
end

-- =========================
-- Member Actions (inside roster)
-- =========================
local function openMemberActions(dept, member, returnToRosterMenuId, returnMenuIdForRoster)
    local menuId = ('snapduty_member_actions_%s_%s'):format(dept, member.citizenid)

    local options = {
        {
            title = 'Set as Primary Department',
            description = ('Make %s their default when using /duty.'):format(deptLabel(dept)),
            icon = 'location-dot',
            disabled = (member.primary_dept == dept),
            onSelect = function()
                local r = lib.callback.await('snapduty:server:setMemberPrimaryDept', false, member.citizenid, dept)
                if r and r.ok then
                    toast('Primary department updated.', 'success')
                    -- reopen roster
                    lib.showContext(returnMenuIdForRoster)
                else
                    toast((r and r.error) or 'Failed to update.', 'error')
                end
            end
        },
        {
            title = 'Change Callsign',
            description = ('Current: %s'):format(member.callsign or 'N/A'),
            icon = 'id-badge',
            onSelect = function()
                local input = lib.inputDialog('Change Callsign', {
                    { type = 'input', label = 'Callsign', description = 'Example: 704', default = member.callsign or '', required = true, min = 1, max = 12 }
                })
                if not input or not input[1] then return end

                local newCs = tostring(input[1])
                if newCs == (member.callsign or '') then return end

                local r = lib.callback.await('snapduty:server:setMemberCallsign', false, member.citizenid, newCs)
                if r and r.ok then
                    toast('Callsign updated.', 'success')
                    lib.showContext(returnMenuIdForRoster)
                else
                    toast((r and r.error) or 'Failed to update.', 'error')
                end
            end
        },
        {
            title = 'Remove from Department',
            description = ('Remove this member from %s roster.'):format(deptLabel(dept)),
            icon = 'user-minus',
            onSelect = function()
                local sure = lib.alertDialog({
                    header = 'Remove Member?',
                    content = ('Remove %s from %s roster?'):format(member.name or member.citizenid, deptLabel(dept)),
                    centered = true,
                    cancel = true
                })
                if sure ~= 'confirm' then return end

                local r = lib.callback.await('snapduty:server:removeMember', false, member.citizenid, dept)
                if r and r.ok then
                    toast('Member removed.', 'success')
                    lib.showContext(returnMenuIdForRoster)
                else
                    toast((r and r.error) or 'Failed to remove.', 'error')
                end
            end
        }
    }

    lib.registerContext({
        id = menuId,
        title = (member.name or member.citizenid),
        menu = returnToRosterMenuId,
        options = options
    })
    lib.showContext(menuId)
end

-- =========================
-- Roster
-- =========================
local function openRoster(dept, returnMenuId)
    local res = lib.callback.await('snapduty:server:getDeptRoster', false, dept)
    if not res or not res.ok then
        toast(res and res.error or "Failed to load roster.", "error")
        return
    end

    local rosterMenuId = ('snapduty_hc_roster_%s'):format(dept)

    local options = {}
    for _, m in ipairs(res.roster or {}) do
        local hcTag = ""
if m.hc_dept and tostring(m.hc_dept) ~= "" then
    if tostring(m.hc_dept) == tostring(dept) then
        hcTag = " ⭐ HC"
    else
        hcTag = (" ⭐ HC:%s"):format(tostring(m.hc_dept))
    end
end
        local primary = (m.primary_dept == dept) and " 🧭" or ""
        local title = ("%s%s%s"):format(m.callsign or (m.name or m.citizenid), hcTag, primary)
        local desc = ("%s | %s"):format(m.name or "Unknown", m.citizenid or "")

        options[#options + 1] = {
            title = title,
            description = desc,
            icon = 'user',
            onSelect = function()
                openMemberActions(dept, m, rosterMenuId, rosterMenuId)
            end
        }
    end

    if #options == 0 then
        options = { { title = 'Roster is empty', description = 'No members assigned yet.', icon = 'user-xmark' } }
    end

    lib.registerContext({
        id = rosterMenuId,
        title = deptLabel(dept) .. ' Roster',
        menu = returnMenuId,
        options = options
    })
    lib.showContext(rosterMenuId)
end

-- =========================
-- Add Member
-- =========================
local function addMemberFlowForDept(dept, returnToMenuId)
    local players = lib.callback.await('snapduty:server:getOnlinePlayers', false)
    if not players or #players == 0 then
        toast("No online players found.", "error")
        return
    end

    local opts = {}
    for _, p in ipairs(players) do
        opts[#opts + 1] = { label = ("%s (%s)"):format(p.name, p.id), value = p.id }
    end

    local input = lib.inputDialog(('Add Member: %s'):format(deptLabel(dept)), {
        { type = 'select', label = 'Player', options = opts, required = true },
        { type = 'input', label = 'Callsign (optional)', description = 'Example: 704', required = false, min = 0, max = 12 }
    })
    if not input then return end

    local playerId = input[1]
    local callsign = input[2]

    local res = lib.callback.await('snapduty:server:addMember', false, playerId, callsign, dept)
    if res and res.ok then
        toast("Member added.", "success")
        openRoster(dept, returnToMenuId)
    else
        toast((res and res.error) or "Failed to add member.", "error")
    end
end

-- =========================
-- Staff: Grant/Remove High Command
-- =========================
local function adminGrantHCFlow()
    local scope = getMyScope()
    if not scope or not scope.isStaff then
        toast("Staff only.", "error")
        return
    end

    local depts = lib.callback.await('snapduty:server:getDepartments', false) or {}
    local deptOpts = {}
    for _, d in ipairs(depts) do
        deptOpts[#deptOpts + 1] = { label = d.label, value = d.key }
    end

    local players = lib.callback.await('snapduty:server:getOnlinePlayers', false) or {}
    local playerOpts = {}
    for _, p in ipairs(players) do
        playerOpts[#playerOpts + 1] = { label = ("%s (%s)"):format(p.name, p.id), value = p.id }
    end

    local input = lib.inputDialog('Staff: High Command Access', {
        { type = 'select', label = 'Player', options = playerOpts, required = true },
        { type = 'select', label = 'Department', options = deptOpts, required = true },
        { type = 'select', label = 'Action', options = {
    { label = 'Grant High Command', value = 'grant' },
    { label = 'Revoke High Command', value = 'revoke' }
}, required = true }
    })
    if not input then return end

    local playerId = input[1]
    local dept = input[2]
    local enabled = tostring(input[3]) == 'grant'

    local res = lib.callback.await('snapduty:server:adminSetHC', false, playerId, dept, enabled)
    if res and res.ok then
        toast(enabled and "High Command granted." or "High Command revoked.", "success")
    else
        toast((res and res.error) or "Failed.", "error")
    end
end

-- =========================
-- Menus (HC mode / Admin mode / Mode picker)
-- =========================
local function openHCMode(hcDept, isStaff)
    local options = {
        {
            title = 'Department Roster',
            description = 'View and manage your department roster.',
            icon = 'users',
            onSelect = function() openRoster(hcDept, 'snapduty_hc_root') end
        },
        {
            title = 'Add Member',
            description = 'Add an online player to your department.',
            icon = 'user-plus',
            onSelect = function() addMemberFlowForDept(hcDept, 'snapduty_hc_root') end
        },
        {
            title = 'Audit Log',
            description = 'View recent changes made by High Command.',
            icon = 'scroll',
            onSelect = function() openAudit(hcDept, 'snapduty_hc_root') end
        }
    }

    -- IMPORTANT: add staff tools BEFORE registerContext
    if isStaff then
        options[#options + 1] = {
            title = 'Staff: High Command Access',
            description = 'Grant or revoke High Command (staff only).',
            icon = 'shield-halved',
            onSelect = adminGrantHCFlow
        }
    end

    lib.registerContext({
        id = 'snapduty_hc_root',
        title = 'SnapDuty High Command - ' .. deptLabel(hcDept),
        options = options
    })
    lib.showContext('snapduty_hc_root')
end

local function openAdminDeptPicker(isStaff)
    local depts = lib.callback.await('snapduty:server:getDepartments', false) or {}
    if #depts == 0 then
        toast("No departments configured.", "error")
        return
    end

    local options = {}

    -- Staff tool always available in admin view
    if isStaff then
        options[#options + 1] = {
            title = 'Staff: High Command Access',
            description = 'Grant or revoke High Command (staff only).',
            icon = 'shield-halved',
            onSelect = adminGrantHCFlow
        }
    end

    for _, d in ipairs(depts) do
        options[#options + 1] = {
            title = d.label,
            description = 'Manage roster & logs',
            icon = 'building-shield',
            onSelect = function()
                local deptKey = d.key
                local deptMenuId = ('snapduty_admin_dept_%s'):format(deptKey)

                lib.registerContext({
                    id = deptMenuId,
                    title = 'Admin: ' .. deptLabel(deptKey),
                    menu = 'snapduty_admin_root',
                    options = {
                        { title = 'Department Roster', icon = 'users', onSelect = function() openRoster(deptKey, deptMenuId) end },
                        { title = 'Add Member', icon = 'user-plus', onSelect = function() addMemberFlowForDept(deptKey, deptMenuId) end },
                        { title = 'Audit Log', icon = 'scroll', onSelect = function() openAudit(deptKey, deptMenuId) end }
                    }
                })

                lib.showContext(deptMenuId)
            end
        }
    end

    lib.registerContext({
        id = 'snapduty_admin_root',
        title = 'SnapDuty Admin View',
        options = options
    })
    lib.showContext('snapduty_admin_root')
end

local function openModePicker(scope)
    local options = {}

    if scope.hcDept then
        options[#options + 1] = {
            title = 'High Command View',
            description = 'Manage your HC department',
            icon = 'user-shield',
            onSelect = function() openHCMode(scope.hcDept, scope.isStaff) end
        }
    end

    if scope.isStaff then
        options[#options + 1] = {
            title = 'Admin View',
            description = 'Manage any department',
            icon = 'shield-halved',
            onSelect = function() openAdminDeptPicker(true) end
        }
        options[#options + 1] = {
            title = 'Staff: High Command Access',
            description = 'Grant or revoke High Command (staff only).',
            icon = 'shield-halved',
            onSelect = adminGrantHCFlow
        }
    end

    lib.registerContext({
        id = 'snapduty_mode_root',
        title = 'SnapDuty',
        options = options
    })

    lib.showContext('snapduty_mode_root')
end

-- =========================
-- Entry
-- =========================
local function openHC()
    local scope = getMyScope()
    if not scope then
        toast("Failed to load permissions.", "error")
        return
    end

    if not scope.hcDept and not scope.isStaff then
        toast("You are not High Command.", "error")
        return
    end

    -- HC only
    if scope.hcDept and not scope.isStaff then
        openHCMode(scope.hcDept, false)
        return
    end

    -- Staff only
    if scope.isStaff and not scope.hcDept then
        openAdminDeptPicker(true)
        return
    end

    -- Staff + HC
    openModePicker(scope)
end

RegisterCommand((Config and Config.HCCommand) or 'sdhc', function()
    openHC()
end, false)

-- SnapDuty/client/duty_ui.lua
-- ox_lib prompts used by /duty flow (server requests)

lib.callback.register('snapduty:client:selectDept', function(allowedDepts)
    local options = {}
    for _, dept in ipairs(allowedDepts or {}) do
        local cfg = (Config.Departments or {})[dept] or {}
        table.insert(options, {
            title = cfg.label or dept,
            description = dept,
            icon = 'id-badge',
            onSelect = function() end,
            args = dept
        })
    end

    local selected = nil
    lib.registerContext({
        id = 'snapduty_select_dept',
        title = 'Select Department',
        options = options,
        onExit = function() selected = nil end
    })

    lib.showContext('snapduty_select_dept')

    -- ox_lib context can't directly "return" selection, so we use a small selection dialog instead
    -- fallback: inputSelect
    local input = lib.inputDialog('Select Department', {
        { type = 'select', label = 'Department', options = (function()
            local o = {}
            for _, dept in ipairs(allowedDepts or {}) do
                local cfg = (Config.Departments or {})[dept] or {}
                table.insert(o, { label = cfg.label or dept, value = dept })
            end
            return o
        end)(), required = true }
    })

    if input and input[1] then
        selected = input[1]
    end
    return selected
end)

lib.callback.register('snapduty:client:promptCallsign', function(current)
    local input = lib.inputDialog('Enter Callsign', {
        { type = 'input', label = 'Callsign', description = 'Example: 704', default = current or '', required = true, min = 1, max = 12 }
    })
    if input and input[1] then
        return tostring(input[1])
    end
    return nil
end)

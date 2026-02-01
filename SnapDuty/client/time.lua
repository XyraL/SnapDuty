-- Shows ONLY the weekly total in chat

-- Prevent double registration if file loads twice
if _G.__SNAPDUTY_TIME_CLIENT_LOADED then return end
_G.__SNAPDUTY_TIME_CLIENT_LOADED = true

-- /dutytime command
RegisterCommand("dutytime", function()
    TriggerServerEvent("snapduty:server:requestWeekly")
end, false)

local function fmt(sec)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

local __lastWeeklyMsgAt = 0

RegisterNetEvent("snapduty:client:weekly", function(payload)
    local now = GetGameTimer()
    if now - __lastWeeklyMsgAt < 500 then return end
    __lastWeeklyMsgAt = now

    local total = (payload and payload.total) or 0
    TriggerEvent('chat:addMessage', {
        args = { "^2Weekly Total", "^7" .. fmt(total) }
    })
end)

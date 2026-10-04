-- Small helpers shared by Better Lag Compensation
local Util = {}

function Util.Now()
    -- Simulation clock: 1/30 s steps, monotonic on clients. GetTimeRealSeconds()
    -- looks precise but TheSim:GetRealTime() only moves in whole seconds in
    -- current builds, which turned every timing in the logs into 0 or 1000 ms.
    return GetTime()
end

function Util.Log(text)
    print("[BLC] " .. text)
end

function Util.SafeCall(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Util.Log("error in " .. what .. ": " .. tostring(err)) end
    return ok, err
end

function Util.Player()
    return rawget(_G, "ThePlayer")
end

local function NetGet(net, key)
    local ok, v = pcall(function() return net[key] end)
    return ok and v or nil
end

-- Ping to the server in ms (0 when hosting); nil if the game does not tell
function Util.Ping()
    local net = rawget(_G, "TheNet")
    if net == nil then return nil end
    local is_server = NetGet(net, "GetIsServer")
    if type(is_server) == "function" then
        local ok, host = pcall(is_server, net)
        if ok and host then return 0 end
    end
    for _, name in ipairs({ "GetAveragePing", "GetPing" }) do
        local fn = NetGet(net, name)
        if type(fn) == "function" then
            local ok, v = pcall(fn, net)
            if ok and type(v) == "number" and v >= 0 then return v end
        end
    end
    local ok, client = pcall(function() return net:GetClientTableForUser(net:GetUserID()) end)
    if ok and type(client) == "table" and type(client.ping) == "number" then return client.ping end
    return nil
end

-- Lag compensation (movement prediction) is on for this player
function Util.Predicting(player)
    local pc = player ~= nil and player.components.playercontroller or nil
    return pc ~= nil and pc.locomotor ~= nil
end

return Util

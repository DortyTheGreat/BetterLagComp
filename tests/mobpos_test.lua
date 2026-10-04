-- The future view of mob positions against a mocked engine that treats a position set by the
-- client in one of three ways:  lua5.1 tests/mobpos_test.lua
package.path = "./scripts/?.lua;" .. package.path

local lines = {}
local real_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    table.insert(lines, table.concat(parts, " "))
    if os.getenv("VERBOSE") then real_print(parts[1]) end
end
local function Count(pattern)
    local c = 0
    for _, l in ipairs(lines) do if l:find(pattern) then c = c + 1 end end
    return c
end

FRAMES = 1 / 30
local F = FRAMES
local TICK = 0
function GetTime() return TICK * F end
local Pipe = { enabled = true }
package.loaded["blc/pipeline"] = Pipe

local passes, fails = 0, 0
local function check(cond, what)
    if cond then passes = passes + 1; real_print("  ok    " .. what)
    else fails = fails + 1; real_print("  FAIL  " .. what) end
end

local MP = require("blc/mobpos")
MP.notify = function(kind, text) print("[LAB] " .. kind .. " " .. text) end

-- a mob: where the server has it (srv), what the client got last (net, every 2nd frame), and the
-- Transform the engine and we both write
local function Mob(guid, x, mode)
    local e = { GUID = guid, prefab = "killerbee", valid = true, mode = mode, speed = 0 }
    e.srv, e.net, e.pos = { x = x, z = 0 }, { x = x, z = 0 }, { x = x, z = 0 }
    e.Transform = {
        GetWorldPosition = function() return e.pos.x, 0, e.pos.z end,
        SetPosition = function(_, px, _, pz) e.pos.x, e.pos.z = px, pz end,
    }
    function e:IsValid() return self.valid end
    return e
end

local function Engine(e)
    e.angle = (e.angle or 0) + (e.turn or 0) * F
    e.srv.x = e.srv.x + e.speed * math.cos(e.angle) * F
    e.srv.z = e.srv.z + e.speed * math.sin(e.angle) * F
    if TICK % 2 == 0 and (e.net.x ~= e.srv.x or e.net.z ~= e.srv.z) then
        e.net.x, e.net.z = e.srv.x, e.srv.z
        e.update = true
    end
    if e.mode == "held" then
        if e.update then e.pos.x, e.pos.z = e.net.x, e.net.z end
    elseif e.mode == "frame" then
        e.pos.x, e.pos.z = e.net.x, e.net.z
    elseif e.mode == "pull" then -- a share of the way to its target every frame
        -- (uneven frames: one or two drawn frames' worth of it, at random)
        local share = 0.4
        if e.uneven == "wild" then share = math.random() < 0.5 and 0.075 or 0.15
        elseif e.uneven then share = 0.12 + 0.03 * math.random() end
        e.pos.x = e.pos.x + share * (e.net.x - e.pos.x)
        e.pos.z = e.pos.z + share * (e.net.z - e.pos.z)
    elseif e.mode == "pulls" then -- a fixed step a frame towards its target: not a share
        for _, k in ipairs({ "x", "z" }) do
            local d = e.net[k] - e.pos[k]
            e.pos[k] = e.pos[k] + math.max(-0.1, math.min(0.1, d))
        end
    end
    e.update = false
end

local mobs = {}
local CL = { View = function() return { mobs = mobs } end, Lead = function() return 0.2 end }

local function Run(seconds, each)
    for _ = 1, math.floor(seconds / F + 0.5) do
        TICK = TICK + 1
        for e in pairs(mobs) do Engine(e) end
        MP.Update(CL, GetTime())
        if each then each() end
    end
end

for _, mode in ipairs({ "held", "frame", "pull", "pulls" }) do
    real_print("[probe 3, an engine that " .. mode .. "]")
    MP._reset()
    lines = {}
    local still = Mob(1, 3, mode)
    mobs = { [still] = { onme = false } }
    Run(1.2)
    check(MP._state().mode == mode, "the probe tells it: " .. tostring(MP._state().mode))
    if mode == "pull" then
        check(math.abs(MP._state().pull - 0.4) < 0.02 and Count("pulls a mob towards its position from the server by 40%%") == 1,
            "  and measures the share: " .. tostring(MP._state().pull))
    end
    check(math.abs(still.pos.x - 3) < 0.01, "  and the mob is back where it was")
end

real_print("[a bee chasing you at 6/s, the engine keeps what is set]")
do
    MP._reset()
    lines = {}
    local still = Mob(1, 3, "held")
    local bee = Mob(2, -5, "held")
    mobs = { [still] = { onme = false }, [bee] = { onme = true } }
    Run(1.2) -- the probe
    bee.speed = 6
    local back, last = false, nil
    local ahead = {}
    Run(1.0, function()
        if last ~= nil and bee.pos.x + 1e-6 < last then back = true end
        last = bee.pos.x
        table.insert(ahead, bee.pos.x - bee.net.x)
    end)
    local a = ahead[#ahead]
    check(a > 1.1 and a < 1.5, string.format("shown about speed x lead ahead of its last position from the server: %.2f", a))
    check(not back, "  moving smoothly, never back")
    bee.speed = 0
    Run(0.4)
    check(math.abs(bee.pos.x - bee.net.x) < 1e-6, "it stops: shown where it is")
    bee.speed = 6
    Run(0.6)
    Pipe.enabled = false
    Run(F)
    check(math.abs(bee.pos.x - bee.net.x) < 0.25, "F8: back to the server's position at once (the jump you see)")
    Pipe.enabled = true
    Run(0.3)
    check(bee.pos.x - bee.net.x > 1.0, "  and ahead again")
    mobs[bee].onme = false
    Run(F)
    check(math.abs(bee.pos.x - bee.net.x) < 0.25, "it stops targeting you: back to the server's position")
end

real_print("[a bee circling you, turning all the time: the clean engines are not taken for leaking]")
for _, mode in ipairs({ "held", "frame" }) do
    MP._reset()
    lines = {}
    local still = Mob(1, 3, mode)
    local bee = Mob(2, -5, mode)
    mobs = { [still] = { onme = false }, [bee] = { onme = true } }
    Run(1.2)
    bee.speed, bee.turn = 6, 2.5
    Run(4.0)
    check(MP._state().mode == mode and Count("lean towards") == 0, "  " .. mode .. ": still on after 4 s of turning")
end

real_print("[an engine that writes every frame]")
do
    MP._reset()
    local still = Mob(1, 3, "frame")
    local bee = Mob(2, -5, "frame")
    mobs = { [still] = { onme = false }, [bee] = { onme = true } }
    Run(1.2)
    bee.speed = 6
    Run(1.0)
    check(bee.pos.x - bee.net.x > 1.0, "set again every frame after it: ahead")
end

real_print("[an engine that pulls a share of the way every frame (as the game's did)]")
do
    MP._reset()
    lines = {}
    local still = Mob(1, 3, "pull")
    local bee = Mob(2, -5, "pull")
    mobs = { [still] = { onme = false }, [bee] = { onme = true } }
    Run(1.2)
    bee.speed = 6
    local ahead, after = {}, {}
    Run(1.5, function() table.insert(ahead, bee.pos.x - bee.srv.x) end)
    local a = ahead[#ahead]
    check(a > 1.0 and a < 1.6, string.format("shown speed x lead ahead of the server, the engine's smoothing made up: %.2f", a))
    -- what the engine does with ours before the next frame: still ahead (a share of it)
    Engine(bee)
    check(bee.pos.x - bee.srv.x > 0.5, string.format("  after the engine's pull it is still ahead: %.2f", bee.pos.x - bee.srv.x))
    check(MP._state().mode == "pull" and Count("lean towards") == 0, "  no leak: the shift does not build up")
    local grow = false
    for i = 20, #ahead do if ahead[i] > 1.6 then grow = true end end
    check(not grow, "  and stays put (never more than speed x lead)")
    bee.turn = 2.5
    Run(3.0)
    check(MP._state().mode == "pull", "  turning all the time: still on")
    Pipe.enabled = false
    Run(0.5)
    check(math.abs(bee.pos.x - bee.net.x) < 0.2, "F8: the engine slides it back to the server's position")
    Pipe.enabled = true
end

for _, case in ipairs({ { "12..15% a frame (as the probe in the game measured)", true, 0.1 },
    { "7.5 or 15% a frame at random (far worse than measured)", "wild", 0.2 } }) do
    real_print("[an engine that pulls " .. case[1] .. "]")
    math.randomseed(7)
    MP._reset()
    lines = {}
    local still = Mob(1, 3, "pull")
    local bee = Mob(2, -5, "pull")
    still.uneven, bee.uneven = case[2], case[2]
    mobs = { [still] = { onme = false }, [bee] = { onme = true } }
    Run(1.2)
    check(MP._state().mode == "pull", "the probe takes it for a share of the way: " .. string.format("%.3f", MP._state().pull))
    bee.speed = 6
    local offs = {}
    Run(2.0, function() table.insert(offs, bee.pos.x - bee.srv.x) end)
    local jump, sum, n = 0, 0, 0
    for i = 31, #offs do
        jump = math.max(jump, math.abs(offs[i] - offs[i - 1]))
        sum, n = sum + offs[i], n + 1
    end
    real_print(string.format("        shown ahead %.2f on average, the most it changed in a frame %.2f", sum / n, jump))
    check(jump < case[3], string.format("  no blinking: the shift changes less than %.1f a frame", case[3]))
    check(sum / n > 0.8 and sum / n < 1.7, "  and the mob is ahead of the server by about speed x lead (1.2)")
end

real_print("[an engine that pulls back: left alone]")
do
    MP._reset()
    local still = Mob(1, 3, "pulls")
    local bee = Mob(2, -5, "pulls")
    mobs = { [still] = { onme = false }, [bee] = { onme = true } }
    Run(1.2)
    bee.speed = 6
    local touched = false
    local set = bee.Transform.SetPosition
    bee.Transform.SetPosition = function(...) touched = true; return set(...) end
    Run(1.0)
    check(not touched, "never set")
end

real_print("[the probe said 'held' but moving mobs pull back: it notices and stops]")
do
    MP._reset()
    lines = {}
    local still = Mob(1, 3, "held")
    local bee = Mob(2, -5, "held")
    mobs = { [still] = { onme = false }, [bee] = { onme = true } }
    Run(1.2)
    bee.mode = "pull" -- pulls a share of the way, unknown to the shift (it took the probe's "held")
    bee.speed = 6
    Run(2.0)
    check(MP._state().mode == "pulls" and Count("lean towards the shift") == 1, "it turns itself off")
    check(math.abs(bee.pos.x - bee.net.x) < 0.5, "  and leaves the mob to the engine")
end

real_print(string.format("\n%d passed, %d failed", passes, fails))
if fails > 0 then os.exit(1) end

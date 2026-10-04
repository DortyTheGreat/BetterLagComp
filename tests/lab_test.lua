-- Lag Lab against a mocked game: run from the mod folder with  lua5.1 tests/lab_test.lua
package.path = "./scripts/?.lua;" .. package.path

local lines = {}
local real_print = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    table.insert(lines, table.concat(parts, " "))
    if os.getenv("VERBOSE") then real_print(parts[1]) end
end

FRAMES = 1 / 30
local NOW = 0
function GetTime() return NOW end
function GetTimeRealSeconds() return math.floor(NOW) end -- whole seconds, like the real game
function hash(str) -- djb2, like any string hash the game might use
    local h = 5381
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
    return h
end
RPC = { ActionButton = 1, LeftClick = 2, PredictWalking = 3, StopControl = 4, AttackButton = 5,
    SetMovementPredictionEnabled = 6 }
ACTIONS_BY_ACTION_CODE = { [7] = { id = "PICKUP" }, [8] = { id = "CHOP" } }
local PING = 180
TheNet = { GetIsServer = function() return false end, GetPing = function() return PING end }
package.preload["stategraphs/SGwilson"] = function()
    return { states = { idle = {}, doshortaction = {}, hit = {}, run = {}, eat = {} } }
end
package.preload["widgets/text"] = function()
    return function()
        local t = { inst = { IsValid = function() return true end } }
        function t:SetString(v) self.value = v end
        function t:SetColour(...) self.colour = { ... } end
        function t:SetHAnchor() end
        function t:SetVAnchor() end
        function t:SetScaleMode() end
        function t:SetPosition() end
        return t
    end
end

local Lab = require("blc/lab")

---------------------------------------------------------------- a mocked player
local function Listeners()
    local l = { events = {} }
    function l:ListenForEvent(ev, fn) self.events[ev] = fn end
    function l:RemoveEventCallback(ev) self.events[ev] = nil end
    function l:IsValid() return true end
    return l
end

local P
local function NewPlayer(predicting, has_velocity)
    P = Listeners()
    P.x, P.z, P.vx, P.vz = 0, 0, 0, 0
    P.Transform = { GetWorldPosition = function() return P.x, 0, P.z end }
    if has_velocity ~= false then
        P.Physics = { GetVelocity = function() return P.vx, 0, P.vz end }
    else
        P.Physics = {}
    end
    P.components = { playercontroller = { locomotor = predicting and {} or nil } }
    function P:GetCurrentPlatform() return nil end
    function P:DoPeriodicTask(_, fn) P.tick = fn; return { Cancel = function() P.tick = nil end } end
    if predicting then
        local cls = Listeners()
        cls.server = hash("idle")
        cls.currentstate = { value = function() return cls.server end }
        cls.pausepredictionframes = { value = function() return cls.frames or 0 end }
        cls.isperformactionsuccess = { value = function() return cls.success end }
        P.player_classified = cls
        P.sg = { currentstate = { name = "idle" }, sg = { states = { idle = {}, doshortaction = {} } } }
        function P.sg:ServerStateMatches() return self.server_states[cls.server] end
    end
    ThePlayer = P
    return P
end

local function Run(seconds, step)
    local n = math.floor(seconds * 30 + 0.5)
    for _ = 1, n do
        NOW = NOW + FRAMES
        if step then step() end
        P.x, P.z = P.x + P.vx * FRAMES, P.z + P.vz * FRAMES
        P.tick()
    end
end

local function Count(pattern)
    local c = 0
    for _, l in ipairs(lines) do if l:find(pattern) then c = c + 1 end end
    return c
end

local passes, fails = 0, 0
local function check(cond, what)
    if cond then passes = passes + 1; real_print("  ok    " .. what)
    else fails = fails + 1; real_print("  FAIL  " .. what) end
end

local function Fresh(predicting, has_velocity)
    lines = {}
    NewPlayer(predicting, has_velocity)
    Lab.Configure({ detail = "problems" })
    Lab.Start(P)
    return Lab._state()
end

---------------------------------------------------------------- position
real_print("[corrections]")
do
    local s = Fresh(true)
    P.vx = 6
    Run(2)
    check(s.total.corr == 0, "walking straight: nothing")
    Run(0.5, function() end)
    P.x = P.x - 1.0 -- the server pulls us back one unit
    Run(0.5)
    check(s.total.corr == 1, "a one-unit jump back: one correction")
    check(Count("!correct.-moved 1%.0%d by the server %(pulled back%)") == 1, "logged as pulled back, ~1.0 units")
    local spread = 0
    Run(0.3, function()
        spread = spread + 1
        if spread <= 4 then P.z = P.z + 0.15 end -- smoothed over 4 ticks
    end)
    Run(0.5)
    check(s.total.corr == 2, "a correction spread over 4 ticks counts once")
    check(Count("moved 0%.6%d") == 1, "  with its full size (0.6)")
    P.x = P.x + 20 -- wormhole
    Run(0.5)
    check(s.total.corr == 2, "a teleport is not a correction")
    P.vx = 6
    local x0 = P.x
    Run(0.5, function() P.x = x0 - P.vx * FRAMES end) -- pushing into a wall: no movement
    check(s.total.corr == 2, "walking into a wall is not a correction")
    P.vx = 0
    Run(1, function() P.x = P.x + (math.random() - 0.5) * 0.04 end)
    check(s.total.corr == 2, "small jitter is not a correction")
end
do
    local s = Fresh(true, false)
    P.vx = 6
    Run(2)
    check(s.total.corr == 0, "no velocity from physics: steady walking still clean")
    P.x = P.x - 1.2
    Run(0.5)
    check(s.total.corr == 1, "  and a jump back still found")
    for _ = 1, 3 do
        P.vx = 0; Run(0.4)
        P.vx, P.vz = 0, -6; Run(0.4)
        P.vx, P.vz = 6, 0; Run(0.4)
    end
    check(s.total.corr == 1, "  stopping, starting and turning: no false corrections")
end
do
    local s = Fresh(true)
    for _ = 1, 3 do
        P.vx, P.vz = 0, 0; Run(0.4)
        P.vx, P.vz = 0, -6; Run(0.4)
        P.vx, P.vz = 6, 0; Run(0.4)
    end
    check(s.total.corr == 0, "with physics velocity: stopping, starting and turning are clean too")
end

---------------------------------------------------------------- states
real_print("[predicted states the server did not follow]")
do
    local s = Fresh(true)
    local cls = P.player_classified
    P.sg.currentstate = { name = "doshortaction" }
    P.sg.server_states = { [hash("doshortaction")] = true }
    Run(0.2)
    cls.server = hash("doshortaction")
    Run(0.5)
    check(s.total.miss == 0, "the server follows within the ping: fine")
    P.sg.currentstate = { name = "idle" }
    P.sg.server_states = nil
    Run(0.1)
    cls.server = hash("idle")
    P.sg.currentstate = { name = "doshortaction" }
    P.sg.server_states = { [hash("doshortaction")] = true }
    Lab.OnRpc(RPC.ActionButton, 7, { prefab = "twigs", GUID = 42 })
    Run(1.0)
    check(s.total.miss == 1, "the server stays idle: one miss")
    check(Count("!miss.-doshortaction.-it is in idle.-PICKUP twigs#42") == 1, "  logged with the server's state and the action")
    Run(1.0)
    check(s.total.miss == 1, "  counted once per predicted state")
end

real_print("[the server's signals]")
do
    local s = Fresh(true)
    local cls = P.player_classified
    cls.server = hash("hit")
    Run(0.1)
    cls.frames = 6
    P.events.cancelmovementprediction()
    check(s.total.pause == 1 and Count("!pause.-6 frames.-it is in hit") == 1, "a server pause: counted, with its state")
    Lab.OnRpc(RPC.LeftClick, 8, 1, 2, { prefab = "evergreen", GUID = 7 })
    cls.success = true
    cls.events.isperformactionsuccessdirty()
    cls.success = false
    cls.events.isperformactionsuccessdirty()
    check(s.total.ok == 1 and s.total.failed == 1, "action results: one done, one failed")
    check(Count("!failed.-CHOP evergreen#7") == 1, "  the failure names the action")
    check(Count("send.-LeftClick CHOP evergreen#7") >= 1, "  and the context shows the request before it")
    Lab.OnRpc(RPC.PredictWalking, 1, 2)
    check(Count("PredictWalking") == 0, "walking requests are not logged")
    Run(0.2)
    Lab.Stop(P)
    check(Count("summary.-corrections 0.-server pauses 1 %[hit 1%].-actions failed 1 of 2 %[CHOP 1%]") == 1,
        "the summary on leaving counts it all")
    check(P.events.cancelmovementprediction == nil and cls.events.isperformactionsuccessdirty == nil, "  and unhooks")
end

real_print("[clock, lag comp switches, pace]")
do
    NOW = 100.4
    check(require("blc/util").Now() == 100.4, "the clock is the 1/30 s game clock, not the whole-second real time")
end
do
    local s = Fresh(false)
    P.vx = 6
    Run(1)
    P.x = P.x - 1.0
    Run(0.5)
    check(s.total.corr == 0, "lag comp off: the server moving you is by design, not a correction")
end
do
    local s = Fresh(true)
    P.vx = 6
    Run(1)
    Lab.OnRpc(RPC.SetMovementPredictionEnabled, true)
    Run(0.3)
    P.x = P.x - 1.0
    Run(0.5)
    check(s.total.corr == 1 and Count("right after lag comp was switched") == 1,
        "a jump right after switching lag comp is labelled as caused by the switch")
end
do
    local s = Fresh(true)
    P.player_classified.frames = 0
    P.events.cancelmovementprediction()
    check(s.total.pause == 0, "a prediction reset with no frozen frames is not a pause")
end
do
    local s = Fresh(true)
    local cls = P.player_classified
    local function Pick()
        P.sg.currentstate = { name = "doshortaction" }
        P.sg.server_states = { [hash("doshortaction")] = true }
        Run(0.3)                      -- the server follows 300 ms later
        cls.server = hash("doshortaction")
        Run(0.1)
        P.sg.currentstate = { name = "idle" }
        P.sg.server_states = nil
        Run(0.23)
        cls.server = hash("idle")
        Run(0.27)                     -- 900 ms per item in all
    end
    for _ = 1, 4 do Pick() end
    Lab.Stop(P)
    check(s.total.miss == 0, "a server that follows: no misses")
    check(Count("server follows you after 300 ms %(4%)") == 1, "  the summary has how late the server follows")
    check(Count("pace per item doshortaction 900 ms %(3%)") == 1, "  and the pace per picked item")
end

real_print("[lag compensation off, HUD, names]")
do
    lines = {}
    NewPlayer(false)
    Lab.Configure({ detail = "all" })
    local Text = require("widgets/text")
    Lab.AttachHud({ AddChild = function(_, w) return w end })
    Lab.Start(P)
    P.vx = 6
    local ok = pcall(Run, 2)
    check(ok, "no prediction (no local states, no server state): runs without errors")
    check(Count("OFF: turn it on") == 1, "  and says lag compensation should be on")
    check(Lab.hud_text.value ~= nil and Lab.hud_text.value:find("ping 180") ~= nil, "the HUD line shows the ping")
    Lab.Stop(P)
end

real_print(string.format("\n%d passed, %d failed", passes, fails))
if fails > 0 then os.exit(1) end

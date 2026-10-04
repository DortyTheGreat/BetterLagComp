-- Combat Lab against mocked mobs and player: run from the mod folder with
--     lua5.1 tests/combat_test.lua
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
local NOW = 100
function GetTime() return NOW end
function hash(str)
    local h = 5381
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
    return h
end
TheNet = { GetIsServer = function() return false end, GetAveragePing = function() return 200 end }
local MOBS = {}
TheSim = { FindEntities = function() return MOBS end }

local passes, fails = 0, 0
local function check(cond, what)
    if cond then passes = passes + 1; real_print("  ok    " .. what)
    else fails = fails + 1; real_print("  FAIL  " .. what) end
end

-- an animation: a name, a length, a time that runs; SetTime moves it (or, if the "server" owns
-- it, is undone at once)
local function Anim()
    local a = { name = "idle_loop", t = 0, frames = 40, server_owned = false }
    function a:Play(name, frames) self.name, self.t, self.frames = name, 0, frames or 20 end
    function a:IsCurrentAnimation(n) return self.name == n end
    function a:GetCurrentAnimationTime() return self.t end
    function a:GetCurrentAnimationNumFrames() return self.frames end
    function a:GetCurrentAnimationLength() return self.frames * F end
    function a:SetTime(t) if not self.server_owned then self.t = t end end
    function a:PlayAnimation(name) self:Play(name, 30) end
    function a:Step() self.t = self.t + F end
    return a
end

local P = { GUID = 1, prefab = "woodie", events = {}, tasks = {} }
P.AnimState = Anim()
P.Transform = { GetWorldPosition = function() return 0, 0, 0 end }
P.sg = { currentstate = { name = "idle" } }
local server_state = "idle"
P.player_classified = { currentstate = { value = function() return hash(server_state) end } }
function P:IsValid() return true end
function P:ListenForEvent(ev, fn) self.events[ev] = fn end
function P:RemoveEventCallback(ev) self.events[ev] = nil end
function P:DoPeriodicTask(_, fn) local t = { fn = fn }; function t:Cancel() t.dead = true end; table.insert(self.tasks, t); return t end

local function Mob(guid, prefab, x, range)
    local m = { GUID = guid, prefab = prefab, AnimState = Anim(), target = nil }
    m.replica = { combat = { GetTarget = function() return m.target end,
        _attackrange = { value = function() return range or 2 end } } }
    m.Transform = { GetWorldPosition = function() return x or 1, 0, 0 end }
    function m:IsValid() return true end
    return m
end

TUNING = { PIG_ATTACK_PERIOD = 3 }
BODYTEXTFONT = "body"
local created = {}
function CreateEntity()
    local e = { tags = {}, valid = true, text = nil, colour = nil, parent = nil }
    e.entity = { AddTransform = function() end, AddLabel = function() end,
        SetParent = function(_, p) e.parent = p end }
    e.Label = { SetFontSize = function() end, SetFont = function() end, SetWorldOffset = function() end,
        Enable = function() end, SetText = function(_, t) e.text = t end,
        SetColour = function(_, r, g, b) e.colour = { r, g, b } end }
    function e:AddTag(t) self.tags[t] = true end
    function e:IsValid() return self.valid end
    function e:Remove() self.valid = false end
    table.insert(created, e)
    return e
end

local CL = require("blc/combatlab")
CL.notify = function(kind, text) print(string.format("[LAB] %-7s %s", kind, text)) end

local function Run(seconds, each)
    for _ = 1, math.floor(seconds / F + 0.5) do
        NOW = NOW + F
        P.AnimState:Step()
        for _, m in ipairs(MOBS) do m.AnimState:Step() end
        if each then each() end
        for _, t in ipairs(P.tasks) do if not t.dead then t.fn() end end
    end
end

real_print("[mobs and hits]")
local spider = Mob(2, "spider")
local hound = Mob(3, "hound")
MOBS = { spider, hound }
CL.probes = false -- the probes on their own, below
CL.Start(P)
Run(0.6)
spider.target = P
Run(0.1)
check(Count("spider#2 targets you") == 1, "a mob turning on you is noticed")
spider.AnimState:Play("atk", 19)
Run(0.45)
P.events.healthdelta(P, { oldpercent = 1, newpercent = 0.9 })
check(Count("attack 'atk' %(19 frames%) seen") == 1, "its attack animation is seen")
check(Count("hit by spider#2: its 'atk' seen 4%d%d ms before the hit; with ping 200 a step had to leave within 2%d%d ms") == 1,
    "the hit is put down to it: windup ~450 ms, ~250 ms left to dodge at 200 ping")
spider.AnimState:Play("atk", 19)
Run(2.2)
check(Count("attack 'atk': no hit on you") == 1, "an attack with no hit after it: dodged or missed")
hound.target = P
Run(0.1)
hound.AnimState:Play("atk_pre", 8)
Run(0.15)
P.events.healthdelta(P, { oldpercent = 0.9, newpercent = 0.8 })
check(Count("hit by hound#3: its 'atk_pre' seen 1%d%d ms before the hit; with ping 200 a step had to leave %d+ ms BEFORE") == 1,
    "a windup shorter than the ping: not dodgeable by sight")
Run(2.2)
P.events.healthdelta(P, { oldpercent = 0.8, newpercent = 0.75 })
check(Count("health down with no attack seen") == 1, "damage with no attack before it is told apart")
local summary = CL.TakePeriod()
real_print("        " .. tostring(summary))
check(summary ~= nil and summary:find("mobs on you 2, their attacks seen 3: hit you 2, no hit 1; other damage 1") ~= nil
    and summary:find("spider 4%d%d ms") ~= nil and summary:find("hound 1%d%d ms") ~= nil, "the summary line")
check(CL.TakePeriod() == nil, "  nothing new: no line")

real_print("[an attack in two animations, several mobs at once, one too far]")
do
    local tall = Mob(10, "tallbird")
    local b1, b2 = Mob(11, "killerbee"), Mob(12, "killerbee")
    local far = Mob(13, "killerbee", 12, 1)
    MOBS = { tall, b1, b2, far }
    CL.Stop(P); CL.Start(P)
    Run(0.6)
    tall.target, b1.target, b2.target, far.target = P, P, P, P
    Run(0.1)
    tall.AnimState:Play("atk_pre", 10)
    Run(0.333)
    tall.AnimState:Play("atk", 21)
    Run(0.067)
    P.events.healthdelta(P, { oldpercent = 1, newpercent = 0.9 })
    check(Count("hit by tallbird#10: its 'atk_pre%+atk' seen 4%d%d ms before the hit") == 1,
        "atk_pre then atk: one attack, timed from the windup's start (~400 ms, not ~67)")
    Run(2.2)
    b1.AnimState:Play("atk", 27)
    Run(0.3)
    b2.AnimState:Play("atk", 27)
    Run(0.18)
    far.AnimState:Play("atk", 27)
    Run(0.02)
    P.events.healthdelta(P, { oldpercent = 0.9, newpercent = 0.8 })
    check(Count("hit by killerbee#11: its 'atk' seen 5%d%d ms") == 1,
        "two bees 300 ms apart: the hit goes to the one whose windup fits, not the latest; the far one is out")
    local summary = CL.TakePeriod()
    real_print("        " .. tostring(summary))
    check(summary ~= nil and summary:find("their attacks seen 4: hit you 2") ~= nil, "  the pair is counted as one attack")
end
CL.Stop(P)
MOBS = { spider, hound }
CL.Start(P)
CL.probes = false

real_print("[the dodge cue: the round trip and the way out of its reach]")
do
    local Cue = require("blc/cue")
    CL.cue = Cue
    TUNING.SPIDER_ATTACK_PERIOD = 3
    local sp = Mob(30, "spider", 2.0) -- 25-frame windup (833 ms); reach 2 + your 0.5; you are 2.0 away
    sp.entity = {}
    MOBS = { sp }
    CL.Stop(P); CL.Start(P)
    Run(0.6)
    sp.target = P
    Run(0.1)
    local function Label() return Cue._labels()[sp] end
    check(Label() ~= nil and Label().text == "ready", "a spider on you within reach: 'ready'")
    sp.AnimState:Play("atk", 43)
    Run(0.1) -- deadline: 833 - 267 (round trip) - 117 (0.5 to run at 6/s, and a frame) = 450 ms after its start
    local left = tonumber((Label().text or ""):match("^dodge (%d+)$") or -1)
    check(left >= 320 and left <= 380 and Label().colour[2] > 0.5, "its attack starts: 'dodge ~350' in yellow (" .. tostring(left) .. ")")
    check(sp.AnimState.t >= 0.267 + 0.09, "  and its attack is shown a round trip further on (future view of mobs)")
    check(Count("seen; 2.0 from it, reach 2.5: 117 ms to get out: a step must leave within 4%d%d ms") == 1, "  logged with the numbers")
    Run(0.25)
    check(Label().text:find("^dodge %d+$") ~= nil and Label().colour[2] < 0.5, "under 150 ms: red")
    Run(0.15)
    check(Label().text == "no dodge", "past the deadline: 'no dodge'")
    Run(0.3)
    P.events.healthdelta(P, { oldpercent = 1, newpercent = 0.9 })
    check(Count("hit by spider#30: .*; you did not move") == 1, "the outcome is logged: you did not move, it hit")
    Run(0.05)
    check(Label().text:find("^safe 2%.%d$") ~= nil and Label().colour[1] < 0.5, "after its hit: 'safe 2.x' in green (its period is 3 s)")
    Run(2.3)
    -- the next one: you start running in time and it misses
    sp.AnimState:Play("atk", 43)
    Run(0.2)
    P.sg.currentstate.name = "run_start"
    Run(0.1)
    P.sg.currentstate.name = "idle"
    Run(2.0)
    check(Count("spider#30 attack 'atk': no hit on you .*; you moved 2%d%d ms before the deadline") == 1,
        "you started moving 250 ms before the deadline and it missed: logged so")
    local summary = CL.TakePeriod()
    real_print("        " .. tostring(summary))
    check(summary ~= nil and summary:find("you moved before the step deadline 1 %(hit 0%), after it 0 %(hit 0%), stayed 1 %(hit 1%)") ~= nil,
        "  and counted in the summary")
    -- out of its reach: nothing to dodge
    MOBS = { sp }
    sp.Transform = { GetWorldPosition = function() return 3.2, 0, 0 end }
    Run(3)
    sp.AnimState:Play("atk", 43)
    Run(0.1)
    check(Label() == nil and Count("you are out of its reach %(3.2, reach 2.5%)") == 1, "out of its reach: no label")
    -- seen out of reach as it stops to attack; on screen it catches up a few frames later
    Run(3)
    sp.Transform = { GetWorldPosition = function() return 2.9, 0, 0 end }
    sp.AnimState:Play("atk", 43)
    Run(0.067)
    sp.Transform = { GetWorldPosition = function() return 2.0, 0, 0 end }
    Run(0.1)
    check(Label() ~= nil and Label().text:find("^dodge %d+$") ~= nil, "seen out of reach, then on screen it catches up: 'dodge' after all")
    -- you hit it during its windup: its blow does not come
    Run(3)
    sp.AnimState:Play("atk", 43)
    Run(0.2)
    sp.AnimState:Play("hit", 12)
    Run(0.1)
    check(Count("spider#30 attack 'atk': cut short, it was hit during its windup") == 1, "hit during its windup: cut short, not a dodge")
    check(Label() == nil or not Label().text:find("dodge"), "  and no dodge shown for it")
    local sum = CL.TakePeriod()
    check(sum ~= nil and sum:find("attacks cut short by your hits 1") ~= nil, "  counted")
    CL.cue = nil
end
CL.Stop(P)
MOBS = { spider, hound }
CL.Start(P)

real_print("[probe 1: the player's swing while the server chops]")
CL.probes = true
CL._state().p2.next = math.huge -- one probe at a time here
server_state = "chop"
P.AnimState:Play("chop_loop", 15)
-- the server's next swing reaches the client 0.4 s later and replaces what is shown
local swing_at = NOW + 0.4
Run(0.6, function()
    if swing_at ~= nil and NOW >= swing_at then
        P.AnimState:Play("chop_loop", 15)
        swing_at = nil
    end
end)
check(Count("probe   1: the server's swing %('chop_loop'%) is shown here") == 1, "while the server chops, its swing is shown")
check(Count("replaced by the server's 'chop_loop' after [34]%d%d ms") == 1, "the client's own animation lasts until the server's next swing")
Run(7) -- the next try: this time nothing from the server replaces it
check(Count("stayed %d+ ms, not replaced") == 1 and P.AnimState.name == "chop_loop",
    "  or it stays (then the swing is put back)")
server_state = "idle"

real_print("[probe 2: a mob moved in time]")
spider.target, hound.target = nil, nil
CL._state().p2.next = 0
hound.AnimState:Play("idle_loop", 60)
spider.AnimState:Play("idle_loop", 60)
Run(0.1)
Run(0.3)
check(Count("2: moving %a+#%d's animation 300 ms forward") == 1, "a mob's animation is moved forward")
check(Count("stays moved 300 ms forward") == 1, "  and it stays moved")
CL._state().p2.next = 0
spider.AnimState.server_owned, hound.AnimState.server_owned = true, true
spider.AnimState:Play("idle_loop", 60)
hound.AnimState:Play("idle_loop", 60)
Run(0.4)
check(Count("snapped back to the server's time") == 1, "  or it snaps back to the server's time")
local summary2 = CL.TakePeriod()
check(summary2 ~= nil and summary2:find("probe 2: a mob's animation moved with SetTime stayed moved 1, snapped back 1") ~= nil,
    "the probes are in the summary")

CL.Stop(P)
check(P.events.healthdelta == nil and CL._state() == nil, "stops cleanly")

real_print(string.format("\n%d passed, %d failed", passes, fails))
if fails > 0 then os.exit(1) end

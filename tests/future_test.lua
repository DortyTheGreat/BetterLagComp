-- The future view for tool work against a mocked animation engine and server:
--     lua5.1 tests/future_test.lua
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
function hash(str)
    local h = 5381
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
    return h
end
TheNet = { GetIsServer = function() return false end, GetAveragePing = function() return 250 end }
CONTROL_ACTION, CONTROL_PRIMARY, CONTROL_CONTROLLER_ACTION = 1, 2, 3
local held = true
TheInput = { IsControlPressed = function(_, c) return held and c == CONTROL_ACTION end }

local work_done = false
package.loaded["blc/pipeline"] = { enabled = true, FollowDelay = function() return 9 * F end,
    WorkDone = function() return work_done end }

local passes, fails = 0, 0
local function check(cond, what)
    if cond then passes = passes + 1; real_print("  ok    " .. what)
    else fails = fails + 1; real_print("  FAIL  " .. what) end
end

-- the engine: one animation and a queue; the time runs, a non-looping one at its end goes on to
-- the queued one
local LEN = { chop_pre = 10, chop_lag = 30, chop_loop = 18, idle_loop = 40, hit = 12 }
local A = { name = "idle_loop", t = 0, queue = {} }
function A:IsCurrentAnimation(n) return self.name == n end
function A:GetCurrentAnimationTime() return self.t end
function A:GetCurrentAnimationLength() return (LEN[self.name] or 20) * F end
function A:PlayAnimation(n) self.name, self.t, self.queue = n, 0, {} end
function A:PushAnimation(n) table.insert(self.queue, n) end
function A:SetTime(t) self.t = t end
function A:Step()
    self.t = self.t + F
    local len = (LEN[self.name] or 20) * F
    if self.t >= len and #self.queue > 0 then
        self.name, self.t = table.remove(self.queue, 1), self.t - len
    end
end

local server_state = "idle"
local P = { tasks = {}, AnimState = A, sg = { currentstate = { name = "idle" } } }
P.player_classified = { currentstate = { value = function() return server_state == "0" and 0 or hash(server_state) end } }
function P:IsValid() return true end
function P:DoPeriodicTask(_, fn) local t = { fn = fn }; function t:Cancel() t.dead = true end; table.insert(self.tasks, t); return t end

-- a local entity with an updatelooper: its post-update runs in the loop after the server's frame
function CreateEntity()
    local d = { entity = { SetCanSleep = function() end }, valid = true }
    function d:AddTag() end
    function d:IsValid() return self.valid end
    function d:Remove() self.valid = false end
    function d:AddComponent(name)
        assert(name == "updatelooper")
        self.components = { updatelooper = {
            AddPostUpdateFn = function(_, fn)
                local task = { fn = fn }
                table.insert(P.tasks, task)
                d.Remove = function(self) self.valid = false; task.dead = true; WALL = {} end
            end,
            AddOnWallUpdateFn = function(_, fn) table.insert(WALL, function() fn(d, F) end) end,
        } }
    end
    return d
end
WALL = {}
local Future = require("blc/future")
Future.notify = function(kind, text) print(string.format("[LAB] %-7s %s", kind, text)) end

-- the client starts chopping at tick 0; the server shows its start `delay` frames later and
-- swings every 14 frames after its 10-frame start, until `last` swings are done
local shown = {}
local function Run(opt)
    TICK = 0
    work_done, held = false, true
    A.name, A.t, A.queue = "idle_loop", 0, {}
    server_state = "idle"
    P.sg.currentstate.name = "chop_start"
    A:PlayAnimation("chop_pre")
    A:PushAnimation("chop_lag")
    for _, t in ipairs(P.tasks) do t.dead = true end
    P.tasks = {}
    Future.Start(P)
    shown = {}
    local delay = opt.delay or 9
    local swings = opt.swings or 4
    local function ServerFrame(tick)
            -- the server, as the client sees it
            local st = tick - delay
            if st == 0 and not opt.no_server then
                server_state = "chop_start"
                A:PlayAnimation("chop_pre")
                if opt.clear then
                    -- the client matches the server's start and goes idle: the game clears its copy
                    -- of the server's state to 0 until the server's next state (ClearCachedServerState)
                    P.sg.currentstate.name = "idle"
                    server_state = "0"
                end
            end
            if not opt.no_server and st >= 10 then
                local k = math.floor((st - 10) / 14)
                if k < swings and (st - 10) % 14 == 0 then
                    server_state = "chop"
                    A:PlayAnimation("chop_loop")
                    if P.sg.currentstate.name == "chop_start" then P.sg.currentstate.name = "idle" end -- matched
                elseif k >= swings and st == 10 + swings * 14 + 6 then
                    server_state = "idle"
                    A:PlayAnimation("idle_loop")
                end
            end
    end
    for tick = 1, opt.ticks or 120 do
        TICK = tick
        A:Step()
        if not opt.late then ServerFrame(tick) end
        if opt.at ~= nil then opt.at(tick) end
        for _, t in ipairs(P.tasks) do if not t.dead then t.fn() end end
        if opt.late then ServerFrame(tick) end -- the server's frame comes in after the post-update
        if opt.foreign_at == tick then A:PlayAnimation("idle_loop") end
        for _, w in ipairs(WALL) do w() end
        shown[tick] = { name = A.name, t = A.t }
    end
    Future.Stop(P)
end

-- what the client's own time line has at a tick, the start at tick `t0`
local function Expected(tick, t0)
    local d = tick - t0
    if d < 10 then return "chop_pre", d end
    return "chop_loop", (d - 10) % 14
end

local function Matches(from, to, t0)
    for tick = from, to do
        local name, phase = Expected(tick, t0)
        local s = shown[tick]
        if s.name ~= name or math.abs(s.t / F - phase) > 1.6 then
            real_print(string.format("        tick %d: shown %s %.1f, expected %s %d", tick, s.name, s.t / F, name, phase))
            return false
        end
    end
    return true
end

real_print("[the server on time: the swing on our time line throughout]")
do
    Run({ delay = 9, swings = 4, ticks = 60 })
    local lag = false
    for tick = 1, 60 do if shown[tick].name == "chop_lag" then lag = true end end
    check(not lag, "no waiting pose")
    check(Matches(1, 60, 0), "the start of the swing, then a swing every 14 frames, from our start on")
    check(Count("re%-timed") == 0, "  the server's swings agree with it: nothing re-timed")
end

real_print("[run after the game frame (post-update), not as a task]")
do
    Run({ delay = 9, swings = 1, ticks = 3 })
    Future.Start(P)
    check(Future._state().driver ~= nil and Future._state().task == nil, "the future view runs in the post-update")
    Future.Stop(P)
end

real_print("[the server's swings come in after the post-update, before drawing]")
do
    lines = {}
    Run({ delay = 9, swings = 4, ticks = 90, late = true })
    local back = false
    for tick = 2, 60 do
        local a, b = shown[tick - 1], shown[tick]
        if a.name == b.name and b.t + 1.5 * F < a.t and a.t < 12 * F then back = true end
    end
    check(not back, "put back in the wall update: never drawn going back")
    check(Count("in the wall update [1-9]") == 1, "  counted where they were caught")
    check(Matches(1, 60, 0), "  and the swing is ours throughout")
    lines = {}
    Run({ delay = 9, swings = 4, ticks = 40, foreign_at = 30 })
    check(Count("a frame of 'idle_loop' on you before drawing") == 1, "something else on you: not touched, noted by name")
end

real_print("[hits on your time line: one per swing, on the frame the server's lands]")
do
    local hits = {}
    Future.impact = { Tick = function() end, Hit = function(kind) table.insert(hits, { tick = TICK, kind = kind }) end }
    Run({ delay = 9, swings = 4, ticks = 60 })
    Future.impact = nil
    local loops, ok = 0, true
    for tick = 1, 60 do
        local a = shown[tick]
        if a.name == "chop_loop" and a.t < F - 1e-6 then loops = loops + 1 end
    end
    for _, h in ipairs(hits) do
        local a = shown[h.tick]
        if h.kind ~= "chop" or a.name ~= "chop_loop" or math.abs(a.t - 2 * F) > 0.5 * F then ok = false end
    end
    check(#hits == loops and #hits >= 3, string.format("a hit for each swing shown (%d swings, %d hits)", loops, #hits))
    if os.getenv("DUMP") then
        for _, h in ipairs(hits) do real_print(h.tick, shown[h.tick].name, string.format("%.2f", shown[h.tick].t / F)) end
    end
    check(ok, "  each on frame 2 of the swing, where the server's chop lands")
end

real_print("[the server starts 6 frames late (it walked first)]")
do
    lines = {}
    Run({ delay = 15, swings = 4, ticks = 70 })
    if os.getenv("DUMP") then
        for tick = 8, 34 do real_print(tick, shown[tick].name, string.format("%.2f", shown[tick].t / F)) end
    end
    check(Count("the server's swing came 200 ms later than ours: easing it in") == 1, "noticed on its first swing, once")
    local back = false
    for tick = 16, 30 do
        local a, b = shown[tick - 1], shown[tick]
        if a.name == b.name and b.t + 0.5 * F < a.t and a.t < 12 * F then back = true end
    end
    check(not back, "  eased in: the swing never jumps back on screen")
    check(Matches(30, 70, 6), "  then in step with the server, a round trip ahead of it")
end

real_print("[the client clears its copy of the server's state (back to idle): still working]")
do
    lines = {}
    Run({ delay = 9, swings = 4, ticks = 60, clear = true })
    check(Count("server stopped") == 0 and Count("never started") == 0, "a 0 for the server's state is not 'it stopped'")
    check(Matches(1, 60, 0), "  the swing stays ours throughout")
end

real_print("[the last hit: no new swing predicted]")
do
    lines = {}
    Run({ delay = 9, swings = 2, ticks = 60, at = function(tick) if tick == 30 then work_done = true end end })
    local restarted = false
    for tick = 39, 44 do
        if shown[tick].name == "chop_loop" and shown[tick].t < 3 * F then restarted = true end
    end
    check(not restarted, "the target done: the swing runs out, no new one")
    check(shown[60].name == "idle_loop", "  the server's idle shown once it is there")
end

real_print("[something else on screen]")
do
    lines = {}
    local after
    Run({ delay = 9, swings = 4, ticks = 50, at = function(tick)
        if tick == 30 then A:PlayAnimation("hit") end
        if tick == 32 then after = Future._state().run end
    end })
    check(shown[30].name == "hit" and shown[32].name == "hit" and after == nil,
        "a hit is left alone: the server's animations are the game's again")
    check(Count("something else on screen") == 1, "  noted")
end

real_print("[no server]")
do
    lines = {}
    Run({ no_server = true, ticks = 40 })
    check(Count("the server never started") == 1, "the server never starts: the client's own state is left to the game")
end

real_print("[the next tree while the server still finishes the last]")
do
    lines = {}
    Run({ delay = 9, swings = 4, ticks = 40, at = function(tick)
        if tick == 30 then
            P.sg.currentstate.name = "chop_start" -- a new start, our own
            A:PlayAnimation("chop_pre")
            A:PushAnimation("chop_lag")
        end
    end })
    check(Count("the next one") == 1 and shown[31].name == "chop_pre" and math.abs(shown[31].t - F) < 0.01,
        "our time line starts again from the new start")
end

real_print("[switched off]")
do
    lines = {}
    Future.enabled = false
    Run({ delay = 15, swings = 4, ticks = 30 })
    Future.enabled = true
    local lag = false
    for tick = 10, 14 do if shown[tick].name == "chop_lag" then lag = true end end
    check(lag, "off: the game's waiting pose")
end

real_print(string.format("\n%d passed, %d failed", passes, fails))
if fails > 0 then os.exit(1) end

-- Future view for tool work: the swing shown on your time line, not the server's.
--
-- The game's client has no chopping of its own: it plays the start of the swing, then holds a
-- "waiting" pose until it sees the server chopping, and from then on shows the server's swings,
-- each a round trip late. The engine lets the client play an animation of its own until the
-- server's next one arrives (the Combat Lab's probe: replaced after exactly one swing, 467 ms).
--
-- So here the client runs the swing itself, from the moment you start it: the start of the swing,
-- then a swing every 14 frames (Woodie with his axe 10, the shovel 35), as the server's
-- stategraph repeats it while the button is held. Each swing of the server's that arrives is used
-- only to check the timing: it started on the server the usual follow delay after our request, so
-- our time line should have it exactly that much earlier; if not (the server walked first,
-- started late), ours is moved to match, once. Then our phase is put back on screen. A new swing is
-- only predicted while the button is held and the target is not done (after the last hit the
-- server just finishes its swing). Anything else on screen (a hit, another action) and it stops.
local Util = require("blc/util")

local Future = { enabled = true }

local F = rawget(_G, "FRAMES") or 1 / 30
local TOLERANCE = 1.5 -- frames of phase difference left alone on screen
local RETIME = 4 -- frames our time line may be off the server's before it is moved
local EASE = 0.5 -- frames per frame a move is eased in by (no jump back on screen)
local FAMILIES = {
    { pres = { "woodie_chop_pre", "woodie_chop_atk_pre" }, lag = "woodie_chop_lag", loop = "woodie_chop_loop", period = 10 },
    { pres = { "chop_pre" }, lag = "chop_lag", loop = "chop_loop", period = 14 },
    { pres = { "pickaxe_pre" }, lag = "pickaxe_lag", loop = "pickaxe_loop", period = 14 }, -- mine, hammer
    { pres = { "shovel_pre" }, lag = "shovel_lag", loop = "shovel_loop", period = 35 },
}
local START_STATES = { chop_start = true, mine_start = true, dig_start = true, hammer_start = true }
local WORK_STATES = { "chop_start", "chop", "mine_start", "mine", "dig_start", "dig", "hammer_start", "hammer" }

local s = nil
local WORK_HASH = {}

local function Now() return Util.Now() end
local function Ms(t) return math.floor(t * 1000 + 0.5) end

local function Note(text)
    if Future.notify ~= nil then Future.notify("future", text) end
end

local function PreOf(anim, fam)
    for _, name in ipairs(fam.pres) do
        if anim:IsCurrentAnimation(name) then return name end
    end
    return nil
end

-- the family of the tool work on screen, by the start of the swing (or its waiting pose)
local function FamilyOf(anim)
    for _, fam in ipairs(FAMILIES) do
        if PreOf(anim, fam) ~= nil or anim:IsCurrentAnimation(fam.lag) then return fam end
    end
    return nil
end

-- the server's state, the last one it sent: when the client goes back to idle the game clears its
-- copy to 0 (SGwilson_client's ClearCachedServerState) until the server's next state arrives
local function ServerWorking()
    local classified = s.inst.player_classified
    local v = classified ~= nil and classified.currentstate ~= nil and classified.currentstate:value() or nil
    if v ~= nil and v ~= 0 then s.server_v = v end
    return s.server_v ~= nil and WORK_HASH[s.server_v] == true
end

local function LocalState()
    local sg = s.inst.sg
    return sg ~= nil and sg.currentstate ~= nil and sg.currentstate.name or nil
end

-- the time from our request to seeing the server start it, as fast chains measure it
local function Lead()
    local Pipe = package.loaded["blc/pipeline"]
    local d = Pipe ~= nil and Pipe.FollowDelay ~= nil and Pipe.FollowDelay() or nil
    return d or ((Util.Ping() or 200) / 1000 + 2 * F)
end

-- the server repeats the swing while the button is held and the target can still be worked
local function GoesOn()
    local Pipe = package.loaded["blc/pipeline"]
    if Pipe ~= nil and Pipe.WorkDone ~= nil and Pipe.WorkDone() then return false end
    local input = rawget(_G, "TheInput")
    if input == nil then return true end
    return input:IsControlPressed(CONTROL_ACTION) or input:IsControlPressed(CONTROL_PRIMARY)
        or (CONTROL_CONTROLLER_ACTION ~= nil and input:IsControlPressed(CONTROL_CONTROLLER_ACTION))
end

local function Stop(why)
    if s.run ~= nil and s.run.swings > 0 and why ~= nil then
        Note(string.format("%d swings shown ahead, re-timed %d times; %s", s.run.swings, s.run.retimed, why))
    end
    s.run = nil
end

-- where our time line has the swing now
local function Predicted(run, now)
    local d = now - run.t0
    if d < run.pre_len then return run.pre, d end
    local k = math.floor((d - run.pre_len) / run.fam.period / F)
    if k > run.k then
        if GoesOn() then
            run.k = k
            run.swings = run.swings + 1
        else
            k = run.k -- no new swing: the last one runs out
        end
    end
    return run.fam.loop, d - run.pre_len - k * run.fam.period * F
end

-- a swing of the server's arrived (the animation went back, not by us): our time line is checked
-- against it
local function Arrived(run, now, start_seen, is_pre)
    local start = start_seen - Lead() -- where it is on our time line
    local ours
    if is_pre then
        ours = run.t0
    else
        local k = math.floor((start - run.t0 - run.pre_len) / (run.fam.period * F) + 0.5)
        ours = run.t0 + run.pre_len + math.max(0, k) * run.fam.period * F
    end
    local delta = start - (ours + run.pending)
    -- a few frames off is left alone (the hits come from the server anyway); more is eased in,
    -- half a frame per frame, rather than jumped
    if math.abs(delta) > RETIME * F then
        run.pending = run.pending + delta
        run.retimed = run.retimed + 1
        if run.retimed <= 3 then
            Note(string.format("the server's swing came %d ms %s than ours: easing it in", Ms(math.abs(delta)),
                delta > 0 and "later" or "earlier"))
        end
    end
end

local function Tick()
    if s == nil then return end
    local inst = s.inst
    local anim = inst.AnimState
    local now = Now()
    local state = LocalState()
    local Pipe = package.loaded["blc/pipeline"]
    local on = Future.enabled and (Pipe == nil or Pipe.enabled)
    local run = s.run
    local fresh = START_STATES[tostring(state)] and s.state ~= state -- a new start of work (the next tree)
    s.state = state
    if fresh and run ~= nil then
        Stop("the next one")
        run = nil
    end
    if run == nil then
        if not on or not START_STATES[tostring(state)] then return end
        local fam = FamilyOf(anim)
        if fam == nil then return end
        local pre = PreOf(anim, fam)
        run = { fam = fam, pre = pre or fam.pres[1], k = -1, swings = 0, retimed = 0, pending = 0, seen = false,
            t0 = now - (pre ~= nil and anim:GetCurrentAnimationTime() or 0),
            pre_len = pre ~= nil and anim:GetCurrentAnimationLength() or 8 * F }
        s.run = run
        s.last = nil
    end
    if not on then return Stop("switched off") end
    -- another state took over (a walk, another action), or the server is not working and had
    -- the time to start
    if not START_STATES[tostring(state)] and state ~= "idle" then return Stop(nil) end
    local working = ServerWorking()
    if working then
        run.seen = true
    elseif run.seen then
        return Stop("the server stopped") -- it was working and is not any more
    elseif now - run.t0 > Lead() + 0.6 then
        return Stop("the server never started")
    end
    local easing = run.pending ~= 0
    if easing then
        local step = math.max(-EASE * F, math.min(EASE * F, run.pending))
        run.t0, run.pending = run.t0 + step, run.pending - step
    end
    local fam = run.fam
    local pre = PreOf(anim, fam)
    local is_loop = anim:IsCurrentAnimation(fam.loop)
    if pre == nil and not is_loop and not anim:IsCurrentAnimation(fam.lag) then
        return Stop("something else on screen") -- a hit, an animation of the server's: not ours to touch
    end
    local t = anim:GetCurrentAnimationTime()
    local last = s.last
    if last ~= nil and (pre ~= nil or is_loop) then
        local same = (pre ~= nil and last.name == pre) or (is_loop and last.name == fam.loop)
        if not same or t + TOLERANCE * F < last.phase + (now - last.t) then
            -- a swing of the server's: it went back, or it is not what we showed
            Arrived(run, now, now - t, pre ~= nil)
        end
    end
    local name, phase = Predicted(run, now)
    if not anim:IsCurrentAnimation(name) then
        anim:PlayAnimation(name)
        anim:SetTime(phase)
    elseif easing or math.abs(t - phase) > TOLERANCE * F then
        anim:SetTime(phase) -- (while easing every frame: the engine's own clock runs at full speed)
    end
    s.last = { name = name, phase = phase, t = now }
end

function Future.Start(inst)
    if s ~= nil then Future.Stop(s.inst) end
    local h = rawget(_G, "hash")
    WORK_HASH = {}
    if h ~= nil then
        for _, name in ipairs(WORK_STATES) do WORK_HASH[h(name)] = true end
    end
    s = { inst = inst }
    s.task = inst:DoPeriodicTask(F, function() Util.SafeCall("future view", Tick) end)
end

function Future.Stop(inst)
    if s == nil or (inst ~= nil and inst ~= s.inst) then return end
    if s.task ~= nil then s.task:Cancel() end
    s = nil
end

function Future.Active() return s ~= nil and s.run ~= nil end

function Future._state() return s end

return Future

-- Combat Lab: fighting with ping, measured.
--
-- Mobs near you: whom they target (the game sends it: combat._target), when one of their attack
-- animations starts (as seen here), when a hit lands on you (as seen here). Both arrive through
-- the same downlink, so the time between them is the mob's own windup on the server. The time
-- you had to dodge after seeing the windup = that - your ping: the sight came half a ping late,
-- your step needs half a ping to get there.
--
-- Two engine checks ("probe" lines; the game's scripts cannot tell, the engine decides), a couple
-- of times per session:
--   1. While the server works (chopping, mining...) and the client stands by: does the client
--      show the server's swing animation, and does an animation the client plays itself stay
--      until the server's next one, or is it replaced at once? I.e. can the client draw its own
--      swing, ahead of the server. (Seen: the character stands still for a moment.)
--   2. A mob's animation moved forward with SetTime: does it stay moved until the mob's next
--      animation, or snap back? I.e. can mobs be shown on our time line. (Seen: a mob's
--      animation jumps a little.)
local Util = require("blc/util")

local CL = { probes = true, probe_swing = true, future_mobs = true }

-- the game's own numbers per mob (tools/mobdata.py): the attack's first animation, its hit frame,
-- its attack period
local ok_data, MOBDATA = pcall(require, "blc/mobdata")
if not ok_data or type(MOBDATA) ~= "table" then MOBDATA = {} end

local F = rawget(_G, "FRAMES") or 1 / 30
local RADIUS = 16 -- mobs watched around you
local SCAN = 0.5 -- seconds between looks for mobs
local MAX_MOBS = 16
local WINDOW = 2.0 -- a hit is put down to an attack seen at most this long before it
local ATTACK_ANIMS = { "atk_pre", "atk", "attack", "attack_pre", "atk_loop", "atk1", "atk2", "atk3", "charge_pre",
    "charge_loop", "atk_leap_pre", "atk_leap", "atk_prop_pre", "atk_object", "were_atk_pre", "spit", "bite" }
local WORK_LOOPS = { "chop_loop", "woodie_chop_loop", "pickaxe_loop", "shovel_loop" }
local WORK_STATES = { "chop_start", "chop", "mine_start", "mine", "dig_start", "dig", "hammer_start", "hammer" }
local MOB_MUST = { "_combat" }
local MOB_CANT = { "INLIMBO", "player", "playerghost", "FX", "DECOR", "wall", "structure", "NOCLICK" }
local PROBE_TRIES = 2
local PRIOR_WINDUP = 0.45 -- before a mob kind has been measured: a typical windup (pig 13 frames, bee 15)
local REACH = 4 -- beyond its attack range plus this, a mob did not hit you
local PLAYER_RADIUS = 0.5 -- the server's hit check: distance <= hit range + the target's radius
local RUN_SPEED = 6 -- if the locomotor does not say
local PROBE_WATCH = 1.5 -- seconds a probe watches before it concludes
local MOB_JUMP = 0.3 -- seconds a mob's animation is moved forward in probe 2

local s = nil
local Shift
local WORK_HASH = {}

local function Now() return Util.Now() end
local function Ms(t) return math.floor(t * 1000 + 0.5) end

local function Note(kind, text, problem)
    if CL.notify ~= nil then CL.notify(kind, text, problem) end
end

local function Name(e)
    return tostring(e.prefab) .. "#" .. tostring(e.GUID)
end

local function NewPeriod()
    return { aggro = 0, attacks = 0, hits = 0, nohit = 0, other = 0, windups = {}, shifted = 0, interrupted = 0,
        -- did you start moving before the step deadline, and did it hit
        dodge = { early = { 0, 0 }, late = { 0, 0 }, stayed = { 0, 0 } } }
end

local function Median(list)
    local v = {}
    for i, x in ipairs(list) do v[i] = x end
    table.sort(v)
    return v[math.floor((#v + 1) / 2)]
end

-- the windup of a kind of mob: measured this session (2 hits or more), else the game's number
local function Windup(prefab)
    local h = s.history[prefab]
    if h ~= nil and #h >= 2 then return Median(h) end
    local d = MOBDATA[prefab]
    return d ~= nil and d.hit * F or nil
end

-- for picking which attack a hit came from: a guess is better than nothing
local function Expected(prefab)
    local h = s.history[prefab]
    if h ~= nil and #h > 0 then return Median(h) end
    return Windup(prefab) or PRIOR_WINDUP
end

-- the least time between two attacks of a kind of mob: the game's attack period, else the
-- shortest seen
local function Period(prefab)
    local d = MOBDATA[prefab]
    if d ~= nil and d.period ~= nil then
        local v = type(d.period) == "number" and d.period or (rawget(_G, "TUNING") ~= nil and TUNING[d.period] or nil)
        if type(v) == "number" and v > 0 then return v end
    end
    local gaps = s.gaps[prefab]
    if gaps ~= nil and #gaps >= 2 then
        local least = math.huge
        for _, g in ipairs(gaps) do least = math.min(least, g) end
        return least
    end
    return nil
end

local function Dist(a, b)
    local ax, _, az = a.Transform:GetWorldPosition()
    local bx, _, bz = b.Transform:GetWorldPosition()
    return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end

-- how far its blow reaches you: its hit range (the game's number, else the attack range the game
-- sends with it) plus your radius
local function Reach(e)
    local d = MOBDATA[e.prefab]
    local r = nil
    if d ~= nil and d.range ~= nil then
        r = type(d.range) == "number" and d.range or (rawget(_G, "TUNING") ~= nil and TUNING[d.range] or nil)
    end
    if type(r) ~= "number" then
        local c = e.replica.combat
        r = c ~= nil and c._attackrange ~= nil and c._attackrange:value() or nil
    end
    return r ~= nil and r + PLAYER_RADIUS or nil
end

local function RunSpeed()
    local loco = s.inst.components ~= nil and s.inst.components.locomotor or nil
    if loco ~= nil and loco.GetRunSpeed ~= nil then
        local ok, v = pcall(loco.GetRunSpeed, loco)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return RUN_SPEED
end

local function Moving()
    local sg = s.inst.sg
    local name = sg ~= nil and sg.currentstate ~= nil and sg.currentstate.name or nil
    return name == "run_start" or name == "run"
end

local function InReach(e)
    if e.Transform == nil or s.inst.Transform == nil then return true end
    local c = e.replica.combat
    local range = c ~= nil and c._attackrange ~= nil and c._attackrange:value() or nil
    if range == nil then return true end
    return Dist(e, s.inst) <= range + REACH
end

local function AnimIs(anim, names)
    for _, name in ipairs(names) do
        if anim:IsCurrentAnimation(name) then return name end
    end
    return nil
end

local function Ping() return (Util.Ping() or 200) / 1000 end

---------------------------------------------------------------- mobs

local function Scan()
    local x, y, z = s.inst.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, y, z, RADIUS, MOB_MUST, MOB_CANT)
    local seen = {}
    for i, e in ipairs(ents) do
        if i > MAX_MOBS then break end
        if e ~= s.inst and e.AnimState ~= nil and e.replica ~= nil and e.replica.combat ~= nil then
            seen[e] = true
            if s.mobs[e] == nil then s.mobs[e] = { t = -1, n = -1 } end
        end
    end
    for e in pairs(s.mobs) do
        if not seen[e] or not e:IsValid() then s.mobs[e] = nil end
    end
end

-- where you are against its reach: whether a step is needed, and the last moment it can leave. Again
-- every frame of its windup until you move: the mob's position on screen catches up a few frames
-- after it stops to attack (it was shown behind), and you may move
local function Assess(e, a, now)
    local windup, reach = Windup(a.prefab), Reach(e)
    if reach == nil or e.Transform == nil or s.inst.Transform == nil then return "" end
    local dist = Dist(e, s.inst)
    a.out = dist > reach
    local travel = math.max(0, reach - dist) / RunSpeed() + F
    a.deadline = (windup ~= nil and not a.out) and (a.t + windup - CL.Lead() - travel) or nil
    return a.out and string.format("; you are out of its reach (%.1f, reach %.1f)", dist, reach)
        or string.format("; %.1f from it, reach %.1f: %d ms to get out", dist, reach, Ms(travel))
end

-- a mob's attack shown on your time line: as far into it as the server will be when your input
-- reaches it (the engine keeps an animation's time until the mob's next animation)
Shift = function(e, anim, t, by)
    anim:SetTime(t + by)
    s.period.shifted = s.period.shifted + 1
end

local function UpdateMob(e, m, now)
    local onme = e.replica.combat:GetTarget() == s.inst
    if onme ~= m.onme then
        m.onme = onme
        if onme then
            s.period.aggro = s.period.aggro + 1
            Note("aggro", Name(e) .. " targets you")
        end
    end
    -- a new animation: its time went back, or its length changed
    local anim = e.AnimState
    local t, n = anim:GetCurrentAnimationTime(), anim:GetCurrentAnimationNumFrames()
    local new = n ~= m.n or t + 0.001 < m.t
    m.t, m.n = t, n
    local open = m.attack
    if open ~= nil and (open.hit ~= nil or open.closed) then open = nil end
    local windup = open ~= nil and Windup(open.prefab) or nil
    if onme and open ~= nil and open.moved == nil and windup ~= nil and now < open.t + windup then
        Assess(e, open, now)
    end
    if not new or not onme then return end
    if open ~= nil and now < open.t + (windup or 0.6) and anim:IsCurrentAnimation("hit") then
        -- hit during its windup: its blow will not come (stunned), it was not a dodge
        open.closed = true
        s.period.interrupted = s.period.interrupted + 1
        for i, a in ipairs(s.open) do
            if a == open then table.remove(s.open, i) break end
        end
        Note("mobatk", string.format("%s attack '%s': cut short, it was hit during its windup", Name(e), open.name))
        return
    end
    local d = MOBDATA[e.prefab]
    local name = (d ~= nil and anim:IsCurrentAnimation(d.anim)) and d.anim or AnimIs(anim, ATTACK_ANIMS)
    if name == nil then return end
    local start = now - t -- it started this long ago (we see it a frame or so late)
    local last = m.attack
    if last ~= nil and last.name:find("_pre$") and start - last.t <= (last.frames + 3) * F then
        -- the attack itself after its windup (atk_pre, then atk): one attack, from the windup's start.
        -- If the engine went on to it from our moved windup it is ahead already; if the server's
        -- arrived on its own time, move it too
        if last.shift ~= nil and start > last.t + last.frames * F - last.shift / 2 then
            Shift(e, anim, t, last.shift)
        end
        last.name = last.name .. "+" .. name
        last.frames = n
        return
    end
    s.period.attacks = s.period.attacks + 1
    local a = { mob = e, prefab = tostring(e.prefab), name = name, frames = n, t = start }
    if last ~= nil and start - last.t < 8 then
        local gaps = s.gaps[a.prefab] or {}
        s.gaps[a.prefab] = gaps
        table.insert(gaps, start - last.t)
        if #gaps > 8 then table.remove(gaps, 1) end
    end
    m.attack = a
    table.insert(s.open, a)
    -- when a step must leave to be out of its reach when the blow lands
    local where = Assess(e, a, now)
    if Moving() then a.moved = now end
    local Pipe = package.loaded["blc/pipeline"]
    if CL.future_mobs and (Pipe == nil or Pipe.enabled) and not name:find("_loop$") then
        a.shift = CL.Lead()
        Shift(e, anim, t, a.shift)
    end
    Note("mobatk", string.format("%s attack '%s' (%d frames) seen%s%s", Name(e), name, n, where,
        a.deadline ~= nil and string.format(": a step must leave within %d ms", Ms(a.deadline - now)) or ""))
end

local function Record(prefab, h) -- a measured windup
    local w = s.period.windups[prefab] or { list = {} }
    s.period.windups[prefab] = w
    table.insert(w.list, h)
    local hist = s.history[prefab] or {}
    s.history[prefab] = hist
    table.insert(hist, h)
    if #hist > 9 then table.remove(hist, 1) end
end

-- did you start moving before the deadline, and did it hit
local function Outcome(a, hit)
    if a.deadline == nil then return "" end
    local d = s.period.dodge
    local slot, text
    if a.moved == nil then
        slot, text = d.stayed, "you did not move"
    elseif a.moved <= a.deadline then
        slot, text = d.early, string.format("you moved %d ms before the deadline", Ms(a.deadline - a.moved))
    else
        slot, text = d.late, string.format("you moved %d ms after the deadline", Ms(a.moved - a.deadline))
    end
    slot[hit and 1 or 2] = slot[hit and 1 or 2] + 1
    return "; " .. text
end

-- the local player's health went down
local function OnHealthDelta(_, data)
    if s == nil or data == nil or data.newpercent == nil or data.oldpercent == nil then return end
    if data.newpercent >= data.oldpercent then return end
    local now = Now()
    -- of the attacks seen, by mobs within reach, the one whose time since its start is closest
    -- to that kind's usual windup (with several mobs at once the latest one is often not it)
    local best, at, off
    for i, a in ipairs(s.open) do
        if now - a.t <= WINDOW and a.mob:IsValid() and InReach(a.mob) then
            local d = math.abs((now - a.t) - Expected(a.prefab))
            if best == nil or d < off then best, at, off = a, i, d end
        end
    end
    if best == nil then
        s.period.other = s.period.other + 1
        Note("hurt", "health down with no attack seen before it (cold, hunger, something not watched...)")
        return
    end
    table.remove(s.open, at)
    best.hit = now
    s.period.hits = s.period.hits + 1
    local h = now - best.t
    Record(best.prefab, h)
    local dodge = h - Ping()
    Note("hit", string.format("hit by %s#%s: its '%s' seen %d ms before the hit; with ping %d a step had to leave %s",
        best.prefab, tostring(best.mob.GUID), best.name, Ms(h), Util.Ping() or 0,
        dodge > 0 and string.format("within %d ms of seeing it", Ms(dodge))
            or string.format("%d ms BEFORE it could be seen: not dodgeable by sight", Ms(-dodge))) .. Outcome(best, true), true)
end

local function Expire(now)
    for i = #s.open, 1, -1 do
        local a = s.open[i]
        if now - a.t > WINDOW then
            table.remove(s.open, i)
            s.period.nohit = s.period.nohit + 1
            Note("mobatk", string.format("%s#%s attack '%s': no hit on you (dodged, missed, or someone else)%s",
                a.prefab, tostring(a.mob.GUID), a.name, Outcome(a, false)))
        end
    end
end

---------------------------------------------------------------- probe 1: the player's swing

local function ServerWorking()
    local classified = s.inst.player_classified
    local v = classified ~= nil and classified.currentstate ~= nil and classified.currentstate:value() or nil
    return v ~= nil and WORK_HASH[v] == true
end

local function LocalState()
    local sg = s.inst.sg
    return sg ~= nil and sg.currentstate ~= nil and sg.currentstate.name or nil
end

local function Probe1(now)
    local p = s.p1
    local anim = s.inst.AnimState
    if p.active ~= nil then
        local a = p.active
        local loop = AnimIs(anim, WORK_LOOPS)
        if loop ~= nil then
            p.active = nil
            table.insert(p.replaced, now - a.t)
            Note("probe", string.format("1: the client's own animation was replaced by the server's '%s' after %d ms "
                .. "(the server's swing comes every ~%d ms)", loop, Ms(now - a.t), Ms(14 * F)))
        elseif now - a.t > PROBE_WATCH or not ServerWorking() then
            p.active = nil
            p.kept = p.kept + 1
            Note("probe", string.format("1: the client's own animation stayed %d ms, not replaced by the server's",
                Ms(now - a.t)))
            if a.loop ~= nil and ServerWorking() then anim:PlayAnimation(a.loop, true) end -- back to the swing
        end
        return
    end
    if not ServerWorking() or LocalState() ~= "idle" then return end
    -- passive: what the client shows while the server works and the client stands by
    local loop = AnimIs(anim, WORK_LOOPS)
    if loop ~= nil then p.shows = p.shows + 1 else p.other = p.other + 1 end
    if loop ~= nil and CL.probes and p.tries < PROBE_TRIES and now >= p.next then
        -- active: play something else ourselves and see how long it lasts
        p.tries, p.next = p.tries + 1, now + 5
        p.active = { t = now, loop = loop }
        anim:PlayAnimation("idle_loop", true)
        Note("probe", "1: the server's swing ('" .. loop .. "') is shown here; playing 'idle_loop' on the client to see "
            .. "whether the server's next swing replaces it")
    end
end

---------------------------------------------------------------- probe 2: a mob moved in time

local function Probe2(now)
    local p = s.p2
    if p.active ~= nil then
        local a = p.active
        local e = a.mob
        if not e:IsValid() then p.active = nil return end
        local anim = e.AnimState
        local elapsed = now - a.t
        if anim:GetCurrentAnimationNumFrames() ~= a.n then
            p.active = nil
            table.insert(p.held, elapsed)
            Note("probe", string.format("2: %s's animation stayed moved %d ms forward until its next animation (%d ms later)",
                Name(e), Ms(MOB_JUMP), Ms(elapsed)))
            return
        end
        if elapsed < 6 * F then return end
        local t = anim:GetCurrentAnimationTime()
        local moved, unmoved = a.base + MOB_JUMP + elapsed, a.base + elapsed
        p.active = nil
        if math.abs(t - moved) < math.abs(t - unmoved) then
            table.insert(p.held, elapsed)
            Note("probe", string.format("2: %s's animation stays moved %d ms forward (%d ms later: at %.2f s, unmoved "
                .. "would be %.2f s)", Name(e), Ms(MOB_JUMP), Ms(elapsed), t, unmoved))
        else
            p.snapped = p.snapped + 1
            Note("probe", string.format("2: %s's animation snapped back to the server's time (%d ms later: at %.2f s, "
                .. "moved would be %.2f s)", Name(e), Ms(elapsed), t, moved))
        end
        return
    end
    if not CL.probes or p.tries >= PROBE_TRIES or now < p.next then return end
    for e, m in pairs(s.mobs) do
        local anim = e.AnimState
        local t, len = anim:GetCurrentAnimationTime(), anim:GetCurrentAnimationLength()
        if not m.onme and len >= 1 and t + MOB_JUMP + 6 * F + 0.1 < len then
            p.tries, p.next = p.tries + 1, now + 10
            p.active = { mob = e, t = now, base = t, n = anim:GetCurrentAnimationNumFrames() }
            anim:SetTime(t + MOB_JUMP)
            Note("probe", string.format("2: moving %s's animation %d ms forward (SetTime)", Name(e), Ms(MOB_JUMP)))
            return
        end
    end
end

---------------------------------------------------------------- lifecycle

local function Tick()
    if s == nil then return end
    local now = Now()
    if now >= s.next_scan then
        s.next_scan = now + SCAN
        Scan()
    end
    if CL.mobpos ~= nil then Util.SafeCall("mob positions", CL.mobpos.Update, CL, now) end
    for e, m in pairs(s.mobs) do
        if e:IsValid() then UpdateMob(e, m, now) end
    end
    if Moving() then
        for _, a in ipairs(s.open) do
            if a.moved == nil then a.moved = now end
        end
    end
    Expire(now)
    if CL.probe_swing then Util.SafeCall("combat probe 1", Probe1, now) end
    Util.SafeCall("combat probe 2", Probe2, now)
    if CL.cue ~= nil then Util.SafeCall("dodge cue", CL.cue.Update, CL, now) end
end

function CL.Start(inst)
    if s ~= nil then CL.Stop(s.inst) end
    local h = rawget(_G, "hash")
    WORK_HASH = {}
    if h ~= nil then
        for _, name in ipairs(WORK_STATES) do WORK_HASH[h(name)] = true end
    end
    s = { inst = inst, mobs = {}, open = {}, period = NewPeriod(), next_scan = 0, history = {}, gaps = {},
        p1 = { tries = 0, next = 0, shows = 0, other = 0, kept = 0, replaced = {} },
        p2 = { tries = 0, next = 0, held = {}, snapped = 0 } }
    s.on_health = function(i, data) Util.SafeCall("combat health", OnHealthDelta, i, data) end
    inst:ListenForEvent("healthdelta", s.on_health)
    s.task = inst:DoPeriodicTask(F, function() Util.SafeCall("combat tick", Tick) end)
end

function CL.Stop(inst)
    if s == nil or (inst ~= nil and inst ~= s.inst) then return end
    if CL.cue ~= nil then Util.SafeCall("dodge cue clear", CL.cue.Clear) end
    if CL.mobpos ~= nil then Util.SafeCall("mob positions clear", CL.mobpos.Clear) end
    if s.task ~= nil then s.task:Cancel() end
    if s.inst:IsValid() then s.inst:RemoveEventCallback("healthdelta", s.on_health) end
    s = nil
end

-- for the Lag Lab summary: a line about the fighting since the last call, or nil
function CL.TakePeriod()
    if s == nil then return nil end
    local p = s.period
    s.period = NewPeriod()
    local parts = {}
    if p.aggro + p.attacks + p.hits + p.other > 0 then
        table.insert(parts, string.format("mobs on you %d, their attacks seen %d: hit you %d, no hit %d; other damage %d",
            p.aggro, p.attacks, p.hits, p.nohit, p.other))
        local w = {}
        for prefab, v in pairs(p.windups) do
            local lo, hi = math.huge, 0
            for _, x in ipairs(v.list) do lo, hi = math.min(lo, x), math.max(hi, x) end
            table.insert(w, string.format("%s %d ms (%d..%d, %d)", prefab, Ms(Median(v.list)), Ms(lo), Ms(hi), #v.list))
        end
        table.sort(w)
        if #w > 0 then table.insert(parts, "windup seen -> hit: " .. table.concat(w, ", ")) end
        local d = p.dodge
        if d.early[1] + d.early[2] + d.late[1] + d.late[2] + d.stayed[1] + d.stayed[2] > 0 then
            table.insert(parts, string.format("you moved before the step deadline %d (hit %d), after it %d (hit %d), "
                .. "stayed %d (hit %d)", d.early[1] + d.early[2], d.early[1], d.late[1] + d.late[2], d.late[1],
                d.stayed[1] + d.stayed[2], d.stayed[1]))
        end
        if p.interrupted > 0 then table.insert(parts, string.format("attacks cut short by your hits %d", p.interrupted)) end
        if p.shifted > 0 then table.insert(parts, string.format("attacks shown on your time line %d", p.shifted)) end
    end
    if CL.mobpos ~= nil then
        local mp = CL.mobpos.TakePeriod()
        if mp.shown > 0 then
            table.insert(parts, string.format("mobs shown ahead %d frames, up to %.1f", mp.shown, mp.most))
        end
    end
    -- the probes: what came out since the last summary
    local p1, p2 = s.p1, s.p2
    if p1.shows + p1.other > 0 or #p1.replaced + p1.kept > 0 then
        local r = {}
        for _, v in ipairs(p1.replaced) do table.insert(r, tostring(Ms(v))) end
        table.insert(parts, string.format("probe 1: while the server works the client shows its swing %d/%d times; "
            .. "the client's own animation replaced after %s ms, kept %d", p1.shows, p1.shows + p1.other,
            #r > 0 and table.concat(r, "/") or "-", p1.kept))
        p1.shows, p1.other, p1.replaced, p1.kept = 0, 0, {}, 0
    end
    if #p2.held + p2.snapped > 0 then
        table.insert(parts, string.format("probe 2: a mob's animation moved with SetTime stayed moved %d, snapped back %d",
            #p2.held, p2.snapped))
        p2.held, p2.snapped = {}, 0
    end
    if #parts == 0 then return nil end
    return "combat: " .. table.concat(parts, "; ")
end

-- for the dodge cue
function CL.View() return s end
CL.Windup = function(prefab) return s ~= nil and Windup(prefab) or nil end
CL.Period = function(prefab) return s ~= nil and Period(prefab) or nil end
CL.InReach = function(e) return s ~= nil and InReach(e) end
function CL.Lead()
    local Pipe = package.loaded["blc/pipeline"]
    local d = Pipe ~= nil and Pipe.FollowDelay ~= nil and Pipe.FollowDelay() or nil
    return d or ((Util.Ping() or 200) / 1000 + 2 * F)
end

function CL._state() return s end

return CL

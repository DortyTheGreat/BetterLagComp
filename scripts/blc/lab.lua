-- Lag Lab: finds where the game's lag compensation (movement prediction) goes wrong.
--
-- With prediction on, this client acts ahead of the server: it walks and starts actions at
-- once, tells the server the path (RPC.PredictWalking) and the action (when it starts it
-- locally), and the server follows half a ping later. Things go wrong in four ways, and the
-- game gives a signal for each (scripts: playercontroller.lua, player_classified.lua,
-- SGwilson_client.lua, stategraph.lua):
--   correction  the engine moves the player to where the server says it is (a rollback).
--               No event for this: found as a jump the player's own velocity does not explain.
--   pause       the server forces its own state ("pausepredictionframes" -> the event
--               "cancelmovementprediction"): hit, eating, emotes... states the client cannot predict.
--   miss        the client is in a predicted state that lists the server states it expects
--               (state.server_states); the server's state (player_classified.currentstate, sent
--               on every change while predicting) never became one of them: the server did
--               not do what the client showed.
--   failed      the server's verdict on each action (player_classified.isperformactionsuccess):
--               false = the action failed there.
-- Every problem is logged with what led to it (the requests and states just before).
local Util = require("blc/util")

local Lab = { active = false }

local F = rawget(_G, "FRAMES") or 1 / 30
local CORR_TICK = 0.05 -- a tick's unexplained movement above this counts (units)
local CORR_MIN = 0.3 -- a correction smaller than this is noise
local TELEPORT = 8 -- larger jumps are teleports (wormholes...), not corrections
local GROUP = 0.25 -- unexplained movement closer than this in time is one correction
local MISS_GRACE = 0.35 -- on top of the ping, before a predicted state counts as not followed
local CONTEXT_TIME = 1.5 -- seconds of history printed with a problem
local CONTEXT_MAX = 40
local REPORT_EVERY = 60
local SWITCH_TIME = 2 -- position jumps this soon after lag comp was switched come from the switch
local CHAIN_GAP = 2.5 -- the same action started again within this is the same chain (pace)
-- server states that start one item of work; the time between two of them is the pace
local WORK_STATES = { doshortaction = true, dolongaction = true, dojostleaction = true, dostandingaction = true,
    chop_start = true, mine_start = true, hammer_start = true, dig_start = true, attack = true, quickeat = true }
local HUD_EVERY = 0.25

-- requests sent all the time while walking: never worth a line
local NOISY = { PredictWalking = true, DirectWalking = true, DragWalking = true, PredictOverrideLocomote = true }

-- requests that carry an action: where its code and target are
local ACTION_RPCS = {
    ActionButton = { action = 1, target = 2, mod = 5 },
    ControllerActionButton = { action = 1, target = 2, mod = 5 },
    ControllerAltActionButton = { action = 1, target = 2, mod = 5 },
    LeftClick = { action = 1, target = 4, mod = 8 },
    RightClick = { action = 1, target = 4, mod = 9 },
    UseItemFromInvTile = { action = 1, target = 2, mod = 4 },
    AttackButton = { target = 1 },
}

local cfg = { detail = "all", hud = true }
local s = nil -- the state while a player is active

function Lab.Configure(config)
    cfg.detail = config.detail or "all"
    cfg.hud = config.hud ~= false
end

---------------------------------------------------------------- names

local rpc_names = nil
local function RpcName(code)
    if rpc_names == nil then
        rpc_names = {}
        for k, v in pairs(rawget(_G, "RPC") or {}) do rpc_names[v] = k end
    end
    return rpc_names[code] or ("rpc#" .. tostring(code))
end

local function ActionName(code, mod_name)
    if code == nil then return nil end
    if mod_name ~= nil then
        local ids = rawget(_G, "ACTION_MOD_IDS")
        local list = ids ~= nil and ids[mod_name] or nil
        return list ~= nil and list[code] or (tostring(mod_name) .. "#" .. tostring(code))
    end
    local by_code = rawget(_G, "ACTIONS_BY_ACTION_CODE")
    local action = by_code ~= nil and by_code[code] or nil
    return action ~= nil and action.id or ("action#" .. tostring(code))
end

local function Label(e)
    if type(e) ~= "table" then return "-" end
    return tostring(e.prefab or "?") .. "#" .. tostring(e.GUID or "?")
end

-- The server's state arrives as a hash of its name. Names: the client's own states, every
-- server state they expect, and the server stategraph's states if it can be read here.
local state_names = nil
local function StateName(h)
    if h == nil or h == 0 then return "-" end
    if state_names == nil then
        state_names = {}
        local hash = rawget(_G, "hash")
        if hash ~= nil then
            local function Add(n)
                if type(n) == "string" then state_names[hash(n)] = n end
            end
            local player = Util.Player()
            if player ~= nil and player.sg ~= nil and player.sg.sg ~= nil then
                for n in pairs(player.sg.sg.states or {}) do Add(n) end
            end
            local ok, sg = pcall(require, "stategraphs/SGwilson")
            if ok and type(sg) == "table" and type(sg.states) == "table" then
                for n in pairs(sg.states) do Add(n) end
            end
        end
    end
    return state_names[h] or ("#" .. tostring(h))
end

---------------------------------------------------------------- events

local function Ms(v) return math.floor(v * 1000 + 0.5) end

local function Line(now, kind, text)
    Util.Log(string.format("[LAB] %8.3f  %-8s %s", now % 1000, kind, text))
end

-- an ordinary event: kept as context, printed only with detail "all"
local function Note(kind, text)
    if s == nil then return end
    local now = Util.Now()
    table.insert(s.context, { t = now, kind = kind, text = text })
    if #s.context > CONTEXT_MAX then table.remove(s.context, 1) end
    if cfg.detail == "all" then Line(now, kind, text) end
end

-- a problem: always printed; with detail "problems" also what led to it
local function Problem(kind, text)
    if s == nil then return end
    local now = Util.Now()
    if cfg.detail ~= "all" then
        for _, e in ipairs(s.context) do
            if now - e.t <= CONTEXT_TIME then Line(e.t, "  " .. e.kind, e.text) end
        end
    end
    Line(now, "!" .. kind, text)
    table.insert(s.context, { t = now, kind = "!" .. kind, text = text })
    if #s.context > CONTEXT_MAX then table.remove(s.context, 1) end
    s.flash_until = now + 1
end

local function LastAction(now)
    local a = s.last_action
    if a == nil then return "no action" end
    return string.format("%s %s %d ms ago", a.name, a.target, Ms(now - a.t))
end

local function Count(tbl, key)
    tbl[key] = (tbl[key] or 0) + 1
end

local function NewPeriod(now)
    return { t0 = now, corr = 0, corr_dist = 0, corr_back = 0, corr_by = {}, pause = 0, pause_by = {},
        miss = 0, miss_by = {}, ok = 0, failed = 0, failed_by = {}, pings = {}, pace = {}, follow_n = 0, follow_sum = 0 }
end

---------------------------------------------------------------- requests

function Lab.OnRpc(code, ...)
    if s == nil then return end
    local name = RpcName(code)
    if NOISY[name] then return end
    if name == "SetMovementPredictionEnabled" then s.switch_at = Util.Now() end
    local spec = ACTION_RPCS[name]
    if spec == nil then
        Note("send", name)
        return
    end
    local action = spec.action ~= nil and select(spec.action, ...) or nil
    local target = select(spec.target, ...)
    local mod_name = spec.mod ~= nil and select(spec.mod, ...) or nil
    local aname = name == "AttackButton" and "ATTACK" or ActionName(action, mod_name)
    if aname == nil then
        Note("send", name .. " (key held / released)")
        return
    end
    s.last_action = { name = aname, target = Label(target), t = Util.Now() }
    Note("send", string.format("%s %s %s", name, aname, Label(target)))
end

---------------------------------------------------------------- the watch, every tick

local function Velocity(inst)
    local phys = inst.Physics
    if phys == nil or phys.GetVelocity == nil then return nil end
    local ok, vx, _, vz = pcall(phys.GetVelocity, phys)
    if ok and type(vx) == "number" and type(vz) == "number" then return vx, vz end
    return nil
end

local function FinishCorrection(now)
    local c = s.corr
    s.corr = nil
    local dist = math.sqrt(c.x * c.x + c.z * c.z)
    if dist < CORR_MIN or dist > TELEPORT then return end
    -- against the way we were moving = pulled back
    local back = c.vx * c.x + c.vz * c.z < 0 and (c.vx * c.vx + c.vz * c.vz) > 0.01
    local p = s.period
    p.corr = p.corr + 1
    p.corr_dist = p.corr_dist + dist
    if back then p.corr_back = p.corr_back + 1 end
    local context = s.last_action ~= nil and now - s.last_action.t < 3 and s.last_action.name or "walking"
    local switched = s.switch_at ~= nil and now - s.switch_at < SWITCH_TIME
    if switched then context = "lag comp switch" end
    Count(p.corr_by, context)
    s.total.corr = s.total.corr + 1
    Problem("correct", string.format("moved %.2f by the server%s%s, over %d ms; local %s, server %s; last %s",
        dist, back and " (pulled back)" or "", switched and " right after lag comp was switched" or "", Ms(c.last - c.first), tostring(s.client_state or "-"),
        StateName(s.server_state), LastAction(now)))
end

local function CheckPosition(inst, now)
    if not Util.Predicting(inst) then
        -- without prediction the server moves you in steps by design: nothing to compare against
        s.px, s.corr, s.dx, s.rdx, s.vx = nil, nil, nil, nil, nil
        return
    end
    local x, _, z = inst.Transform:GetWorldPosition()
    local t = GetTime()
    local platform = inst.GetCurrentPlatform ~= nil and inst:GetCurrentPlatform() or nil
    if s.px ~= nil and platform == nil and s.platform == nil then
        local dt = t - s.pt
        if dt > 0 and dt < 0.2 then
            local dx, dz = x - s.px, z - s.pz
            local vx, vz = Velocity(inst)
            local ex, ez, learn
            if vx ~= nil then
                local pvx, pvz = s.vx or vx, s.vz or vz
                ex, ez = (vx + pvx) * 0.5 * dt, (vz + pvz) * 0.5 * dt
            elseif s.dx == nil then
                learn = true -- no velocity from physics and no history yet
            else
                ex, ez = s.dx, s.dz -- no velocity from physics: expect last tick's normal motion
            end
            if not learn then
                local rx, rz = dx - ex, dz - ez
                local moved = math.sqrt(dx * dx + dz * dz)
                local expected = math.sqrt(ex * ex + ez * ez)
                local blocked = moved < 0.02 and expected > 0.05 -- walking into something
                local odd = not blocked and math.sqrt(rx * rx + rz * rz) > CORR_TICK
                if odd and vx == nil and s.rdx ~= nil
                    and math.sqrt((dx - s.rdx) ^ 2 + (dz - s.rdz) ^ 2) < CORR_TICK then
                    -- the same motion two ticks running: the walk changed, nothing jumped
                    odd, learn, s.corr = false, true, nil
                end
                if odd then
                    if s.corr == nil then
                        s.corr = { first = now, x = 0, z = 0, vx = ex, vz = ez }
                    end
                    s.corr.x, s.corr.z, s.corr.last = s.corr.x + rx, s.corr.z + rz, now
                elseif not blocked then
                    learn = true
                end
            end
            if learn and vx == nil then s.dx, s.dz = dx, dz end
            s.rdx, s.rdz = dx, dz
            s.vx, s.vz = vx, vz
        end
    end
    s.px, s.pz, s.pt, s.platform = x, z, t, platform
    if s.corr ~= nil and now - s.corr.last > GROUP then FinishCorrection(now) end
end

local SERVER_WALKING = { run = true, run_start = true, run_stop = true, walk = true, walk_start = true, walk_stop = true }
local WALK_GRACE = 1.5 -- seconds more for the server to get there

local function CheckStates(inst, now)
    local classified = inst.player_classified
    local server = classified ~= nil and classified.currentstate ~= nil and classified.currentstate:value() or 0
    if server ~= s.server_state then
        s.server_state = server
        if server ~= 0 then
            local name = StateName(server)
            Note("server", name)
            if WORK_STATES[name] then
                local last = s.work
                if last ~= nil and last.name == name and now - last.t < CHAIN_GAP then
                    local pace = s.period.pace[name] or { n = 0, sum = 0 }
                    pace.n, pace.sum = pace.n + 1, pace.sum + (now - last.t)
                    s.period.pace[name] = pace
                end
                s.work = { name = name, t = now }
            end
        end
    end
    local sg = inst.sg
    local client = sg ~= nil and sg.currentstate ~= nil and sg.currentstate.name or nil
    if client ~= s.client_state then
        s.client_state = client
        s.client_since = now
        s.miss_logged = false
        s.followed = false
        if client ~= nil then Note("local", client) end
    end
    -- how long the server takes to follow a predicted state, and states it never followed
    if sg ~= nil and sg.server_states ~= nil and classified ~= nil and not s.followed then
        local ok, matches = pcall(sg.ServerStateMatches, sg)
        if ok and matches then
            s.followed = true
            local mem = sg.statemem
            if not s.miss_logged and now > s.client_since and WORK_STATES[tostring(client)]
                and not (mem ~= nil and mem.blc ~= nil) then
                s.period.follow_n = s.period.follow_n + 1
                s.period.follow_sum = s.period.follow_sum + (now - s.client_since)
            end
        elseif ok and not s.miss_logged then
            local ping = Util.Ping() or 200
            -- still walking there on the server (the client arrived first): it has not missed yet
            local walking = SERVER_WALKING[StateName(server)] == true
            if now - s.client_since > ping / 1000 + MISS_GRACE + (walking and WALK_GRACE or 0) then
                s.miss_logged = true
                s.period.miss = s.period.miss + 1
                s.total.miss = s.total.miss + 1
                Count(s.period.miss_by, tostring(client))
                Problem("miss", string.format("local %s for %d ms, the server never followed (it is in %s); last %s",
                    tostring(client), Ms(now - s.client_since), StateName(server), LastAction(now)))
            end
        end
    end
end

local function Report(now, why)
    local p = s.period
    local Pipe = package.loaded["blc/pipeline"]
    local fast = Pipe ~= nil and Pipe.TakePeriod() or nil
    local CL = package.loaded["blc/combatlab"]
    local combat = CL ~= nil and CL.TakePeriod() or nil
    local has = p.corr + p.pause + p.miss + p.failed + p.follow_n > 0 or next(p.pace) ~= nil
        or (fast ~= nil and fast.item.fast.n + fast.item.normal.n + fast.other.fast.n + fast.other.normal.n + fast.lost
            + fast.waits.start.n + fast.waits.late.n + fast.waits.unseen + fast.waits.backoff + fast.waits.tails > 0)
        or combat ~= nil
    if not has and why == "minute" then
        s.period = NewPeriod(now)
        return
    end
    local function List(tbl)
        local parts = {}
        for k, v in pairs(tbl) do table.insert(parts, k .. " " .. v) end
        table.sort(parts)
        return #parts > 0 and (" [" .. table.concat(parts, ", ") .. "]") or ""
    end
    local ping = 0
    for _, v in ipairs(p.pings) do ping = ping + v end
    ping = #p.pings > 0 and math.floor(ping / #p.pings + 0.5) or nil
    local paces = {}
    for name, v in pairs(p.pace) do
        table.insert(paces, string.format("%s %d ms (%d)", name, Ms(v.sum / v.n), v.n))
    end
    table.sort(paces)
    local space = ""
    if fast ~= nil then
        local function Avg(b) return b.n > 0 and string.format("%d ms (%d)", Ms(b.sum / b.n), b.n) or "-" end
        local function Line(what, k)
            local b = fast[k]
            if b.fast.n + b.normal.n == 0 then return "" end
            return string.format("; Space %s: fast %s, normal %s", what, Avg(b.fast), Avg(b.normal))
        end
        space = Line("pickups", "item") .. Line("picking, harvest, traps", "other")
        if space ~= "" or fast.lost > 0 then space = space .. string.format("; lost %d", fast.lost) end
        local w = fast.waits
        if w ~= nil then
            local parts = {}
            if w.start.n > 0 then table.insert(parts, "for the server's start " .. Avg(w.start)) end
            if w.late.n > 0 then table.insert(parts, "server late " .. Avg(w.late)) end
            if w.unseen > 0 then table.insert(parts, "start not seen " .. w.unseen) end
            if w.backoff > 0 then table.insert(parts, string.format("normal Space %d s", w.backoff)) end
            if #parts > 0 then space = space .. "; fast waited: " .. table.concat(parts, ", ") end
            if w.tails > 0 then space = space .. string.format("; swings cut %d", w.tails) end
        end
    end
    local follow = p.follow_n > 0 and string.format("%d ms (%d)", Ms(p.follow_sum / p.follow_n), p.follow_n) or "-"
    Util.Log(string.format(
        "[LAB] summary of %d s (%s): ping %s, lag comp %s; corrections %d (%.1f units, %d pulled back)%s; "
            .. "server pauses %d%s; not followed %d%s; actions failed %d of %d%s; server follows you after %s; "
            .. "pace per item %s",
        math.floor(now - p.t0 + 0.5), why, ping ~= nil and tostring(ping) or "?",
        Util.Predicting(Util.Player()) and "on" or "off", p.corr, p.corr_dist, p.corr_back, List(p.corr_by),
        p.pause, List(p.pause_by), p.miss, List(p.miss_by), p.failed, p.ok + p.failed, List(p.failed_by),
        follow, #paces > 0 and table.concat(paces, ", ") or "-") .. space .. (combat ~= nil and ("; " .. combat) or ""))
    s.period = NewPeriod(now)
end

local function UpdateHud(now)
    local text = s.hud
    if text == nil or text.inst == nil or not text.inst:IsValid() then return end
    local ping = Util.Ping()
    local t = s.total
    local Pipe = package.loaded["blc/pipeline"]
    text:SetString(string.format("ping %s   corr %d   fail %d/%d   pause %d   miss %d%s",
        ping ~= nil and tostring(math.floor(ping + 0.5)) or "?", t.corr, t.failed, t.ok + t.failed, t.pause, t.miss,
        Pipe ~= nil and ("   fast " .. Pipe.Status()) or ""))
    if now < (s.flash_until or 0) then
        text:SetColour(1, 0.45, 0.45, 1)
    else
        text:SetColour(0.85, 0.85, 0.85, 1)
    end
end

local function Tick(inst)
    if s == nil or inst ~= Util.Player() then return end
    local now = Util.Now()
    CheckPosition(inst, now)
    CheckStates(inst, now)
    if now - s.ping_at >= 1 then
        s.ping_at = now
        local ping = Util.Ping()
        if ping ~= nil then table.insert(s.period.pings, ping) end
    end
    if now - s.period.t0 >= REPORT_EVERY then Report(now, "minute") end
    if now - s.hud_at >= HUD_EVERY then
        s.hud_at = now
        UpdateHud(now)
    end
end

---------------------------------------------------------------- the server's signals

local function OnPause(inst)
    if s == nil then return end
    local classified = inst.player_classified
    local frames = classified ~= nil and classified.pausepredictionframes ~= nil and classified.pausepredictionframes:value() or 0
    local server = StateName(s.server_state)
    if frames <= 0 then
        -- sent when lag comp is switched or a state is forced; nothing was frozen
        Note("cancel", string.format("the server reset prediction (it is in %s)", server))
        return
    end
    s.period.pause = s.period.pause + 1
    s.total.pause = s.total.pause + 1
    Count(s.period.pause_by, server)
    Problem("pause", string.format("the server took over for %d frames (it is in %s); local %s; last %s",
        frames, server, tostring(s.client_state or "-"), LastAction(Util.Now())))
end

local function OnActionResult(classified)
    if s == nil then return end
    local ok = classified.isperformactionsuccess ~= nil and classified.isperformactionsuccess:value()
    local name = s.last_action ~= nil and s.last_action.name or "?"
    if ok then
        s.period.ok = s.period.ok + 1
        s.total.ok = s.total.ok + 1
        Note("result", "done: " .. LastAction(Util.Now()))
    else
        s.period.failed = s.period.failed + 1
        s.total.failed = s.total.failed + 1
        Count(s.period.failed_by, name)
        Problem("failed", string.format("the server says the action failed; last %s; server in %s",
            LastAction(Util.Now()), StateName(s.server_state)))
    end
end

local function Attach(inst)
    local classified = inst.player_classified
    if classified == nil or s.classified == classified then return end
    s.classified = classified
    s.on_result = function() Util.SafeCall("lab result", OnActionResult, classified) end
    classified:ListenForEvent("isperformactionsuccessdirty", s.on_result)
end

---------------------------------------------------------------- lifecycle

-- other parts of the mod log through here (fast chains)
function Lab.Event(kind, text, problem)
    if s == nil then return end
    if problem then Problem(kind, text) else Note(kind, text) end
end

function Lab.Start(inst)
    if s ~= nil then Lab.Stop(s.inst) end
    local now = Util.Now()
    s = {
        inst = inst, context = {}, period = NewPeriod(now), ping_at = -math.huge, hud_at = -math.huge,
        total = { corr = 0, pause = 0, miss = 0, ok = 0, failed = 0 }, client_since = now,
        hud = Lab.hud_text,
    }
    Lab.active = true
    s.on_pause = function() Util.SafeCall("lab pause", OnPause, inst) end
    inst:ListenForEvent("cancelmovementprediction", s.on_pause)
    s.task = inst:DoPeriodicTask(F, function()
        if s ~= nil and s.classified ~= inst.player_classified then Attach(inst) end
        Util.SafeCall("lab tick", Tick, inst)
    end)
    Attach(inst)
    Line(now, "start", string.format("Lag Lab watching; ping %s, lag comp %s",
        tostring(Util.Ping() or "?"), Util.Predicting(inst) and "on (Predictive)" or "OFF: turn it on to test it"))
end

function Lab.Stop(inst)
    if s == nil or (inst ~= nil and inst ~= s.inst) then return end
    local now = Util.Now()
    Report(now, "leaving")
    if s.task ~= nil then s.task:Cancel() end
    if s.inst ~= nil and s.inst:IsValid() then s.inst:RemoveEventCallback("cancelmovementprediction", s.on_pause) end
    if s.classified ~= nil and s.classified:IsValid() then
        s.classified:RemoveEventCallback("isperformactionsuccessdirty", s.on_result)
    end
    s = nil
    Lab.active = false
end

function Lab.AttachHud(controls)
    local Text = require("widgets/text")
    local text = controls:AddChild(Text(rawget(_G, "NUMBERFONT") or rawget(_G, "BODYTEXTFONT"), 22, ""))
    -- top centre: the text is centred on its position, so a long line never runs off the screen
    text:SetHAnchor(rawget(_G, "ANCHOR_MIDDLE") or 0)
    text:SetVAnchor(rawget(_G, "ANCHOR_TOP") or 1)
    text:SetScaleMode(rawget(_G, "SCALEMODE_PROPORTIONAL") or 2)
    text:SetPosition(0, -22, 0)
    Lab.hud_text = text
    if s ~= nil then s.hud = text end
end

-- for tests
Lab._state = function() return s end

return Lab

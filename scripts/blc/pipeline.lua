-- Fast chains: Space on item after item, plant after plant, trap after trap... without losing a
-- round trip on each.
--
-- The game, for each one: the client starts the action and sends the request -> waits until it
-- SEES the server in the same state (one round trip) -> waits until it sees the server's "doing"
-- end -> only then starts the next. The server waits for us a full round trip every time.
-- Here the client keeps its own time line, the one the server runs ping/2 later: our action ends
-- when the server's does (on our time line), the next one starts right away, and its request
-- leaves when the server can take it. The server's "busy"/"doing" for OUR last action, which
-- arrive a round trip late, are hidden from the client (they are the past, not news).
--
-- What the server does in each state we chain (SGwilson), in frames from the state's start:
--   doshortaction (PICKUP, quick PICK): "busy" until 6, the action at 6, idle at 10.
--   dolongaction (PICK of grass, saplings, bushes): "busy" until 4, the action when the state
--     times out, idle a few frames later. The timeout depends on how the state was reached:
--     dolongaction 1 s, domediumaction 0.5 s, dowoodiefastpick 0.85/0.70/0.55 s (Woodie's skill
--     level)... The client only ever sees "dolongaction", so the path is taken from the client's
--     own action handler and each path's length is measured on its first use. Leaving it before the action CANCELS the action (onexit -> ClearBufferedAction), and
--     from frame 4 a LeftClick or a predicted walk does make it leave. So the next request and
--     the walk to the next plant must reach the server after the action, not after "busy".
-- A LeftClick is refused only while "busy" (DoAction), an ActionButton also while "doing"
-- (GetActionButtonAction). Requests are handled before the state graph within a server tick.
-- The first action of a chain is only continued once the client has seen the server start it:
-- after a run the server may still have steps to walk, and the chain counts from when it really
-- started. If the server ever drops one (still there a while later), fast chains stop for a few
-- seconds and the margin grows by a frame.
local Util = require("blc/util")

-- margin: frames on top of the server's own between two requests (upload every 3 frames + jitter)
-- exit: frames after a quick action's request when it is over for us and the next may start
-- jitter: frames of buffer for a ping that jumps: "auto" (from the spread of what is seen) or 0..4
local Pipe = { enabled = true, margin = 4, exit = 8, long_extra = 0, anchor = true, jitter = "auto" }

local F = rawget(_G, "FRAMES") or 1 / 30
local ORDER = 1 -- requests are handled before the state graph within a server tick
local LOST_BACKOFF = 3 -- seconds of normal play after a request the server dropped
local PAUSE_BACKOFF = 1 -- ... after the server froze us (a hit)
local MAX_EXTRA = 4 -- frames of margin added after drops, at most
local SAME_CHAIN = 2.5 -- requests closer than this count for the pace
local LONG_SCRIPT = 30 -- dolongaction's timeout in the scripts (1 s)
local LONG_MIN, LONG_MAX = 6, 60 -- plausible measured lengths, frames
local LONG_SAMPLES = 4 -- the longest of the last few measurements is used
-- Long actions are chained from this ping up: what they can save is the round trip plus the
-- server's few frames after the action, what they cost is the margin; below this the game's
-- own way is as fast (tests/pipe_sim.lua: equal at 80 ms, 10..30% faster above)
local LONG_PING = 0.08

-- busy: "busy" ends; perform: the action happens (nil = measured); pst: frames from the action to
-- idle; anim: what our state plays when it ends
local STATES = {
    doshortaction = { busy = 6, perform = 6, pst = 4, anim = "pickup_pst" },
    dolongaction = { busy = 4, perform = nil, pst = 4, anim = "build_pst", high = "construct_pst" },
}

-- the ways into dolongaction (the server's action handlers and their timeouts)
local LONG_PATHS = { dolongaction = true, domediumaction = true, dowoodiefastpick = true, dolongestaction = true }
local NOISE = 2 -- frames: how much earlier than usual a start may be seen and still be a request's
-- frames of the usual spread in when a start is seen (waiting for the upload, 3 frames, and for
-- a snapshot): already covered by the margin, so a start later than usual only shifts the chain
-- by what goes beyond it
local QUANT = 3
local FOLLOW_SAMPLES = 12
local FOLLOW_WINDOW = 15 -- seconds: older samples say nothing about the ping now
local JITTER_MAX = 4 -- frames the automatic buffer may add
-- the tool work states (SGwilson): "working", never "busy"; the hit at frame 2 (chop), 7 (mine,
-- hammer), 15 (dig), 6 (werebeaver gnaw), then the rest of the swing until idle
local WORK_STATES = { "chop_start", "chop", "mine_start", "mine", "dig_start", "dig", "hammer_start", "hammer", "gnaw" }
local WORK_ACTIONS = { "CHOP", "MINE", "DIG", "HAMMER" }

local s = nil -- the session: the local player while it is in the world
local HASH = {} -- state name -> what player_classified.currentstate holds
local WORK_HASH = {} -- hashes of the tool work states
local WORK_ACTION = {} -- tool action -> the tag its target has while it can be worked

function Pipe.Configure(config)
    config = config or {}
    if config.pipeline ~= nil then Pipe.enabled = config.pipeline ~= false end
    if type(config.margin) == "number" then Pipe.margin = config.margin end
    if config.jitter ~= nil then Pipe.jitter = config.jitter end
end

local function Now() return Util.Now() end

local function Note(kind, text, problem)
    if Pipe.notify ~= nil then Pipe.notify(kind, text, problem) end
end

local function Bucket() return { fast = { n = 0, sum = 0 }, normal = { n = 0, sum = 0 } } end

local function NewPeriod()
    return { item = Bucket(), other = Bucket(), picked = 0, lost = 0, held = 0,
        -- where fast chains waited, for the summary (a "slow" moment with nothing wrong in the log)
        waits = { start = Bucket().fast, late = Bucket().fast, unseen = 0, backoff = 0, tails = 0 } }
end

local function JitterFrames()
    if Pipe.jitter == "auto" then return s.jitter end
    return tonumber(Pipe.jitter) or 0
end

local function Margin() return Pipe.margin + s.extra + JitterFrames() end

-- frames, from the request, at which the server takes the next LeftClick ("click") or ActionButton
-- ("button"), and at which our own state ends and walking to the next target may start ("exit")
local function Timing(state, path)
    local st = STATES[state]
    local perform = st.perform or s.long[path] or LONG_SCRIPT
    local t = {
        click = math.max(st.busy, perform) + ORDER,
        button = perform + st.pst + ORDER,
    }
    if st.busy >= perform then
        t.exit = Pipe.exit -- a walk that arrives while busy is kept until the action is done
    else
        t.exit = perform + ORDER + Margin() + Pipe.long_extra -- a walk that arrives before the action cancels it
    end
    return t
end

-- the chain is live while the server may still be in our last action (seen from the client)
local function ChainActive(now)
    local c = s.chain
    return c ~= nil and now < c.last + s.ping * 2 + (c.button + Margin() + 8) * F
end

-- earliest local time a request may leave so that it reaches the server after it can take it
local function FreeAt(how)
    local c = s.chain
    if c.anchor ~= nil then return math.huge end -- the server's start of the chain not seen yet
    return c.last + (c[how] + Margin()) * F
end

local function Usable(pc)
    if not Pipe.enabled or s == nil or pc.inst ~= s.inst or pc.locomotor == nil then return false end
    -- boats are fine: for an action on a target the server takes the target, the point only has to
    -- be within 64 of the player (IsPointInRange); riding too: its actions go through
    -- domediumaction / dolongaction, a way like any other (measured)
    return Now() >= s.backoff_until
end

-- What Space does that we chain (PlayerController's GetPickupAction picks these by the target's
-- tags; all go through doshortaction or dolongaction on the server). done: the target no longer
-- offers it (the tags GetPickupAction looks at), i.e. the server did it.
local function NoTag(tag) return function(t) return not t:HasTag(tag) end end
local function Harvested(t)
    return not (t:HasTag("harvestable") or t:HasTag("readyforharvest") or t:HasTag("tapped_harvestable")
        or (t:HasTag("notreadyforharvest") and t:HasTag("withered"))
        or (t:HasTag("dried") and not t:HasTag("burnt")) or (t:HasTag("donecooking") and not t:HasTag("burnt")))
end
local CHAINED = {}
-- built when the player arrives (ACTIONS exists by then, whatever the load order)
local function BuildChained()
    if next(CHAINED) ~= nil or rawget(_G, "ACTIONS") == nil then return end
    local function Chain(name, spec)
        local action = ACTIONS[name]
        if action ~= nil then
            spec.name = name
            CHAINED[action] = spec
        end
    end
    Chain("PICKUP", { kind = "item", hide = true, done = function() return false end, -- INLIMBO / removed
        ok = function(t) return not t:HasTag("minigameitem") end }) -- riding: domediumaction
    Chain("PICK", { kind = "other", done = NoTag("pickable"), ok = function(t) return t:HasTag("pickable") end })
    Chain("CHECKTRAP", { kind = "other", done = NoTag("trapsprung") }) -- traps, bird traps
    Chain("HARVEST", { kind = "other", done = Harvested }) -- crock pots, drying racks, farms, bee boxes
    Chain("SMOTHER", { kind = "other", done = NoTag("smolder") })
    Chain("INTERACT_WITH", { kind = "other", done = NoTag("tendable_farmplant"),
        ok = function(t) return t:HasTag("tendable_farmplant") end }) -- tending farm plants
    Chain("TAKEITEM", { kind = "other", done = NoTag("inventoryitemholder_take"),
        ok = function(t) return t:HasTag("inventoryitemholder_take") end })
    Chain("RESETMINE", { kind = "other", done = NoTag("minesprung") }) -- tooth traps
end

local function Chainable(action, target, state)
    local spec = CHAINED[action]
    if spec == nil or STATES[state] == nil then return nil end
    if state == "dolongaction" and s.ping < LONG_PING then return nil end
    if spec.ok ~= nil and not spec.ok(target, state) then return nil end
    return spec
end

local function IsChained(action) return CHAINED[action] ~= nil end

-- which way the server goes into the state, from the client's own action handler (the same logic)
local function PathOf(inst, sg, action, state)
    if state == "doshortaction" then return "short" end
    local graph = sg.sg
    local handler = graph ~= nil and graph.actionhandlers ~= nil and graph.actionhandlers[action.action] or nil
    if handler == nil or handler.deststate == nil then return nil end
    local ok, dest = pcall(handler.deststate, inst, action)
    if ok and LONG_PATHS[dest] then return dest end
    return nil
end

-- the tool work last asked of the server, and whether its target is done (the tree fell, the
-- rock is gone): the server did the last hit
local function WorkDone()
    local w = s.work
    if w == nil then return false end
    local t = w.target
    if type(t) ~= "table" or t.IsValid == nil then
        s.work = nil
        return false
    end
    return not t:IsValid() or t:HasTag("INLIMBO") or not t:HasTag(w.tag)
end

-- the server is finishing the swing after the last hit: "working", never "busy" (a LeftClick is
-- taken, an ActionButton is not), nothing left to hit
local function InWorkTail(inst)
    if s.work == nil then return false end
    local classified = inst.player_classified
    local v = classified ~= nil and classified.currentstate ~= nil and classified.currentstate:value() or nil
    -- the last state the server sent: the client clears its copy to 0 when it goes back to idle
    -- (ClearCachedServerState) until the server's next one
    if v ~= nil and v ~= 0 then s.server_nz = v end
    return s.server_nz ~= nil and WORK_HASH[s.server_nz] == true and WorkDone()
end

local function Gone(target, spec)
    if not target:IsValid() or target:HasTag("INLIMBO") then return true end
    return spec.done(target)
end

-- The server's left click on target must give the same action as our Space did
local function ClickPoint(inst, target, action)
    local inventory = inst.replica ~= nil and inst.replica.inventory or nil
    if inventory ~= nil and inventory:GetActiveItem() ~= nil then return nil end
    local picker = inst.components.playeractionpicker
    if picker == nil then return nil end
    local x, _, z = target.Transform:GetWorldPosition()
    local ok, lmb = pcall(picker.DoGetMouseActions, picker, Vector3(x, 0, z), target)
    if ok and lmb ~= nil and lmb.action == action and lmb.target == target then return x, z end
    return nil
end

local function Count(bucket, dt)
    bucket.n, bucket.sum = bucket.n + 1, bucket.sum + dt
end

-- every Space request for an item or a plant, ours or the game's, for the pace in the summary
local function Pace(t, fast, kind)
    local last = s.last_send[kind]
    if last ~= nil and t - last < SAME_CHAIN then
        local b = s.period[kind]
        Count(fast and b.fast or b.normal, t - last)
    end
    s.last_send[kind] = t
end

local function Sent(entry, t, how, timing)
    entry.sent = t
    local c = s.chain
    if c == nil or not ChainActive(t) then
        c = { last = t, n = 0 }
        s.chain = c
    end
    c.last, c.n = math.max(c.last, t), c.n + 1
    c.click, c.button = timing.click, timing.button
    if entry.path ~= "short" and not entry.vanilla then c.long_ok = true end
    c.last_vanilla = entry.vanilla -- the game's own: its waiting must stay as it is
    local p = { sent = t, spec = entry.spec, how = how, measure = entry.measure, path = entry.path, entry = entry,
        state = HASH[entry.state],
        deadline = t + s.ping * 1.5 + 0.7 + timing.button * F }
    s.pending[entry.target] = p
    if entry.anchor then c.anchor = p end
    c.lastp = p
    Pace(t, not entry.vanilla, entry.spec.kind)
    Note("fast", string.format("%s %s %s#%s (%s, chain %d)", how == "click" and "LeftClick" or "ActionButton",
        entry.spec.name, tostring(entry.target.prefab), tostring(entry.target.GUID),
        entry.vanilla and (entry.path .. ", the game's own: measuring it") or entry.path, c.n))
end

-- how long the server's dolongaction takes before the action: seen from the client, the time
-- from the server entering it to the plant being picked (both arrive through the same channel)
local function Measure(dt, path)
    local frames = math.floor(dt / F + 0.5)
    if frames < LONG_MIN or frames > LONG_MAX then return end
    local samples = s.long_samples[path] or {}
    s.long_samples[path] = samples
    table.insert(samples, frames)
    if #samples > LONG_SAMPLES then table.remove(samples, 1) end
    local longest = 0
    for _, v in ipairs(samples) do longest = math.max(longest, v) end
    if longest ~= s.long[path] then
        s.long[path] = longest
        Note("fast", string.format("%s takes %d frames (%d ms)", path, longest, math.floor(longest * F * 1000 + 0.5)))
    end
end

-- the usual time from a request to seeing the server in its state: the quickest of the last
-- few seconds (the ping moves: an old quick one would make everything look late)
local function Baseline(now)
    local best
    for _, f in ipairs(s.follow) do
        if now - f.t <= FOLLOW_WINDOW then best = best == nil and f.v or math.min(best, f.v) end
    end
    return best or (s.ping + 2 * F)
end

-- automatic buffer: the spread (interquartile) of the recent ones beyond what the upload ticks
-- and the snapshots alone give (1 frame: the model of the network, steady connection)
local function UpdateJitter(now)
    local v = {}
    for _, f in ipairs(s.follow) do
        if now - f.t <= FOLLOW_WINDOW then v[#v + 1] = f.v end
    end
    if #v < 6 then return end
    table.sort(v)
    local iqr = v[math.floor(#v * 0.75 + 0.5)] - v[math.floor(#v * 0.25 + 0.5)]
    local frames = math.max(0, math.min(JITTER_MAX, math.floor(iqr / F + 0.5) - 1))
    if frames ~= s.jitter then
        s.jitter = frames
        if Pipe.jitter == "auto" then
            Note("fast", string.format("jitter buffer %d ms (the ping jumps by about %d ms)", math.floor(frames * F * 1000 + 0.5),
                math.floor(2 * iqr * 1000 + 0.5)))
        end
    end
end

-- the server was seen starting the action of p: anchor the chain on it
local function Observed(p, now)
    local dt = now - p.sent
    local late = dt - Baseline(now)
    table.insert(s.follow, { t = now, v = dt })
    if #s.follow > FOLLOW_SAMPLES then table.remove(s.follow, 1) end
    UpdateJitter(now)
    local entry = p.entry
    local c = s.chain
    local shift = late - QUANT * F
    if shift > 0 then
        -- the server started it late (it still had steps to walk): what comes next counts from
        -- its real start. In time only if the next request has not left yet: always for the
        -- first of a chain (the chain waits for this), often for the others.
        entry.shift = shift
        if c ~= nil and (c.anchor == p or c.lastp == p) then
            c.last = math.max(c.last, p.sent + shift)
            Count(s.period.waits.late, shift)
            Note("fast", string.format("the server started %s#%s %d ms later than usual (still walking): the next waits",
                tostring(entry.target.prefab), tostring(entry.target.GUID), math.floor(shift * 1000 + 0.5)))
        end
    end
    if entry.anchor and not entry.anchored then
        entry.anchored = true
        if c ~= nil and c.anchor == p then c.anchor = nil end
    end
end

---------------------------------------------------------------- hooks

-- every request this client sends (Space, mouse, ours): tool work started on a target
function Pipe.OnRpc(code, ...)
    if s == nil or RPC == nil then return end
    local action_code, target, mod_name
    if code == RPC.LeftClick then
        -- action, x, z, target, isreleased, controlmods, noforce, mod_name, ...
        local a, _, _, t, _, _, _, mod = ...
        action_code, target, mod_name = a, t, mod
    elseif code == RPC.ActionButton then
        -- action, target, isreleased, noforce, mod_name
        local a, t, _, _, mod = ...
        action_code, target, mod_name = a, t, mod
    else
        return
    end
    if action_code == nil or mod_name ~= nil or type(target) ~= "table" or target.IsValid == nil then return end
    local by_code = rawget(_G, "ACTIONS_BY_ACTION_CODE")
    local action = by_code ~= nil and by_code[action_code] or nil
    local tag = action ~= nil and WORK_ACTION[action] or nil
    if tag ~= nil then s.work = { target = target, tag = tag } end
end

-- PlayerController:RemoteActionButton, called by the game when the client starts the action
-- it walked to (preview_cb) or for the plain "button held" message
function Pipe.OnRemoteActionButton(pc, old, action, isreleased)
    local mine = s ~= nil and pc.inst == s.inst
    if action == nil or not Usable(pc) then
        if mine and action ~= nil and IsChained(action.action) then Pace(Now(), false, CHAINED[action.action].kind) end
        return old(pc, action, isreleased)
    end
    local inst = pc.inst
    local now = Now()
    local sg = inst.sg
    local state = sg ~= nil and sg.currentstate ~= nil and sg.currentstate.name or nil
    local target = action.target
    local tail = InWorkTail(inst)
    local spec = target ~= nil and target:IsValid() and Chainable(action.action, target, state) or nil
    if spec == nil then
        if IsChained(action.action) then Pace(now, false, CHAINED[action.action].kind) end
        if tail and target ~= nil and target:IsValid() then
            -- the last hit is done, the server is finishing the swing: a LeftClick now, else wait
            local x, z = ClickPoint(inst, target, action.action)
            if x ~= nil then
                s.period.waits.tails = s.period.waits.tails + 1
                Note("fast", string.format("LeftClick %s %s#%s while the server finishes the last swing",
                    tostring(action.action.id), tostring(target.prefab), tostring(target.GUID)))
                pc.remote_controls[CONTROL_PRIMARY] = nil
                SendRPCToServer(RPC.LeftClick, action.action.code, x, z, target, true, nil, nil,
                    action.action.mod_name, nil, false)
                return
            end
            local function Wait()
                if s ~= nil and InWorkTail(inst) then
                    inst:DoTaskInTime(F, function() Util.SafeCall("fast tail", Wait) end)
                else
                    old(pc, action, isreleased)
                end
            end
            return Wait()
        end
        -- something else right after our chain (a tree after the logs): as a LeftClick it is
        -- taken as soon as the server is not "busy"; an ActionButton only once it is done with
        -- "doing" too. Held until then.
        if ChainActive(now) then
            local x, z
            if target ~= nil and target:IsValid() then x, z = ClickPoint(inst, target, action.action) end
            local how = x ~= nil and "click" or "button"
            local function Go()
                if x ~= nil then
                    pc.remote_controls[CONTROL_PRIMARY] = nil
                    SendRPCToServer(RPC.LeftClick, action.action.code, x, z, target, true, nil, nil,
                        action.action.mod_name, nil, false)
                else
                    old(pc, action, isreleased)
                end
            end
            local function Try()
                if s == nil or s.chain == nil then return Go() end -- the chain is over: nothing to wait for
                local t = Now()
                local at = FreeAt(how)
                if at > t + F * 0.5 then
                    inst:DoTaskInTime(at == math.huge and F or (at - t), function() Util.SafeCall("fast hold", Try) end)
                    return
                end
                Go()
            end
            if FreeAt(how) > now + F * 0.5 then s.period.held = s.period.held + 1 end
            return Try()
        end
        return old(pc, action, isreleased)
    end

    local path = PathOf(inst, sg, action, state)
    if path == nil then
        -- a way into the state we do not know the length of (wx spin...): the game's own
        Pace(now, false, spec.kind)
        return old(pc, action, isreleased)
    end
    local timing = Timing(state, path)
    local first = not ChainActive(now)
    -- a long action of unknown length is entirely the game's (it gets measured)
    local unmeasured = state == "dolongaction" and s.long[path] == nil
    local entry = { target = target, spec = spec, state = state, path = path, exit = timing.exit, vanilla = unmeasured,
        measure = state == "dolongaction" and (first or unmeasured), anchor = first and Pipe.anchor }
    local mem = sg.statemem
    if not unmeasured then
        mem.blc = entry -- our time line for this state
        entry.mem = mem
    end
    local x, z
    if (not first or tail) and not unmeasured then x, z = ClickPoint(inst, target, action.action) end
    local how = x ~= nil and "click" or "button"
    local function Try()
        if s == nil or sg.statemem ~= mem or Gone(target, spec) then
            entry.cancelled = true -- our action was interrupted or the target is gone: nothing to ask
            return
        end
        local t = Now()
        if not first and s.chain == nil then
            -- the chain ended while we waited (the server's start of it was never seen): this one
            -- is the game's own
            entry.cancelled = true
            old(pc, action, isreleased)
            return
        end
        local at
        if first then
            -- after tool work the server may still be in the swing: an ActionButton waits for it
            at = (how ~= "click" and InWorkTail(inst)) and math.huge or t
        else
            at = FreeAt(how)
        end
        if at > t + F * 0.5 then
            entry.due = at
            inst:DoTaskInTime(at == math.huge and F or (at - t), function() Util.SafeCall("fast send", Try) end)
            return
        end
        if how == "click" then
            if first and tail then s.period.waits.tails = s.period.waits.tails + 1 end
            pc.remote_controls[CONTROL_PRIMARY] = nil
            SendRPCToServer(RPC.LeftClick, action.action.code, x, z, target, true, nil, nil,
                action.action.mod_name, nil, false)
        else
            old(pc, action, isreleased)
        end
        Sent(entry, Now(), how, timing)
    end
    Try()
end

-- The client state's onupdate, for our actions: ends on our time line
-- (true = handled; false = let the game's onupdate run)
function Pipe.UpdateState(inst, entry)
    if s == nil or entry.cancelled then return false end
    local st = STATES[entry.state]
    local mem = inst.sg.statemem
    local anim = mem.dohighaction and st.high or st.anim
    if entry.sent == nil then
        if inst.bufferedaction == nil then -- the game dropped it before our slot came
            entry.cancelled = true
            inst.AnimState:PlayAnimation(anim)
            inst.sg:GoToState("idle", true)
        end
        -- else: waiting for our slot. Not the game's check: the server's state it would match
        -- is the last action's, not this one's.
        return true
    end
    if entry.anchor and not entry.anchored then return true end -- the server's start not seen yet
    local now = Now()
    if now + 0.001 < entry.sent + (entry.shift or 0) + entry.exit * F then return true end
    local held = now - (entry.sent + entry.exit * F)
    if entry.anchor and held > F * 0.5 then Count(s.period.waits.start, held) end
    local target = entry.target
    local p = s.pending[target]
    if entry.spec.hide and p ~= nil and target:IsValid() and not target:HasTag("INLIMBO") then
        p.hidden = true
        target:Hide() -- picked up on our time line; the server does it ping/2 later
    end
    local pc = inst.components.playercontroller
    if pc ~= nil and pc.remote_controls ~= nil and pc.remote_controls[CONTROL_ACTION] ~= nil then
        pc.remote_controls[CONTROL_ACTION] = 0 -- the game's "wait for the server" cooldown
    end
    entry.ended = true -- ended by us, on our time line
    inst.AnimState:PlayAnimation(anim)
    inst.sg:GoToState("idle", true)
    return true
end

-- PlayerController:GetActionButtonAction: what we asked for is not a candidate any more
-- at least how long the walk to target takes before its action can start (reach 0.5: on the
-- short side, so a walk is never held back: at worst the waiting pose shows a little longer)
local function WalkTime(inst, target)
    if target == nil or not target:IsValid() or inst.Transform == nil then return 0 end
    local x, _, z = target.Transform:GetWorldPosition()
    local px, _, pz = inst.Transform:GetWorldPosition()
    local d = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
    local loco = inst.components.locomotor
    local speed = loco ~= nil and loco.GetRunSpeed ~= nil and loco:GetRunSpeed() or 6
    return math.max(0, d - 0.5) / math.max(speed, 1)
end

function Pipe.Search(pc, old, force_target)
    if s == nil or pc.inst ~= s.inst then return old(pc, force_target) end
    local result
    if next(s.pending) == nil then
        result = old(pc, force_target)
    else
        local see = rawget(_G, "CanEntitySeeTarget")
        local pending = s.pending
        rawset(_G, "CanEntitySeeTarget", function(viewer, target)
            if pending[target] ~= nil then return false end
            return see(viewer, target)
        end)
        local ok, r = pcall(old, pc, force_target)
        rawset(_G, "CanEntitySeeTarget", see)
        if not ok then error(r, 0) end
        result = r
    end
    -- something not chained right after our chain (a tree after the logs): not started before its
    -- request can leave, or the client would stand in its "waiting for the server" pose all along
    -- (walking there first is fine: only what the walk does not cover is waited out here)
    if result ~= nil and Pipe.enabled and CHAINED[result.action] == nil and s.chain ~= nil and ChainActive(Now()) then
        local target = result.target
        local x = target ~= nil and target:IsValid() and ClickPoint(pc.inst, target, result.action) or nil
        local wait = FreeAt(x ~= nil and "click" or "button") - Now()
        if wait > F * 0.5 and wait > WalkTime(pc.inst, target) then return nil end
    end
    return result
end

-- The server's "busy"/"doing" while it is in a state of our live chain: already accounted for
-- on our time line (a long action only once we know how long it takes)
function Pipe.Masking(inst)
    if s == nil or inst ~= s.inst or not Pipe.enabled then return false end
    if InWorkTail(inst) then return true end
    if not ChainActive(Now()) then return false end
    local classified = inst.player_classified
    if classified == nil or classified.currentstate == nil then return false end
    if s.chain.last_vanilla then return false end
    local v = classified.currentstate:value()
    return v == HASH.doshortaction or (v == HASH.dolongaction and s.chain.long_ok == true and s.ping >= LONG_PING)
end

function Pipe.PatchController(pc)
    if pc.blc_patched then return end
    pc.blc_patched = true
    local remote = pc.RemoteActionButton
    pc.RemoteActionButton = function(self, action, isreleased)
        if s == nil then return remote(self, action, isreleased) end
        local ok, err = pcall(Pipe.OnRemoteActionButton, self, remote, action, isreleased)
        if not ok then
            Util.Log("error in fast chains: " .. tostring(err))
            Pipe.enabled = false
            return remote(self, action, isreleased)
        end
    end
    local search = pc.GetActionButtonAction
    pc.GetActionButtonAction = function(self, force_target)
        return Pipe.Search(self, search, force_target)
    end
end

function Pipe.PatchStategraph(sg)
    local patched = 0
    for name in pairs(STATES) do
        local state = sg.states ~= nil and sg.states[name] or nil
        if state ~= nil then
            local update = state.onupdate
            state.onupdate = function(inst, dt)
                local entry = inst.sg.statemem.blc
                if entry ~= nil then
                    local ok, handled = pcall(Pipe.UpdateState, inst, entry)
                    if not ok then
                        Util.Log("error in fast chains: " .. tostring(handled))
                        inst.sg.statemem.blc = nil
                    elseif handled then
                        return
                    end
                end
                if update ~= nil then return update(inst, dt) end
            end
            patched = patched + 1
        else
            Util.Log("no " .. name .. " in the client state graph: not chained")
            STATES[name] = nil
        end
    end
    if patched == 0 then Pipe.enabled = false end
end

local function MaskTags(inst)
    if inst.blc_hastag ~= nil then return end
    local base = inst.HasTag
    inst.blc_hastag = base
    inst.HasTag = function(self, tag)
        if (tag == "busy" or tag == "doing" or tag == "working") and s ~= nil and self == s.inst then
            -- the game's own checks go through here: whatever goes wrong in the mod, they get
            -- the game's answer
            local ok, masked = pcall(Pipe.Masking, self)
            if ok and masked then return false end
        end
        return base(self, tag)
    end
end

---------------------------------------------------------------- watch, every tick

local function Lost(target, p, now)
    if p.hidden and target:IsValid() then target:Show() end
    s.period.lost = s.period.lost + 1
    s.total_lost = s.total_lost + 1
    s.extra = math.min(s.extra + 1, MAX_EXTRA)
    s.backoff_until = now + LOST_BACKOFF
    s.period.waits.backoff = s.period.waits.backoff + LOST_BACKOFF
    s.chain = nil
    Note("lost", string.format("the server did not %s %s#%s (%s, %d ms ago): normal Space for %d s, margin now %d frames",
        p.spec.name, tostring(target.prefab), tostring(target.GUID), p.how,
        math.floor((now - p.sent) * 1000 + 0.5), LOST_BACKOFF, Margin()), true)
end

local function Watch()
    if s == nil then return end
    local now = Now()
    s.ping = (Util.Ping() or 200) / 1000
    local classified = s.inst.player_classified
    local v = classified ~= nil and classified.currentstate ~= nil and classified.currentstate:value() or nil
    if v ~= s.server_state then
        if v ~= nil and (v == HASH.doshortaction or v == HASH.dolongaction) then
            -- the server starts an action: of our requests not seen started yet, the newest one
            -- that can have reached it by now (one in the same state right after another shows
            -- no change: older unseen ones are skipped, not matched to this)
            local reach = now - math.max(2 * F, 0.5 * s.ping) -- had time to get there and back
            local newest
            for _, p in pairs(s.pending) do
                if p.seen == nil and p.state == v and p.sent <= reach and (newest == nil or p.sent > newest.sent) then
                    newest = p
                end
            end
            if newest ~= nil then
                for _, p in pairs(s.pending) do
                    if p.seen == nil and p.sent < newest.sent then p.seen = false end
                end
                newest.seen = now
                Observed(newest, now)
            end
        end
        s.server_state = v
    end
    if v ~= nil and v ~= 0 then s.server_nz = v end
    if s.work ~= nil and (s.server_nz == nil or not WORK_HASH[s.server_nz]) and WorkDone() then s.work = nil end
    local c = s.chain
    if c ~= nil and c.anchor ~= nil and now > c.anchor.sent + s.ping * 2 + 0.5 then
        c.anchor.entry.anchored = true
        s.chain = nil
        s.period.waits.unseen = s.period.waits.unseen + 1
        Note("fast", "the server's start of the chain was not seen: chain ended")
    end
    for target, p in pairs(s.pending) do
        local e = p.entry
        if e.mem ~= nil and not e.ended and not p.excused and s.inst.sg ~= nil and s.inst.sg.statemem ~= e.mem then
            -- left before our end of it, not by us: you walked off or did something else. If the
            -- server was not done yet that cancels it, as in the game: not a timing problem
            p.excused, p.yours = true, true
        end
        if Gone(target, p.spec) then
            s.pending[target] = nil
            s.period.picked = s.period.picked + 1
            if p.measure and type(p.seen) == "number" then Measure(now - p.seen, p.path) end
            if p.entry.anchor and not p.entry.anchored then
                p.entry.anchored = true -- gone before its start was seen (the snapshots skipped it)
                if s.chain ~= nil and s.chain.anchor == p then s.chain.anchor = nil end
            end
        elseif now >= p.deadline then
            s.pending[target] = nil
            if p.excused then
                -- the server froze us (a hit), or you left it early: it may have been cancelled,
                -- not a timing problem
                if p.hidden then target:Show() end
                if p.yours then
                    Note("fast", string.format("%s %s#%s not done: you left it before it was over (as in the game; not counted)",
                        p.spec.name, tostring(target.prefab), tostring(target.GUID)))
                end
            else
                Lost(target, p, now)
            end
        end
    end
end

local function OnPause(inst)
    if s == nil then return end
    local classified = inst.player_classified
    local frames = classified ~= nil and classified.pausepredictionframes ~= nil and classified.pausepredictionframes:value() or 0
    s.chain = nil
    for _, p in pairs(s.pending) do p.excused = true end
    if frames > 0 then
        s.backoff_until = math.max(s.backoff_until, Now() + PAUSE_BACKOFF)
        s.period.waits.backoff = s.period.waits.backoff + PAUSE_BACKOFF
    end
end

---------------------------------------------------------------- lifecycle, settings

function Pipe.Start(inst)
    if s ~= nil then Pipe.Stop(s.inst) end
    BuildChained()
    local h = rawget(_G, "hash")
    for name in pairs(STATES) do HASH[name] = h ~= nil and h(name) or nil end
    WORK_HASH = {}
    for _, name in ipairs(WORK_STATES) do if h ~= nil then WORK_HASH[h(name)] = true end end
    WORK_ACTION = {}
    for _, name in ipairs(WORK_ACTIONS) do
        if rawget(_G, "ACTIONS") ~= nil and ACTIONS[name] ~= nil then WORK_ACTION[ACTIONS[name]] = name .. "_workable" end
    end
    s = { inst = inst, pending = {}, chain = nil, extra = 0, backoff_until = -math.huge, ping = 0.2,
        period = NewPeriod(), total_lost = 0, last_send = {}, long = {}, long_samples = {}, follow = {}, jitter = 0,
        work = nil }
    MaskTags(inst)
    s.on_pause = function() Util.SafeCall("fast pause", OnPause, inst) end
    inst:ListenForEvent("cancelmovementprediction", s.on_pause)
    s.task = inst:DoPeriodicTask(F, function() Util.SafeCall("fast watch", Watch) end)
    Watch()
end

function Pipe.Stop(inst)
    if s == nil or (inst ~= nil and inst ~= s.inst) then return end
    for target, p in pairs(s.pending) do
        if p.hidden and target:IsValid() and not target:HasTag("INLIMBO") then target:Show() end
    end
    if s.task ~= nil then s.task:Cancel() end
    if s.inst:IsValid() then s.inst:RemoveEventCallback("cancelmovementprediction", s.on_pause) end
    s = nil
end

function Pipe.Toggle()
    Pipe.enabled = not Pipe.enabled
    if s ~= nil then s.chain = nil end
    Util.Log("fast chains " .. (Pipe.enabled and "on" or "off"))
    Note("fast", "fast chains switched " .. (Pipe.enabled and "on" or "off"))
    return Pipe.enabled
end

-- for the Lag Lab summary: what happened since the last call
function Pipe.TakePeriod()
    if s == nil then return nil end
    local p = s.period
    s.period = NewPeriod()
    return p
end

function Pipe.Status()
    if not Pipe.enabled then return "off" end
    if s ~= nil and Now() < s.backoff_until then return "paused" end
    local j = s ~= nil and JitterFrames() or 0
    return j > 0 and string.format("on +%d ms", math.floor(j * F * 1000 + 0.5)) or "on"
end

-- for the future view: the usual time from a request to seeing the server in its state, and
-- whether the tool work's target is done (the last hit is in)
function Pipe.FollowDelay()
    if s == nil then return nil end
    return Baseline(Now())
end

function Pipe.WorkDone() return s ~= nil and WorkDone() end
-- the target of the tool work last asked for, and the tag it has while it can be worked
function Pipe.WorkTarget()
    local w = s ~= nil and s.work or nil
    if w == nil or type(w.target) ~= "table" or w.target.IsValid == nil or not w.target:IsValid() then return nil end
    return w.target, w.tag
end

function Pipe._state() return s end

return Pipe

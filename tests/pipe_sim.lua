-- Fast chains against a simulated server, network and client. Run from the mod folder:
--     lua5.1 tests/pipe_sim.lua          (VERBOSE=1 for every step of the runs)
-- The rules come from the game's scripts (2026 build):
--   server, 30 ticks/s: requests first, then PlayerController (predicted walking), locomotor,
--     state graph.
--     ActionButton: refused while "busy" or "doing" (GetActionButtonAction), item within 6.
--     LeftClick: refused while "busy" (DoAction).
--     both: PushAction -> OnRemoteBufferedAction (snap if within a step, walk point y = 5) ->
--       in reach: doshortaction, else walk to the item with the action.
--     PredictWalking: stored (y = 4). Applied when not busy; a y = 4 point while walking to an
--       item drops that item's action (WalkInDirection -> SetBufferedAction(nil)).
--     doshortaction: busy + doing; frame 6: busy off, item picked; frame 10: idle.
--     dolongaction (PICK): busy + doing; frame 4: busy off; frame T: plant picked (T = 30 in the
--       scripts, 18 on the server of the logs); T + 4: idle. Leaving it before T (a new action,
--       a walk, a stop) cancels the pick.
--   network: requests leave 10 times a second (every 3 ticks), arrive ping/2 later in order;
--     state snapshots 15 times a second, ping/2 later, in order; optional jitter.
--   client: the game's Space repeat (PlayerController:OnUpdate: local "idle", cooldown cleared
--     once the server is not idle/moving), GetActionButtonAction (cooldown, IsBusy with the
--     server's "busy", IsDoingOrWorking with the server's "doing"), locomote ignored while busy,
--     SGwilson_client doshortaction (waits for the server's state).
package.path = "./scripts/?.lua;" .. package.path

local real_print = print
local VERBOSE = os.getenv("VERBOSE") ~= nil
print = function(...) if VERBOSE then real_print(...) end end

---------------------------------------------------------------- game stubs
FRAMES = 1 / 30
local F = FRAMES
local TICK = 0
function GetTime() return TICK * F end
function hash(str)
    local h = 5381
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
    return h
end
function Vector3(x, y, z) return { x = x, y = y, z = z } end
ACTIONS = { PICKUP = { id = "PICKUP", code = 1 }, CHOP = { id = "CHOP", code = 2 }, PICK = { id = "PICK", code = 3 },
    CHECKTRAP = { id = "CHECKTRAP", code = 4 }, HARVEST = { id = "HARVEST", code = 5 }, DIG = { id = "DIG", code = 6 } }
ACTIONS_BY_ACTION_CODE = {}
for _, a in pairs(ACTIONS) do ACTIONS_BY_ACTION_CODE[a.code] = a end
RPC = { LeftClick = 1, ActionButton = 2, PredictWalking = 3 }
CONTROL_ACTION, CONTROL_PRIMARY = 1, 2
local PING_MS = 160
TheNet = { GetIsServer = function() return false end, GetAveragePing = function() return PING_MS end }
function CanEntitySeeTarget(_, target) return target ~= nil and target:IsValid() end

local Pipe = require("blc/pipeline")

-- tool work (SGwilson): the hit, the server's own repeat while Space is held, the end of the swing
local WORK = {
    tree = { action = "CHOP", state = "chop", hit = 2, rep = 14, stop = 16 },
    tuft = { action = "DIG", state = "dig", hit = 15, rep = 35, stop = 40 },
}

local RUN = 6
local ARRIVE = 0.6 -- pickup reach, both sides
local function Dist(ax, az, bx, bz) return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) end

---------------------------------------------------------------- one run
local W -- the world of the current run

local function Lat()
    return W.opt.ping / 2000 / F + (math.random() * 2 - 1) * W.opt.jitter / 1000 / F
end

function SendRPCToServer(code, ...)
    Pipe.OnRpc(code, ...) -- main.lua's hook does this in the game
    local msg = { code, ... }
    msg.n = select("#", ...) + 1
    table.insert(W.outbox, msg)
    if code == RPC.LeftClick and msg[2] ~= nil then W.sent.click = W.sent.click + 1 end
    if code == RPC.ActionButton and msg[2] ~= nil then W.sent.button = W.sent.button + 1 end
end

-- server ---------------------------------------------------------------
local function Refuse(why)
    W.refused[why] = (W.refused[why] or 0) + 1
    W.refused_n = W.refused_n + 1
    print(string.format("%5d  server REFUSES: %s", TICK, why))
end

local function SetState(name)
    local sv = W.sv
    if (sv.state == "doshortaction" or sv.state == "dolongaction") and not sv.performed and sv.cur ~= nil
        and name ~= "hit" then
        W.interrupted = W.interrupted + 1 -- left before the action: the server cancels it
        print(string.format("%5d  server INTERRUPTS %s of %d (frame %d) -> %s", TICK, sv.state, sv.cur.id, TICK - sv.t0, name))
    end
    sv.state, sv.t0 = name, TICK
    sv.busy = name == "doshortaction" or name == "dolongaction" or name == "hit"
    sv.doing = name == "doshortaction" or name == "dolongaction"
    sv.working = name == "chop" or name == "dig"
end

local function StartAction(it)
    local sv = W.sv
    local work = WORK[it.kind]
    if work ~= nil then
        SetState(work.state)
        sv.cur, sv.performed, sv.dest, sv.walkpt, sv.work = it, false, nil, nil, work
        print(string.format("%5d  server %s %d", TICK, sv.state, it.id))
        return
    end
    local medium = W.opt.riding and (it.kind == "item" or it.kind == "trap") -- domediumaction: 0.5 s
    local long = (it.kind == "plant" and not it.quick) or it.kind == "pot" or medium
    SetState(it.kind == "tree" and "chop_start" or long and "dolongaction" or "doshortaction")
    sv.cur, sv.performed, sv.dest, sv.walkpt = it, false, nil, nil
    sv.T = medium and 15 or (it.noquick or it.kind == "pot") and 30 or W.opt.long
    print(string.format("%5d  server %s %d", TICK, sv.state, it.id))
end

local function PushAction(it)
    local sv = W.sv
    local v = sv.vec
    if v ~= nil and v.y >= 3 then -- OnRemoteBufferedAction
        if v.y < 5 and not sv.busy then
            local d = Dist(sv.x, sv.z, v.x, v.z)
            if d > 0 and d <= RUN * F then sv.x, sv.z = v.x, v.z end
        end
        v.y = 5
    end
    sv.walkpt = nil
    if Dist(sv.x, sv.z, it.x, it.z) <= ARRIVE then
        StartAction(it)
    else
        sv.dest = it
        SetState("run")
    end
end

local function OnRequest(m)
    local sv = W.sv
    local code = m[1]
    if code == RPC.PredictWalking then
        sv.vec = { x = m[2], z = m[3], y = 4 }
        return
    end
    local target = code == RPC.ActionButton and m[3] or m[5]
    if m[2] == nil then return end -- "button held"
    local it = W.items[target.id]
    if it.picked or it.chopped then return Refuse("item gone") end
    if it.spawn ~= nil and not it.spawned then return Refuse("not there yet") end
    if code == RPC.ActionButton then
        if sv.busy then return Refuse("ActionButton while busy") end
        if sv.doing or sv.working then return Refuse("ActionButton while doing") end
        if Dist(sv.x, sv.z, it.x, it.z) > 6 then return Refuse("too far") end
    else
        W.clicks = W.clicks + 1
        if W.clicks == W.opt.drop_click then return Refuse("dropped on purpose") end
        if sv.busy then return Refuse("LeftClick while busy") end
        if sv.dest == it then return end -- the same action again
    end
    PushAction(it)
end

local function ServerController()
    local sv = W.sv
    if sv.busy then return end
    local v = sv.vec
    if v == nil or v.y < 3 then return end
    local d = Dist(sv.x, sv.z, v.x, v.z)
    if v.y == 5 and (sv.dest ~= nil or not (sv.state == "idle" or sv.state == "run")) then
        if d * d <= 0.05 then v.y = 0 end
        return
    end
    if v.y < 5 and sv.dest ~= nil then
        W.cancelled = W.cancelled + 1 -- the walk to an item, and its pickup, dropped
        print(string.format("%5d  server DROPS the walk to item %d (new walk point)", TICK, sv.dest.id))
        sv.dest = nil
    end
    if d * d > 0.05 then
        sv.walkpt = v
        if sv.state ~= "run" then SetState("run") end
    else
        sv.walkpt = nil
        if sv.state ~= "idle" then SetState("idle") end -- Stop({ force_idle_state = true })
    end
end

local function ServerMove()
    local sv = W.sv
    if sv.state ~= "run" then return end
    local it = sv.dest
    local tx, tz
    if it ~= nil then
        tx, tz = it.x, it.z
    elseif sv.walkpt ~= nil then
        tx, tz = sv.walkpt.x, sv.walkpt.z
    else
        SetState("idle")
        return
    end
    local d = Dist(sv.x, sv.z, tx, tz)
    local step = RUN * F
    if d <= step then
        sv.x, sv.z = tx, tz
    else
        sv.x, sv.z = sv.x + (tx - sv.x) / d * step, sv.z + (tz - sv.z) / d * step
    end
    if it ~= nil then
        if Dist(sv.x, sv.z, it.x, it.z) <= ARRIVE then StartAction(it) end
    elseif d <= step then
        sv.walkpt = nil
        SetState("idle")
    end
end

local function ServerStateGraph()
    local sv = W.sv
    local f = TICK - sv.t0
    if sv.state == "doshortaction" then
        if f >= 6 and not sv.performed then
            sv.performed, sv.busy = true, false
            local it = sv.cur
            if not it.picked then
                it.picked, it.pick_tick = true, TICK
                table.insert(W.picks, TICK)
                print(string.format("%5d  server picked up %d", TICK, it.id))
            end
        end
        if f >= 10 then SetState("idle") end
    elseif sv.state == "dolongaction" then
        if f >= 4 then sv.busy = false end
        if f >= sv.T and not sv.performed then
            sv.performed = true
            local it = sv.cur
            if not it.picked then
                it.picked, it.pick_tick = true, TICK
                table.insert(W.picks, TICK)
                print(string.format("%5d  server picked %d", TICK, it.id))
            end
        end
        if f >= sv.T + 4 then SetState("idle") end
    elseif sv.work ~= nil and sv.state == sv.work.state then
        local work, it = sv.work, sv.cur
        if f >= work.hit and not sv.performed then
            sv.performed = true
            it.hits = it.hits - 1
            if it.hits <= 0 and not it.chopped then
                it.chopped = true
                print(string.format("%5d  server: %d done", TICK, it.id))
                for _, drop in pairs(W.items) do
                    if drop.spawn == it.id then drop.spawned = true end
                end
            end
        end
        if f >= work.rep and W.space and not it.chopped and sv.performed then
            sv.t0, sv.performed = TICK, false -- the server's own repeat while the button is held
        elseif f >= work.stop then
            SetState("idle")
        end
    elseif sv.state == "hit" then
        if f >= 6 then SetState("idle") end
    end
    if sv.pause > 0 then sv.pause = sv.pause - 1 end
end

local function ServerTick()
    local up = W.up
    while #up > 0 and up[1].arrive <= TICK do
        local packet = table.remove(up, 1)
        for _, m in ipairs(packet.msgs) do OnRequest(m) end
    end
    if W.opt.hit_at == TICK then -- something hits us: the server takes over for 6 frames
        local sv = W.sv
        SetState("hit")
        sv.pause, sv.pause_seq, sv.dest, sv.walkpt = 6, sv.pause_seq + 1, nil, nil
        print(string.format("%5d  server: HIT", TICK))
    end
    ServerController()
    ServerMove()
    ServerStateGraph()
    if TICK % 2 == 0 then
        local sv = W.sv
        local snap = { state = sv.state, busy = sv.busy, doing = sv.doing, working = sv.working,
            idle = sv.state == "idle", moving = sv.state == "run", pause = sv.pause, pause_seq = sv.pause_seq, gone = {} }
        snap.spawned = {}
        for id, it in pairs(W.items) do
            if it.picked or it.chopped then snap.gone[id] = true end
            if it.spawned then snap.spawned[id] = true end
        end
        snap.arrive = math.max(TICK + Lat(), W.down_last)
        W.down_last = snap.arrive
        table.insert(W.down, snap)
    end
end

-- client ---------------------------------------------------------------
local P, pc, rep, sg
local SPACE = { tree = "CHOP", tuft = "DIG", plant = "PICK", trap = "CHECKTRAP", pot = "HARVEST", item = "PICKUP" }
local STAYS = { plant = true, trap = true, pot = true, tree = true, tuft = true } -- still there, not offering it

local function ClientEntity(it)
    local e = { prefab = it.kind == "tree" and "evergreen" or it.kind == "plant" and "grass" or "log", GUID = it.id,
        id = it.id, kind = it.kind, quick = it.quick, noquick = it.noquick, limbo = false, hidden = false, picked = false }
    e.Transform = { GetWorldPosition = function() return it.x, 0, it.z end }
    e.entity = { IsVisible = function() return not e.limbo and not e.hidden end }
    function e:IsValid() return true end
    function e:HasTag(t)
        if t == "INLIMBO" then return e.limbo end
        if t == "pickable" then return e.kind == "plant" and not e.picked end
        if t == "trapsprung" then return e.kind == "trap" and not e.picked end
        if t == "donecooking" then return e.kind == "pot" and not e.picked end
        if t == "CHOP_workable" then return e.kind == "tree" and not e.picked end
        if t == "DIG_workable" then return e.kind == "tuft" and not e.picked end
        return false
    end
    function e:Hide() e.hidden = true end
    function e:Show() e.hidden = false end
    return e
end

local function MakeClient()
    rep = { state = "idle", tags = { idle = true }, pause = 0, pause_seq = 0 }
    P = { x = 0, z = 0, events = {}, AnimState = { PlayAnimation = function() end, PushAnimation = function() end } }
    function P:HasTag(t) return rep.tags[t] == true end
    P.Transform = { GetWorldPosition = function() return P.x, 0, P.z end }
    function P:IsValid() return true end
    function P:GetCurrentPlatform() return nil end
    function P:ListenForEvent(ev, fn) self.events[ev] = fn end
    function P:RemoveEventCallback(ev) self.events[ev] = nil end
    function P:PushEvent(ev) if self.events[ev] then self.events[ev]() end end
    function P:DoTaskInTime(delay, fn)
        local task = { at = GetTime() + delay, fn = fn }
        function task:Cancel() self.dead = true end
        table.insert(W.tasks, task)
        return task
    end
    function P:DoPeriodicTask(period, fn)
        local task = { at = GetTime() + period, fn = fn, period = period }
        function task:Cancel() self.dead = true end
        table.insert(W.tasks, task)
        return task
    end
    function P:PerformPreviewBufferedAction()
        local ba = self.bufferedaction
        if ba ~= nil and not ba.ispreviewing then
            pc:RemoteBufferedAction(ba)
            ba.ispreviewing = true
        end
    end
    P.player_classified = {
        currentstate = { value = function() return hash(rep.state) end },
        pausepredictionframes = { value = function() return rep.pause end },
    }
    P.replica = { inventory = { GetActiveItem = function() return nil end } }
    local picker = {}
    function picker:DoGetMouseActions(_, target)
        return { action = ACTIONS[SPACE[target.kind]], target = target }
    end

    -- SGwilson_client, the parts that matter
    local states = {
        idle = { name = "idle", tags = { idle = true }, onenter = function(inst) inst.bufferedaction = nil end },
        run = { name = "run", tags = { moving = true } },
        doshortaction = {
            name = "doshortaction", tags = { doing = true, busy = true }, server_states = { [hash("doshortaction")] = true },
            onenter = function(inst)
                inst:PerformPreviewBufferedAction()
                inst.sg:SetTimeout(2)
            end,
            onupdate = function(inst)
                if inst.sg:ServerStateMatches() then
                    inst.sg:GoToState("idle", "noanim") -- FlattenMovementPrediction() assumed true
                elseif inst.bufferedaction == nil then
                    inst.sg:GoToState("idle", true)
                end
            end,
            ontimeout = function(inst)
                inst.bufferedaction = nil
                inst.sg:GoToState("idle", true)
            end,
        },
        dolongaction = {
            name = "dolongaction", tags = { doing = true, busy = true }, busy_frames = 4,
            server_states = { [hash("dolongaction")] = true },
            onenter = function(inst)
                inst:PerformPreviewBufferedAction()
                inst.sg:SetTimeout(2)
            end,
            onupdate = function(inst)
                if inst.sg:ServerStateMatches() then
                    inst.sg:GoToState("idle", "noanim")
                elseif inst.bufferedaction == nil then
                    inst.sg:GoToState("idle", true)
                end
            end,
            ontimeout = function(inst)
                inst.bufferedaction = nil
                inst.sg:GoToState("idle", true)
            end,
        },
        dig_start = {
            name = "dig_start", tags = { working = true }, server_states = { [hash("dig")] = true },
            onenter = function(inst)
                inst:PerformPreviewBufferedAction()
                inst.sg:SetTimeout(2)
            end,
            onupdate = function(inst)
                if inst.sg:ServerStateMatches() then inst.sg:GoToState("idle") end
            end,
            ontimeout = function(inst)
                W.timeouts = W.timeouts + 1
                inst.sg:GoToState("idle")
            end,
        },
        chop_start = {
            name = "chop_start", tags = { working = true }, server_states = { [hash("chop")] = true },
            onenter = function(inst)
                W.pose_from = TICK -- the "waiting for the server" pose starts
                inst:PerformPreviewBufferedAction()
                inst.sg:SetTimeout(2)
            end,
            onupdate = function(inst)
                if inst.sg:ServerStateMatches() then
                    if W.pose_from ~= nil then
                        table.insert(W.poses, TICK - W.pose_from)
                        W.pose_from = nil
                    end
                    inst.sg:GoToState("idle")
                end
            end,
            ontimeout = function(inst)
                W.timeouts = W.timeouts + 1
                inst.sg:GoToState("idle")
            end,
        },
    }
    Pipe.PatchStategraph({ states = states })
    local handlers = {
        [ACTIONS.PICKUP] = { deststate = function() return W.opt.riding and "domediumaction" or "doshortaction" end },
        [ACTIONS.CHOP] = { deststate = function() return "chop_start" end },
        [ACTIONS.DIG] = { deststate = function() return "dig_start" end },
        [ACTIONS.CHECKTRAP] = { deststate = function() return W.opt.riding and "domediumaction" or "doshortaction" end },
        [ACTIONS.HARVEST] = { deststate = function() return "dolongaction" end },
        [ACTIONS.PICK] = { deststate = function(_, action)
            local t = action.target
            if t.quick then return "doshortaction" end
            if t.noquick or not W.opt.woodie then return "dolongaction" end
            return "dowoodiefastpick"
        end },
    }
    sg = { states = states, sg = { actionhandlers = handlers } }
    function sg:GoToState(name, params)
        local st = states[name]
        self.currentstate, self.statemem, self.timeout, self.t0 = st, {}, nil, TICK
        if st.onenter then st.onenter(P, params) end
    end
    function sg:HasStateTag(t)
        local st = self.currentstate
        if t == "busy" and st.busy_frames ~= nil and TICK - self.t0 >= st.busy_frames then return false end
        return st.tags[t] == true
    end
    function sg:ServerStateMatches()
        local ss = self.currentstate.server_states
        return ss ~= nil and ss[hash(rep.state)] == true
    end
    function sg:SetTimeout(t) self.timeout = GetTime() + t end
    function sg:PreviewAction(ba)
        local long = (ba.action == ACTIONS.PICK and not ba.target.quick) or ba.action == ACTIONS.HARVEST
            or (W.opt.riding and (ba.action == ACTIONS.PICKUP or ba.action == ACTIONS.CHECKTRAP))
        self:GoToState(ba.action == ACTIONS.CHOP and "chop_start" or ba.action == ACTIONS.DIG and "dig_start"
            or long and "dolongaction" or "doshortaction")
    end
    function sg:Update()
        local st = self.currentstate
        if self.timeout ~= nil and GetTime() >= self.timeout - 1e-9 then
            self.timeout = nil
            st.ontimeout(P)
        elseif st.onupdate then
            st.onupdate(P, F)
        end
    end
    P.sg = sg

    -- PlayerController, the parts that matter
    pc = { inst = P, remote_controls = {}, locomotor = {} }
    function pc:IsBusy() return P:HasTag("busy") or P.sg:HasStateTag("busy") or rep.pause > 0 end
    function pc:IsDoingOrWorking()
        return P.sg:HasStateTag("doing") or P.sg:HasStateTag("working") or P:HasTag("doing") or P:HasTag("working")
    end
    function pc:GetActionButtonAction()
        if (self.remote_controls[CONTROL_ACTION] or 0) > 0 or self:IsBusy() or self:IsDoingOrWorking() then return nil end
        local best, bd
        for _, e in ipairs(W.ents) do
            local x, _, z = e.Transform:GetWorldPosition()
            local d = Dist(P.x, P.z, x, z)
            if d <= 6 and e.entity:IsVisible() and CanEntitySeeTarget(P, e) and not (STAYS[e.kind] and e.picked)
                and (best == nil or d < bd) then
                best, bd = e, d
            end
        end
        if best ~= nil then
            return { action = ACTIONS[SPACE[best.kind]], target = best, options = {} }
        end
    end
    function pc:RemoteActionButton(action, isreleased)
        self.remote_controls[CONTROL_ACTION] = action ~= nil and 0.5 or 0
        SendRPCToServer(RPC.ActionButton, action and action.action.code, action and action.target, isreleased)
    end
    function pc:RemoteBufferedAction(ba)
        if self.walked then
            SendRPCToServer(RPC.PredictWalking, P.x, P.z)
            self.walked = nil
        end
        ba.preview_cb()
    end
    function pc:DoActionButton()
        local ba = self:GetActionButtonAction()
        if ba ~= nil then
            ba.preview_cb = function() self:RemoteActionButton(ba, not W.space or nil) end
            P.bufferedaction = ba
            local x, _, z = ba.target.Transform:GetWorldPosition()
            if Dist(P.x, P.z, x, z) <= ARRIVE then
                P.sg:PreviewAction(ba)
            else
                P.walk_target = ba.target
            end
        end
        if self.remote_controls[CONTROL_ACTION] == nil then self:RemoteActionButton() end
    end
    function pc:OnUpdate()
        local moving = P:HasTag("idle") or P:HasTag("moving")
        for k, v in pairs(self.remote_controls) do
            self.remote_controls[k] = moving and math.max(v - F, 0) or 0
        end
        if P.sg:HasStateTag("idle") and W.space then self:DoActionButton() end
    end
    P.components = { playercontroller = pc, playeractionpicker = picker }
    Pipe.PatchController(pc)
    ThePlayer = P
    sg:GoToState("idle")
end

local function ClientMove()
    local t = P.walk_target
    if t == nil then return end
    if pc:IsBusy() then return end -- "locomote" is ignored while busy
    local st = P.sg.currentstate.name
    if st ~= "idle" and st ~= "run" then return end
    if st == "idle" then P.sg:GoToState("run") end
    local x, _, z = t.Transform:GetWorldPosition()
    local d = Dist(P.x, P.z, x, z)
    local step = RUN * F
    if d <= step then
        P.x, P.z = x, z
    else
        P.x, P.z = P.x + (x - P.x) / d * step, P.z + (z - P.z) / d * step
    end
    pc.walked = TICK
    SendRPCToServer(RPC.PredictWalking, P.x, P.z)
    if Dist(P.x, P.z, x, z) <= ARRIVE then
        P.walk_target = nil
        P.sg:PreviewAction(P.bufferedaction)
    end
end

local function ApplySnapshot(snap)
    rep.state, rep.pause = snap.state, snap.pause
    rep.tags = { busy = snap.busy, doing = snap.doing, working = snap.working, idle = snap.idle, moving = snap.moving }
    for id in pairs(snap.gone) do
        local e = W.ents[id]
        if STAYS[e.kind] then e.picked = true else e.limbo = true end
    end
    for id in pairs(snap.spawned or {}) do
        if not snap.gone[id] then W.ents[id].limbo = false end
    end
    if snap.pause_seq ~= rep.pause_seq then
        rep.pause_seq = snap.pause_seq
        P.walk_target = nil
        P:PushEvent("cancelmovementprediction")
        P.sg:GoToState("idle")
    end
end

local function ClientTick()
    while #W.down > 0 and W.down[1].arrive <= TICK do ApplySnapshot(table.remove(W.down, 1)) end
    local now = GetTime()
    for i = #W.tasks, 1, -1 do
        local task = W.tasks[i]
        if task.dead then
            table.remove(W.tasks, i)
        elseif task.at <= now + 1e-9 then
            task.fn()
            if task.period then task.at = task.at + task.period else table.remove(W.tasks, i) end
        end
    end
    pc:OnUpdate()
    ClientMove()
    P.sg:Update()
    if (TICK + W.phase) % 3 == 0 and #W.outbox > 0 then
        local arrive = math.max(TICK + Lat(), W.up_last)
        W.up_last = arrive
        table.insert(W.up, { arrive = arrive, msgs = W.outbox })
        W.outbox = {}
    end
end

---------------------------------------------------------------- layouts and the runner
local LAYOUTS = {
    saplings = function() -- a planted row, 1.2 apart
        local t = {}
        for i = 1, 8 do t[i] = { 0.3 + 1.2 * (i - 1), 0, "plant" } end
        return t
    end,
    grass = function() -- tufts a few steps apart
        local t = {}
        for i = 1, 6 do t[i] = { 2.2 * (i - 1) + 0.3, 0.6 * math.sin(i), "plant" } end
        return t
    end,
    patch = function() -- a tight patch: some need no walking at all
        local t = {}
        for i = 1, 6 do t[i] = { 0.45 * ((i - 1) % 3), 0.45 * math.floor((i - 1) / 3), "plant" } end
        return t
    end,
    carrots = function() -- quick picks (carrots, flowers, mushrooms, ferns): doshortaction
        local t = {}
        for i = 1, 8 do t[i] = { 0.3 + 0.9 * (i - 1), 0.4 * (i % 2), "plant", true } end
        return t
    end,
    meadow = function() -- grass (Woodie's quick pick) mixed with plants that take the full second
        local t = {}
        for i = 1, 8 do t[i] = { 0.3 + 1.1 * (i - 1), 0.3 * (i % 2), "plant", false, i % 3 == 0 } end
        return t
    end,
    camp = function() -- a line of rabbit traps, then crock pots, things lying around
        local t = {}
        for i = 1, 5 do t[#t + 1] = { 0.3 + 1.3 * (i - 1), 0, "trap" } end
        for i = 1, 3 do t[#t + 1] = { 6.8 + 1.4 * (i - 1), 0.5, "pot" } end
        t[#t + 1] = { 2.2, 0.7, "item" }
        t[#t + 1] = { 7.5, -0.4, "item" }
        return t
    end,
    forest = function() -- three trees of 3 hits, 2 logs falling out of each, the player next to the first
        local t = {}
        for k = 0, 2 do
            local x = 0.8 + 3.2 * k
            t[#t + 1] = { x, 0, "tree" }
            t[#t + 1] = { x - 0.4, 0.7, "item", spawn = #t }
            t[#t + 1] = { x + 0.5, 0.6, "item", spawn = #t - 1 }
        end
        return t
    end,
    tufts = function() -- digging up a row of grass tufts with a shovel: 1 hit, a dug tuft left each
        local t = {}
        for k = 0, 5 do
            t[#t + 1] = { 0.8 + 1.3 * k, 0, "tuft" }
            t[#t + 1] = { 0.8 + 1.3 * k + 0.2, 0.3, "item", spawn = #t }
        end
        return t
    end,
    mixed = function() -- bushes with things lying around them
        local t = {}
        for i = 1, 8 do t[i] = { 1.1 * (i - 1) + 0.3, (i % 2) * 0.5, i % 2 == 1 and "plant" or "item" } end
        return t
    end,
    pile = function() -- a pile under the player: no walking between items
        local t = {}
        for i = 1, 8 do t[i] = { 0.25 * math.cos(i), 0.25 * math.sin(i) } end
        return t
    end,
    trail = function() -- a line of items 1.2 apart
        local t = {}
        for i = 1, 10 do t[i] = { 0.3 + 1.2 * (i - 1), 0 } end
        return t
    end,
    trees = function() -- what is left around felled trees: 3 heaps of 4 items, a few steps apart
        local t = {}
        for c = 0, 2 do
            local cx = 4.5 * c
            for k = 1, 4 do
                table.insert(t, { cx + 0.9 * math.cos(k * 1.7 + c), 0.9 * math.sin(k * 1.7 + c) })
            end
        end
        return t
    end,
}

local function Run(opt)
    PING_MS = opt.reported_ping or opt.ping -- what GetAveragePing says; the network has opt.ping
    math.randomseed(opt.seed or 1)
    W = { opt = opt, items = {}, ents = {}, outbox = {}, up = {}, up_last = 0, down = {}, down_last = 0,
        tasks = {}, refused = {}, refused_n = 0, cancelled = 0, interrupted = 0, picks = {}, sent = { click = 0, button = 0 },
        timeouts = 0, space = true, clicks = 0, poses = {}, phase = math.random(0, 2),
        sv = { x = -(opt.server_behind or 0), z = 0, state = "idle", t0 = 0, busy = false, doing = false, pause = 0,
            pause_seq = 0 } }
    W.opt.jitter = W.opt.jitter or 0
    W.opt.long = W.opt.long or 18
    local spots = LAYOUTS[opt.layout or "pile"]()
    for i, p in ipairs(spots) do
        W.items[i] = { id = i, x = p[1], z = p[2], kind = p[3] or "item", quick = p[4], noquick = p[5], spawn = p.spawn,
            hits = p[3] == "tree" and 3 or 1 }
    end
    if opt.tree then
        local last = spots[#spots]
        local id = #spots + 1
        W.items[id] = { id = id, x = last[1] + 1.5, z = last[2], kind = "tree", hits = 1 }
    end
    for i, it in ipairs(W.items) do
        W.ents[i] = ClientEntity(it)
        if it.spawn ~= nil then W.ents[i].limbo = true end
    end
    TICK = 0
    MakeClient()
    Pipe.enabled = opt.fast ~= false
    Pipe.margin = opt.margin or 4
    Pipe.notify = function(kind, text) print(string.format("%5d  client %-5s %s", TICK, kind, text)) end
    Pipe.Start(P)
    for path, frames in pairs(opt.long_known or {}) do Pipe._state().long[path] = frames end -- measured before
    local n_items = 0
    for _, it in pairs(W.items) do
        if WORK[it.kind] == nil and it.kind ~= "tree" then n_items = n_items + 1 end
    end
    local done_at
    for tick = 1, opt.ticks or 900 do
        TICK = tick
        if opt.release_at == tick then W.space = false end
        ServerTick()
        ClientTick()
        local all = #W.picks == n_items
        for _, it in pairs(W.items) do
            if WORK[it.kind] ~= nil and not it.chopped then all = false end
        end
        if all and done_at == nil then done_at = tick end
        if done_at ~= nil and tick > done_at + 60 then break end
    end
    local st = Pipe._state()
    local hidden = 0
    for _, e in ipairs(W.ents) do
        if e.hidden and not e.limbo then hidden = hidden + 1 end
    end
    local r = { picked = #W.picks, n = n_items, refused = W.refused_n, reasons = W.refused, cancelled = W.cancelled,
        interrupted = W.interrupted, long = st.long, longs = st.long,
        lost = st.total_lost, hidden = hidden, sent = W.sent, timeouts = W.timeouts, extra = st.extra,
        chopped = opt.tree and W.items[#W.items].chopped or nil, done_at = done_at,
        waits = st.period.waits, jitter = st.jitter, poses = W.poses }
    if #W.picks > 1 then
        r.ms = (W.picks[#W.picks] - W.picks[1]) / (#W.picks - 1) * F * 1000
    end
    Pipe.Stop(P)
    return r
end

---------------------------------------------------------------- checks
if rawget(_G, "PIPE_SIM_LIB") then return Run end -- for experiments: the runner only
local passes, fails = 0, 0
local function check(cond, what)
    if cond then
        passes = passes + 1
        real_print("  ok    " .. what)
    else
        fails = fails + 1
        real_print("  FAIL  " .. what)
    end
end
local function ms(r) return r.ms ~= nil and math.floor(r.ms + 0.5) or -1 end
local function Reasons(r)
    local parts = {}
    for k, v in pairs(r.reasons) do table.insert(parts, k .. " " .. v) end
    return table.concat(parts, ", ")
end
local function Clean(r)
    return r.picked == r.n and r.refused == 0 and r.cancelled == 0 and r.interrupted == 0 and r.lost == 0 and r.hidden == 0
end

real_print("[the game, without fast chains: does the model match the logs?]")
do
    local r = Run({ ping = 160, layout = "pile", fast = false })
    real_print(string.format("        pile at 160 ms: %d ms per item (the logs: 600 for items side by side)", ms(r)))
    check(r.picked == 8 and r.ms > 520 and r.ms < 680, "items side by side: about 600 ms each, like in the logs")
    check(r.refused == 0 and r.sent.click == 0, "  no refused requests, no LeftClick")
    local t = Run({ ping = 160, layout = "trees", fast = false })
    real_print(string.format("        heaps at 160 ms: %d ms per item (the logs: 720..870 with short walks)", ms(t)))
    check(t.picked == 12 and t.ms > 650 and t.ms < 950, "heaps with short walks: 700..900 ms each")
end

real_print("[fast chains at 160 ms]")
local base = {}
for _, layout in ipairs({ "pile", "trail", "trees" }) do
    local slow = Run({ ping = 160, layout = layout, fast = false })
    local fast = Run({ ping = 160, layout = layout })
    base[layout] = { slow = slow, fast = fast }
    real_print(string.format("        %-5s: %4d -> %4d ms per item (x%.2f); %d LeftClick, %d ActionButton",
        layout, ms(slow), ms(fast), slow.ms / fast.ms, fast.sent.click, fast.sent.button))
    check(Clean(fast), layout .. ": every item picked up, nothing refused, dropped or left hidden")
end
check(base.pile.fast.ms < 400, "pile: one item every ~11 frames (367 ms)")
check(base.trail.slow.ms / base.trail.fast.ms > 1.6, "trail: at least 1.6x faster")
check(base.trees.slow.ms / base.trees.fast.ms > 1.5, "heaps: at least 1.5x faster")

real_print("[other pings]")
for _, ping in ipairs({ 60, 270, 400 }) do
    local slow = Run({ ping = ping, layout = "trees", fast = false })
    local fast = Run({ ping = ping, layout = "trees" })
    real_print(string.format("        %3d ms: %4d -> %4d ms per item (x%.2f)", ping, ms(slow), ms(fast), slow.ms / fast.ms))
    check(Clean(fast) and fast.ms < slow.ms, ping .. " ms: clean and faster")
end

real_print("[a sweep: pings 40..400, jitter, random upload phase, 3 layouts, 12 seeds each]")
for _, jitter in ipairs({ 0, 10, 25 }) do
    local runs, dirty, all_picked, worst = 0, 0, true, ""
    for _, ping in ipairs({ 40, 100, 160, 220, 270, 400 }) do
        for _, layout in ipairs({ "pile", "trail", "trees" }) do
            for seed = 1, 12 do
                local r = Run({ ping = ping, layout = layout, jitter = jitter, seed = seed, ticks = 1500 })
                runs = runs + 1
                if r.picked ~= r.n or r.hidden > 0 then all_picked = false end
                if r.refused + r.cancelled + r.lost > 0 then
                    dirty = dirty + 1
                    worst = string.format("%d ms %s seed %d: refused %d (%s), dropped walks %d, lost %d", ping, layout, seed,
                        r.refused, Reasons(r), r.cancelled, r.lost)
                end
            end
        end
    end
    real_print(string.format("        jitter +-%d ms: %d runs, %d with a refused/dropped request%s", jitter, runs, dirty,
        dirty > 0 and ("; e.g. " .. worst) or ""))
    check(all_picked, string.format("jitter +-%d ms: every item picked up in every run, none left hidden", jitter))
    if jitter <= 10 then check(dirty == 0, string.format("  jitter +-%d ms: never a refused or dropped request", jitter)) end
end

real_print("[when the server does drop a request]")
do
    local r = Run({ ping = 160, layout = "pile", drop_click = 3, ticks = 1500 })
    check(r.refused == 1 and r.lost == 1, "the item the server never picked up is noticed")
    check(r.picked == r.n and r.hidden == 0, "  it comes back and is picked up after all")
    check(r.extra == 1, "  and the margin grows by a frame")
end

real_print("[interruptions]")
do
    local r = Run({ ping = 160, layout = "pile", hit_at = 40, ticks = 1500 })
    check(r.picked == r.n and r.hidden == 0, "hit in the middle of a chain: everything picked up, nothing left hidden")
    check(r.lost == 0, "  a pickup the hit cancelled is not counted as lost")
    local q = Run({ ping = 160, layout = "trail", release_at = 50, ticks = 400 })
    check(q.picked < q.n and q.picked > 0 and q.hidden == 0 and q.refused == 0,
        string.format("Space released after a few items: stops cleanly (%d picked)", q.picked))
    local t = Run({ ping = 160, layout = "trees", tree = true, ticks = 1500 })
    check(t.picked == t.n and t.chopped and t.refused == 0 and t.timeouts == 0,
        "a tree right after the chain: CHOP waits for the server to be done, not refused")
end

real_print("[picking plants: grass, saplings, bushes (dolongaction)]")
do
    for _, long in ipairs({ 18, 30 }) do
        local r = Run({ ping = 160, layout = "saplings", long = long, ticks = 2000 })
        local got = r.long.dolongaction
        check(got ~= nil and math.abs(got - long) <= 1,
            string.format("the length of a long action is measured: %s frames (the server: %d)", tostring(got), long))
    end
    local first = Run({ ping = 160, layout = "grass", ticks = 2000 })
    check(Clean(first) and first.sent.button >= 1, "the first one is the game's own (measured), then the chain")
    local results = {}
    for _, ping in ipairs({ 160, 270 }) do
        for _, layout in ipairs({ "saplings", "grass", "patch", "mixed" }) do
            local slow = Run({ ping = ping, layout = layout, fast = false, ticks = 2000 })
            local fast = Run({ ping = ping, layout = layout, ticks = 2000 })
            results[ping .. layout] = slow.ms / fast.ms
            real_print(string.format("        %3d ms %-8s: %4d -> %4d ms per plant (x%.2f)", ping, layout, ms(slow), ms(fast),
                slow.ms / fast.ms))
            check(Clean(fast), string.format("%d ms %s: everything picked, nothing refused or cancelled", ping, layout))
        end
    end
    check(results["160saplings"] > 1.1 and results["160grass"] > 1.1 and results["160mixed"] > 1.25,
        "160 ms: plants 10%+ faster, plants with items around 25%+")
    check(results["270saplings"] > 1.2 and results["270grass"] > 1.2, "270 ms: plants 20%+ faster")
    for _, ping in ipairs({ 60, 160 }) do
        local slow = Run({ ping = ping, layout = "carrots", fast = false, ticks = 2000 })
        local fast = Run({ ping = ping, layout = "carrots", ticks = 2000 })
        real_print(string.format("        %3d ms carrots : %4d -> %4d ms per plant (x%.2f)", ping, ms(slow), ms(fast), slow.ms / fast.ms))
        check(Clean(fast) and slow.ms / fast.ms > (ping >= 160 and 1.5 or 1.2),
            string.format("%d ms quick picks (carrots, flowers...): like items, clean", ping))
    end
    local low = Run({ ping = 60, layout = "patch", ticks = 2000 })
    local low_slow = Run({ ping = 60, layout = "patch", fast = false, ticks = 2000 })
    check(low.sent.click == 0 and math.abs(low.ms - low_slow.ms) < 1,
        "below 80 ms plants are left to the game (no faster that way)")
end

real_print("[other Space actions: checking traps (short), harvesting crock pots (long, 1 s), items around]")
do
    for _, ping in ipairs({ 160, 270 }) do
        local slow = Run({ ping = ping, layout = "camp", fast = false, ticks = 3000 })
        local fast = Run({ ping = ping, layout = "camp", ticks = 3000 })
        real_print(string.format("        %3d ms camp    : %4d -> %4d ms per thing (x%.2f); %d LeftClick", ping, ms(slow), ms(fast),
            slow.ms / fast.ms, fast.sent.click))
        check(Clean(fast) and fast.ms < slow.ms, string.format("%d ms: traps, pots and items in one chain: clean and faster", ping))
    end
end

real_print("[riding: pickups and traps go through domediumaction (0.5 s)]")
do
    for _, layout in ipairs({ "trees", "camp" }) do
        local slow = Run({ ping = 200, layout = layout, riding = true, fast = false, ticks = 3000 })
        local fast = Run({ ping = 200, layout = layout, riding = true, ticks = 3000 })
        real_print(string.format("        200 ms %-6s: %4d -> %4d ms per thing (x%.2f), domediumaction measured %s frames",
            layout, ms(slow), ms(fast), slow.ms / fast.ms, tostring(fast.long.domediumaction)))
        check(Clean(fast) and fast.ms < slow.ms, "riding, " .. layout .. ": clean and faster")
    end
end

real_print("[ways into the long action: Woodie's quick pick and the full second, in one chain]")
do
    local r = Run({ ping = 160, layout = "meadow", woodie = true, long = 17, ticks = 2500 })
    real_print(string.format("        measured: dowoodiefastpick %s frames, dolongaction %s frames",
        tostring(r.long.dowoodiefastpick), tostring(r.long.dolongaction)))
    check(r.long.dowoodiefastpick ~= nil and math.abs(r.long.dowoodiefastpick - 17) <= 1
        and r.long.dolongaction ~= nil and math.abs(r.long.dolongaction - 30) <= 1, "each way is measured on its own")
    check(Clean(r), "  and a chain mixing them never cancels a pick")
end

real_print("[the server still walking when the chain starts (seen in the logs: a berry bush, ~8 frames)]")
do
    local Pipe = require("blc/pipeline")
    for _, layout in ipairs({ "pile", "trail", "saplings", "patch" }) do
        local known = { dolongaction = 18 } -- plants: a later chain, the length already measured
        Pipe.anchor = false
        local bad = Run({ ping = 160, layout = layout, server_behind = 2.4, long_known = known, ticks = 2500 })
        Pipe.anchor = true
        local good = Run({ ping = 160, layout = layout, server_behind = 2.4, long_known = known, ticks = 2500 })
        real_print(string.format("        %-8s: without waiting for the server's start: refused %d, cancelled picks %d, lost %d;"
            .. " with: %d, %d, %d", layout, bad.refused, bad.interrupted + bad.cancelled, bad.lost, good.refused,
            good.interrupted + good.cancelled, good.lost))
        check(Clean(good), layout .. ": the chain waits for the server's real start: clean")
    end
end

real_print("[plants: a sweep, pings 80..400, jitter, long actions of 18 and 30 frames]")
do
    local runs, dirty, worst = 0, 0, ""
    for _, jitter in ipairs({ 0, 10, 25 }) do
        for _, ping in ipairs({ 80, 160, 270, 400 }) do
            for _, layout in ipairs({ "saplings", "grass", "patch", "mixed" }) do
                for _, long in ipairs({ 18, 30 }) do
                    for seed = 1, 5 do
                        local r = Run({ ping = ping, layout = layout, jitter = jitter, seed = seed, long = long, ticks = 2500 })
                        runs = runs + 1
                        if not Clean(r) then
                            dirty = dirty + 1
                            worst = string.format("%d ms %s jitter %d T %d seed %d: cancelled picks %d, refused %d, lost %d",
                                ping, layout, jitter, long, seed, r.interrupted, r.refused, r.lost)
                        end
                    end
                end
            end
        end
    end
    real_print(string.format("        %d runs, %d with a cancelled/refused/lost one%s", runs, dirty,
        dirty > 0 and ("; e.g. " .. worst) or ""))
    check(dirty == 0, "never a cancelled pick, a refused request or a lost plant")
end

real_print("[tool work: the last hit done, the next while the server finishes the swing]")
do
    for _, layout in ipairs({ "forest", "tufts" }) do
        for _, ping in ipairs({ 160, 270 }) do
            local slow = Run({ ping = ping, layout = layout, fast = false, ticks = 4000 })
            local fast = Run({ ping = ping, layout = layout, ticks = 4000 })
            real_print(string.format("        %3d ms %-6s: all done in %5.2f -> %5.2f s (x%.2f), swings cut %d", ping, layout,
                slow.done_at / 30, fast.done_at / 30, slow.done_at / fast.done_at, fast.waits.tails))
            check(Clean(fast) and fast.waits.tails > 0 and slow.done_at / fast.done_at > 1.25 and fast.timeouts == 0,
                string.format("%d ms %s: clean, 25%%+ faster", ping, layout))
        end
    end
    local runs, dirty = 0, 0
    for _, jitter in ipairs({ 0, 25 }) do
        for _, ping in ipairs({ 60, 160, 270, 400 }) do
            for _, layout in ipairs({ "forest", "tufts" }) do
                for seed = 1, 6 do
                    local r = Run({ ping = ping, layout = layout, jitter = jitter, seed = seed, ticks = 5000 })
                    runs = runs + 1
                    if not Clean(r) or r.done_at == nil then dirty = dirty + 1 end
                end
            end
        end
    end
    real_print(string.format("        sweep: %d runs, %d not clean", runs, dirty))
    check(dirty == 0, "pings 60..400, jitter up to 25 ms: always clean")
end

real_print("[a tree right after a chain: the waiting pose before the first swing]")
do
    for _, ping in ipairs({ 160, 270 }) do
        local slow = Run({ ping = ping, layout = "trees", tree = true, fast = false, ticks = 3000 })
        local fast = Run({ ping = ping, layout = "trees", tree = true, ticks = 3000 })
        local a, b = slow.poses[1] or 0, fast.poses[1] or 99
        real_print(string.format("        %3d ms: pose %d ms (the game) -> %d ms; tree done at frame %d -> %d", ping,
            math.floor(a * 1000 / 30 + 0.5), math.floor(b * 1000 / 30 + 0.5), slow.done_at, fast.done_at))
        check(b <= a + 2 and fast.done_at < slow.done_at and Clean(fast),
            ping .. " ms: the pose is no longer than in the game, the tree is done sooner")
    end
end

real_print("[the ping the game reports is off (it is an average; the real one jumps)]")
do
    for _, case in ipairs({ { 160, 260 }, { 260, 160 }, { 160, 100 } }) do
        local r = Run({ ping = case[1], reported_ping = case[2], layout = "trees", ticks = 3000 })
        local plants = Run({ ping = case[1], reported_ping = case[2], layout = "saplings", long_known = { dolongaction = 18 },
            ticks = 3000 })
        real_print(string.format("        real %d, reported %d: items %d ms, start seen late %d, not seen %d; saplings %d ms, not seen %d",
            case[1], case[2], ms(r), r.waits.start.n, r.waits.unseen, ms(plants), plants.waits.unseen))
        check(Clean(r) and Clean(plants) and r.waits.unseen == 0 and plants.waits.unseen == 0 and r.ms < 520,
            string.format("real %d / reported %d ms: the start of the chain is always recognised", case[1], case[2]))
    end
end

real_print("[the jitter buffer]")
do
    local calm = Run({ ping = 160, layout = "trees", jitter = 0, ticks = 3000 })
    local shaky = Run({ ping = 160, layout = "trees", jitter = 45, seed = 2, ticks = 3000 })
    real_print(string.format("        jitter 0: buffer %d frames, %d ms per item; jitter +-45 ms: buffer %d frames, %d ms per item",
        calm.jitter, ms(calm), shaky.jitter, ms(shaky)))
    check(calm.jitter == 0, "a steady connection: no buffer")
    check(shaky.jitter > 0, "  a shaky one: the buffer grows by itself")
end

real_print("[off]")
do
    local r = Run({ ping = 160, layout = "trees", fast = false })
    check(r.sent.click == 0 and r.picked == r.n and r.refused == 0, "fast chains off: the game's own requests only")
end

real_print(string.format("\n%d passed, %d failed", passes, fails))
if fails > 0 then os.exit(1) end

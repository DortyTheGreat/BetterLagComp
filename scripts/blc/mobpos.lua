-- Future view of mob positions: a mob that targets you is shown where the server will have it when
-- your input gets there: its last position from the server plus its velocity times the round trip.
-- A chasing bee on screen is speed x ping behind where it is: 1-2 units at 160 ms.
--
-- How the engine treats a position the client sets on a networked mob is not known from the
-- scripts. So first a check (probe 3, once a session): a mob standing still is moved 0.5 and
-- watched for 6 frames, then put back:
--   held   the position stays until the server's next one: set ours, keep the server's apart
--   frame  the engine puts it back at once: it writes positions every frame, ours is set every
--          frame after it
--   pulls  it creeps back: the engine moves from wherever the mob is, ours would build up: off
-- The velocity comes only from positions the server sent (a change the client did not make), a
-- mob with no new position for 0.2 s is standing, the shift is at most 2.5. If the speeds start to
-- look impossible (our shift leaking into what the engine gives back) it turns itself off and puts
-- the mobs back. Off with F8 too: the mobs jump back to the server's positions.
local Util = require("blc/util")

local MP = { enabled = true }

local F = rawget(_G, "FRAMES") or 1 / 30
local MAX_AHEAD = 3.5 -- units
local STALE = 0.2 -- seconds with no new position from the server: it is standing
local MAX_SPEED = 14 -- units/s: faster for long, and our shift is leaking back
local JUMP_SPEED = 40 -- units/s: a jump (spawned, teleported): start again
local PROBE_SHIFT = 0.5
local PROBE_STILL = 0.6 -- seconds a mob must stand still to be probed
local PROBE_WATCH = 12 -- frames watched

local st = { mode = nil, tries = 0, next = 0, mobs = setmetatable({}, { __mode = "k" }), shown = 0, most = 0 }

local function Note(text)
    if MP.notify ~= nil then MP.notify("probe", text) end
end

local function Mob(e)
    local ms = st.mobs[e]
    if ms == nil then
        ms = { vx = 0, vz = 0, fast = 0 }
        st.mobs[e] = ms
    end
    return ms
end

-- put a mob back where the server last had it
local function Restore(e, ms)
    if ms.qx == nil then return end
    if st.mode == "pull" then -- the engine slides it back to its target by itself
        ms.qx, ms.qz = nil, nil
        return
    end
    if e:IsValid() and ms.ex ~= nil then
        local _, y = e.Transform:GetWorldPosition()
        e.Transform:SetPosition(ms.ex, y, ms.ez)
    end
    ms.qx, ms.qz = nil, nil
end

local function RestoreAll()
    for e, ms in pairs(st.mobs) do Restore(e, ms) end
end

---------------------------------------------------------------- probe 3

local function Fmt(list)
    local out = {}
    for i, d in ipairs(list) do out[i] = string.format("%.2f", d) end
    return table.concat(out, " ")
end

-- what the engine did with the shift, from where the mob was each frame since (the server sends
-- nothing new for a mob standing still)
local function Judge(p)
    local d = p.d
    if math.abs(d[1]) < 0.01 then return "frame" end
    local held = true
    for _, v in ipairs(d) do
        if math.abs(v - PROBE_SHIFT) > 0.01 then held = false end
    end
    if held then return "held" end
    -- pulled back: by the same share of what is left every frame?
    local ratios = {}
    for k = 2, #d do
        if d[k - 1] > 0.03 then table.insert(ratios, d[k] / d[k - 1]) end
    end
    local first = d[1] / PROBE_SHIFT
    if #ratios >= 2 then
        table.sort(ratios)
        local med = ratios[math.floor((#ratios + 1) / 2)]
        local same = math.abs(first - med) < 0.1
        for _, r in ipairs(ratios) do
            if math.abs(r - med) > 0.1 then same = false end
        end
        if same and med > 0.05 and med < 0.9 then
            -- the share over all the frames watched (single frames are uneven)
            local n = #d
            while n > 1 and d[n] < 0.03 do n = n - 1 end
            local r = n > 1 and (d[n] / d[1]) ^ (1 / (n - 1)) or med
            st.pull = 1 - r
            -- moving that way, the engine's mob is (1 - share) / share frames behind its target
            st.lag = (1 - st.pull) / st.pull * F
            return "pull"
        end
    end
    return "pulls"
end

local function Probe(view, now)
    local p = st.probe
    if p ~= nil then
        local e = p.mob
        if not e:IsValid() then st.probe = nil return end
        local x, _, z = e.Transform:GetWorldPosition()
        if math.abs(z - p.z0) > 0.01 or x > p.x0 + PROBE_SHIFT + 0.01 or x < p.x0 - 0.01 then
            st.probe, st.next = nil, now + 3 -- it moved by itself: no answer, another time
            e.Transform:SetPosition(p.x0, p.y0, p.z0)
            return
        end
        table.insert(p.d, x - p.x0)
        if #p.d < PROBE_WATCH and not (#p.d == 1 and math.abs(p.d[1]) < 0.01) then return end
        st.probe = nil
        local result = Judge(p)
        if result ~= "frame" then e.Transform:SetPosition(p.x0, p.y0, p.z0) end -- back where it was
        st.mode = result
        local text
        if result == "held" then
            text = "3: a mob's position set here stays until the server's next one: mobs that target you are shown ahead"
        elseif result == "frame" then
            text = "3: the engine put the mob back at once (it writes positions every frame): ours is set every frame "
                .. "after it; if F8 shows no jump, the engine draws its own and this does nothing"
        elseif result == "pull" then
            text = string.format("3: the engine pulls a mob towards its position from the server by %d%% of the way a "
                .. "frame (%s): a moving mob is drawn %d ms behind its position from the server on top of the ping; "
                .. "mobs that target you are shown ahead by both", math.floor(st.pull * 100 + 0.5), Fmt(p.d),
                math.floor(st.lag * 1000 + 0.5))
        else
            text = "3: the engine moves a mob back from where it is, not by a share of the way a frame (" .. Fmt(p.d)
                .. "): a shift would build up: mob positions are left alone"
        end
        Note(text)
        return
    end
    if st.mode ~= nil or st.tries >= 4 or now < st.next then return end
    for e, m in pairs(view.mobs) do
        local ms = Mob(e)
        if not m.onme and e:IsValid() and ms.still ~= nil and now - ms.still >= PROBE_STILL then
            local x, y, z = e.Transform:GetWorldPosition()
            st.tries, st.next = st.tries + 1, now + 1
            st.probe = { mob = e, x0 = x, y0 = y, z0 = z, d = {} }
            e.Transform:SetPosition(x + PROBE_SHIFT, y, z)
            Note(string.format("3: moving %s#%s's position %.1f to see what the engine does with it",
                tostring(e.prefab), tostring(e.GUID), PROBE_SHIFT))
            return
        end
    end
end

---------------------------------------------------------------- the shift

local function Ahead(e, ms, lead, now)
    local x, y, z = e.Transform:GetWorldPosition()
    -- a new position from the server (or the engine's own, every frame): not the one set here, and
    -- not the same one written again
    local fresh = (ms.qx == nil or math.abs(x - ms.qx) > 1e-3 or math.abs(z - ms.qz) > 1e-3)
        and (ms.ex == nil or math.abs(x - ms.ex) > 1e-3 or math.abs(z - ms.ez) > 1e-3)
    if fresh then
        if ms.ex ~= nil and now > ms.et then
            local dt = now - ms.et
            -- did the engine start from what was set here? Then the new position leans towards
            -- our shift, against where its own track says it would be (a clean one does not)
            local olen = math.sqrt((ms.ox or 0) ^ 2 + (ms.oz or 0) ^ 2)
            if ms.qx ~= nil and olen > 0.3 then
                local px, pz = ms.ex + ms.vx * dt, ms.ez + ms.vz * dt
                local lean = ((x - px) * ms.ox + (z - pz) * ms.oz) / (olen * olen)
                ms.lean = 0.8 * (ms.lean or 0) + 0.2 * lean
                ms.leans = (ms.leans or 0) + 1
                if ms.leans >= 6 and ms.lean > 0.3 then return "leak" end
            end
            local vx, vz = (x - ms.ex) / dt, (z - ms.ez) / dt
            if math.sqrt(vx * vx + vz * vz) > JUMP_SPEED then
                ms.vx, ms.vz = 0, 0
            else
                ms.vx, ms.vz = 0.5 * (ms.vx + vx), 0.5 * (ms.vz + vz)
            end
        end
        ms.ex, ms.ez, ms.et = x, z, now
    end
    if now - ms.et > STALE then ms.vx, ms.vz = 0, 0 end
    -- impossible speeds for a while: our shift is coming back to us
    if math.sqrt(ms.vx * ms.vx + ms.vz * ms.vz) > MAX_SPEED then
        ms.fast = ms.fast + 1
        if ms.fast > 10 then return "leak" end
    else
        ms.fast = 0
    end
    local ahead = lead + (now - ms.et)
    local ox, oz = ms.vx * ahead, ms.vz * ahead
    local len = math.sqrt(ox * ox + oz * oz)
    if len > MAX_AHEAD then ox, oz, len = ox * MAX_AHEAD / len, oz * MAX_AHEAD / len, MAX_AHEAD end
    if len < 0.02 and ms.qx == nil then return end -- standing: nothing to show
    ms.ox, ms.oz = ox, oz
    ms.qx, ms.qz = ms.ex + ox, ms.ez + oz
    e.Transform:SetPosition(ms.qx, y, ms.qz)
    st.shown = st.shown + 1
    st.most = math.max(st.most, len)
end

-- "pull": the engine moves the mob a share of the way to its target every frame, from wherever it
-- is. Dividing what it did by that share gives the target, but the share is not steady (frame
-- times are not), and the error comes out times the shift over the share: the mob jumps about a
-- unit each frame. So instead a model of where the engine would have the mob without us (u),
-- moved by what it did to ours plus the share of the gap between ours and the model: an error in
-- the share only biases the shift a little, it does not throw the mob about. The velocity is the
-- model's, smoothed: no 15-a-second steps in it.
local function AheadPull(e, ms, lead, now)
    local x, y, z = e.Transform:GetWorldPosition()
    local a = st.pull
    if ms.qx == nil or ms.ux == nil then
        ms.ux, ms.uz = x, z -- nothing of ours in it
    else
        ms.ux = ms.ux + (x - ms.qx) + a * (ms.qx - ms.ux)
        ms.uz = ms.uz + (z - ms.qz) + a * (ms.qz - ms.uz)
    end
    -- the velocity over the last few frames of the model (one frame's is noisy), smoothed
    ms.hist = ms.hist or {}
    table.insert(ms.hist, { ms.ux, ms.uz, now })
    if #ms.hist > 5 then table.remove(ms.hist, 1) end
    local h = ms.hist[1]
    if #ms.hist >= 3 and now > h[3] then
        local dt = now - h[3]
        local vx, vz = (ms.ux - h[1]) / dt, (ms.uz - h[2]) / dt
        if math.sqrt(vx * vx + vz * vz) > JUMP_SPEED then
            ms.vx, ms.vz, ms.hist = 0, 0, {}
        else
            local k = math.min(1, F / 0.12)
            ms.vx, ms.vz = ms.vx + k * (vx - ms.vx), ms.vz + k * (vz - ms.vz)
        end
    end
    if math.sqrt(ms.vx * ms.vx + ms.vz * ms.vz) > MAX_SPEED then
        ms.fast = ms.fast + 1
        if ms.fast > 10 then return "leak" end
    else
        ms.fast = 0
    end
    -- the round trip, and the engine's own smoothing behind its target on top
    local ahead = lead + (st.lag or 0)
    local ox, oz = ms.vx * ahead, ms.vz * ahead
    local len = math.sqrt(ox * ox + oz * oz)
    if len > MAX_AHEAD then ox, oz, len = ox * MAX_AHEAD / len, oz * MAX_AHEAD / len, MAX_AHEAD end
    -- the shift itself eased (a turn moves it over a few frames, not in one)
    local k = math.min(1, F / 0.1)
    ox, oz = (ms.sx or 0) + k * (ox - (ms.sx or 0)), (ms.sz or 0) + k * (oz - (ms.sz or 0))
    ms.sx, ms.sz = ox, oz
    len = math.sqrt(ox * ox + oz * oz)
    if len < 0.05 then
        ms.qx, ms.qz = nil, nil -- standing: leave it to the engine
        return
    end
    ms.qx, ms.qz = ms.ux + ox, ms.uz + oz
    e.Transform:SetPosition(ms.qx, y, ms.qz)
    st.shown = st.shown + 1
    st.most = math.max(st.most, len)
end

function MP.Update(CL, now)
    local view = CL.View()
    if view == nil then return end
    -- standing still (for the probe), from what the engine gives
    for e in pairs(view.mobs) do
        local ms = Mob(e)
        if ms.qx == nil and e:IsValid() then
            local x, _, z = e.Transform:GetWorldPosition()
            if ms.lx == nil or math.abs(x - ms.lx) > 1e-3 or math.abs(z - ms.lz) > 1e-3 then ms.still = now end
            ms.lx, ms.lz = x, z
        end
    end
    Probe(view, now)
    local Pipe = package.loaded["blc/pipeline"]
    local on = MP.enabled and (Pipe == nil or Pipe.enabled) and (st.mode == "held" or st.mode == "frame" or st.mode == "pull")
    local lead = CL.Lead()
    for e, ms in pairs(st.mobs) do
        local m = view.mobs[e]
        if not e:IsValid() then
            st.mobs[e] = nil
        elseif on and m ~= nil and m.onme then
            if (st.mode == "pull" and AheadPull or Ahead)(e, ms, lead, now) == "leak" then
                st.mode = "pulls"
                RestoreAll()
                Note("3: positions from the engine lean towards the shift shown here (it moves a mob from where "
                    .. "it is shown): mob positions are left alone from now on")
                return
            end
        else
            Restore(e, ms)
        end
    end
end

function MP.Clear()
    RestoreAll()
    st.probe = nil
end

-- for the minute summary
function MP.TakePeriod()
    local shown, most = st.shown, st.most
    st.shown, st.most = 0, 0
    return { mode = st.mode, shown = shown, most = most }
end

function MP._state() return st end
function MP._reset() st = { mode = nil, tries = 0, next = 0, mobs = setmetatable({}, { __mode = "k" }), shown = 0, most = 0 } end
function MP.Mode() return st.mode, st.pull end

return MP

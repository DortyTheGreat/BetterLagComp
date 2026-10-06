-- Hits on your time line. With the future view your swing is on your time line, but what it hits
-- reacted only when the server's reaction arrived, a round trip later. Now the reaction is shown
-- when your swing lands on screen (the frame the server performs the action: SGwilson chop 2,
-- mine 7), as the game's own code does it on the server:
--   evergreens (prefabs/evergreens.lua chop_tree): the chop shake of its stage, then sway; the
--     needles (not twiggy trees); the chop sound (the werebeaver's own)
--   rocks (commonstates.lua PlayMiningFX): the dust (ice, moon glass, crystal ones too); the
--     pick sound
-- The server's copies, a round trip later, are kept from showing twice: its shake is moved to
-- where ours is (the engine keeps an animation's time), its effect's picture is not made (an
-- effect from fx.lua is a networked proxy whose picture each client makes a frame later: that
-- task is skipped), its sound is muted on the one playing it (the tree; you, for the pick, while
-- you stand mining). A tree that falls while muted gets its fall sound from here.
local Util = require("blc/util")

local Impact = { enabled = true }

local F = rawget(_G, "FRAMES") or 1 / 30
local WINDOW = 0.7 -- seconds past the round trip in which the server's copy of a hit is expected
local STAGES = { "short", "normal", "tall" }
local TREE_BUILDS = { normal = true, sparse = true, twiggy = true }
-- the effects whose server copies are matched (also given to AddPrefabPostInit)
Impact.FX = { "pine_needles_chop", "mining_fx", "mining_ice_fx", "mining_moonglass_fx", "mining_crystal_fx" }

local s = nil

local function Now() return Util.Now() end

local function Note(text)
    if Impact.notify ~= nil then Impact.notify("impact", text) end
end

local function Lead()
    local Future = package.loaded["blc/future"]
    return Future ~= nil and Future.Lead ~= nil and Future.Lead() or 0.2
end

---------------------------------------------------------------- what is shown here

local fxdefs = nil
local function FxDef(name)
    if fxdefs == nil then
        fxdefs = {}
        local ok, list = pcall(require, "fx")
        if ok and type(list) == "table" then
            for _, t in ipairs(list) do
                if type(t) == "table" and t.name ~= nil then fxdefs[t.name] = t end
            end
        end
    end
    return fxdefs[name]
end

-- an effect's picture, made the way fx.lua makes it on a client
local function LocalFx(name, x, y, z)
    local t = FxDef(name)
    if t == nil or t.bank == nil or t.build == nil or t.anim == nil then return nil end
    local inst = CreateEntity()
    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst:AddTag("FX")
    inst:AddTag("NOCLICK")
    inst.entity:SetCanSleep(false)
    inst.persists = false
    inst.Transform:SetPosition(x, y, z)
    inst.AnimState:SetBank(t.bank)
    inst.AnimState:SetBuild(t.build)
    inst.AnimState:PlayAnimation(type(t.anim) == "function" and t.anim() or t.anim)
    if t.transform ~= nil and t.transform.Get ~= nil then inst.AnimState:SetScale(t.transform:Get()) end
    if t.bloom then inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh") end
    inst:ListenForEvent("animover", inst.Remove)
    inst:DoTaskInTime(3, inst.Remove)
    return inst
end

local function LocalSound(x, y, z, sound)
    local inst = CreateEntity()
    inst.entity:AddTransform()
    inst.entity:AddSoundEmitter()
    inst.entity:SetCanSleep(false)
    inst.persists = false
    inst:AddTag("FX")
    inst:AddTag("NOCLICK")
    inst.Transform:SetPosition(x, y, z)
    inst.SoundEmitter:PlaySound(sound)
    inst:DoTaskInTime(3, inst.Remove)
end

-- the server's sound on it is muted until its copy of our hit is past
local function Mute(ent, now)
    if ent.SoundEmitter == nil or ent.SoundEmitter.OverrideVolumeMultiplier == nil then return end
    local m = s.muted[ent]
    if m == nil then
        ent.SoundEmitter:OverrideVolumeMultiplier(0)
        m = {}
        s.muted[ent] = m
    end
    m.till = now + Lead() + WINDOW
end

local function Unmute(ent)
    if s.muted[ent] == nil then return end
    s.muted[ent] = nil
    if ent:IsValid() and ent.SoundEmitter ~= nil then ent.SoundEmitter:OverrideVolumeMultiplier(1) end
end

-- the server will make this effect here: its picture is not to be made again
local function Expect(name, x, z, now)
    table.insert(s.expect, { name = name, x = x, z = z, t = now })
end

---------------------------------------------------------------- the targets

local function TreeStage(tree)
    local a = tree.AnimState
    for _, st in ipairs(STAGES) do
        if a:IsCurrentAnimation("sway1_loop_" .. st) or a:IsCurrentAnimation("sway2_loop_" .. st)
            or a:IsCurrentAnimation("idle_" .. st) or a:IsCurrentAnimation("chop_" .. st) then
            return st
        end
    end
    if a:IsCurrentAnimation("idle_old") or a:IsCurrentAnimation("chop_old") then return "old" end
end

local function ChopTree(tree, now)
    if not (tree:HasTag("tree") and TREE_BUILDS[tree.build]) or tree:HasTag("burnt") or tree:HasTag("stump") then
        return false
    end
    local stage = TreeStage(tree)
    if stage == nil then return false end
    local x, y, z = tree.Transform:GetWorldPosition()
    Mute(tree, now)
    LocalSound(x, y, z, s.inst:HasTag("beaver") and "dontstarve/characters/woodie/beaver_chop_tree"
        or "dontstarve/wilson/use_axe_tree")
    if stage == "old" then return true end -- an old tree only makes the sound
    tree.AnimState:PlayAnimation("chop_" .. stage)
    tree.AnimState:PushAnimation("sway1_loop_" .. stage, true)
    s.shakes[tree] = { anim = "chop_" .. stage, t = now }
    if tree.build ~= "twiggy" then
        LocalFx("pine_needles_chop", x, y + math.random() * 2, z)
        Expect("pine_needles_chop", x, z, now)
    end
    return true
end

local function MineRock(rock, now)
    local frozen = rock:HasTag("frozen")
    local moonglass = rock:HasTag("moonglass") or rock:HasTag("LunarBuildup")
    local crystal = rock:HasTag("crystal")
    local fx = (frozen and "mining_ice_fx") or (moonglass and "mining_moonglass_fx")
        or (crystal and "mining_crystal_fx") or "mining_fx"
    local x, y, z = rock.Transform:GetWorldPosition()
    LocalFx(fx, x, y, z)
    Expect(fx, x, z, now)
    -- the pick sound is the player's on the server
    Mute(s.inst, now)
    local px, py, pz = s.inst.Transform:GetWorldPosition()
    LocalSound(px, py, pz, (frozen and "dontstarve_DLC001/common/iceboulder_hit")
        or ((moonglass or crystal) and "turnoftides/common/together/moon_glass/mine")
        or "dontstarve/wilson/use_pick_rock")
    return true
end

-- the future view's swing reached the frame its hit lands on
function Impact.Hit(kind)
    if s == nil or not Impact.enabled then return end
    local Pipe = package.loaded["blc/pipeline"]
    local target, tag = nil, nil
    if Pipe ~= nil and Pipe.WorkTarget ~= nil then target, tag = Pipe.WorkTarget() end
    if target == nil or not target:IsValid() or target.Transform == nil or target.AnimState == nil then return end
    local now = Now()
    local done = false
    if kind == "chop" and tag == "CHOP_workable" then
        done = ChopTree(target, now)
    elseif kind == "mine" and tag == "MINE_workable" then
        done = MineRock(target, now)
    end
    if done then s.hits = s.hits + 1 end
end

---------------------------------------------------------------- the server's copies

-- an effect's proxy from the server: its picture is made a frame later (fx.lua startfx); if we
-- showed this one already, that is skipped
local function Claim(proxy)
    if proxy.blc_claim ~= nil then return proxy.blc_claim end
    local claim = false
    if s ~= nil and proxy.Transform ~= nil then
        local x, _, z = proxy.Transform:GetWorldPosition()
        local now = Now()
        for _, e in ipairs(s.expect) do
            if not e.claimed and e.name == proxy.prefab and now - e.t < Lead() + WINDOW
                and (x - e.x) ^ 2 + (z - e.z) ^ 2 < 2.25 then
                e.claimed = true
                claim = true
                s.claimed = s.claimed + 1
                break
            end
        end
    end
    proxy.blc_claim = claim
    return claim
end

function Impact.ProxyInit(proxy)
    if s == nil or not Impact.enabled or proxy.pendingtasks == nil then return end
    for task in pairs(proxy.pendingtasks) do
        local fn = task.fn
        if type(fn) == "function" then
            task.fn = function(...)
                if Claim(proxy) then return end
                return fn(...)
            end
        end
    end
end

function Impact.Tick(on)
    if s == nil then return end
    local now = Now()
    local keep = Lead() + WINDOW
    if not on then
        for ent in pairs(s.muted) do Unmute(ent) end
        s.shakes, s.expect = {}, {}
        return
    end
    -- the server's shake arrived (its chop animation started again): to where ours is
    for tree, h in pairs(s.shakes) do
        if not tree:IsValid() or now - h.t > keep then
            s.shakes[tree] = nil
        elseif tree.AnimState:IsCurrentAnimation(h.anim) then
            local t, want = tree.AnimState:GetCurrentAnimationTime(), now - h.t
            if t + 2 * F < want then
                local len = tree.AnimState:GetCurrentAnimationLength()
                tree.AnimState:SetTime(math.min(want, len))
                s.moved = s.moved + 1
            end
        end
    end
    for i = #s.expect, 1, -1 do
        if now - s.expect[i].t > keep then table.remove(s.expect, i) end
    end
    -- sounds back on; a tree that fell while muted gets its fall sound here
    local state = s.inst.sg ~= nil and s.inst.sg.currentstate ~= nil and s.inst.sg.currentstate.name or nil
    for ent, m in pairs(s.muted) do
        if not ent:IsValid() then
            s.muted[ent] = nil
        else
            if ent ~= s.inst and not m.fell then
                for _, st in ipairs({ "short", "normal", "tall", "old" }) do
                    if ent.AnimState:IsCurrentAnimation("fallleft_" .. st) or ent.AnimState:IsCurrentAnimation("fallright_" .. st) then
                        m.fell = true
                        local x, y, z = ent.Transform:GetWorldPosition()
                        LocalSound(x, y, z, "dontstarve/forest/treefall")
                        break
                    end
                end
            end
            -- you: back on as soon as you walk (your steps are on the same emitter)
            if now > m.till or (ent == s.inst and (state == "run_start" or state == "run")) then Unmute(ent) end
        end
    end
end

function Impact.Start(inst)
    if TheWorld ~= nil and TheWorld.ismastersim then return end -- the host has no round trip
    s = { inst = inst, muted = {}, shakes = {}, expect = {}, hits = 0, claimed = 0, moved = 0 }
end

function Impact.Stop()
    if s == nil then return end
    for ent in pairs(s.muted) do Unmute(ent) end
    s = nil
end

-- for the minute summary
function Impact.TakePeriod()
    if s == nil then return nil end
    local p = { hits = s.hits, claimed = s.claimed, moved = s.moved }
    s.hits, s.claimed, s.moved = 0, 0, 0
    return p
end

function Impact._state() return s end

return Impact

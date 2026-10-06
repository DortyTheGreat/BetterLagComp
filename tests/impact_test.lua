-- Hits on your time line: what a tree and a rock show, and the server's copies kept from showing
-- twice.  lua5.1 tests/impact_test.lua
package.path = "./scripts/?.lua;" .. package.path

FRAMES = 1 / 30
local F = FRAMES
local TICK = 0
function GetTime() return TICK * F end
TheWorld = { ismastersim = false }

local passes, fails = 0, 0
local function check(cond, what)
    if cond then passes = passes + 1; print("  ok    " .. what)
    else fails = fails + 1; print("  FAIL  " .. what) end
end

-- the engine, as far as these use it
local made, sounds, tasks = {}, {}, {}
local function Anim()
    local a = { name = nil, t = 0, len = 15 * F, bank = nil }
    function a:PlayAnimation(n) self.name, self.t = n, 0 end
    function a:PushAnimation() end
    function a:IsCurrentAnimation(n) return self.name == n end
    function a:GetCurrentAnimationTime() return self.t end
    function a:GetCurrentAnimationLength() return self.len end
    function a:SetTime(t) self.t = t end
    function a:SetBank(b) self.bank = b end
    function a:SetBuild() end
    function a:SetScale() end
    function a:SetBloomEffectHandle() end
    return a
end
local function Entity(x, z, tags)
    local e = { tags = {}, valid = true, x = x or 0, z = z or 0 }
    for _, t in ipairs(tags or {}) do e.tags[t] = true end
    e.Transform = { GetWorldPosition = function() return e.x, 0, e.z end, SetPosition = function(_, px, _, pz) e.x, e.z = px, pz end }
    e.AnimState = Anim()
    e.SoundEmitter = { mult = 1, PlaySound = function(_, snd) table.insert(sounds, snd) end,
        OverrideVolumeMultiplier = function(self, m) self.mult = m end }
    e.entity = { AddTransform = function() end, AddAnimState = function() end, AddSoundEmitter = function() end,
        SetCanSleep = function() end }
    function e:AddTag(t) self.tags[t] = true end
    function e:HasTag(t) return self.tags[t] == true end
    function e:IsValid() return self.valid end
    function e:ListenForEvent() end
    function e:DoTaskInTime(t, fn) table.insert(tasks, { at = GetTime() + t, fn = fn, inst = self }) end
    function e:Remove() self.valid = false end
    return e
end
function CreateEntity()
    local e = Entity()
    table.insert(made, e)
    return e
end
package.preload["fx"] = function()
    return { { name = "pine_needles_chop", bank = "pine_needles", build = "pine_needles", anim = "chop" },
        { name = "mining_fx", bank = "mining_fx", build = "mining_fx", anim = "anim" } }
end

local work = {}
package.loaded["blc/pipeline"] = { enabled = true, WorkTarget = function() return work.target, work.tag end }
package.loaded["blc/future"] = { Lead = function() return 0.2 end }

local Impact = require("blc/impact")
local player = Entity(0, 0)
player.sg = { currentstate = { name = "chop" } }
Impact.Start(player)

local function Run(seconds, on)
    for _ = 1, math.floor(seconds / F + 0.5) do
        TICK = TICK + 1
        for _, e in ipairs(made) do e.AnimState.t = e.AnimState.t + F end
        work.target.AnimState.t = work.target.AnimState.t + F
        Impact.Tick(on ~= false)
    end
end
local function Made(bank)
    for _, e in ipairs(made) do if e.AnimState.bank == bank then return e end end
end
local function Sounded(snd)
    for _, x in ipairs(sounds) do if x == snd then return true end end
end
-- a proxy from the server: its picture is made a frame later by a task
local function Proxy(prefab, x, z)
    local p = Entity(x, z)
    p.prefab = prefab
    p.pictured = false
    local task = { fn = function() p.pictured = true end, arg = {} }
    p.pendingtasks = { [task] = true }
    Impact.ProxyInit(p)
    task.fn(unpack(task.arg))
    return p
end

print("[a pine tree chopped]")
local tree = Entity(3, 0, { "tree" })
tree.build = "normal"
tree.AnimState:PlayAnimation("sway1_loop_normal")
work.target, work.tag = tree, "CHOP_workable"
Impact.Hit("chop")
check(tree.AnimState.name == "chop_normal", "the tree shakes the moment your swing lands (its stage's chop)")
check(Made("pine_needles") ~= nil, "  needles made here")
check(Sounded("dontstarve/wilson/use_axe_tree") and tree.SoundEmitter.mult == 0, "  the chop sound from here, the tree's own muted")
Run(0.2)
tree.AnimState:PlayAnimation("chop_normal") -- the server's shake, a round trip later
Run(F)
check(math.abs(tree.AnimState.t - (0.2 + F)) < F, "the server's shake is moved to where ours is (no second shake)")
local mine = Proxy("pine_needles_chop", 3, 0)
local other = Proxy("pine_needles_chop", 12, 0)
check(not mine.pictured, "the server's needles for this tree: not made again")
check(other.pictured, "  another tree's (someone else chopping): made as usual")
Run(1.0)
check(tree.SoundEmitter.mult == 1, "the tree's sounds back on after the server's copy is past")

print("[the last hit: the tree falls while muted]")
Impact.Hit("chop")
Run(0.2)
tree.AnimState:PlayAnimation("fallleft_normal")
Run(F)
check(Sounded("dontstarve/forest/treefall"), "its fall sound is played here (the server's was muted)")

print("[a rock]")
local rock = Entity(-3, 0, {})
rock.AnimState:PlayAnimation("full")
work.target, work.tag = rock, "MINE_workable"
Impact.Hit("mine")
check(Made("mining_fx") ~= nil and Sounded("dontstarve/wilson/use_pick_rock"), "the dust and the pick sound the moment your swing lands")
check(player.SoundEmitter.mult == 0, "  the pick sound is yours on the server: muted on you")
player.sg.currentstate.name = "run_start"
Run(F)
check(player.SoundEmitter.mult == 1, "  back on as soon as you walk (your steps)")
player.sg.currentstate.name = "mine"

print("[not ours to show]")
made = {}
local birch = Entity(5, 0, { "tree" }) -- a birchnut tree: other animations, other effects
birch.AnimState:PlayAnimation("idle_normal")
work.target, work.tag = birch, "CHOP_workable"
Impact.Hit("chop")
check(#made == 0 and birch.AnimState.name == "idle_normal", "a tree that is not an evergreen: left to the server")
work.target, work.tag = rock, "MINE_workable"
Impact.Hit("chop")
check(#made == 0, "a swing of the axe at a rock: nothing")

print("[F8 off]")
Impact.Hit("mine")
Run(F, false)
check(player.SoundEmitter.mult == 1, "everything muted is back on")

print(string.format("\n%d passed, %d failed", passes, fails))
if fails > 0 then os.exit(1) end

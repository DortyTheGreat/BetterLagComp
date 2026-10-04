-- The mod's wiring against mocked mod API and game: run from the mod folder with
--     lua5.1 tests/boot_test.lua
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
local NOW = 10
function GetTime() return NOW end
function GetTimeRealSeconds() return math.floor(NOW) end
function hash(str)
    local h = 5381
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
    return h
end
function Vector3(x, y, z) return { x = x, y = y, z = z } end
ACTIONS = { PICKUP = { id = "PICKUP", code = 1 }, PICK = { id = "PICK", code = 3 } }
ACTIONS_BY_ACTION_CODE = { [1] = ACTIONS.PICKUP }
RPC = { LeftClick = 1, ActionButton = 2 }
CONTROL_ACTION, CONTROL_PRIMARY = 1, 2
KEY_F8 = 289
function SendRPCToServer() end
function CanEntitySeeTarget() return true end
TheNet = { GetIsServer = function() return false end, GetAveragePing = function() return 150 end }
TheSim = { FindEntities = function() return {} end }
local keys = {}
TheInput = { AddKeyDownHandler = function(_, key, fn) keys[key] = fn end }
local screen = { name = "HUD" }
TheFrontEnd = { GetActiveScreen = function() return screen end }
package.preload["stategraphs/SGwilson"] = function() return { states = { idle = {}, doshortaction = {} } } end
package.preload["widgets/text"] = function()
    return function()
        local t = { inst = { IsValid = function() return true end } }
        function t:SetString(v) self.value = v end
        function t:SetColour() end
        function t:SetHAnchor() end
        function t:SetVAnchor() end
        function t:SetScaleMode() end
        function t:SetPosition() end
        return t
    end
end

local passes, fails = 0, 0
local function check(cond, what)
    if cond then passes = passes + 1; real_print("  ok    " .. what)
    else fails = fails + 1; real_print("  FAIL  " .. what) end
end

---------------------------------------------------------------- boot
local reg = { components = {}, stategraphs = {}, players = {}, classes = {} }
local api = {
    modname = "BetterLagComp",
    AddClassPostConstruct = function(name, fn) reg.classes[name] = fn end,
    AddPlayerPostInit = function(fn) table.insert(reg.players, fn) end,
    AddComponentPostInit = function(name, fn) reg.components[name] = fn end,
    AddStategraphPostInit = function(name, fn) reg.stategraphs[name] = fn end,
}
local config = { lab = true, hud = true, detail = "all", pipeline = true, pipeline_key = "KEY_F8", margin = 5 }
real_print("[boot]")
require("blc/main").Boot(api, config)
local Pipe = require("blc/pipeline")
local Lab = require("blc/lab")
check(reg.components.playercontroller ~= nil and reg.stategraphs.wilson_client ~= nil,
    "hooks the player controller and the client state graph")
check(keys[KEY_F8] ~= nil, "  and the toggle key")
check(Pipe.margin == 5 and Pipe.enabled, "  with the settings")
check(Count("fast chains on %(margin 5 frames%)") == 1, "  and says so in the log")

local update_called = false
local sg = { states = { doshortaction = { onupdate = function() update_called = true end }, dolongaction = {} } }
reg.stategraphs.wilson_client(sg)
local inst_for_sg = { sg = { statemem = {} } }
sg.states.doshortaction.onupdate(inst_for_sg, FRAMES)
check(update_called, "the game's doshortaction update still runs for the game's own pickups")

local remote_called = false
local pc = { RemoteActionButton = function() remote_called = true end, GetActionButtonAction = function() return "act" end,
    remote_controls = {} }
reg.components.playercontroller(pc)
pc:RemoteActionButton(nil)
check(remote_called and pc:GetActionButtonAction() == "act", "the controller still works before the player is in the world")

---------------------------------------------------------------- the player
real_print("[in the world]")
local said = {}
local P = { events = {}, tasks = {}, components = {}, replica = {} }
function P:ListenForEvent(ev, fn) self.events[ev] = self.events[ev] or {}; table.insert(self.events[ev], fn) end
function P:RemoveEventCallback(ev, fn)
    for i, f in ipairs(self.events[ev] or {}) do if f == fn then table.remove(self.events[ev], i) end end
end
function P:Fire(ev) for _, fn in ipairs(self.events[ev] or {}) do fn() end end
function P:DoPeriodicTask(_, fn) local t = { fn = fn }; function t:Cancel() t.dead = true end; table.insert(self.tasks, t); return t end
function P:HasTag(tag) return tag == "busy" end
function P:IsValid() return true end
P.Transform = { GetWorldPosition = function() return 0, 0, 0 end }
P.components.talker = { Say = function(_, text) table.insert(said, text) end }
P.components.playercontroller = { locomotor = {} }
P.player_classified = { currentstate = { value = function() return hash("doshortaction") end },
    pausepredictionframes = { value = function() return 0 end }, ListenForEvent = function() end,
    RemoveEventCallback = function() end, IsValid = function() return true end }
ThePlayer = P
reg.classes["widgets/controls"]({ AddChild = function(_, w) return w end })
for _, fn in ipairs(reg.players) do fn(P) end
P:Fire("playeractivated")
check(Lab.active and Pipe._state() ~= nil and require("blc/combatlab")._state() ~= nil,
    "Lag Lab, Combat Lab and fast chains start with the player")
check(P.blc_hastag ~= nil and P:HasTag("busy"), "  the server's tags are only hidden during a chain")
for _, t in ipairs(P.tasks) do if not t.dead then t.fn() end end
check(Lab.hud_text ~= nil and Lab.hud_text.value ~= nil and Lab.hud_text.value:find("fast on") ~= nil,
    "the HUD line shows fast chains on")

keys[KEY_F8]()
check(not Pipe.enabled and said[#said] == "Fast chains: off", "the key switches fast chains off, and says so")
screen = { name = "ChatInputScreen" }
keys[KEY_F8]()
check(not Pipe.enabled, "  not while typing")
screen = { name = "HUD" }
keys[KEY_F8]()
check(Pipe.enabled and said[#said] == "Fast chains: on", "  and back on")

Pipe._state().period.item.fast = { n = 3, sum = 1.2 }
Pipe._state().period.item.normal = { n = 2, sum = 1.3 }
Pipe._state().period.other.fast = { n = 4, sum = 3.2 }
P:Fire("playerdeactivated")
check(Count("Space pickups: fast 400 ms %(3%), normal 650 ms %(2%); Space picking, harvest, traps: fast 800 ms %(4%), normal %-; lost 0") == 1,
    "the summary has the pace of pickups and of picking, fast and normal")
check(not Lab.active and Pipe._state() == nil and require("blc/combatlab")._state() == nil, "all stop with the player")
check(Count("error") == 0, "no errors anywhere")

real_print(string.format("\n%d passed, %d failed", passes, fails))
if fails > 0 then os.exit(1) end

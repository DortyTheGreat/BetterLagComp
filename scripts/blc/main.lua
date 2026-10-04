-- Better Lag Compensation: boot. Wires the game's hooks to the parts of the mod.
local Util = require("blc/util")
local Lab = require("blc/lab")
local Pipe = require("blc/pipeline")
local CombatLab = require("blc/combatlab")
local Cue = require("blc/cue")
local Future = require("blc/future")
local MobPos = require("blc/mobpos")

local BLC = { config = {} }

-- Every request this client sends to the server passes through here first
local function HookRPC()
    local send = rawget(_G, "SendRPCToServer")
    if send == nil then
        Util.Log("SendRPCToServer not found: requests are not watched")
        return
    end
    rawset(_G, "SendRPCToServer", function(code, ...)
        if Lab.active then Util.SafeCall("lab rpc", Lab.OnRpc, code, ...) end
        Util.SafeCall("fast rpc", Pipe.OnRpc, code, ...)
        return send(code, ...)
    end)
end

-- Say something above the player's head, only on this screen
local function Say(text)
    local player = Util.Player()
    local talker = player ~= nil and player.components.talker or nil
    if talker ~= nil then pcall(talker.Say, talker, text) end
end

local function HookKey(key)
    local input = rawget(_G, "TheInput")
    local code = key ~= nil and rawget(_G, key) or nil
    if input == nil or code == nil then return end
    input:AddKeyDownHandler(code, function()
        local frontend = rawget(_G, "TheFrontEnd")
        local screen = frontend ~= nil and frontend:GetActiveScreen() or nil
        if screen == nil or screen.name ~= "HUD" or Util.Player() == nil then return end -- typing, menus
        Say("Fast chains: " .. (Pipe.Toggle() and "on" or "off"))
    end)
end

function BLC.Boot(api, config)
    BLC.config = config or {}
    local lab = BLC.config.lab ~= false
    local fast = BLC.config.pipeline ~= false
    local cue = BLC.config.cue ~= false
    local future = fast and BLC.config.future ~= false
    -- watching the mobs: for the Lab's log and for the dodge cue
    local combat = lab or cue
    if lab then
        Lab.Configure(BLC.config)
        CombatLab.notify = Lab.Event
        Future.notify = Lab.Event
    end
    CombatLab.probes = lab and BLC.config.probes ~= false
    CombatLab.probe_swing = not future -- answered; it would fight the future view over the animation
    CombatLab.cue = cue and Cue or nil
    CombatLab.future_mobs = BLC.config.future_mobs ~= false
    CombatLab.mobpos = CombatLab.future_mobs and MobPos or nil
    MobPos.notify = lab and Lab.Event or nil
    combat = combat or CombatLab.future_mobs
    if lab or fast then HookRPC() end
    if fast then
        Pipe.Configure(BLC.config)
        Pipe.notify = Lab.Event
        api.AddComponentPostInit("playercontroller", function(pc)
            Util.SafeCall("fast chains controller", Pipe.PatchController, pc)
        end)
        api.AddStategraphPostInit("wilson_client", function(sg)
            Util.SafeCall("fast chains states", Pipe.PatchStategraph, sg)
        end)
        HookKey(BLC.config.pipeline_key)
    end
    api.AddPlayerPostInit(function(inst)
        inst:ListenForEvent("playeractivated", function()
            if inst ~= Util.Player() then return end
            if lab then Util.SafeCall("lab start", Lab.Start, inst) end
            if combat then Util.SafeCall("combat watch start", CombatLab.Start, inst) end
            if fast then Util.SafeCall("fast chains start", Pipe.Start, inst) end
            if future then Util.SafeCall("future view start", Future.Start, inst) end
        end)
        inst:ListenForEvent("playerdeactivated", function()
            Util.SafeCall("future view stop", Future.Stop, inst)
            Util.SafeCall("combat watch stop", CombatLab.Stop, inst)
            Util.SafeCall("lab stop", Lab.Stop, inst)
            Util.SafeCall("fast chains stop", Pipe.Stop, inst)
        end)
    end)
    if lab and BLC.config.hud ~= false then
        api.AddClassPostConstruct("widgets/controls", function(controls)
            Util.SafeCall("lab hud", Lab.AttachHud, controls)
        end)
    end
    Util.Log(string.format("Better Lag Compensation loaded: Lag Lab %s, fast chains %s%s, dodge cue %s, future view %s",
        lab and "on" or "off", fast and (Pipe.enabled and "on" or "off") or "not loaded",
        fast and string.format(" (margin %d frames)", Pipe.margin) or "", cue and "on" or "off", future and "on" or "off"))
end

return BLC

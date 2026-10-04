-- Better Lag Compensation: entry point. Only what exists in the mod environment lives here;
-- the logic is in scripts/blc/ and runs in the game's global environment.
local api = {
    modname = modname,
    AddClassPostConstruct = AddClassPostConstruct,
    AddPlayerPostInit = AddPlayerPostInit,
    AddComponentPostInit = AddComponentPostInit,
    AddStategraphPostInit = AddStategraphPostInit,
}
local config = {
    lab = GetModConfigData("lab"),
    hud = GetModConfigData("hud"),
    detail = GetModConfigData("detail"),
    pipeline = GetModConfigData("pipeline"),
    pipeline_key = GetModConfigData("pipeline_key"),
    margin = GetModConfigData("margin"),
    jitter = GetModConfigData("jitter"),
    probes = GetModConfigData("probes"),
    cue = GetModConfigData("cue"),
    future = GetModConfigData("future"),
    future_mobs = GetModConfigData("future_mobs"),
}
GLOBAL.require("blc/main").Boot(api, config)

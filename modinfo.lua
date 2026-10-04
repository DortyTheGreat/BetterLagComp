name = "Better Lag Compensation"
description = [[A better lag compensation for playing with ping, client-side only: works on any server.

Fast chains: Space on one thing after another without waiting a round trip to the server for
each: items (about 1.6x faster at 160 ms, 2x at 270+), grass, saplings, bushes (15-30%), carrots,
flowers, mushrooms, traps, crock pots, drying racks, farms, bee boxes. Chopping, mining, digging,
hammering (also the werebeaver): the next target starts while the server finishes the last
swing (forest 1.4x, digging 1.8x). Boats and riding too. Uses the game's own lag compensation,
which must stay ON (Predictive). F8 switches it, to compare.

Lag Lab: logs corrections (rollbacks), server pauses, refused actions, the pace and where fast
chains waited to client_log.txt, with a summary every minute.]]
author = "DortyTheGreat"
version = "0.9.2"
api_version = 10
dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false
client_only_mod = true
all_clients_require_mod = false
server_filter_tags = {}
icon_atlas = "modicon.xml"
icon = "modicon.tex"

local function Key(k) return { description = k, data = "KEY_" .. k } end

configuration_options = {
    {
        name = "pipeline", label = "Fast chains",
        hover = "Space on one thing after another (items, plants, traps, crock pots...) without waiting a round trip to the server for each.",
        options = { { description = "On", data = true }, { description = "Off", data = false } },
        default = true,
    },
    {
        name = "pipeline_key", label = "Fast chains key",
        hover = "Switches fast chains on and off while playing, to compare.",
        options = { { description = "None", data = false }, Key("F5"), Key("F6"), Key("F7"), Key("F8"), Key("F9"),
            Key("F10"), Key("F11") },
        default = "KEY_F8",
    },
    {
        name = "jitter", label = "Jitter buffer",
        hover = "Extra safety for a ping that jumps. Auto: grows when the delays start to scatter, back to 0 when "
            .. "the connection is steady.",
        options = { { description = "Auto", data = "auto" }, { description = "0 ms", data = 0 },
            { description = "33 ms", data = 1 }, { description = "67 ms", data = 2 }, { description = "100 ms", data = 3 },
            { description = "133 ms", data = 4 } },
        default = "auto",
    },
    {
        name = "margin", label = "Fast chains margin",
        hover = "Frames of safety between two requests. More = safer on a shaky connection, a bit slower. "
            .. "It grows by itself if the server ever drops a request.",
        options = { { description = "2", data = 2 }, { description = "3", data = 3 }, { description = "4 (default)", data = 4 },
            { description = "5", data = 5 }, { description = "6", data = 6 }, { description = "8", data = 8 } },
        default = 4,
    },
    {
        name = "lab", label = "Lag Lab",
        hover = "Watch for rollbacks and refused actions, and log them to client_log.txt.",
        options = { { description = "On", data = true }, { description = "Off", data = false } },
        default = false,
    },
    {
        name = "hud", label = "Lag Lab on screen",
        hover = "A line at the top of the screen: ping, corrections, refused actions, pauses, misses.",
        options = { { description = "On", data = true }, { description = "Off", data = false } },
        default = false,
    },
    {
        name = "detail", label = "Log detail",
        hover = "Everything: every request, state and server state (a lot of lines). Problems: only problems, each with what led to it.",
        options = { { description = "Everything", data = "all" }, { description = "Problems", data = "problems" } },
        default = "all",
    },
    {
        name = "probes", label = "Lab engine checks",
        hover = "A couple of times per session: the character stands still for a moment while chopping, and a mob's "
            .. "animation jumps a little. Answers what the engine allows (see the log's 'probe' lines).",
        options = { { description = "On", data = true }, { description = "Off", data = false } },
        default = true,
    },
    {
        name = "cue", label = "Dodge cue",
        hover = "Over each mob that targets you: 'dodge 210' (ms left to step away), 'x' (too late), "
            .. "'safe 1.4' (it cannot attack for 1.4 s: hit it), 'ready' (it can attack any moment).",
        options = { { description = "On", data = true }, { description = "Off", data = false } },
        default = false,
    },
    {
        name = "future", label = "Future view: tool work",
        hover = "Chopping, mining, digging, hammering: your swing is shown on your time line from the start, "
            .. "no waiting pose. Off with fast chains (F8) too.",
        options = { { description = "On", data = true }, { description = "Off", data = false } },
        default = true,
    },
    {
        name = "future_mobs", label = "Future view: mobs",
        hover = "A mob that targets you is shown where the server will have it when your input gets there: its "
            .. "attack a round trip further on, its position ahead by its speed x the round trip. Off with F8 too.",
        options = { { description = "On", data = true }, { description = "Off", data = false } },
        default = false,
    },
}

-- Dodge cue: over each mob that targets you, when to step away and when you may hit.
--
--   dodge 210  its attack has started: a step away must start within 210 ms to be out of its reach
--              when the blow lands on the server (its windup, as the game's stategraph has it or as
--              measured, minus your round trip, minus the run out of its reach at your speed).
--              Yellow, red under 150 ms. Nothing if you are out of its reach already.
--   no dodge   too late to run out of this one: hit it, or take it.
--   safe 1.4   it attacked: it cannot start another for 1.4 s (its attack period). Green.
--   ready      its period is over and it is within reach: an attack can start any moment.
--
-- The data comes from the Combat Lab's watching of the mobs (combatlab.lua).
local Cue = { enabled = true }

local F = rawget(_G, "FRAMES") or 1 / 30
local CLOSE = 0.15 -- seconds: red below this
local COLOURS = {
    dodge = { 1, 0.85, 0.2 },
    close = { 1, 0.35, 0.2 },
    late = { 0.65, 0.65, 0.65 },
    safe = { 0.45, 1, 0.45 },
    ready = { 1, 1, 1 },
}

local labels = {}

local function NewLabel(mob)
    local e = CreateEntity("blc_cue")
    --[[Non-networked entity]]
    e.entity:AddTransform()
    e.entity:AddLabel()
    e:AddTag("CLASSIFIED")
    e:AddTag("NOCLICK")
    e:AddTag("FX")
    e.persists = false
    e.Label:SetFontSize(22)
    e.Label:SetFont(rawget(_G, "BODYTEXTFONT") or rawget(_G, "DEFAULTFONT"))
    e.Label:SetWorldOffset(0, 3, 0)
    e.Label:Enable(true)
    e.entity:SetParent(mob.entity)
    return e
end

-- what to show over this mob now, or nil
local function Text(CL, mob, m, now)
    local prefab = tostring(mob.prefab)
    local a = m.attack
    local windup = CL.Windup(prefab)
    if a ~= nil and a.hit == nil and not a.closed and windup ~= nil and now < a.t + windup + 2 * F then
        if a.out then return nil end -- out of its reach: nothing to do
        -- the deadline counts the way out of its reach at your speed, not only the round trip
        local left = (a.deadline or (a.t + windup - CL.Lead())) - now
        if left > 0 then
            return string.format("dodge %d", math.floor(left * 1000 + 0.5)), left < CLOSE and COLOURS.close or COLOURS.dodge
        end
        return "no dodge", COLOURS.late
    end
    local period = CL.Period(prefab)
    if a ~= nil and period ~= nil then
        local rest = a.t + period - now
        if rest > 0 then return string.format("safe %.1f", rest), COLOURS.safe end
    end
    if CL.InReach(mob) then return "ready", COLOURS.ready end
    return nil
end

function Cue.Update(CL, now)
    local view = CL.View()
    local shown = {}
    if view ~= nil and Cue.enabled then
        for mob, m in pairs(view.mobs) do
            if m.onme and mob:IsValid() then
                local text, colour = Text(CL, mob, m, now)
                if text ~= nil then
                    local e = labels[mob]
                    if e == nil or not e:IsValid() then
                        e = NewLabel(mob)
                        labels[mob] = e
                    end
                    e.Label:SetText(text)
                    e.Label:SetColour(colour[1], colour[2], colour[3])
                    shown[mob] = true
                end
            end
        end
    end
    for mob, e in pairs(labels) do
        if not shown[mob] then
            if e:IsValid() then e:Remove() end
            labels[mob] = nil
        end
    end
end

function Cue.Clear()
    for mob, e in pairs(labels) do
        if e:IsValid() then e:Remove() end
        labels[mob] = nil
    end
end

function Cue._labels() return labels end

return Cue

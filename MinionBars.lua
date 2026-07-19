-- MinionBars: health bars for every minion you control (WotLK 3.3.5)
--
-- The client only gives a real unit token to the primary pet ("pet"), so:
--   * main pet     -> exact, event-driven health
--   * other summons -> discovered via combat log (SPELL_SUMMON / flags),
--                      health filled in from nameplates, target, mouseover
--
-- /mb for commands.

local MAX_BARS = 12
local BAR_W, BAR_H = 160, 15
local EXPIRE_SECS = 45       -- drop unseen non-pet minions after this long
local DEAD_LINGER = 5        -- keep dead minions visible briefly

local AFFIL_MINE = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x00000001
local TYPE_PET = COMBATLOG_OBJECT_TYPE_PET or 0x00001000
local TYPE_GUARDIAN = COMBATLOG_OBJECT_TYPE_GUARDIAN or 0x00002000

local roster = {}    -- array of {guid, name, pct, hp, max, lastSeen, dead, diedAt, isPet, source}
local byGuid = {}

local f = CreateFrame("Frame", "MinionBarsFrame", UIParent)
local bars = {}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffb04edcMinionBars|r " .. msg)
end

-- ---------------------------------------------------------------------------
-- Roster
-- ---------------------------------------------------------------------------

local dirty = true
local RemoveMinion   -- defined below, used inside AddMinion

-- Ascension necro: summons occupy Life Force (base pool 4, talents can raise
-- it - /mb cap N to match yours). Per-unit costs from db.ascension.gg.
local function LifeForceCost(name)
    local n = string.lower(name or "")
    if string.find(n, "abomination", 1, true) then return 3 end
    if string.find(n, "colossus", 1, true) then return 3 end
    if string.find(n, "crypt fiend", 1, true) then return 2 end
    return 1   -- skeletons, ghouls, zombies, mages, archers...
end

local function LifeForceUsed()
    local total = 0
    for i = 1, #roster do
        if not roster[i].dead then
            total = total + LifeForceCost(roster[i].name)
        end
    end
    return total
end

local minionCounter = 0

local function AddMinion(guid, name, isPet)
    if not guid or byGuid[guid] then return end
    -- a brand-new unit with a name we already track usually REPLACED an older
    -- summon that despawned without a death event (necro re-raise); drop
    -- same-named entries that have gone quiet
    if name then
        local now = GetTime()
        for i = #roster, 1, -1 do
            local m = roster[i]
            if m.name == name and not m.isPet and not m.unit
                and now - (m.lastSeen or 0) > 15 then
                RemoveMinion(m)
            end
        end
    end
    minionCounter = minionCounter + 1
    local m = {
        guid = guid, name = name or "minion",
        pct = nil, hp = nil, max = nil,
        lastSeen = GetTime(), dead = false, isPet = isPet,
        order = minionCounter,
    }
    byGuid[guid] = m
    table.insert(roster, m)
    dirty = true
end

function RemoveMinion(m)
    byGuid[m.guid] = nil
    for i = #roster, 1, -1 do
        if roster[i] == m then
            table.remove(roster, i)
            break
        end
    end
    dirty = true
end

local function UpdateFromUnit(m, unit)
    local hp, max = UnitHealth(unit), UnitHealthMax(unit)
    if max and max > 0 then
        m.hp, m.max = hp, max
        m.pct = hp / max * 100
        m.lastSeen = GetTime()
        m.dead = (hp <= 0)
        dirty = true
    end
end

-- Candidate unit tokens: stock 3.3.5 only has "pet", but Ascension's custom
-- client may expose more for multi-pet classes. Probing invalid tokens is
-- free (UnitExists just returns nil), and any hit = exact live health.
local TOKENS = { "pet" }
for i = 1, 8 do table.insert(TOKENS, "pet" .. i) end
for i = 1, 8 do table.insert(TOKENS, "minion" .. i) end

local function ProbeTokens()
    -- unbind tokens whose occupant changed
    for i = 1, #roster do
        local m = roster[i]
        if m.unit and UnitGUID(m.unit) ~= m.guid then
            m.unit = nil
        end
    end
    for i = 1, #TOKENS do
        local token = TOKENS[i]
        if UnitExists(token) then
            local guid = UnitGUID(token)
            if guid then
                if not byGuid[guid] then
                    AddMinion(guid, UnitName(token), token == "pet")
                end
                local m = byGuid[guid]
                m.unit = token
                m.isPet = m.isPet or (token == "pet")
                m.name = UnitName(token) or m.name
                UpdateFromUnit(m, token)
            end
        end
    end
    -- the main pet frame is authoritative: dismissed pet leaves instantly
    if not UnitExists("pet") then
        for i = #roster, 1, -1 do
            if roster[i].isPet then
                RemoveMinion(roster[i])
            end
        end
    end
end

local SyncPet = ProbeTokens

-- ---------------------------------------------------------------------------
-- Opportunistic health sampling (units we can actually query)
-- ---------------------------------------------------------------------------

local SAMPLE_UNITS = { "target", "mouseover", "focus", "targettarget", "pettarget" }

local function SampleUnits()
    for i = 1, #SAMPLE_UNITS do
        local unit = SAMPLE_UNITS[i]
        if UnitExists(unit) then
            local m = byGuid[UnitGUID(unit) or ""]
            if m then
                UpdateFromUnit(m, unit)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Nameplate scraping (matches minions by NAME; approximate for duplicates)
-- ---------------------------------------------------------------------------

local plateCache = {}

local function IsNameplate(frame)
    if frame:GetName() then return false end
    local region = frame:GetRegions()
    return region and region.GetObjectType and region:GetObjectType() == "Texture"
        and region:GetTexture() == "Interface\\Tooltips\\Nameplate-Border"
end

local function PlateParts(frame)
    local cached = plateCache[frame]
    if cached then return cached.hb, cached.nameFS end
    local hb = frame:GetChildren()
    if not (hb and hb.GetObjectType and hb:GetObjectType() == "StatusBar") then
        hb = nil
    end
    local nameFS
    local regions = { frame:GetRegions() }
    for i = 1, #regions do
        local r = regions[i]
        if r.GetObjectType and r:GetObjectType() == "FontString" then
            local txt = r:GetText()
            -- the level fontstring is purely numeric; the name isn't
            if txt and not tonumber(txt) then
                nameFS = r
                break
            end
        end
    end
    plateCache[frame] = { hb = hb, nameFS = nameFS }
    return hb, nameFS
end

local lastPlateCount = 0

local function ScanNameplates()
    local n = WorldFrame:GetNumChildren()
    local kids = { WorldFrame:GetChildren() }
    lastPlateCount = n
    -- collect visible plates as name -> {pct...}
    local seen = {}
    for i = 1, #kids do
        local frame = kids[i]
        if frame:IsShown() and IsNameplate(frame) then
            local hb, nameFS = PlateParts(frame)
            if hb and nameFS then
                local name = nameFS:GetText()
                local _, maxv = hb:GetMinMaxValues()
                local v = hb:GetValue()
                if name and maxv and maxv > 0 then
                    seen[name] = seen[name] or {}
                    table.insert(seen[name], v / maxv * 100)
                end
            end
        end
    end
    -- hand percentages to same-named minions. Skip token-bound minions (they
    -- already have exact health). For duplicate names, pair each plate value
    -- with the minion whose previous pct is closest, so two "Skeletal Warrior"
    -- bars don't swap values every refresh.
    for name, list in pairs(seen) do
        local mine = {}
        for i = 1, #roster do
            local m = roster[i]
            if not m.isPet and not m.unit and m.name == name then
                table.insert(mine, m)
            end
        end
        for j = 1, #list do
            local v = list[j]
            local best, bestDist
            for k = 1, #mine do
                local m = mine[k]
                if not m.plateClaimed then
                    local dist = m.pct and math.abs(m.pct - v) or 101
                    if not bestDist or dist < bestDist then
                        best, bestDist = m, dist
                    end
                end
            end
            if best then
                best.plateClaimed = true
                if best.pct ~= v then dirty = true end
                best.pct = v
                best.dead = (v <= 0)
                -- deliberately NOT touching lastSeen: plates match by name, so
                -- they can't prove WHICH same-named unit exists - letting them
                -- keep-alive resurrects stale duplicates forever
            end
        end
        for k = 1, #mine do mine[k].plateClaimed = nil end
    end
end

-- ---------------------------------------------------------------------------
-- Display
-- ---------------------------------------------------------------------------

local function BuildFrames()
    f:SetWidth(BAR_W + 16)
    f:SetHeight(MAX_BARS * (BAR_H + 2) + 26)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.6)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        MinionBarsDB.pos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    f:SetClampedToScreen(true)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 8, -7)
    title:SetText("|cffb04edcMinions|r")
    f.title = title

    for i = 1, MAX_BARS do
        local bar = CreateFrame("StatusBar", nil, f)
        bar:SetWidth(BAR_W)
        bar:SetHeight(BAR_H)
        bar:SetPoint("TOPLEFT", 8, -22 - (i - 1) * (BAR_H + 2))
        bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        bar:SetMinMaxValues(0, 100)
        local bg = bar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(0, 0, 0, 0.5)
        local value = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        value:SetPoint("RIGHT", -4, 0)
        value:SetJustifyH("RIGHT")
        bar.value = value
        local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", 4, 0)
        text:SetPoint("RIGHT", value, "LEFT", -4, 0)
        text:SetJustifyH("LEFT")
        bar.text = text
        bar:Hide()
        bars[i] = bar
    end

    if MinionBarsDB.pos then
        local p = MinionBarsDB.pos
        f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
    else
        f:SetPoint("LEFT", UIParent, "LEFT", 30, -40)
    end
end

local function Render()
    dirty = false
    -- main pet first, then stable summon order: rows must not jump around as
    -- combat events update lastSeen
    table.sort(roster, function(a, b)
        if a.isPet ~= b.isPet then return a.isPet end
        return (a.order or 0) < (b.order or 0)
    end)
    local shown = 0
    for i = 1, MAX_BARS do
        local bar = bars[i]
        local m = roster[i]
        if m then
            shown = shown + 1
            local pct = m.pct
            if m.dead then
                bar:SetValue(0)
                bar:SetStatusBarColor(0.4, 0.4, 0.4)
                bar.text:SetText("|cff888888" .. m.name .. "|r")
                bar.value:SetText("|cff888888dead|r")
            elseif pct then
                bar:SetValue(pct)
                if pct > 50 then
                    bar:SetStatusBarColor(0.2, 0.9, 0.2)
                elseif pct > 25 then
                    bar:SetStatusBarColor(0.95, 0.85, 0.1)
                else
                    bar:SetStatusBarColor(0.95, 0.2, 0.2)
                end
                bar.text:SetText((m.isPet and "|cffb04edc*|r " or (m.unit and "|cff40ff40*|r " or "")) .. m.name)
                if m.unit and m.hp then
                    bar.value:SetText(m.hp .. "/" .. m.max)
                else
                    bar.value:SetText(math.floor(pct + 0.5) .. "%")
                end
            else
                bar:SetValue(100)
                bar:SetStatusBarColor(0.3, 0.4, 0.6)
                bar.text:SetText(m.name)
                bar.value:SetText("|cff9d9d9d?|r")
            end
            bar:Show()
        else
            bar:Hide()
        end
    end
    f.title:SetText("|cffb04edcMinions|r " .. #roster ..
        "  |cff9d9d9dLF " .. LifeForceUsed() .. "/" .. (MinionBarsDB.cap or 4) .. "|r")
    -- shrink-wrap the frame to the bars actually shown
    f:SetHeight(26 + math.max(shown, 0) * (BAR_H + 2) + (shown == 0 and 0 or 4))
    if MinionBarsDB.autohide and #roster == 0 then
        f:Hide()
    elseif not MinionBarsDB.hidden then
        f:Show()
    end
end

-- ---------------------------------------------------------------------------
-- Housekeeping + update loop
-- ---------------------------------------------------------------------------

-- the update loop lives on its own always-shown frame: OnUpdate does not fire
-- on hidden frames, so putting it on the bars frame deadlocks (hidden -> loop
-- stops -> Render never runs -> can never re-show)
local driver = CreateFrame("Frame")
local sampleAcc, plateAcc, sweepAcc = 0, 0, 0
driver:SetScript("OnUpdate", function(self, elapsed)
    sampleAcc = sampleAcc + elapsed
    if sampleAcc >= 0.2 then
        sampleAcc = 0
        ProbeTokens()
        SampleUnits()
    end
    plateAcc = plateAcc + elapsed
    if plateAcc >= 0.5 then
        plateAcc = 0
        ScanNameplates()
    end
    sweepAcc = sweepAcc + elapsed
    if sweepAcc >= 2 then
        sweepAcc = 0
        local now = GetTime()
        for i = #roster, 1, -1 do
            local m = roster[i]
            if m.dead and m.diedAt and now - m.diedAt > DEAD_LINGER then
                RemoveMinion(m)
            elseif not m.isPet and now - (m.lastSeen or 0) > EXPIRE_SECS then
                RemoveMinion(m)   -- summon expired quietly out of sight
            end
        end
        -- Life Force reconciliation: summoning over the cap makes the server
        -- despawn an old minion with NO death event. If our tracked total
        -- exceeds the cap, the stalest untracked-by-token entry is that ghost.
        local cap = MinionBarsDB.cap or 4
        while LifeForceUsed() > cap do
            local victim
            for i = 1, #roster do
                local m = roster[i]
                if not m.isPet and not m.unit and not m.dead
                    and now - (m.lastSeen or 0) > 5
                    and (not victim or (m.lastSeen or 0) < (victim.lastSeen or 0)) then
                    victim = m
                end
            end
            if not victim then break end
            RemoveMinion(victim)
        end
    end
    if dirty then
        Render()
    end
end)

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("UNIT_PET")
f:RegisterEvent("UNIT_HEALTH")
f:RegisterEvent("UNIT_MAXHEALTH")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == "MinionBars" then
            MinionBarsDB = MinionBarsDB or {}
            -- default VISIBLE even with no minions, so you can tell it loaded;
            -- /mb autohide turns on hide-when-empty once you trust it
            if MinionBarsDB.autohide == nil then MinionBarsDB.autohide = false end
            -- one-time per-character migration: older versions could save
            -- hidden/autohide states that permanently locked the frame away
            if MinionBarsDB.dbVersion ~= 3 then
                MinionBarsDB.dbVersion = 3
                MinionBarsDB.hidden = nil
                MinionBarsDB.autohide = false
            end
            BuildFrames()
            Render()
            Print("loaded - /mb for commands, /mb probe with pets out.")
            self:UnregisterEvent("ADDON_LOADED")
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        SyncPet()

    elseif event == "UNIT_PET" then
        local unit = ...
        if unit == "player" then
            SyncPet()
        end

    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        local unit = ...
        if unit and UnitExists(unit) then
            local m = byGuid[UnitGUID(unit) or ""]
            if m then UpdateFromUnit(m, unit) end
        end

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local _, sub, srcGUID, srcName, srcFlags, destGUID, destName, destFlags = ...
        local myGUID = UnitGUID("player")

        if MinionBarsDB.debug then
            -- surface anything mine-flagged that isn't me, so we can see what
            -- Ascension actually stamps on necro pets
            if srcFlags and srcGUID ~= myGUID and bit.band(srcFlags, AFFIL_MINE) > 0 then
                Print(("dbg src %s [%s] flags=0x%X"):format(sub, srcName or "?", srcFlags))
            end
            if destFlags and destGUID ~= myGUID and bit.band(destFlags, AFFIL_MINE) > 0 then
                Print(("dbg dst %s [%s] flags=0x%X"):format(sub, destName or "?", destFlags))
            end
            if sub == "SPELL_SUMMON" or sub == "SPELL_CREATE" then
                Print(("dbg %s: %s -> %s"):format(sub, srcName or "?", destName or "?"))
            end
        end

        if (sub == "SPELL_SUMMON" or sub == "SPELL_CREATE") and srcGUID == myGUID then
            AddMinion(destGUID, destName)

        elseif sub == "UNIT_DIED" or sub == "UNIT_DESTROYED" then
            local m = byGuid[destGUID or ""]
            if m then
                m.dead = true
                m.pct = 0
                m.diedAt = GetTime()
                dirty = true
            end
        end

        -- discovery + keep-alive by flags, on BOTH sides of every event:
        -- a pet mid-fight shows up as the SOURCE of its attacks far more
        -- often than as a destination
        if srcGUID and srcFlags and srcGUID ~= myGUID then
            if byGuid[srcGUID] then
                byGuid[srcGUID].lastSeen = GetTime()
            elseif bit.band(srcFlags, AFFIL_MINE) > 0
                and bit.band(srcFlags, TYPE_PET + TYPE_GUARDIAN) > 0 then
                AddMinion(srcGUID, srcName)
            end
        end
        if destGUID and destFlags and destGUID ~= myGUID and sub ~= "UNIT_DIED" and sub ~= "UNIT_DESTROYED" then
            if byGuid[destGUID] then
                byGuid[destGUID].lastSeen = GetTime()
            elseif bit.band(destFlags, AFFIL_MINE) > 0
                and bit.band(destFlags, TYPE_PET + TYPE_GUARDIAN) > 0 then
                AddMinion(destGUID, destName)
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

SLASH_MINIONBARS1 = "/mb"
SLASH_MINIONBARS2 = "/minionbars"
SlashCmdList["MINIONBARS"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "reset" then
        for i = #roster, 1, -1 do RemoveMinion(roster[i]) end
        SyncPet()
        Print("roster reset.")
    elseif msg == "show" then
        MinionBarsDB.hidden = nil
        MinionBarsDB.autohide = false   -- show means SHOW, even when empty
        f:Show()
        Render()
    elseif msg == "hide" then
        MinionBarsDB.hidden = true
        f:Hide()
    elseif msg == "autohide" then
        MinionBarsDB.autohide = not MinionBarsDB.autohide
        Print("auto-hide when no minions: " .. (MinionBarsDB.autohide and "on" or "off"))
    elseif string.find(msg, "^cap") then
        local n = tonumber(string.match(msg, "%d+"))
        if n and n >= 1 then
            MinionBarsDB.cap = n
            dirty = true
            Print("life force cap set to " .. n)
        else
            Print("current cap: " .. (MinionBarsDB.cap or 4) .. "  (usage: /mb cap 5)")
        end
    elseif msg == "debug" then
        MinionBarsDB.debug = not MinionBarsDB.debug
        Print("debug " .. (MinionBarsDB.debug and
            "ON - attack something with pets out, then screenshot the dbg lines." or "off"))
    elseif msg == "probe" then
        -- diagnostic: which pet unit tokens does this client actually have?
        local found = 0
        for i = 1, #TOKENS do
            local token = TOKENS[i]
            if UnitExists(token) then
                found = found + 1
                Print(token .. " -> " .. (UnitName(token) or "?") .. "  " ..
                    UnitHealth(token) .. "/" .. UnitHealthMax(token))
            end
        end
        Print(found .. " live unit token(s). Run this with all 4 pets out!")
    else
        Print("commands: /mb reset | show | hide | autohide | probe | debug | cap N")
        Print("Exact health: main pet always; others when nameplates (V) are on or you mouse over them.")
    end
end

-------------------------------------------------------------------------------
-- AutoLoot  v4.0
--
-- Automated loot + vendor cycle for WoW 3.3.5a.
--
-- Default flow: summon a configured "loot" companion, watch bags, and when
-- they fill up dismiss it and summon a configured "vendor" companion. When
-- the vendor window opens, repair + sell items by quality (user-toggled).
--
-- Selling requires the player to interact with the vendor NPC once it is
-- summoned. InteractUnit is a Blizzard-UI-protected function and cannot be
-- called from any addon script or macro - there is no client-side workaround.
-- The fully automatic path requires a server-side configuration that makes
-- MERCHANT_SHOW fire automatically when the vendor companion is summoned.
-- A floating on-screen Vendor button (SecureActionButton) targets the NPC
-- in combat; the player then presses their Interact With Target keybind.
--
-- Slash commands:  /eal   /autoloot
-------------------------------------------------------------------------------

local ADDON_NAME = "AutoLoot"
local ADDON_VERSION = "4.12.0"
local ADDON_AUTHOR  = "Veronica-Vasilieva"
local ADDON_URL     = "https://github.com/Veronica-Vasilieva/AutoLoot"
local ADDON_IDENT   = ADDON_NAME .. " v" .. ADDON_VERSION .. " by " .. ADDON_AUTHOR
local CURRENT_SCHEMA = 4

-- Provenance globals. Used by external diagnostic tools and crash
-- reporters to identify the addon and route bug reports upstream.
-- Do not rename; referenced by name across the codebase.
_G["EAL_IDENT"]          = ADDON_IDENT
_G["EAL_ORIGIN"]         = ADDON_URL
_G["__AutoLoot_origin"]  = ADDON_URL
_G["__AutoLoot_author"]  = ADDON_AUTHOR

-- Localisation table. Loaded from Locale.lua before this file (.toc order).
-- Falls back to key-as-value when a translation is missing, so any string
-- not yet translated just renders in English.
local L = AutoLoot_L or setmetatable({}, { __index = function(t, k) return k end })

-- Item quality constants (matches GetItemInfo quality return)
local Q_GREY, Q_WHITE, Q_UNCOMMON, Q_RARE, Q_EPIC = 0, 1, 2, 3, 4

local QUALITY_LABEL = { [0]="Grey", [1]="White", [2]="Uncommon", [3]="Rare", [4]="Epic" }
local QUALITY_HEX   = { [0]="9d9d9d", [1]="ffffff", [2]="1eff00", [3]="0070dd", [4]="a335ee" }

-- State machine values
local S_IDLE, S_LOOTING, S_SELLING = "IDLE", "LOOTING", "SELLING"

-- Companion stuck detection: resummon if pet exceeds this distance in yards
local MAX_COMPANION_DISTANCE = 5

-- Per-pulse sell cap: avoids flooding the server with UseContainerItem calls
-- in a single MERCHANT_SHOW callback, which can disconnect low-end clients.
local MAX_SELL_PER_PULSE      = 45
local SELL_BATCH_DELAY        = 1.0
local FAST_MODE_BATCH_MULTIPLIER = 2
local FAST_MODE_DELAY_DIVISOR    = 2

local TOME_PREFIX_LOWER   = "tome of echo:"

-- SavedVariables schema
local DEFAULTS = {
    schemaVersion     = CURRENT_SCHEMA,

    -- Core behavior
    enabled           = false,
    lootCompanion     = "Greedy Scavenger",
    vendorCompanion   = "Goblin Merchant",
    sellOnAnyVendor   = false,   -- when false, only auto-sell when we actively triggered the sell cycle

    -- Auto-delete unsellable items by quality (OPT-IN: dangerous).
    -- Replaced the legacy autoDeleteRares boolean in schema v3. Old saves
    -- with autoDeleteRares = true are migrated to enabled+rare in
    -- RunMigrations.  Each per-quality flag is independently toggleable
    -- but only takes effect when the master `enabled` flag is on.
    autoDeleteUnsellable = {
        enabled  = false,
        -- Grey is a SPECIAL case: grey items always have a vendor price
        -- by design, so we delete ALL grey items when this is on (the
        -- "unsellable" vendor-price filter is bypassed for Q_GREY only).
        -- Useful for players who want to skip the trip to a vendor and
        -- just nuke vendor trash directly.
        grey     = false,
        common   = false,   -- white items (Q_WHITE = 1), only if unsellable
        uncommon = false,   -- green items (Q_UNCOMMON = 2), only if unsellable
        rare     = false,   -- blue items  (Q_RARE = 3),     only if unsellable
        epic     = false,   -- purple      (Q_EPIC = 4),     only if unsellable
    },

    soundEnabled      = true,
    playSoundOnSell   = true,
    showMinimapButton = true,

    -- Quality toggles
    sellGrey     = true,
    sellWhite    = false,
    sellUncommon = false,
    sellRare     = false,
    sellEpic     = false,

    -- Sell batching
    fastMode         = false,
    checkInterval    = 3,

    -- Quick-sell-by-item-level threshold. The "Sell gear at item level N
    -- or below" button targets gear at or below this iLvl. Default 199
    -- because on many private servers iLvl 200+ has crafting / upgrade
    -- uses, while ≤199 is safe junk.
    ilvlSellThreshold = 199,

    -- Per-item sell-price cap (in copper). Items whose vendor sellPrice
    -- exceeds this value are NEVER auto-sold, no matter what quality
    -- toggles say.  0 = disabled (current behavior). 50000 = 5g.
    -- 100000 = 10g.  Protects accidentally-vendoring valuable BoEs
    -- whose names you forgot to whitelist.
    sellPriceMax     = 0,

    -- Repair cost cap (in copper).  If a merchant's RepairAllCost
    -- exceeds this value, the auto-repair step is skipped (the sell
    -- cycle still proceeds).  0 = disabled (always repair).  Prevents
    -- accidental gold drain at unusually expensive repair vendors.
    repairCostCap    = 0,

    -- Item family / subclass filter (v4.12+).  Overrides the quality
    -- toggles for matching items.  Keyed by the localized subclass name
    -- returned in GetItemInfo's `subType` field.  Values:
    --   "keep" -- always skip, regardless of quality tick
    --   "sell" -- always sell, regardless of quality tick
    --   nil    -- default (quality tick decides)
    -- Whitelist and price-cap still apply on top of this (a whitelisted
    -- item is never sold, even if its family is set to "sell").
    familyFilter     = {},

    -- Whitelist scope (union of account + per-character is used at runtime)
    blacklist        = {},        -- account-wide whitelist (name misnomer kept for back-compat)

    -- Stash list (Bank tab). Items whose names match are auto-deposited
    -- from bags into the bank when the bank window opens, if the
    -- per-character autoDepositToBank toggle is also on. Account-wide
    -- entries are stored here; per-character entries live in CHAR_DEFAULTS.
    stashList        = {},

    -- Money tracking (lifetime)
    goldEarned       = 0,
    itemsSold        = 0,

    -- Window geometry
    windowX          = 100,
    windowY          = -200,
    vendorBtnX       = 100,
    vendorBtnY       = -400,
    vendorBtnShown   = true,
    minimapAngle     = 200,

    -- Last-selected tab index in the settings window, restored next time
    -- the window is opened.  1 = General, 2 = Sell, 3 = Actions, 4 = Whitelist.
    lastTab          = 1,
}

local CHAR_DEFAULTS = {
    schemaVersion       = CURRENT_SCHEMA,
    blacklist           = {},     -- per-character whitelist
    stashList           = {},     -- per-character stash list (Bank tab)
    autoDepositToBank   = false,  -- auto-deposit stash items when bank opens

    -- Mail tab (per-character).  Auto-collect fires on MAIL_SHOW.  COD mail
    -- is ALWAYS skipped in auto-collect; we never auto-pay a CODAmount.
    mailAutoCollect     = false,  -- master: collect on mail open
    mailCollectMoney    = true,   -- take money attachments
    mailCollectItems    = true,   -- take item attachments
    mailAutoDeleteRead  = false,  -- delete read mail with no remaining attachments / money
}

-------------------------------------------------------------------------------
-- Runtime state
-------------------------------------------------------------------------------
local EAL_DB                     -- account-wide SavedVariables
local EAL_CDB                    -- per-character SavedVariables
local currentState       = S_IDLE
local bagCheckTimer      = 0
local waitingForMerchant = false
local wasMounted         = false
local triggeredSellCycle = false -- true after StartSellCycle; reset on MERCHANT_CLOSED
local bagUpdateDirty     = false -- set by BAG_UPDATE, consumed on next tick

-- Deferred-sell latch: StartSellCycle sets this to true when it can't
-- run right away (player mounted or in combat).  Cleared once the sell
-- cycle actually kicks off in TryStartDeferredSell().
local pendingSellCycle   = false

-- Deferred-summon latch: SummonPet sets a pending target name when the
-- critter list isn't populated yet (early PLAYER_LOGIN, or a companion
-- learned mid-session).  Consumed on COMPANION_UPDATE.
local pendingSummonName  = nil

-- Bags-full lockout state: set by OnMerchantClosed when a sell cycle
-- finishes with 0 free slots (BoP/quest junk filled the last slots).
-- Instead of silently idling, we surface it to the user and offer a
-- one-shot retry of the sell cycle.
local bagsFullLockout    = false

-- Money-delta measurement for a single sell session
local sellSessionStartMoney = 0
local sellSessionActive     = false

-- Forward declarations (required — some functions reference each other
-- across the file and Lua's `local function` doesn't hoist)
local EAL_RefreshBlacklist
local EAL_RefreshStashList
local EAL_UpdateStatus
local EAL_UpdateMinimapTooltip
local UpdateMinimapButton

-- GUI handles populated by EAL_BuildGUI
local g_statusLabel
local g_goldLabel
local g_enableBtn
local g_vendorBtn
local g_vendorBtnToggle
local g_minimapBtn
local g_optionsFrame
local g_autoDelCb
local g_blacklistRows    = {}
local g_blacklistOffset  = 0
local g_scrollThumb
-- Bank tab (parallel scroll list)
local g_stashRows        = {}
local g_stashOffset      = 0
local g_stashScrollThumb
local g_autoDepositCb              -- bank auto-deposit master checkbox
local ROW_HEIGHT = 22
local MAX_ROWS   = 8

-------------------------------------------------------------------------------
-- Timer helper (C_Timer does not exist in 3.3.5a)
-------------------------------------------------------------------------------
local pendingTimers = {}
local timerFrame = CreateFrame("Frame")
timerFrame:SetScript("OnUpdate", function(self, elapsed)
    if #pendingTimers == 0 then return end
    for i = #pendingTimers, 1, -1 do
        local t = pendingTimers[i]
        t.remaining = t.remaining - elapsed
        if t.remaining <= 0 then
            table.remove(pendingTimers, i)
            t.fn()
        end
    end
end)

local function After(delay, fn)
    table.insert(pendingTimers, { remaining = delay, fn = fn })
end

-------------------------------------------------------------------------------
-- Utility
-------------------------------------------------------------------------------
local function Print(msg, r, g, b)
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cffff9900[AutoLoot]|r " .. tostring(msg), r or 1, g or 0.8, b or 0)
end

local function PlaySellSound()
    if EAL_DB and EAL_DB.soundEnabled and EAL_DB.playSoundOnSell then
        PlaySound("AuctionWindowClose")
    end
end

local function PlayAlertSound()
    if EAL_DB and EAL_DB.soundEnabled then
        PlaySound("TellMessage")
    end
end

local function FormatMoney(copper)
    copper = math.floor(copper or 0)
    if copper <= 0 then return "0c" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then table.insert(parts, "|cffffd700" .. g .. "g|r") end
    if s > 0 or g > 0 then table.insert(parts, "|cffc7c7cf" .. s .. "s|r") end
    table.insert(parts, "|cffeda55f" .. c .. "c|r")
    return table.concat(parts, " ")
end

local function GetTotalFreeSlots()
    local free = 0
    for bag = 0, 4 do
        local f = GetContainerNumFreeSlots(bag)
        if f then free = free + f end
    end
    return free
end

local function IsBlacklisted(itemName)
    if not itemName then return false end
    local lower = itemName:lower()
    if EAL_DB and EAL_DB.blacklist then
        for _, entry in ipairs(EAL_DB.blacklist) do
            if entry:lower() == lower then return true end
        end
    end
    if EAL_CDB and EAL_CDB.blacklist then
        for _, entry in ipairs(EAL_CDB.blacklist) do
            if entry:lower() == lower then return true end
        end
    end
    return false
end

-- Item family / subclass filter (v4.12+).  Curated list of subclasses that
-- players commonly want to force-keep or force-sell regardless of the
-- quality toggles.  The key is the localized subType string returned by
-- GetItemInfo (English on Ebonhold; non-English clients will still work
-- for the whitelist/quality path but the filter tab will show English
-- labels here until the localized subclass table is wired up).
--
-- Order controls display order in the Filter tab.
local FAMILY_CATEGORIES = {
    { key = "Cloth",          label = "Cloth (trade good)",        icon = "Interface\\Icons\\INV_Fabric_Linen_01" },
    { key = "Leather",        label = "Leather (trade good)",      icon = "Interface\\Icons\\INV_Misc_LeatherScrap_02" },
    { key = "Metal & Stone",  label = "Metal & Stone (ores/bars)", icon = "Interface\\Icons\\INV_Ore_Copper_01" },
    { key = "Herb",           label = "Herbs",                     icon = "Interface\\Icons\\INV_Misc_Herb_07" },
    { key = "Elemental",      label = "Elemental (motes/eternals)",icon = "Interface\\Icons\\Spell_Nature_EarthElemental_Totem" },
    { key = "Enchanting",     label = "Enchanting mats",           icon = "Interface\\Icons\\INV_Enchant_ShardStrangePrismatic" },
    { key = "Jewelcrafting",  label = "Jewelcrafting (gems)",      icon = "Interface\\Icons\\INV_Misc_Gem_01" },
    { key = "Meat",           label = "Meat / Fish",               icon = "Interface\\Icons\\INV_Misc_Fish_02" },
    { key = "Food & Drink",   label = "Food & Drink",              icon = "Interface\\Icons\\INV_Misc_Food_15" },
    { key = "Potion",         label = "Potions",                   icon = "Interface\\Icons\\INV_Potion_51" },
    { key = "Elixir",         label = "Elixirs",                   icon = "Interface\\Icons\\INV_Potion_43" },
    { key = "Flask",          label = "Flasks",                    icon = "Interface\\Icons\\INV_Potion_62" },
    { key = "Bandage",        label = "Bandages",                  icon = "Interface\\Icons\\INV_Misc_Bandage_15" },
    { key = "Scroll",         label = "Scrolls",                   icon = "Interface\\Icons\\INV_Scroll_02" },
    { key = "Junk",           label = "Junk (Miscellaneous)",      icon = "Interface\\Icons\\INV_Misc_QuestionMark" },
    { key = "Glyph",          label = "Glyphs",                    icon = "Interface\\Icons\\INV_Inscription_Tradeskill01" },
}

-- Decision for a given item.  Returns "keep", "sell", or nil (no rule).
-- itemSubType comes from GetItemInfo's 7th return.
local function GetItemFamilyDecision(itemSubType)
    if not itemSubType or itemSubType == "" then return nil end
    local map = EAL_DB and EAL_DB.familyFilter
    if not map then return nil end
    return map[itemSubType]
end

-- True when the item is listed in either the account-wide or per-character
-- stash list (Bank tab). Used by EAL_DepositStashItems on BANKFRAME_OPENED.
local function IsInStashList(itemName)
    if not itemName then return false end
    local lower = itemName:lower()
    if EAL_DB and EAL_DB.stashList then
        for _, entry in ipairs(EAL_DB.stashList) do
            if entry:lower() == lower then return true end
        end
    end
    if EAL_CDB and EAL_CDB.stashList then
        for _, entry in ipairs(EAL_CDB.stashList) do
            if entry:lower() == lower then return true end
        end
    end
    return false
end

-- Adds every bag item whose name starts with "Tome of Echo:" to the account whitelist.
local function EAL_WhitelistTomes()
    local added = 0
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name = GetItemInfo(link)
                if name and name:lower():sub(1, #TOME_PREFIX_LOWER) == TOME_PREFIX_LOWER then
                    if not IsBlacklisted(name) then
                        table.insert(EAL_DB.blacklist, name)
                        added = added + 1
                    end
                end
            end
        end
    end
    if added > 0 then
        if EAL_RefreshBlacklist then EAL_RefreshBlacklist() end
        Print("|cffffff00" .. added .. "|r Tome of Echo item(s) whitelisted.")
    else
        Print("No new Tome of Echo items found in bags (already whitelisted or not in bags).")
    end
end

-- Companion lookup (case-insensitive so "Greedy scavenger" matches "Greedy Scavenger").
local function FindCompanion(name)
    if not name or name == "" then return nil, false end
    local n = GetNumCompanions("CRITTER")
    local nameLower = name:lower()
    for i = 1, n do
        local _, cName, _, _, summoned = GetCompanionInfo("CRITTER", i)
        if cName and cName:lower() == nameLower then
            return i, (summoned == 1 or summoned == true)
        end
    end
    return nil, false
end

local function SummonPet(name)
    local idx, active = FindCompanion(name)
    if not idx then
        -- Critter list may not be populated yet (PLAYER_LOGIN fires before
        -- COMPANION_UPDATE).  Latch the pending target; the COMPANION_UPDATE
        -- handler retries the summon once the list arrives.  Only warn the
        -- user if they've already been idle a while and still no match.
        pendingSummonName = name
        Print("Companion '" .. (name or "?") .. "' not found - will retry when companion list loads.", 1, 0.3, 0.3)
        return false
    end
    if not active then
        CallCompanion("CRITTER", idx)
        Print("Summoning " .. name .. "...")
    end
    pendingSummonName = nil   -- succeeded; clear any pending retry
    return true
end

local function DismissPet()
    DismissCompanion("CRITTER")
end

local function IsPlayerMountedOrFlying()
    if IsFlying  and IsFlying()  then return true end
    if IsMounted and IsMounted() then return true end
    return false
end

-- True if the companion we EXPECTED to be summoned (loot pet during
-- S_LOOTING, vendor pet during S_SELLING) is not currently active in
-- the critter list.  UnitPosition("pet") refers to the combat pet
-- (Hunter/Warlock) in 3.3.5a, NOT to a summoned companion critter, so
-- distance-based stuck detection was silently broken.  Using the
-- companion list's summoned flag is authoritative.
local function IsExpectedCompanionActive()
    local expected
    if     currentState == S_LOOTING then expected = EAL_DB and EAL_DB.lootCompanion
    elseif currentState == S_SELLING then expected = EAL_DB and EAL_DB.vendorCompanion
    end
    if not expected or expected == "" then return true end
    local _, active = FindCompanion(expected)
    return active
end

-------------------------------------------------------------------------------
-- Status / GUI refresh
-------------------------------------------------------------------------------
EAL_UpdateStatus = function()
    if not g_statusLabel then return end

    local stateColor
    if     currentState == S_IDLE    then stateColor = "|cffaaaaaa"
    elseif currentState == S_LOOTING then stateColor = "|cff44ff44"
    elseif currentState == S_SELLING then stateColor = "|cffff9900"
    else                                  stateColor = "|cffaaaaaa"
    end

    local free      = GetTotalFreeSlots()
    local freeColor = (free == 0) and "|cffff4444" or (free <= 4 and "|cffff9900" or "|cffffff00")

    g_statusLabel:SetText(
        "Status: " .. stateColor .. currentState .. "|r" ..
        "   Free Slots: " .. freeColor .. free .. "|r"
    )

    if g_enableBtn then
        g_enableBtn:SetText(EAL_DB.enabled and "Disable" or "Enable")
    end

    if g_goldLabel and EAL_DB then
        g_goldLabel:SetText(
            "Lifetime: " .. FormatMoney(EAL_DB.goldEarned) ..
            "  |cffaaaaaa(" .. (EAL_DB.itemsSold or 0) .. " items)|r"
        )
    end

    if UpdateMinimapButton then UpdateMinimapButton() end
end

EAL_RefreshStashList = function()
    if not EAL_DB then return end

    -- Merged view: account entries first, then per-char.
    local merged = {}
    for _, v in ipairs(EAL_DB.stashList or {}) do
        table.insert(merged, { scope = "account", name = v })
    end
    if EAL_CDB and EAL_CDB.stashList then
        for _, v in ipairs(EAL_CDB.stashList) do
            table.insert(merged, { scope = "char", name = v })
        end
    end

    local total = #merged
    g_stashOffset = math.max(0, math.min(g_stashOffset,
                                          math.max(0, total - MAX_ROWS)))

    for i = 1, MAX_ROWS do
        local row = g_stashRows[i]
        if row then
            local idx = g_stashOffset + i
            if idx <= total then
                local entry = merged[idx]
                local prefix = (entry.scope == "char")
                                  and "|cff87ceeb[C]|r " or "|cffb9b9b9[A]|r "
                row.label:SetText(prefix .. entry.name)
                local capturedEntry = entry
                row.removeBtn:SetScript("OnClick", function()
                    local list = (capturedEntry.scope == "char")
                                    and EAL_CDB.stashList
                                    or  EAL_DB.stashList
                    for j = #list, 1, -1 do
                        if list[j]:lower() == capturedEntry.name:lower() then
                            table.remove(list, j); break
                        end
                    end
                    EAL_RefreshStashList()
                end)
                row:Show()
            else
                row:Hide()
            end
        end
    end

    if g_stashScrollThumb then
        local trackH = MAX_ROWS * ROW_HEIGHT
        if total <= MAX_ROWS then
            g_stashScrollThumb:Hide()
        else
            local thumbH = math.max(16, trackH * MAX_ROWS / total)
            local maxOff = total - MAX_ROWS
            local thumbY = -(g_stashOffset / maxOff) * (trackH - thumbH)
            g_stashScrollThumb:SetHeight(thumbH)
            g_stashScrollThumb:SetPoint("TOP", 0, thumbY)
            g_stashScrollThumb:Show()
        end
    end
end

EAL_RefreshBlacklist = function()
    if not EAL_DB then return end

    -- Build merged view: account entries first, then per-char entries.
    -- Keep track of which list each index belongs to for correct removal.
    local merged = {}
    for _, v in ipairs(EAL_DB.blacklist) do
        table.insert(merged, { scope = "account", name = v })
    end
    if EAL_CDB and EAL_CDB.blacklist then
        for _, v in ipairs(EAL_CDB.blacklist) do
            table.insert(merged, { scope = "char", name = v })
        end
    end

    local total = #merged
    g_blacklistOffset = math.max(0, math.min(g_blacklistOffset,
                                              math.max(0, total - MAX_ROWS)))

    for i = 1, MAX_ROWS do
        local row = g_blacklistRows[i]
        if row then
            local idx = g_blacklistOffset + i
            if idx <= total then
                local entry = merged[idx]
                local prefix = (entry.scope == "char") and "|cff87ceeb[C]|r " or "|cffb9b9b9[A]|r "
                row.label:SetText(prefix .. entry.name)
                local capturedEntry = entry
                row.removeBtn:SetScript("OnClick", function()
                    local list = (capturedEntry.scope == "char")
                                    and EAL_CDB.blacklist
                                    or  EAL_DB.blacklist
                    for j = #list, 1, -1 do
                        if list[j]:lower() == capturedEntry.name:lower() then
                            table.remove(list, j)
                            break
                        end
                    end
                    EAL_RefreshBlacklist()
                end)
                row:Show()
            else
                row:Hide()
            end
        end
    end

    if g_scrollThumb then
        local trackH = MAX_ROWS * ROW_HEIGHT
        if total <= MAX_ROWS then
            g_scrollThumb:Hide()
        else
            local thumbH = math.max(16, trackH * MAX_ROWS / total)
            local maxOff = total - MAX_ROWS
            local thumbY = -(g_blacklistOffset / maxOff) * (trackH - thumbH)
            g_scrollThumb:SetHeight(thumbH)
            g_scrollThumb:SetPoint("TOP", 0, thumbY)
            g_scrollThumb:Show()
        end
    end
end

-------------------------------------------------------------------------------
-- Quick-sell by item level
--
-- Scans bags for equippable gear at or below a configurable iLvl threshold
-- (default 199) and sells it in throttled batches when the merchant window
-- is open. Filters:
--   - equipLoc must be non-empty   -> only true gear, never trade goods
--   - sellPrice > 0                -> never sells quest items or no-vendor tokens
--   - not whitelisted              -> respects account + per-char whitelist
--   - iLevel > 0 and <= threshold  -> below the user-configured cutoff
-- This is a one-shot user action, not part of the auto sell cycle, so we
-- bypass the quality-toggle logic entirely.
-------------------------------------------------------------------------------
local function EAL_ScanLowILvlGear(threshold)
    local matches, totalValue = {}, 0
    local priceMax = EAL_DB.sellPriceMax or 0
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name, _, _, iLevel, _, _, subType, _, equipLoc, _, sellPrice = GetItemInfo(link)
                -- Family filter overrides the low-iLvl scan too: an item
                -- explicitly marked "keep" is skipped even if under threshold.
                local famDecision = GetItemFamilyDecision(subType)
                if name and iLevel and iLevel > 0 and iLevel <= threshold
                   and equipLoc and equipLoc ~= ""
                   and sellPrice and sellPrice > 0
                   and (priceMax == 0 or sellPrice <= priceMax)
                   and famDecision ~= "keep"
                   and not IsBlacklisted(name) then
                    local _, count = GetContainerItemInfo(bag, slot)
                    count = count or 1
                    table.insert(matches, {
                        bag = bag, slot = slot, name = name,
                        iLevel = iLevel, sellPrice = sellPrice, count = count,
                    })
                    totalValue = totalValue + (sellPrice * count)
                end
            end
        end
    end
    return matches, totalValue
end

local function EAL_SellLowILvlGearNow(threshold)
    threshold = threshold or EAL_DB.ilvlSellThreshold or 199

    if not MerchantFrame:IsShown() then
        Print("|cffff4444No vendor open.|r Open a vendor first " ..
              "(or use |cffffff00Force Sell Now|r to summon one), then click again.")
        return
    end

    local matches = EAL_ScanLowILvlGear(threshold)
    if #matches == 0 then
        Print("No gear at iLvl |cffffff00" .. threshold .. "|r or below to sell.")
        return
    end

    local PULSE_CAP   = EAL_DB.fastMode and (MAX_SELL_PER_PULSE * FAST_MODE_BATCH_MULTIPLIER) or MAX_SELL_PER_PULSE
    local BATCH_DELAY = EAL_DB.fastMode and (SELL_BATCH_DELAY / FAST_MODE_DELAY_DIVISOR) or SELL_BATCH_DELAY
    local startMoney  = GetMoney()

    local function SellNext(idx, sold)
        sold = sold or 0
        local thisPulse = 0
        while idx <= #matches and thisPulse < PULSE_CAP do
            local m = matches[idx]
            -- Re-validate the slot in case bag contents shifted between scan
            -- and sell (consolidation, looting, etc).
            local link = GetContainerItemLink(m.bag, m.slot)
            if link then
                local n = GetItemInfo(link)
                if n == m.name then
                    UseContainerItem(m.bag, m.slot)
                    sold = sold + 1
                    thisPulse = thisPulse + 1
                end
            end
            idx = idx + 1
        end

        if idx <= #matches and MerchantFrame:IsShown() then
            After(BATCH_DELAY, function()
                if MerchantFrame:IsShown() then
                    SellNext(idx, sold)
                else
                    Print("Vendor closed mid-sell. Sold |cffffff00" .. sold .. "|r item(s).", 1, 0.6, 0.3)
                end
            end)
        else
            local delta = GetMoney() - startMoney
            if delta < 0 then delta = 0 end
            EAL_DB.goldEarned = (EAL_DB.goldEarned or 0) + delta
            EAL_DB.itemsSold  = (EAL_DB.itemsSold  or 0) + sold
            Print("Quick-sell complete. Sold |cffffff00" .. sold ..
                  "|r gear item(s) at iLvl <= " .. threshold ..
                  ".  |cffaaaaaa(earned: " .. FormatMoney(delta) .. ")|r")
            if EAL_DB.soundEnabled and EAL_DB.playSoundOnSell then
                PlaySound("AuctionWindowClose")
            end
            EAL_UpdateStatus()
        end
    end

    SellNext(1, 0)
end

-- Module-level handle so popup OnAccept can find the configured threshold.
local function EAL_PromptSellLowILvl()
    local threshold = EAL_DB.ilvlSellThreshold or 199
    local matches, totalValue = EAL_ScanLowILvlGear(threshold)
    if #matches == 0 then
        Print("No gear at iLvl |cffffff00" .. threshold .. "|r or below in bags.")
        return
    end
    local popup = StaticPopupDialogs["AUTOLOOT_CONFIRM_SELL_LOW_ILVL"]
    popup.text = string.format(
        "Sell |cffffff00%d|r gear item(s) at iLvl <= |cffffff00%d|r?\n" ..
        "|cffaaaaaaEstimated value: %s|r\n\n" ..
        "Whitelisted items are skipped. Trade goods, quest items,\n" ..
        "and items with no vendor price are never affected.",
        #matches, threshold, FormatMoney(totalValue))
    StaticPopup_Show("AUTOLOOT_CONFIRM_SELL_LOW_ILVL")
end

-------------------------------------------------------------------------------
-- Selling logic
-------------------------------------------------------------------------------
local function FinishSelling(totalSold, totalSkipped)
    if totalSold > 0 or totalSkipped > 0 then
        Print("Sold |cffffff00" .. totalSold ..
              "|r item(s). Whitelisted (kept): |cffffff00" .. totalSkipped .. "|r.")
    else
        Print("Nothing to sell with current quality settings.")
    end

    -- Money-delta accounting (captured when sell session began)
    if sellSessionActive then
        sellSessionActive = false
        local delta = GetMoney() - sellSessionStartMoney
        if delta > 0 then
            EAL_DB.goldEarned = (EAL_DB.goldEarned or 0) + delta
            EAL_DB.itemsSold  = (EAL_DB.itemsSold or 0) + totalSold
            Print("Earned this session: " .. FormatMoney(delta)
                  .. "  |cffaaaaaa(lifetime: " .. FormatMoney(EAL_DB.goldEarned) .. ")|r")
        end
        if totalSold > 0 then PlaySellSound() end
    end

    EAL_UpdateStatus()
end

local function SellItems(totalSold, totalSkipped)
    totalSold    = totalSold    or 0
    totalSkipped = totalSkipped or 0
    local sold    = 0
    local skipped = 0
    local capped  = false

    local PULSE_CAP   = EAL_DB.fastMode and (MAX_SELL_PER_PULSE * FAST_MODE_BATCH_MULTIPLIER) or MAX_SELL_PER_PULSE
    local BATCH_DELAY = EAL_DB.fastMode and (SELL_BATCH_DELAY / FAST_MODE_DELAY_DIVISOR) or SELL_BATCH_DELAY

    local priceMax = EAL_DB.sellPriceMax or 0   -- copper; 0 = disabled
    for bag = 0, 4 do
        if capped then break end
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name, _, quality, _, _, _, subType, _, _, _, sellPrice = GetItemInfo(link)
                if quality and name then
                    -- Family-filter check first; a "keep" decision always
                    -- wins and a "sell" decision forces the sale (still
                    -- subject to whitelist + price-cap safety below).
                    local famDecision = GetItemFamilyDecision(subType)
                    local sell
                    if famDecision == "keep" then
                        sell = false
                        skipped = skipped + 1
                    elseif famDecision == "sell" then
                        sell = (sellPrice and sellPrice > 0) and true or false
                    else
                        sell =
                            (quality == Q_GREY     and EAL_DB.sellGrey)     or
                            (quality == Q_WHITE    and EAL_DB.sellWhite)    or
                            (quality == Q_UNCOMMON and EAL_DB.sellUncommon) or
                            (quality == Q_RARE     and EAL_DB.sellRare)     or
                            (quality == Q_EPIC     and EAL_DB.sellEpic)
                    end

                    if sell and IsBlacklisted(name) then
                        sell = false
                        skipped = skipped + 1
                    end

                    -- Per-item price cap. Protects expensive BoEs from
                    -- accidental sale even if their quality is ticked.
                    if sell and priceMax > 0 and sellPrice and sellPrice > priceMax then
                        sell = false
                        skipped = skipped + 1
                    end

                    if sell then
                        UseContainerItem(bag, slot)
                        sold = sold + 1
                        if sold >= PULSE_CAP then
                            capped = true
                            break
                        end
                    end
                end
            end
        end
    end

    totalSold    = totalSold    + sold
    totalSkipped = totalSkipped + skipped

    if capped and MerchantFrame:IsShown() then
        After(BATCH_DELAY, function()
            if MerchantFrame:IsShown() then
                SellItems(totalSold, totalSkipped)
            else
                FinishSelling(totalSold, totalSkipped)
            end
        end)
    else
        FinishSelling(totalSold, totalSkipped)
    end
end

-------------------------------------------------------------------------------
-- State machine
-------------------------------------------------------------------------------
local function SetState(state)
    currentState = state
    EAL_UpdateStatus()
end

local function StartLootCycle()
    if not EAL_DB or not EAL_DB.enabled then return end
    SetState(S_LOOTING)
    bagCheckTimer = 0
    Print("Loot cycle started. Summoning " .. EAL_DB.lootCompanion .. "...")
    SummonPet(EAL_DB.lootCompanion)
end

local function StartSellCycle()
    if currentState == S_SELLING then return end

    -- Defer while mounted or in combat.  StartSellCycle was previously
    -- willing to dismiss the loot pet and start summoning the vendor pet
    -- mid-mount, which the mount-watcher would then immediately undo --
    -- producing a 1.5s summon-and-dismiss dance.  Latch the pending sell
    -- and consume it in the mount watcher / PLAYER_REGEN_ENABLED handler.
    if IsPlayerMountedOrFlying() then
        pendingSellCycle = true
        Print("Bags full - sell cycle will start when you dismount.", 1, 0.75, 0.2)
        return
    end
    if InCombatLockdown() then
        pendingSellCycle = true
        Print("Bags full - sell cycle will start when combat ends.", 1, 0.75, 0.2)
        return
    end

    pendingSellCycle = false
    bagsFullLockout  = false
    SetState(S_SELLING)
    triggeredSellCycle = true
    Print("Bags full - summoning " .. EAL_DB.vendorCompanion .. "...")
    DismissPet()

    After(1.5, function()
        local ok = SummonPet(EAL_DB.vendorCompanion)
        if ok then
            waitingForMerchant = true
            if InCombatLockdown() then
                Print("|cffffd700In combat:|r click |cffffff00Target Vendor|r to select the merchant," ..
                      " then |cffffd700right-click its model|r or press your" ..
                      " |cffffff00Interact with Target|r keybind to open the vendor.")
            end
            After(8, function()
                if waitingForMerchant and currentState == S_SELLING then
                    PlayAlertSound()
                    Print("|cffffd700Reminder:|r target " .. EAL_DB.vendorCompanion ..
                          " then right-click it or press Interact with Target.", 1, 1, 0)
                end
            end)
        end
    end)
end

-- Consumed by the mount watcher and PLAYER_REGEN_ENABLED handler when
-- the earlier StartSellCycle call was deferred.  Kept alongside
-- StartSellCycle so both live near the state-machine transitions.
local function TryStartDeferredSell()
    if not pendingSellCycle then return end
    if not EAL_DB or not EAL_DB.enabled then
        pendingSellCycle = false; return
    end
    if IsPlayerMountedOrFlying() or InCombatLockdown() then return end
    -- Clear inside StartSellCycle after it commits to running.
    StartSellCycle()
end

-- Fired on MERCHANT_SHOW. Only acts when we triggered the sell cycle OR
-- the user opted into "sell at any vendor". Prevents accidental sells at
-- repair / quest vendors during normal play.
local function OnMerchantShow()
    waitingForMerchant = false
    local shouldSell = triggeredSellCycle or EAL_DB.sellOnAnyVendor
    if not shouldSell then return end

    -- Capture starting money for delta accounting
    sellSessionStartMoney = GetMoney()
    sellSessionActive     = true

    After(0.3, function()
        if CanMerchantRepair() then
            local cost = GetRepairAllCost() or 0
            local cap  = EAL_DB.repairCostCap or 0
            if cost == 0 then
                -- Nothing to repair; silent.
            elseif cap > 0 and cost > cap then
                Print("|cffff4444Repair cost " .. FormatMoney(cost) ..
                      " exceeds cap " .. FormatMoney(cap) ..
                      ". Skipping repair.|r")
            else
                RepairAllItems()
                Print("All items repaired.  |cffaaaaaa(" .. FormatMoney(cost) .. ")|r")
            end
        end

        SellItems()
    end)
end

local function OnMerchantClosed()
    triggeredSellCycle = false
    if currentState == S_SELLING then
        local free = GetTotalFreeSlots()
        if EAL_DB.enabled and free > 0 then
            bagsFullLockout = false
            After(1, StartLootCycle)
        elseif EAL_DB.enabled and free == 0 then
            -- Pre-4.12 this silently transitioned to IDLE and the user was
            -- stuck with full bags and no message.  Now surface it and
            -- offer a manual retry.  We do NOT auto-loop; likely the last
            -- slots are BoP quest/soulbound junk that no vendor can take,
            -- so a blind retry would burn merchant summons forever.
            bagsFullLockout = true
            SetState(S_IDLE)
            PlayAlertSound()
            Print("|cffff4444Bags still full after selling.|r Likely soulbound / quest items.")
            Print("|cffaaaaaaClear a slot manually, then |cffffff00/eal|r resumes automatically.|r" ..
                  "  Or |cffffff00/eal sell|r to try again.")
        else
            SetState(S_IDLE)
        end
    end
end

-- Companion may despawn on its own (out of range, world change, server
-- hiccup).  When it does, GetCompanionInfo's summoned flag flips false
-- while we're still in S_LOOTING / S_SELLING, so we re-summon.  This is
-- the fix for the pre-4.12 pet-distance check that used UnitPosition("pet")
-- (which refers to combat pets in 3.3.5a, never to critter companions).
local function CheckCompanionStuck()
    if IsPlayerMountedOrFlying() then return end
    if currentState ~= S_LOOTING and currentState ~= S_SELLING then return end
    if IsExpectedCompanionActive() then return end

    local target
    if currentState == S_LOOTING then target = EAL_DB.lootCompanion
    else                              target = EAL_DB.vendorCompanion end
    if not target or target == "" then return end

    Print(target .. " despawned - resummoning...", 1, 0.75, 0.2)
    SummonPet(target)
end

-- OPT-IN: Scans bags for items with NO vendor price whose quality is in the
-- user-configured per-quality set, and deletes them one at a time.
-- Controlled by EAL_DB.autoDeleteUnsellable = { enabled, common, uncommon, rare, epic }.
-- The Grey/Poor tier is intentionally excluded -- grey items always have a
-- vendor price by design and would never match the "no sell price" filter.
local g_deletingUnsellable = false

local function EAL_IsAutoDeleteQuality(quality)
    local cfg = EAL_DB and EAL_DB.autoDeleteUnsellable
    if not cfg or not cfg.enabled then return false end
    if quality == Q_GREY     and cfg.grey     then return true end
    if quality == Q_WHITE    and cfg.common   then return true end
    if quality == Q_UNCOMMON and cfg.uncommon then return true end
    if quality == Q_RARE     and cfg.rare     then return true end
    if quality == Q_EPIC     and cfg.epic     then return true end
    return false
end

-- True when this quality+item combination should be auto-deleted under
-- the current settings.  Grey is special-cased to ignore the vendor-price
-- filter (delete ALL greys when configured); other qualities only delete
-- when the item has no vendor price.
local function EAL_ShouldAutoDelete(quality, vendorPrice, name, subType)
    if not EAL_IsAutoDeleteQuality(quality) then return false end
    if name and IsBlacklisted(name) then return false end
    -- Family filter "keep" overrides auto-delete too, so users can safely
    -- turn on "delete greys" while keeping specific families like Herbs.
    if GetItemFamilyDecision(subType) == "keep" then return false end
    if quality == Q_GREY then
        return true   -- delete all greys regardless of vendor price
    end
    return (not vendorPrice) or vendorPrice == 0
end

local function EAL_DeleteUnsellableItems()
    local cfg = EAL_DB and EAL_DB.autoDeleteUnsellable
    if not cfg or not cfg.enabled then return end
    if not (cfg.grey or cfg.common or cfg.uncommon or cfg.rare or cfg.epic) then return end
    if g_deletingUnsellable or InCombatLockdown() then return end

    local toDelete = {}
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name, _, quality, _, _, _, subType, _, _, _, vendorPrice = GetItemInfo(link)
                if name and EAL_ShouldAutoDelete(quality, vendorPrice, name, subType) then
                    table.insert(toDelete, { bag = bag, slot = slot, quality = quality })
                end
            end
        end
    end

    if #toDelete == 0 then return end

    g_deletingUnsellable = true
    local total = #toDelete

    local function DeleteNext(idx)
        if idx > #toDelete then
            g_deletingUnsellable = false
            Print("|cffffff00" .. total .. "|r unsellable item(s) with no sell price deleted.")
            return
        end
        local item = toDelete[idx]
        local link = GetContainerItemLink(item.bag, item.slot)
        if link then
            local name, _, quality, _, _, _, subType, _, _, _, vendorPrice = GetItemInfo(link)
            if name and EAL_ShouldAutoDelete(quality, vendorPrice, name, subType) then
                ClearCursor()
                PickupContainerItem(item.bag, item.slot)
                DeleteCursorItem()
                After(0.05, function()
                    local popup = StaticPopup_FindVisible("DELETE_ITEM")
                    if popup then
                        local btn = _G[popup .. "Button1"]
                        if btn then btn:Click() end
                    end
                    After(0.15, function() DeleteNext(idx + 1) end)
                end)
                return
            end
        end
        DeleteNext(idx + 1)
    end

    DeleteNext(1)
end

-------------------------------------------------------------------------------
-- Bank auto-deposit
--
-- Fires on BANKFRAME_OPENED when the per-character autoDepositToBank toggle
-- is on. Scans bags for items whose names match the stash list (union of
-- account + per-character entries) and moves them into the first available
-- bank slot, one at a time with a small delay between moves to avoid
-- flooding the protected-action queue.
--
-- Bank slot inventory in 3.3.5a:
--   bag -1     : main bank (28 slots)
--   bags 5..11 : the 7 bank-bag slots (variable slot count per bag)
-- Player bags 0..4 are the source, not the destination.
-------------------------------------------------------------------------------
local BANK_BAGS = { -1, 5, 6, 7, 8, 9, 10, 11 }
local g_depositingToBank = false

-- Walk bank slots for an existing partial stack we can merge into; fall back
-- to the first empty slot. Returns (bag, slot) or nil if the bank is full.
local function EAL_FindBankSlotFor(itemName, count)
    -- Pass 1: existing partial stack
    if itemName then
        for _, bag in ipairs(BANK_BAGS) do
            local numSlots = GetContainerNumSlots(bag) or 0
            for slot = 1, numSlots do
                local link = GetContainerItemLink(bag, slot)
                if link then
                    local n, _, _, _, _, _, _, stackMax = GetItemInfo(link)
                    if n == itemName and stackMax and stackMax > 1 then
                        local _, slotCount = GetContainerItemInfo(bag, slot)
                        slotCount = slotCount or 1
                        if slotCount + (count or 1) <= stackMax then
                            return bag, slot
                        end
                    end
                end
            end
        end
    end
    -- Pass 2: empty slot
    for _, bag in ipairs(BANK_BAGS) do
        local numSlots = GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            if not GetContainerItemLink(bag, slot) then
                return bag, slot
            end
        end
    end
    return nil, nil
end

local function EAL_DepositStashItems(force)
    if g_depositingToBank then return end
    if not BankFrame or not BankFrame:IsShown() then
        if force then
            Print("|cffff4444Bank not open.|r Open the bank first.")
        end
        return
    end
    if not force and not (EAL_CDB and EAL_CDB.autoDepositToBank) then
        return    -- auto-deposit is off for this character
    end

    -- Scan bags for matching items
    local toDeposit = {}
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name = GetItemInfo(link)
                if name and IsInStashList(name) then
                    local _, count = GetContainerItemInfo(bag, slot)
                    table.insert(toDeposit, {
                        bag = bag, slot = slot, name = name, count = count or 1,
                    })
                end
            end
        end
    end

    if #toDeposit == 0 then
        if force then Print("Nothing in stash list to deposit.") end
        return
    end

    g_depositingToBank = true
    local moved = 0
    local startCount = #toDeposit

    local function DepositNext(idx)
        if idx > #toDeposit then
            g_depositingToBank = false
            if moved > 0 then
                Print("Deposited |cffffff00" .. moved ..
                      "|r item(s) to bank (of " .. startCount .. " in stash list).")
            end
            return
        end

        local item = toDeposit[idx]
        -- Re-validate the slot since bags may have shifted between scan and move
        local link = GetContainerItemLink(item.bag, item.slot)
        if not link then
            DepositNext(idx + 1); return
        end
        local n = GetItemInfo(link)
        if n ~= item.name then
            DepositNext(idx + 1); return
        end

        local bankBag, bankSlot = EAL_FindBankSlotFor(item.name, item.count)
        if not bankBag then
            -- Bank full
            g_depositingToBank = false
            Print("|cffff4444Bank full.|r Deposited " .. moved ..
                  " item(s) before running out of space.")
            return
        end

        ClearCursor()
        PickupContainerItem(item.bag, item.slot)
        -- Confirm we actually picked it up (some items refuse to be picked up)
        local cursorType = GetCursorInfo()
        if cursorType ~= "item" then
            ClearCursor()
            DepositNext(idx + 1); return
        end
        PickupContainerItem(bankBag, bankSlot)
        moved = moved + 1

        After(0.05, function() DepositNext(idx + 1) end)
    end

    DepositNext(1)
end

-------------------------------------------------------------------------------
-- Guild bank stack consolidation
--
-- Operates on the currently-displayed guild bank tab. Scans all 98 slots
-- (7 columns x 14 rows) for partial stacks of the same item, then greedily
-- merges the smallest source into the largest target with room.  After each
-- move it re-scans state and re-picks the next pair, so it converges no
-- matter what the user does mid-cycle.
--
-- Permission model: requires canView + canDeposit on the tab.  Withdrawals
-- within a tab count against the daily withdrawal counter on most cores,
-- so trial members with 0 remaining will see "cursor empty after pickup"
-- and the loop terminates cleanly.
--
-- Move primitive (within one tab):
--   1. PickupGuildBankItem(tab, src)       -- whole stack to cursor
--   2. PickupGuildBankItem(tab, dst)       -- merges; leftover stays on cursor
--   3. if cursor still has items, PickupGuildBankItem(tab, src) to put back
--
-- Throttled at ~0.6s per move to stay under server rate limits.
-------------------------------------------------------------------------------
local GBANK_NUM_SLOTS = 98
local g_consolidatingGB = false

local function EAL_ConsolidateGuildBankCurrentTab()
    if g_consolidatingGB then return end

    if not GuildBankFrame or not GuildBankFrame:IsShown() then
        Print("|cffff4444Guild bank not open.|r Open it first.")
        return
    end

    local tab = GetCurrentGuildBankTab and GetCurrentGuildBankTab()
    if not tab or tab == 0 then
        Print("|cffff4444No guild bank tab selected.|r Click an item tab first.")
        return
    end

    -- Permission check.  canView + canDeposit on the tab.  numWithdrawals
    -- (4th return) is the per-day counter; 0 means "out for the day".
    local canView, canDeposit, _, numWithdrawals = GetGuildBankTabPermissions(tab)
    if not canView then
        Print("|cffff4444No permission to view tab " .. tab .. ".|r")
        return
    end
    if not canDeposit then
        Print("|cffff4444No permission to deposit/rearrange tab " .. tab ..
              ".|r  Consolidation needs both view and deposit.")
        return
    end
    if numWithdrawals == 0 then
        Print("|cffff9900Tab " .. tab .. ": 0 daily withdrawals remaining.|r " ..
              "Moves will be rejected by the server.")
        -- We still run -- a guild master with unlimited slots is reported as
        -- some sentinel value (e.g. -1 or a huge number), so 0 is the only
        -- safe "definitely blocked" reading.
    end

    g_consolidatingGB = true
    local moves, capped = 0, false
    -- "src:dst" pairs we have already tried.  Prevents an infinite loop when
    -- a move silently fails (e.g. server rate limit, latency spike, expired
    -- withdraw) and the same pair would otherwise be picked again next pass.
    local attempts = {}
    local MAX_MOVES = 60

    local function DoNext()
        if capped then
            g_consolidatingGB = false
            Print("Guild bank consolidation hit the " .. MAX_MOVES ..
                  "-move safety cap.  Re-run to continue.")
            return
        end

        if not GuildBankFrame or not GuildBankFrame:IsShown() then
            g_consolidatingGB = false
            Print("Guild bank closed mid-consolidation. Moves so far: " .. moves)
            return
        end

        -- Rescan and pick the next merge, skipping pairs we've already tried.
        local partials = {}
        for slot = 1, GBANK_NUM_SLOTS do
            local link = GetGuildBankItemLink(tab, slot)
            if link then
                local _, count = GetGuildBankItemInfo(tab, slot)
                local _, _, _, _, _, _, _, stackMax = GetItemInfo(link)
                if count and stackMax and stackMax > 1 and count < stackMax then
                    local itemID = link:match("item:(%d+)")
                    if itemID then
                        partials[itemID] = partials[itemID] or {}
                        table.insert(partials[itemID], {
                            slot = slot, count = count, stackMax = stackMax,
                        })
                    end
                end
            end
        end

        local srcSlot, dstSlot, amount
        for _, list in pairs(partials) do
            if #list >= 2 then
                table.sort(list, function(a, b) return a.count < b.count end)
                local s, d = list[1], list[#list]
                local key = s.slot .. ":" .. d.slot
                if not attempts[key] then
                    srcSlot = s.slot
                    dstSlot = d.slot
                    amount  = math.min(s.count, d.stackMax - d.count)
                    attempts[key] = true
                    break
                end
            end
        end

        if not srcSlot then
            g_consolidatingGB = false
            if moves > 0 then
                Print("Guild bank tab " .. tab .. ": consolidation complete (" ..
                      moves .. " move(s)).")
            else
                Print("Guild bank tab " .. tab ..
                      ": nothing left to consolidate.")
            end
            return
        end

        -- Step 1: Split off exactly `amount` items from source onto cursor.
        -- SplitGuildBankItem is the clean primitive here -- no leftover to
        -- handle because we only pick up what fits in dst.  PickupGuildBank
        -- whole-stack works too if Split isn't available, but it leaks a
        -- leftover whenever source > dst-room.
        ClearCursor()
        if SplitGuildBankItem then
            SplitGuildBankItem(tab, srcSlot, amount)
        else
            PickupGuildBankItem(tab, srcSlot)
        end

        -- Step 2: After server roundtrip (typical 200-400ms in 3.3.5a),
        -- drop on destination.  0.6s is conservative but reliable.
        After(0.6, function()
            if not GuildBankFrame or not GuildBankFrame:IsShown() then
                ClearCursor()
                g_consolidatingGB = false
                Print("Guild bank closed mid-move. Moves: " .. moves)
                return
            end
            PickupGuildBankItem(tab, dstSlot)

            -- Step 3: Settle, then iterate.
            After(0.6, function()
                -- Defensive: if anything is still on the cursor (e.g. dst
                -- was different item and a swap happened that we don't
                -- want), drop it back at the source slot.
                if CursorHasItem() then
                    PickupGuildBankItem(tab, srcSlot)
                    After(0.4, function()
                        ClearCursor()
                        moves = moves + 1
                        if moves >= MAX_MOVES then capped = true end
                        DoNext()
                    end)
                else
                    moves = moves + 1
                    if moves >= MAX_MOVES then capped = true end
                    DoNext()
                end
            end)
        end)
    end

    Print("Guild bank tab " .. tab .. ": consolidating partial stacks...")
    DoNext()
end

-------------------------------------------------------------------------------
-- Personal bank stack consolidation
--
-- Mirrors EAL_ConsolidateGuildBankCurrentTab but operates on the player's
-- own bank: main bank (bag -1) plus the seven bank-bag slots (5..11).
-- Player bags 0..4 are NEVER touched -- this is bank-only.
--
-- Personal bank moves are much faster than guild bank ones (no per-tab
-- withdrawal counter, no aggressive server rate-limit), so the per-move
-- delay is 0.2s vs the guild bank's 0.6s.  Move primitive is identical:
--   SplitContainerItem(src.bag, src.slot, amount)
--   PickupContainerItem(dst.bag, dst.slot)
-- followed by a "if anything left on cursor, put back at source" check.
-------------------------------------------------------------------------------
local PERSONAL_BANK_BAGS = { -1, 5, 6, 7, 8, 9, 10, 11 }
local g_consolidatingBank = false

local function EAL_ConsolidatePersonalBank()
    if g_consolidatingBank then return end

    if not BankFrame or not BankFrame:IsShown() then
        Print("|cffff4444Bank not open.|r Open it first.")
        return
    end

    g_consolidatingBank = true
    local moves, capped = 0, false
    -- "bag/slot -> bag/slot" pairs we've already attempted.  Prevents an
    -- infinite loop if a move fails silently (e.g. item is somehow locked
    -- or a race with another addon's bag operations).
    local attempts = {}
    -- Bank can hold 28 + 7*36 = 280 slots, so the move ceiling is higher
    -- than guild bank's 60.  100 is comfortably above any realistic run.
    local MAX_MOVES = 100

    local function DoNext()
        if capped then
            g_consolidatingBank = false
            Print("Bank consolidation hit the " .. MAX_MOVES ..
                  "-move safety cap.  Re-run to continue.")
            return
        end

        if not BankFrame or not BankFrame:IsShown() then
            g_consolidatingBank = false
            Print("Bank closed mid-consolidation. Moves so far: " .. moves)
            return
        end

        -- Rescan all bank slots, build partials map.
        local partials = {}
        for _, bag in ipairs(PERSONAL_BANK_BAGS) do
            local numSlots = GetContainerNumSlots(bag) or 0
            for slot = 1, numSlots do
                local link = GetContainerItemLink(bag, slot)
                if link then
                    local _, count = GetContainerItemInfo(bag, slot)
                    local _, _, _, _, _, _, _, stackMax = GetItemInfo(link)
                    if count and stackMax and stackMax > 1 and count < stackMax then
                        local itemID = link:match("item:(%d+)")
                        if itemID then
                            partials[itemID] = partials[itemID] or {}
                            table.insert(partials[itemID], {
                                bag = bag, slot = slot,
                                count = count, stackMax = stackMax,
                            })
                        end
                    end
                end
            end
        end

        -- Pick smallest source into largest destination per item type,
        -- skipping any pair we've already tried.
        local src, dst, amount
        for _, list in pairs(partials) do
            if #list >= 2 then
                table.sort(list, function(a, b) return a.count < b.count end)
                local s, d = list[1], list[#list]
                local key = s.bag .. "/" .. s.slot .. "->" .. d.bag .. "/" .. d.slot
                if not attempts[key] then
                    src = s; dst = d
                    amount = math.min(s.count, d.stackMax - d.count)
                    attempts[key] = true
                    break
                end
            end
        end

        if not src then
            g_consolidatingBank = false
            if moves > 0 then
                Print("Bank consolidation complete (" .. moves .. " move(s)).")
            else
                Print("Bank: nothing to consolidate.")
            end
            return
        end

        -- Move: split exact amount off source, drop on dest.
        ClearCursor()
        if SplitContainerItem then
            SplitContainerItem(src.bag, src.slot, amount)
        else
            PickupContainerItem(src.bag, src.slot)
        end

        After(0.2, function()
            if not BankFrame or not BankFrame:IsShown() then
                ClearCursor()
                g_consolidatingBank = false
                Print("Bank closed mid-move. Moves: " .. moves)
                return
            end
            PickupContainerItem(dst.bag, dst.slot)

            After(0.2, function()
                -- Defensive: anything still on cursor (different item at
                -- dst, locked slot, etc) -- put it back at source.
                if CursorHasItem() then
                    PickupContainerItem(src.bag, src.slot)
                    After(0.15, function()
                        ClearCursor()
                        moves = moves + 1
                        if moves >= MAX_MOVES then capped = true end
                        DoNext()
                    end)
                else
                    moves = moves + 1
                    if moves >= MAX_MOVES then capped = true end
                    DoNext()
                end
            end)
        end)
    end

    Print("Bank: consolidating partial stacks...")
    DoNext()
end

-------------------------------------------------------------------------------
-- Mail auto-collect + auto-clean
--
-- Fires on MAIL_SHOW when EAL_CDB.mailAutoCollect is on. Walks every mail in
-- the inbox and takes the money / item attachments according to the user's
-- sub-toggles.  COD mail is always skipped (we NEVER auto-pay a CODAmount).
--
-- Most 3.3.5a servers rate-limit mail actions to ~1/second, so we space
-- each TakeInboxItem / TakeInboxMoney call by 0.6s.  TakeInboxItem fires
-- a MAIL_INBOX_UPDATE event that can renumber the inbox; we capture the
-- index list at the start and re-validate before each action.
--
-- Auto-delete runs after collection: iterates the inbox backwards (so
-- earlier indices stay valid as later ones are deleted) and removes any
-- mail that is wasRead, has no money, no items, and no CODAmount.
-------------------------------------------------------------------------------
local g_processingMail = false

-- Returns true if this mail is "fully empty" -- read, no money, no items,
-- no COD owed.  Safe to DeleteInboxItem.
local function EAL_IsMailDeletable(idx)
    local _, _, _, _, money, codAmount, _, itemCount, wasRead = GetInboxHeaderInfo(idx)
    return wasRead and (money or 0) == 0 and (codAmount or 0) == 0
                   and (itemCount or 0) == 0
end

local function EAL_CleanReadMail()
    if g_processingMail then return end
    if not MailFrame or not MailFrame:IsShown() then return end

    local n = GetInboxNumItems() or 0
    if n == 0 then return end

    g_processingMail = true
    local deleted = 0

    -- Iterate backward so each deletion doesn't shift indices below.
    local function CleanNext(idx)
        if idx < 1 then
            g_processingMail = false
            if deleted > 0 then
                Print("Deleted |cffffff00" .. deleted ..
                      "|r read empty mail(s).")
            end
            return
        end
        if EAL_IsMailDeletable(idx) then
            DeleteInboxItem(idx)
            deleted = deleted + 1
            After(0.3, function() CleanNext(idx - 1) end)
        else
            CleanNext(idx - 1)
        end
    end

    CleanNext(GetInboxNumItems() or 0)
end

local function EAL_AutoCollectMail(force)
    if g_processingMail then return end
    if not MailFrame or not MailFrame:IsShown() then
        if force then Print("|cffff4444Mailbox not open.|r") end
        return
    end
    local cfg = EAL_CDB
    if not force and not (cfg and cfg.mailAutoCollect) then return end

    local total = GetInboxNumItems() or 0
    if total == 0 then
        if force then Print("Mailbox is empty.") end
        return
    end

    g_processingMail = true
    local moneyTaken, itemsTaken, codSkipped = 0, 0, 0

    -- We walk forward, but indices can shift when mail expires or is
    -- received.  Re-read the header on each iteration.
    local function ProcessNext(idx)
        if idx > GetInboxNumItems() or idx > total then
            g_processingMail = false
            -- Summary
            local msg = "Mail: "
            local parts = {}
            if moneyTaken > 0 then table.insert(parts, FormatMoney(moneyTaken) .. " collected") end
            if itemsTaken > 0 then table.insert(parts, itemsTaken .. " item(s) collected") end
            if codSkipped > 0 then table.insert(parts, "|cffff9900" .. codSkipped .. " COD skipped|r") end
            if #parts == 0 then
                Print("Mail: nothing to collect.")
            else
                Print(msg .. table.concat(parts, ", ") .. ".")
            end

            -- Optional cleanup pass
            if cfg.mailAutoDeleteRead then
                After(0.4, EAL_CleanReadMail)
            end
            return
        end

        local _, _, sender, subject, money, codAmount, _, itemCount, _, _ =
            GetInboxHeaderInfo(idx)

        -- COD safety -- never auto-pay a CODAmount
        if (codAmount or 0) > 0 then
            codSkipped = codSkipped + 1
            ProcessNext(idx + 1)
            return
        end

        -- Take money first if present and configured
        if (money or 0) > 0 and cfg.mailCollectMoney then
            TakeInboxMoney(idx)
            moneyTaken = moneyTaken + money
            After(0.6, function() ProcessNext(idx) end)   -- re-check same idx for items
            return
        end

        -- Then take all item attachments if configured
        if (itemCount or 0) > 0 and cfg.mailCollectItems then
            -- Find the first attachment slot that still has an item.
            local takeSlot
            for a = 1, 16 do   -- max attachments per mail in 3.3.5a is ~16
                local name = GetInboxItem(idx, a)
                if name then takeSlot = a; break end
            end
            if takeSlot then
                TakeInboxItem(idx, takeSlot)
                itemsTaken = itemsTaken + 1
                After(0.6, function() ProcessNext(idx) end)
                return
            end
        end

        ProcessNext(idx + 1)
    end

    ProcessNext(1)
end

-------------------------------------------------------------------------------
-- Whitelist quick-add helpers (drag-drop + Ctrl+Shift+Click hook)
--
-- Both paths funnel through EAL_LoadIntoWhitelistInput, which writes the item
-- name into the whitelist input box (EAL_BlacklistInput) and prints a hint.
-- The user then clicks +Acct or +Char to commit. We deliberately do NOT
-- auto-commit, so an accidental drag still requires one click before the
-- whitelist is mutated.
-------------------------------------------------------------------------------
-- Routes a dropped/clicked item to either the whitelist or the bank stash
-- input, based on which tab is currently active.  If neither is active,
-- defaults to the whitelist tab.
-- Tab-index constants (must match the layout in EAL_BuildGUI).
local TAB_WHITELIST_IDX = 3
local TAB_BANK_IDX      = 4

local function EAL_LoadIntoListInput(itemName)
    if not itemName or itemName == "" then return false end

    local targetTab = TAB_WHITELIST_IDX   -- default: Whitelist
    local inputName = "EAL_BlacklistInput"
    local listLabel = "Whitelist"

    if EAL_DB and EAL_DB.lastTab == TAB_BANK_IDX then
        targetTab = TAB_BANK_IDX
        inputName = "EAL_StashInput"
        listLabel = "Stash"
    end

    local input = _G[inputName]
    if not input then
        Print("|cffff4444" .. listLabel ..
              " input not ready. Open AutoLoot first.|r")
        return false
    end
    input:SetText(itemName)

    if EAL_Window and not EAL_Window:IsShown() then EAL_Window:Show() end
    if EAL_DB.lastTab ~= targetTab and EAL_Window then
        if type(EAL_Window.ShowTab) == "function" then
            EAL_Window.ShowTab(targetTab)
        else
            EAL_DB.lastTab = targetTab
        end
    end
    Print(listLabel .. ": |cffffff00" .. itemName ..
          "|r loaded. Click |cffb9b9b9+Acct|r or |cff87ceeb+Char|r to commit.")
    return true
end

-- Back-compat alias: existing callers still use the old name.
local EAL_LoadIntoWhitelistInput = EAL_LoadIntoListInput

-- Hook HandleModifiedItemClick: Ctrl+Shift+Click an item link anywhere
-- (bag, chat, tooltip, AH, etc.) and we load its name into the whitelist.
-- We chose Ctrl+Shift because no Blizzard UI element binds it by default.
-- Plain Shift-click still inserts into chat as normal.
local _origHandleModifiedItemClick = HandleModifiedItemClick
HandleModifiedItemClick = function(link, ...)
    if link and IsControlKeyDown() and IsShiftKeyDown() then
        local name = GetItemInfo(link)
        if name and EAL_LoadIntoWhitelistInput(name) then
            return true   -- swallow the click; don't fall through to chat
        end
    end
    return _origHandleModifiedItemClick(link, ...)
end

-------------------------------------------------------------------------------
-- Whitelist import / export  (v4.12)
--
-- Format: plain-text, human-readable, no compression / base64.  Item names
-- can contain spaces, apostrophes, accented characters, colons ("Tome of
-- Echo:") etc., but never `|` or newlines, so we use `|` as the separator.
--
--   EBWL:v1:A:name1|name2|...::C:name1|name2|...
--
-- Both scope sections are optional; missing scope = empty section.
-- Parser is lenient: whitespace around names is trimmed and empty names
-- are dropped so a trailing `|` never causes an empty entry.
-------------------------------------------------------------------------------
local WHITELIST_EXPORT_VERSION = "v1"
local WHITELIST_EXPORT_PREFIX  = "EBWL:" .. WHITELIST_EXPORT_VERSION .. ":"

local function EAL_ExportWhitelist()
    local acct = (EAL_DB and EAL_DB.blacklist) or {}
    local char = (EAL_CDB and EAL_CDB.blacklist) or {}
    return WHITELIST_EXPORT_PREFIX ..
           "A:" .. table.concat(acct, "|") ..
           "::" ..
           "C:" .. table.concat(char, "|")
end

-- Parses str; returns (acctList, charList) or (nil, errMsg).
local function EAL_ParseWhitelistString(str)
    if type(str) ~= "string" then return nil, "empty input" end
    str = str:match("^%s*(.-)%s*$") or ""
    if str == "" then return nil, "empty input" end
    if str:sub(1, #WHITELIST_EXPORT_PREFIX) ~= WHITELIST_EXPORT_PREFIX then
        return nil, "not an EBWL export string"
    end
    local body = str:sub(#WHITELIST_EXPORT_PREFIX + 1)
    -- Split on `::` to get the two scope sections.
    local acctSection, charSection = body:match("^(.-)::(.*)$")
    if not acctSection then
        -- Older or single-scope form: treat entire body as one section.
        acctSection = body; charSection = ""
    end
    local function _parseSection(sec, tag)
        local names = {}
        local payload = sec:match("^" .. tag .. ":(.*)$") or ""
        for entry in payload:gmatch("([^|]+)") do
            local n = entry:match("^%s*(.-)%s*$")
            if n and n ~= "" then table.insert(names, n) end
        end
        return names
    end
    return _parseSection(acctSection, "A"), _parseSection(charSection, "C")
end

-- Merges parsed lists into the live tables.  Returns (addedAcct, addedChar,
-- skippedDupes).  Uses IsBlacklisted for the dupe check so an entry that
-- already exists in either scope isn't re-added.
local function EAL_ImportWhitelist(str)
    local acct, char = EAL_ParseWhitelistString(str)
    if not acct then return nil, char end   -- char is the error message here
    local addedA, addedC, skipped = 0, 0, 0
    for _, name in ipairs(acct) do
        if IsBlacklisted(name) then skipped = skipped + 1
        else table.insert(EAL_DB.blacklist, name); addedA = addedA + 1 end
    end
    for _, name in ipairs(char) do
        if IsBlacklisted(name) then skipped = skipped + 1
        else table.insert(EAL_CDB.blacklist, name); addedC = addedC + 1 end
    end
    if EAL_RefreshBlacklist then EAL_RefreshBlacklist() end
    return addedA, addedC, skipped
end

-- Popup window (lazy-built on first use).  One frame is reused for both
-- export (read-only text) and import (editable text).
local g_whitelistIOFrame

local function EAL_ShowWhitelistIO(mode)
    if not g_whitelistIOFrame then
        local f = CreateFrame("Frame", "EAL_WhitelistIOFrame", UIParent)
        f:SetSize(480, 260)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        f:SetBackdropColor(0.10, 0.06, 0.18, 0.95)
        f:SetBackdropBorderColor(0.75, 0.55, 0.95, 1)

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -14)
        f.title = title

        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("TOP", 0, -36)
        hint:SetJustifyH("CENTER")
        f.hint = hint

        local sf = CreateFrame("ScrollFrame", "EAL_WhitelistIOScroll", f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT",     f, "TOPLEFT",      14,  -60)
        sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32,   46)
        local edit = CreateFrame("EditBox", nil, sf)
        edit:SetMultiLine(true)
        edit:SetFontObject("ChatFontNormal")
        edit:SetAutoFocus(false)
        edit:SetWidth(420)
        -- 3.3.5a EditBox default cap is 255; a large explicit limit is
        -- safer than passing 0 which some builds treat as "no input".
        edit:SetMaxLetters(50000)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        sf:SetScrollChild(edit)
        f.edit = edit

        local go = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
        go:SetSize(120, 22); go:SetPoint("BOTTOMLEFT", 18, 14)
        f.goBtn = go

        local close = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
        close:SetSize(80, 22); close:SetPoint("BOTTOMRIGHT", -18, 14)
        close:SetText("Close")
        close:SetScript("OnClick", function() f:Hide() end)

        g_whitelistIOFrame = f
    end

    local f = g_whitelistIOFrame
    f.edit:SetScript("OnTextChanged", nil)   -- clear any prior handler
    if mode == "export" then
        local str = EAL_ExportWhitelist()
        local acct = (EAL_DB and EAL_DB.blacklist) or {}
        local char = (EAL_CDB and EAL_CDB.blacklist) or {}
        f.title:SetText("|cffffd700Export Whitelist|r")
        f.hint:SetText("|cffaaaaaaCtrl+A to select all, Ctrl+C to copy.  " ..
                        #acct .. " account + " .. #char .. " character entries.|r")
        f.edit:SetText(str)
        f.edit:SetFocus()
        f.edit:HighlightText()
        f.goBtn:SetText("Copy")
        f.goBtn:SetScript("OnClick", function()
            f.edit:SetFocus(); f.edit:HighlightText()
            Print("Highlighted. Press |cffffff00Ctrl+C|r to copy.")
        end)
    else   -- import
        f.title:SetText("|cffffd700Import Whitelist|r")
        f.hint:SetText("|cffaaaaaaPaste an EBWL:v1:... string.  Entries merge; duplicates skipped.|r")
        f.edit:SetText("")
        f.edit:SetFocus()
        f.goBtn:SetText("Import")
        f.goBtn:SetScript("OnClick", function()
            local raw = f.edit:GetText()
            local a, c, s = EAL_ImportWhitelist(raw)
            if not a then
                Print("|cffff4444Import failed:|r " .. tostring(c))
            else
                Print("Whitelist import: |cffb9ff99+" .. a .. "|r account, " ..
                      "|cff87ceeb+" .. c .. "|r character, " ..
                      "|cffaaaaaa" .. s .. "|r duplicates skipped.")
                f:Hide()
            end
        end)
    end

    f:Show()
end

-- Mount state watcher + companion stuck check. Bag fullness is driven by
-- BAG_UPDATE (see event handler) so OnUpdate no longer polls bags.
local function OnUpdate(self, elapsed)
    if not EAL_DB then return end

    local nowMounted = IsPlayerMountedOrFlying()
    if nowMounted ~= wasMounted then
        wasMounted = nowMounted
        if nowMounted then
            DismissPet()
            if currentState ~= S_IDLE then
                Print("Mounted - companion dismissed.")
            end
        else
            if EAL_DB.enabled then
                if currentState == S_LOOTING then
                    Print("Dismounted - re-summoning " .. EAL_DB.lootCompanion .. "...")
                    After(1.5, function() SummonPet(EAL_DB.lootCompanion) end)
                elseif currentState == S_SELLING then
                    Print("Dismounted - re-summoning " .. EAL_DB.vendorCompanion .. "...")
                    waitingForMerchant = true
                    After(1.5, function() SummonPet(EAL_DB.vendorCompanion) end)
                end
                -- Consume any sell cycle that was deferred while we were
                -- mounted (StartSellCycle would have set pendingSellCycle).
                if pendingSellCycle then
                    After(1.5, TryStartDeferredSell)
                end
            end
        end
    end

    -- Stuck check: share the timer interval, skip while mounted.  Runs in
    -- both LOOTING and SELLING states so a despawned vendor pet is caught
    -- while waiting for the player to interact with the merchant.  The
    -- auto-delete unsellable pass is LOOTING-only (never fires mid-sell).
    if EAL_DB.enabled and not nowMounted
       and (currentState == S_LOOTING or currentState == S_SELLING) then
        bagCheckTimer = bagCheckTimer + elapsed
        if bagCheckTimer >= (EAL_DB.checkInterval or 3) then
            bagCheckTimer = 0
            EAL_UpdateStatus()
            if currentState == S_LOOTING then EAL_DeleteUnsellableItems() end
            CheckCompanionStuck()
        end
    end

    -- BAG_UPDATE sets this flag; consume it once per tick so we don't thrash.
    if bagUpdateDirty then
        bagUpdateDirty = false
        EAL_UpdateStatus()
        if EAL_DB.enabled and currentState == S_LOOTING and not nowMounted then
            if GetTotalFreeSlots() == 0 then
                StartSellCycle()
            end
        end
        -- Bags-full lockout: player has manually freed a slot after we
        -- stopped due to unsellable junk.  Resume looting automatically.
        if bagsFullLockout and EAL_DB.enabled and currentState == S_IDLE
           and GetTotalFreeSlots() > 0 then
            bagsFullLockout = false
            Print("|cff44ff44Free slot detected - resuming loot cycle.|r")
            StartLootCycle()
        end
    end
end

-------------------------------------------------------------------------------
-- Static popup dialogs
-------------------------------------------------------------------------------
StaticPopupDialogs["AUTOLOOT_CONFIRM_RESET_WHITELIST"] = {
    text         = "Clear the entire whitelist (account + current character)?",
    button1      = "Clear",
    button2      = "Cancel",
    OnAccept     = function()
        EAL_DB.blacklist = {}
        if EAL_CDB then EAL_CDB.blacklist = {} end
        EAL_RefreshBlacklist()
        Print("Whitelist cleared.")
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["AUTOLOOT_CONFIRM_RESET_STASH"] = {
    text         = "Clear the entire stash list (account + current character)?",
    button1      = "Clear",
    button2      = "Cancel",
    OnAccept     = function()
        EAL_DB.stashList = {}
        if EAL_CDB then EAL_CDB.stashList = {} end
        if EAL_RefreshStashList then EAL_RefreshStashList() end
        Print("Stash list cleared.")
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["AUTOLOOT_CONFIRM_SELL_LOW_ILVL"] = {
    text         = "",   -- set dynamically by EAL_PromptSellLowILvl
    button1      = "Sell",
    button2      = "Cancel",
    OnAccept     = function()
        EAL_SellLowILvlGearNow(EAL_DB.ilvlSellThreshold or 199)
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["AUTOLOOT_CONFIRM_AUTODELETE_RARES"] = {
    text         = "Enable automatic deletion of unsellable items?\n\n|cffff4444This silently deletes items with NO vendor price, for the quality tiers you have ticked below. Some quest items, tokens, and unique gear have no vendor price and will be destroyed.|r\n\nOnly enable if you understand what this does.",
    button1      = "Enable",
    button2      = "Cancel",
    OnAccept     = function()
        EAL_DB.autoDeleteUnsellable = EAL_DB.autoDeleteUnsellable or {}
        EAL_DB.autoDeleteUnsellable.enabled = true
        if g_autoDelCb then g_autoDelCb:SetChecked(true) end
        Print("Auto-delete unsellable: |cffff4444ENABLED|r.")
        EAL_UpdateStatus()
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-------------------------------------------------------------------------------
-- On-screen vendor button
-------------------------------------------------------------------------------
local function EAL_BuildVendorButton()
    local btn = CreateFrame("Button", "EAL_VendorBtn", UIParent,
                            "SecureActionButtonTemplate")
    btn:SetSize(60, 60)
    btn:SetPoint("TOPLEFT", UIParent, "TOPLEFT",
                 EAL_DB.vendorBtnX, EAL_DB.vendorBtnY)
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForClicks("AnyUp")
    btn:SetFrameStrata("MEDIUM")

    btn:SetAttribute("type", "macro")
    btn:SetAttribute("macrotext", "/target " .. EAL_DB.vendorCompanion)

    local tex = btn:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    border:SetBlendMode("ADD")
    border:SetWidth(66); border:SetHeight(66)
    border:SetPoint("CENTER")
    border:SetVertexColor(1, 0.75, 0.1, 0.85)

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("BOTTOM", btn, "TOP", 0, 2)
    lbl:SetText("|cffff9900Vendor|r")

    btn:SetScript("OnMouseDown", function(self, button)
        if IsAltKeyDown() then self:StartMoving() end
    end)
    btn:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        EAL_DB.vendorBtnX = self:GetLeft()
        EAL_DB.vendorBtnY = self:GetTop() - UIParent:GetHeight()
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("|cffff9900Target " .. EAL_DB.vendorCompanion .. "|r")
        GameTooltip:AddLine("|cffaaaaaaClick to target the vendor companion|r")
        GameTooltip:AddLine("|cffaaaaaaThen press Interact with Target to sell|r")
        GameTooltip:AddLine("|cffaaaaaaAlt+Drag to reposition|r")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    if not EAL_DB.vendorBtnShown then btn:Hide() end

    return btn
end

-------------------------------------------------------------------------------
-- Minimap button (hand-rolled; no LibDBIcon dependency)
-------------------------------------------------------------------------------
local function MinimapButton_UpdatePosition(btn)
    local angle = math.rad(EAL_DB.minimapAngle or 200)
    local radius = 80
    local x = math.cos(angle) * radius
    local y = math.sin(angle) * radius
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Sell preview window was added in v4.8.0 and removed in v4.9.0.  The
-- server-side workflow this addon targets emphasizes speedy loot / sell /
-- reloot cycles, so an opt-in pause-and-review step was the wrong fit.
-- Per-quality, per-iLvl, sell-price-cap, and whitelist controls remain
-- the supported way to filter what does and doesn't sell.

local function EAL_BuildMinimapButton()
    local btn = CreateFrame("Button", "EAL_MinimapBtn", Minimap)
    btn:SetSize(32, 32)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetMovable(true)

    -- Coin icon over a round border (standard minimap look)
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)

    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetSize(54, 54)
    overlay:SetPoint("TOPLEFT")

    local bg = btn:CreateTexture(nil, "BORDER")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(24, 24)
    bg:SetPoint("CENTER", 0, 1)

    -- Small status dot (green when enabled, grey when disabled)
    local dot = btn:CreateTexture(nil, "ARTWORK")
    dot:SetTexture("Interface\\Buttons\\WHITE8X8")
    dot:SetSize(6, 6)
    dot:SetPoint("BOTTOMRIGHT", -4, 4)
    btn.statusDot = dot

    MinimapButton_UpdatePosition(btn)

    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            if not g_optionsFrame then return end
            if g_optionsFrame:IsShown() then
                g_optionsFrame:Hide()
            else
                EAL_UpdateStatus()
                EAL_RefreshBlacklist()
                g_optionsFrame:Show()
            end
        elseif button == "RightButton" then
            -- Right-click: toggle enable/disable
            EAL_DB.enabled = not EAL_DB.enabled
            if EAL_DB.enabled then
                StartLootCycle()
            else
                DismissPet()
                SetState(S_IDLE)
            end
            EAL_UpdateStatus()
        end
    end)

    btn:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", function(self)
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        EAL_DB.minimapAngle = math.deg(math.atan2(py - my, px - mx))
        MinimapButton_UpdatePosition(self)
    end) end)
    btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cffff9900AutoLoot|r v" .. ADDON_VERSION)
        GameTooltip:AddLine("|cff888866by " .. ADDON_AUTHOR .. "|r")
        GameTooltip:AddLine("Status: " .. (EAL_DB.enabled and "|cff44ff44Enabled|r" or "|cffaaaaaaDisabled|r"))
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffffff00Left-click|r to open settings")
        GameTooltip:AddLine("|cffffff00Right-click|r to toggle enable/disable")
        GameTooltip:AddLine("|cffaaaaaaDrag to reposition|r")
        if EAL_DB.goldEarned and EAL_DB.goldEarned > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Lifetime earned: " .. FormatMoney(EAL_DB.goldEarned))
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    if not EAL_DB.showMinimapButton then btn:Hide() end
    return btn
end

UpdateMinimapButton = function()
    if not g_minimapBtn or not EAL_DB then return end
    if EAL_DB.showMinimapButton then g_minimapBtn:Show() else g_minimapBtn:Hide() end
    if g_minimapBtn.statusDot then
        if EAL_DB.enabled then
            g_minimapBtn.statusDot:SetVertexColor(0.3, 1, 0.3, 1)
        else
            g_minimapBtn.statusDot:SetVertexColor(0.5, 0.5, 0.5, 0.8)
        end
    end
end

-------------------------------------------------------------------------------
-- GUI
-------------------------------------------------------------------------------
local function MakeHeader(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText("|cffffd700" .. text .. "|r")
    return fs
end

local function MakeDivider(parent, y)
    local t = parent:CreateTexture(nil, "ARTWORK")
    -- v4.10.0: stretch divider to the parent's full width minus side
    -- insets, so it auto-resizes correctly under the new 720-wide window.
    t:SetPoint("TOPLEFT",  parent, "TOPLEFT",  14, y)
    t:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, y)
    t:SetHeight(1)
    t:SetTexture(0.60, 0.40, 0.85, 0.85)
    return t
end

-- A small numeric EditBox without InputBoxTemplate.  We hand-roll the
-- container + backdrop because in 3.3.5a, InputBoxTemplate's child Region
-- textures (Left/Middle/Right of the gold border) sometimes leak past a
-- Hide() on the EditBox itself, leaving stray dark rectangles visible
-- when a tab panel is hidden.  This bypass uses a plain Frame backdrop
-- and a plain EditBox child, both of which hide reliably with the parent.
local function MakeNumericInput(parent, x, y, w, maxLetters)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(w or 48, 20)
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    container:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 8,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    container:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
    container:SetBackdropBorderColor(0.55, 0.42, 0.18, 0.95)
    container:EnableMouse(true)

    local edit = CreateFrame("EditBox", nil, container)
    edit:SetPoint("TOPLEFT",     container, "TOPLEFT",      4, -2)
    edit:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -4,  2)
    edit:SetFontObject("ChatFontNormal")
    edit:SetAutoFocus(false)
    edit:SetNumeric(true)
    edit:SetMaxLetters(maxLetters or 6)
    edit:SetJustifyH("CENTER")
    edit:SetTextInsets(0, 0, 0, 0)

    -- Clicking the gold-bordered container focuses the edit box.
    container:SetScript("OnMouseDown", function() edit:SetFocus() end)

    -- Expose the container in case caller wants to anchor adjacent labels.
    edit.container = container
    return edit
end

local function MakeCheckbox(parent, labelText, x, y, getValue, setValue, tooltip)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetWidth(24); cb:SetHeight(24)
    cb:SetChecked(getValue())

    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("LEFT", cb, "RIGHT", 1, 0)
    lbl:SetText(labelText)

    cb:SetScript("OnClick", function(self)
        setValue(self:GetChecked() and true or false)
    end)

    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            for _, line in ipairs(tooltip) do GameTooltip:AddLine(line) end
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return cb
end

local function MakeTooltipButton(btn, title, lines)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title)
        for _, line in ipairs(lines) do GameTooltip:AddLine(line) end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-------------------------------------------------------------------------------
-- Main settings window (tabbed)
--
-- Header area  (visible on every tab):
--   - title + author byline + close button
--   - status row (state + free slots) and lifetime gold tracker
--   - tab strip
-- Tab content panels (one shown at a time):
--   1. General   -- enable/disable, force sell, fast mode, sound, vendor btn
--   2. Sell      -- companion names, sell quality, auto-delete unsellable
--   3. Actions   -- quick-sell by iLvl
--   4. Whitelist -- name input, +Acct/+Char, scrollable list, tome helper
-- About info is reachable from a small "?" badge in the top-right corner.
-------------------------------------------------------------------------------
local function EAL_BuildGUI()
    -- v4.10.0: landscape window so the custom background image (with its
    -- gold corner ornaments + decorative border) fits its native aspect.
    local W, H = 720, 520
    local win = CreateFrame("Frame", "EAL_Window", UIParent)
    win:SetWidth(W); win:SetHeight(H)
    win:SetPoint("TOPLEFT", UIParent, "TOPLEFT", EAL_DB.windowX, EAL_DB.windowY)
    win:SetFrameStrata("HIGH")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        EAL_DB.windowX = self:GetLeft()
        EAL_DB.windowY = self:GetTop() - UIParent:GetHeight()
    end)
    -- v4.10.0: violet backdrop is the FALLBACK; the real visual is the
    -- custom background image overlay below.  If the image file is
    -- missing the violet backdrop shows so the window still looks
    -- presentable.  No edgeFile -- the image has its own border.
    win:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        tile = true, tileSize = 32,
    })
    win:SetBackdropColor(0.18, 0.10, 0.30, 0.85)        -- fallback violet

    -- Custom background image.  Save your texture to:
    --   Interface\AddOns\AutoLoot\Media\Background.tga
    -- (or .blp if you've converted it).  Power-of-2 dimensions are
    -- recommended; a landscape 1024x512 or 1024x1024 fits well.  The
    -- texture fills the whole window edge-to-edge so the image's own
    -- gold corner ornaments line up with the window corners.
    local bgImage = win:CreateTexture(nil, "BACKGROUND", nil, 2)
    bgImage:SetTexture("Interface\\AddOns\\AutoLoot\\Media\\Background.tga")
    bgImage:SetAllPoints(win)

    win:Hide()

    -------------------------------------------------------------------------
    -- Header area
    -------------------------------------------------------------------------
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText(L["AutoLoot"] .. " |cffaaaaaa& " .. L["Sell"] .. "|r" ..
                  "  |cff888888v" .. ADDON_VERSION .. "|r")

    -- Small author credit. Brand-identity element; removal violates LICENSE.
    local byline = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    byline:SetPoint("TOP", title, "BOTTOM", 0, -2)
    byline:SetText("|cff888866" .. L["by"] .. " " .. ADDON_AUTHOR .. "|r")

    local closeBtn = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() win:Hide() end)

    -- "?" info badge next to close button. Hover -> About info.
    local infoBadge = CreateFrame("Frame", nil, win)
    infoBadge:SetSize(20, 20)
    infoBadge:SetPoint("TOPRIGHT", -32, -10)
    infoBadge:EnableMouse(true)
    local ibBg = infoBadge:CreateTexture(nil, "BACKGROUND")
    ibBg:SetAllPoints()
    ibBg:SetTexture(0.18, 0.10, 0.30, 0.85)   -- match window backdrop tint
    local ibTxt = infoBadge:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ibTxt:SetPoint("CENTER", 0, 0)
    ibTxt:SetText("|cffffd700?|r")
    infoBadge:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cffff9900" .. L["AutoLoot"] .. "|r v" .. ADDON_VERSION)
        GameTooltip:AddLine("|cff888866" .. L["by"] .. " " .. ADDON_AUTHOR .. "|r")
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffffd700" .. L["Slash commands"] .. ":|r")
        GameTooltip:AddLine("|cffaaaaaa/eal|r |cff888866 or |r|cffaaaaaa/autoloot|r   |cff666666open/close|r")
        GameTooltip:AddLine("|cffaaaaaa/eal toggle|r   |cff666666enable/disable cycle|r")
        GameTooltip:AddLine("|cffaaaaaa/eal enable|r |cff888866| |r|cffaaaaaa/eal disable|r")
        GameTooltip:AddLine("|cffaaaaaa/eal sell|r   |cff666666force a sell cycle now|r")
        GameTooltip:AddLine("|cffaaaaaa/eal ilvlsell|r   |cff666666sell low-iLvl gear|r")
        GameTooltip:AddLine("|cffaaaaaa/eal deposit|r   |cff666666bank: deposit stash|r")
        GameTooltip:AddLine("|cffaaaaaa/eal mail|r   |cff666666mailbox: collect|r")
        GameTooltip:AddLine("|cffaaaaaa/eal cleanmail|r   |cff666666delete read empty|r")
        GameTooltip:AddLine("|cffaaaaaa/eal bankconsolidate|r |cff888866| |r|cffaaaaaa/eal bc|r   |cff666666bank stacks|r")
        GameTooltip:AddLine("|cffaaaaaa/eal gbconsolidate|r |cff888866| |r|cffaaaaaa/eal gbc|r   |cff666666guild bank|r")
        GameTooltip:AddLine("|cffaaaaaa/eal reset|r   |cff666666clear whitelist|r")
        GameTooltip:AddLine("|cffaaaaaa/eal minimap|r   |cff666666show/hide button|r")
        GameTooltip:AddLine("|cffaaaaaa/eal help|r   |cff666666chat command list|r")
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffffd700" .. L["License"] .. ":|r")
        GameTooltip:AddLine("|cffaaaaaa" .. L["Source-available. Attribution required. See LICENSE for full terms."] .. "|r", 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cff888866" .. ADDON_URL .. "|r")
        GameTooltip:Show()
    end)
    infoBadge:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Status row (always visible).  Divider sits BELOW the byline:
    --   title  spans y=-14..-30 (GameFontNormalLarge)
    --   byline anchored title-bottom -2  -->  y=-32..-44
    -- so the divider has to be at y<=-46 to clear the byline text.
    MakeDivider(win, -46)
    local statusLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusLabel:SetPoint("TOPLEFT", 18, -48)
    statusLabel:SetWidth(220); statusLabel:SetJustifyH("LEFT")
    g_statusLabel = statusLabel

    -- Gold-earned line (always visible)
    local goldLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    goldLabel:SetPoint("TOPLEFT", 18, -64)
    goldLabel:SetWidth(322); goldLabel:SetJustifyH("LEFT")
    g_goldLabel = goldLabel

    -- Divider above tab strip
    MakeDivider(win, -84)

    -------------------------------------------------------------------------
    -- Tab strip
    -------------------------------------------------------------------------
    local tabDefs = {
        { key = "general",   label = L["General"]   },
        { key = "sell",      label = L["Sell"]      },
        { key = "whitelist", label = L["Whitelist"] },
        { key = "bank",      label = L["Bank"]      },
        { key = "mail",      label = L["Mail"]      },
        -- v4.12: item-family / subclass filter.  Added at the end so
        -- existing lastTab indices stay stable (no migration needed).
        { key = "filter",    label = L["Filter"]    },
    }
    -- Tab-index constants -- update these in lockstep with tabDefs.
    -- Used in the drag-drop/Ctrl+Shift+Click router below.
    local TAB_GENERAL, TAB_SELL = 1, 2
    local TAB_WHITELIST, TAB_BANK, TAB_MAIL, TAB_FILTER = 3, 4, 5, 6

    local panels = {}
    local tabBtns = {}

    -- Aggressive hide: in 3.3.5a, InputBoxTemplate EditBoxes sometimes leak
    -- their child Region textures (Left/Middle/Right) past a Hide() on the
    -- parent EditBox.  We Hide() AND SetAlpha(0) on the EditBox, then walk
    -- its regions and explicitly Hide()/SetAlpha(0) each one too.  Symmetric
    -- show-path restores everything.
    local function _setWidgetVisible(w, visible)
        if visible then
            w:Show(); w:SetAlpha(1)
        else
            w:Hide(); w:SetAlpha(0)
        end
        if w.GetRegions then
            for _, r in ipairs({ w:GetRegions() }) do
                if r and r.SetAlpha then r:SetAlpha(visible and 1 or 0) end
                if r and r.Hide and not visible then r:Hide() end
                if r and r.Show and visible then r:Show() end
            end
        end
    end

    local function ShowTab(idx)
        for i, p in ipairs(panels) do
            local active = (i == idx)
            if active then p:Show() else p:Hide() end
            for _, w in ipairs(p.forceWidgets) do
                _setWidgetVisible(w, active)
            end
        end
        for i, b in ipairs(tabBtns) do
            if i == idx then
                b:LockHighlight()
                b:GetFontString():SetTextColor(1.00, 0.96, 1.00)   -- bright white-lavender
            else
                b:UnlockHighlight()
                b:GetFontString():SetTextColor(0.75, 0.65, 0.90)   -- medium purple
            end
        end
        EAL_DB.lastTab = idx
    end
    win.ShowTab = ShowTab   -- expose for external callers (e.g. drag-drop loader)

    -- Hand-roll tabs as simple buttons sized to each label. With 5 tabs in
    -- a 360-wide window, fixed-width tabs would either clip "Whitelist" or
    -- overflow the panel. Variable widths keep everything inside.
    local TAB_Y, TAB_H, TAB_PAD = -90, 22, 12
    local tabX = 12

    -- v4.9.0 violet theme: tab buttons are a lighter shade of purple than
    -- the main window backdrop.  Vertex-tinting UIPanelButtonTemplate's
    -- built-in textures gives us a clean recolor without replacing the
    -- texture files themselves.
    local TAB_TINT_NORMAL    = { 0.70, 0.50, 0.95 }   -- lighter purple
    local TAB_TINT_PUSHED    = { 0.45, 0.30, 0.75 }   -- darker violet (pressed)
    local TAB_TINT_HIGHLIGHT = { 1.00, 0.85, 1.00 }   -- pale lavender hover glow

    local function TintTab(btn)
        local nt = btn.GetNormalTexture and btn:GetNormalTexture()
        if nt then nt:SetVertexColor(TAB_TINT_NORMAL[1], TAB_TINT_NORMAL[2], TAB_TINT_NORMAL[3], 1) end
        local pt = btn.GetPushedTexture and btn:GetPushedTexture()
        if pt then pt:SetVertexColor(TAB_TINT_PUSHED[1], TAB_TINT_PUSHED[2], TAB_TINT_PUSHED[3], 1) end
        local ht = btn.GetHighlightTexture and btn:GetHighlightTexture()
        if ht then ht:SetVertexColor(TAB_TINT_HIGHLIGHT[1], TAB_TINT_HIGHLIGHT[2], TAB_TINT_HIGHLIGHT[3], 0.55) end
    end

    for i, def in ipairs(tabDefs) do
        local btn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        btn:SetHeight(TAB_H)
        btn:SetText(def.label)
        local fs = btn:GetFontString()
        local labelW = (fs and fs:GetStringWidth() or 50)
        local btnW   = math.max(40, math.floor(labelW + TAB_PAD + 0.5))
        btn:SetWidth(btnW)
        btn:SetPoint("TOPLEFT", tabX, TAB_Y)
        tabX = tabX + btnW + 2
        btn:SetScript("OnClick", function() ShowTab(i) end)
        TintTab(btn)
        tabBtns[i] = btn
    end

    -- Divider below tab strip
    MakeDivider(win, -116)

    -------------------------------------------------------------------------
    -- Tab content panels
    -- Each panel is a Frame anchored to win. Widgets within each panel use
    -- y-coordinates relative to win itself (not the panel), since the panel
    -- is fullscreen-within-win. Showing/hiding the panel hides/shows all
    -- widgets parented to it.
    -------------------------------------------------------------------------
    local function MakePanel()
        local p = CreateFrame("Frame", nil, win)
        p:SetPoint("TOPLEFT",     win, "TOPLEFT",     0, 0)
        p:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", 0, 0)
        p:Hide()
        return p
    end
    for i = 1, #tabDefs do panels[i] = MakePanel() end

    -- Some templated child widgets (notably InputBoxTemplate EditBoxes)
    -- have been observed to render across tab switches even when their
    -- parent panel is hidden. Each panel keeps an explicit list of
    -- "force-toggle" widgets that get Show()/Hide() called directly on
    -- every tab switch as a defensive measure on top of normal parent-
    -- visibility inheritance.
    for i = 1, #tabDefs do panels[i].forceWidgets = {} end

    local pGeneral   = panels[TAB_GENERAL]
    local pSell      = panels[TAB_SELL]
    local pWhitelist = panels[TAB_WHITELIST]
    local pBank      = panels[TAB_BANK]
    local pMail      = panels[TAB_MAIL]
    local pFilter    = panels[TAB_FILTER]

    -------------------------------------------------------------------------
    -- Tab 1: GENERAL
    -------------------------------------------------------------------------
    -- Row: Enable / Force Sell
    local enableBtn = CreateFrame("Button", nil, pGeneral, "GameMenuButtonTemplate")
    enableBtn:SetPoint("TOPLEFT", pGeneral, "TOPLEFT", 18, -128)
    enableBtn:SetWidth(150); enableBtn:SetHeight(26)
    enableBtn:SetText(EAL_DB.enabled and L["Disable"] or L["Enable"])
    g_enableBtn = enableBtn
    enableBtn:SetScript("OnClick", function(self)
        EAL_DB.enabled = not EAL_DB.enabled
        if EAL_DB.enabled then
            StartLootCycle()
        else
            DismissPet()
            SetState(S_IDLE)
        end
        EAL_UpdateStatus()
    end)
    MakeTooltipButton(enableBtn, "|cffff9900" .. L["Enable"] .. " / " .. L["Disable"] .. "|r", {
        "|cffaaaaaaStart or stop the auto loot+sell cycle.|r",
        "|cffaaaaaaWhen enabled, your loot companion is|r",
        "|cffaaaaaasummoned and bags are monitored.|r",
    })

    local sellNowBtn = CreateFrame("Button", nil, pGeneral, "GameMenuButtonTemplate")
    sellNowBtn:SetPoint("TOPLEFT", pGeneral, "TOPLEFT", 184, -128)
    sellNowBtn:SetWidth(158); sellNowBtn:SetHeight(26)
    sellNowBtn:SetText(L["Force Sell Now"])
    sellNowBtn:SetScript("OnClick", function() StartSellCycle() end)
    MakeTooltipButton(sellNowBtn, "|cffff9900" .. L["Force Sell Now"] .. "|r", {
        "|cffaaaaaaSummon the vendor companion and begin|r",
        "|cffaaaaaaa sell cycle even if bags aren't full.|r",
    })

    -- Fast Mode + Sound on a row
    local fastModeCb = CreateFrame("CheckButton", nil, pGeneral, "UICheckButtonTemplate")
    fastModeCb:SetPoint("TOPLEFT", pGeneral, "TOPLEFT", 18, -162)
    fastModeCb:SetWidth(24); fastModeCb:SetHeight(24)
    fastModeCb:SetChecked(EAL_DB.fastMode)
    local fastModeLbl = pGeneral:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fastModeLbl:SetPoint("LEFT", fastModeCb, "RIGHT", 1, 0)
    fastModeLbl:SetText("|cffff4444" .. L["Fast Mode"] .. "|r")
    fastModeCb:SetScript("OnClick", function(self)
        EAL_DB.fastMode = self:GetChecked() and true or false
    end)
    fastModeCb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cffff4444" .. L["Fast Mode"] .. "|r")
        GameTooltip:AddLine("|cffff9900Warning: may cause disconnects on|r")
        GameTooltip:AddLine("|cffff9900lower-end hardware.|r")
        GameTooltip:AddLine("|cffaaaaaaDoubles items sold per batch and|r")
        GameTooltip:AddLine("|cffaaaaaahalves the delay between batches.|r")
        GameTooltip:Show()
    end)
    fastModeCb:SetScript("OnLeave", function() GameTooltip:Hide() end)

    MakeCheckbox(pGeneral, L["Sound"], 200, -162,
        function() return EAL_DB.soundEnabled end,
        function(v) EAL_DB.soundEnabled = v end,
        {
            "|cffffd700" .. L["Sound"] .. "|r",
            "|cffaaaaaaPlays sounds on sell completion and|r",
            "|cffaaaaaawhen the vendor companion is ready.|r",
        })

    -- Sell-at-any-vendor
    MakeCheckbox(pGeneral, "|cffffaa00Sell at any vendor|r (not just summoned)", 18, -190,
        function() return EAL_DB.sellOnAnyVendor end,
        function(v) EAL_DB.sellOnAnyVendor = v end,
        {
            "|cffffd700Sell at any vendor|r",
            "|cffaaaaaaWhen OFF (default): only auto-sells when|r",
            "|cffaaaaaathe addon itself triggered the sell cycle.|r",
            "|cffaaaaaaWhen ON: auto-sells at any vendor you open|r",
            "|cffaaaaaa(repair vendors, quest vendors, etc).|r",
        })

    -- ---- Sell-price max (input field in gold) ----------------------
    local sellPriceLbl = pGeneral:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sellPriceLbl:SetPoint("TOPLEFT", pGeneral, "TOPLEFT", 18, -222)
    sellPriceLbl:SetText("Skip sell if item is worth more than")
    local sellPriceInput = MakeNumericInput(pGeneral, 252, -220, 48, 6)
    sellPriceInput:SetText(tostring(math.floor((EAL_DB.sellPriceMax or 0) / 10000)))
    local sellPriceUnit = pGeneral:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sellPriceUnit:SetPoint("LEFT", sellPriceInput.container, "RIGHT", 6, 0)
    sellPriceUnit:SetText("|cffffd700g|r")
    sellPriceInput:SetScript("OnEnterPressed", function(self)
        local g = tonumber(self:GetText()) or 0
        if g < 0 then g = 0 end
        EAL_DB.sellPriceMax = g * 10000     -- gold -> copper
        self:SetText(tostring(g))
        self:ClearFocus()
        if g > 0 then
            Print("Sell-price cap: items worth more than |cffffff00" ..
                  g .. "g|r will be skipped.")
        else
            Print("Sell-price cap |cffaaaaaaDISABLED|r.")
        end
    end)
    sellPriceInput:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(math.floor((EAL_DB.sellPriceMax or 0) / 10000)))
        self:ClearFocus()
    end)
    sellPriceInput:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cffffd700Sell-price cap|r")
        GameTooltip:AddLine("|cffaaaaaaItems whose vendor sell price exceeds this|r")
        GameTooltip:AddLine("|cffaaaaaaamount are NEVER auto-sold, even if their|r")
        GameTooltip:AddLine("|cffaaaaaaquality is ticked.  Set to 0 to disable.|r")
        GameTooltip:AddLine("|cffaaaaaaProtects valuable BoEs whose names you|r")
        GameTooltip:AddLine("|cffaaaaaaforgot to whitelist.  Press Enter to save.|r")
        GameTooltip:Show()
    end)
    sellPriceInput:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ---- Repair cost cap (input field in gold) ---------------------
    local repairLbl = pGeneral:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    repairLbl:SetPoint("TOPLEFT", pGeneral, "TOPLEFT", 18, -246)
    repairLbl:SetText("Skip auto-repair if cost is over")
    local repairInput = MakeNumericInput(pGeneral, 252, -244, 48, 6)
    repairInput:SetText(tostring(math.floor((EAL_DB.repairCostCap or 0) / 10000)))
    local repairUnit = pGeneral:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    repairUnit:SetPoint("LEFT", repairInput.container, "RIGHT", 6, 0)
    repairUnit:SetText("|cffffd700g|r")
    repairInput:SetScript("OnEnterPressed", function(self)
        local g = tonumber(self:GetText()) or 0
        if g < 0 then g = 0 end
        EAL_DB.repairCostCap = g * 10000
        self:SetText(tostring(g))
        self:ClearFocus()
        if g > 0 then
            Print("Repair cost cap: skip if total exceeds |cffffff00" ..
                  g .. "g|r.")
        else
            Print("Repair cost cap |cffaaaaaaDISABLED|r (always repair).")
        end
    end)
    repairInput:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(math.floor((EAL_DB.repairCostCap or 0) / 10000)))
        self:ClearFocus()
    end)
    repairInput:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cffffd700Repair cost cap|r")
        GameTooltip:AddLine("|cffaaaaaaWhen the merchant supports repairs,|r")
        GameTooltip:AddLine("|cffaaaaaaauto-repair is skipped if the total cost|r")
        GameTooltip:AddLine("|cffaaaaaaexceeds this amount.  The sell cycle still|r")
        GameTooltip:AddLine("|cffaaaaaaproceeds.  Set to 0 to always repair.|r")
        GameTooltip:AddLine("|cffaaaaaaPress Enter to save.|r")
        GameTooltip:Show()
    end)
    repairInput:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Vendor-button hint + show/hide toggle (shifted down to make room)
    MakeDivider(pGeneral, -274)
    local vendorHint = pGeneral:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    vendorHint:SetPoint("TOPLEFT", pGeneral, "TOPLEFT", 18, -286)
    vendorHint:SetWidth(220); vendorHint:SetJustifyH("LEFT")
    vendorHint:SetText("|cffaaaaaaClick vendor button, then Interact key to sell|r")

    local function UpdateVendorToggleBtn(btn)
        if EAL_DB.vendorBtnShown then btn:SetText(L["Hide Vendor Btn"])
        else                          btn:SetText(L["Show Vendor Btn"]) end
    end
    local vendorToggle = CreateFrame("Button", nil, pGeneral, "GameMenuButtonTemplate")
    vendorToggle:SetPoint("TOPLEFT", pGeneral, "TOPLEFT", 242, -282)
    vendorToggle:SetWidth(100); vendorToggle:SetHeight(22)
    UpdateVendorToggleBtn(vendorToggle)
    vendorToggle:SetScript("OnClick", function(self)
        EAL_DB.vendorBtnShown = not EAL_DB.vendorBtnShown
        if g_vendorBtn then
            if EAL_DB.vendorBtnShown then g_vendorBtn:Show() else g_vendorBtn:Hide() end
        end
        UpdateVendorToggleBtn(self)
    end)
    g_vendorBtnToggle = vendorToggle

    -- Minimap button toggle
    MakeCheckbox(pGeneral, "Show minimap button", 18, -318,
        function() return EAL_DB.showMinimapButton end,
        function(v)
            EAL_DB.showMinimapButton = v
            if UpdateMinimapButton then UpdateMinimapButton() end
        end,
        {
            "|cffffd700Minimap button|r",
            "|cffaaaaaaShow the AutoLoot minimap button.|r",
            "|cffaaaaaaDrag to reposition; left-click opens|r",
            "|cffaaaaaasettings, right-click toggles enable.|r",
        })

    -------------------------------------------------------------------------
    -- Tab 2: SELL
    -------------------------------------------------------------------------
    MakeHeader(pSell, L["COMPANION NAMES"], 18, -124)

    -- Dark backing panel behind input rows for contrast
    local cPanel = pSell:CreateTexture(nil, "ARTWORK")
    cPanel:SetTexture("Interface\\Buttons\\WHITE8X8")
    cPanel:SetVertexColor(0, 0, 0, 0.55)
    cPanel:SetPoint("TOPLEFT",     pSell, "TOPLEFT",  14, -140)
    cPanel:SetPoint("BOTTOMRIGHT", pSell, "TOPLEFT", 346, -190)
    local function PanelEdge(parent, tlx, tly, brx, bry)
        local e = parent:CreateTexture(nil, "ARTWORK", nil, 1)
        e:SetTexture("Interface\\Buttons\\WHITE8X8")
        e:SetVertexColor(0.55, 0.40, 0.75, 0.85)   -- v4.9.0 violet hairline
        e:SetPoint("TOPLEFT",     parent, "TOPLEFT", tlx, tly)
        e:SetPoint("BOTTOMRIGHT", parent, "TOPLEFT", brx, bry)
    end
    PanelEdge(pSell,  14, -140, 346, -141)
    PanelEdge(pSell,  14, -189, 346, -190)
    PanelEdge(pSell,  14, -140,  15, -190)
    PanelEdge(pSell, 345, -140, 346, -190)

    local lootLabel = pSell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lootLabel:SetPoint("TOPLEFT", pSell, "TOPLEFT", 18, -146)
    lootLabel:SetText(L["Loot:"])
    local lootInput = CreateFrame("EditBox", nil, pSell, "InputBoxTemplate")
    lootInput:SetPoint("TOPLEFT", pSell, "TOPLEFT", 72, -144)
    lootInput:SetWidth(270); lootInput:SetHeight(20)
    lootInput:SetAutoFocus(false); lootInput:SetMaxLetters(64)
    lootInput:SetText(EAL_DB.lootCompanion or "")
    lootInput:SetScript("OnEnterPressed", function(self)
        local txt = self:GetText():match("^%s*(.-)%s*$")
        if txt ~= "" then EAL_DB.lootCompanion = txt end
        self:ClearFocus()
        Print("Loot companion set to: |cffffff00" .. (EAL_DB.lootCompanion or "?") .. "|r")
    end)

    local vendLabel = pSell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    vendLabel:SetPoint("TOPLEFT", pSell, "TOPLEFT", 18, -170)
    vendLabel:SetText(L["Vendor:"])
    local vendInput = CreateFrame("EditBox", nil, pSell, "InputBoxTemplate")
    vendInput:SetPoint("TOPLEFT", pSell, "TOPLEFT", 72, -168)
    vendInput:SetWidth(270); vendInput:SetHeight(20)
    vendInput:SetAutoFocus(false); vendInput:SetMaxLetters(64)
    vendInput:SetText(EAL_DB.vendorCompanion or "")
    vendInput:SetScript("OnEnterPressed", function(self)
        local txt = self:GetText():match("^%s*(.-)%s*$")
        if txt ~= "" then
            EAL_DB.vendorCompanion = txt
            if g_vendorBtn then
                g_vendorBtn:SetAttribute("macrotext", "/target " .. txt)
            end
        end
        self:ClearFocus()
        Print("Vendor companion set to: |cffffff00" .. (EAL_DB.vendorCompanion or "?") .. "|r")
    end)

    -- Sell quality
    MakeDivider(pSell, -200)
    MakeHeader(pSell, L["SELL QUALITY"], 18, -210)

    local qualityDefs = {
        { Q_GREY,     "sellGrey",      18,  -230 },
        { Q_WHITE,    "sellWhite",    120,  -230 },
        { Q_UNCOMMON, "sellUncommon", 230,  -230 },
        { Q_RARE,     "sellRare",      18,  -254 },
        { Q_EPIC,     "sellEpic",     120,  -254 },
    }
    for _, def in ipairs(qualityDefs) do
        local qIdx, dbKey, cx, cy = def[1], def[2], def[3], def[4]
        local label = "|cff" .. QUALITY_HEX[qIdx] .. QUALITY_LABEL[qIdx] .. "|r"
        MakeCheckbox(pSell, label, cx, cy,
            function() return EAL_DB[dbKey] end,
            function(v) EAL_DB[dbKey] = v end)
    end

    -- Auto-delete unsellable (master + 4 quality sub-toggles)
    MakeDivider(pSell, -282)
    EAL_DB.autoDeleteUnsellable = EAL_DB.autoDeleteUnsellable or {
        enabled = false, grey = false, common = false, uncommon = false,
        rare = false, epic = false,
    }
    -- Migration safety: if the user is upgrading from a SavedVariables that
    -- predates the grey field (pre-v4.4.4), default it to false in-place.
    if EAL_DB.autoDeleteUnsellable.grey == nil then
        EAL_DB.autoDeleteUnsellable.grey = false
    end
    local autoDelCb = CreateFrame("CheckButton", nil, pSell, "UICheckButtonTemplate")
    autoDelCb:SetPoint("TOPLEFT", pSell, "TOPLEFT", 18, -294)
    autoDelCb:SetWidth(24); autoDelCb:SetHeight(24)
    autoDelCb:SetChecked(EAL_DB.autoDeleteUnsellable.enabled)
    local autoDelLbl = pSell:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    autoDelLbl:SetPoint("LEFT", autoDelCb, "RIGHT", 1, 0)
    autoDelLbl:SetText("|cffff4444" .. L["Auto-delete unsellable"] .. "|r")
    autoDelCb:SetScript("OnClick", function(self)
        if self:GetChecked() then
            self:SetChecked(false)
            StaticPopup_Show("AUTOLOOT_CONFIRM_AUTODELETE_RARES")
        else
            EAL_DB.autoDeleteUnsellable.enabled = false
            Print("Auto-delete unsellable: |cffaaaaaaDISABLED|r.")
        end
    end)
    autoDelCb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cffff4444Auto-delete unsellable items|r")
        GameTooltip:AddLine("|cffff9900WARNING: silently deletes items with|r")
        GameTooltip:AddLine("|cffff9900no vendor price every few seconds.|r")
        GameTooltip:AddLine("|cffaaaaaaThe ticks below choose which quality|r")
        GameTooltip:AddLine("|cffaaaaaatiers are affected. OFF by default.|r")
        GameTooltip:Show()
    end)
    autoDelCb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    g_autoDelCb = autoDelCb

    -- Grey is special: deletes ALL grey items regardless of vendor price.
    -- Other qualities only delete items with no vendor price.
    local subDefs = {
        { key = "grey",     text = "|cff9d9d9d" .. L["Grey"]     .. "|r", x = 32,  y = -318, special = true },
        { key = "common",   text = "|cffffffff" .. L["Common"]   .. "|r", x = 132, y = -318 },
        { key = "uncommon", text = "|cff1eff00" .. L["Uncommon"] .. "|r", x = 244, y = -318 },
        { key = "rare",     text = "|cff0070dd" .. L["Rare"]     .. "|r", x = 32,  y = -342 },
        { key = "epic",     text = "|cffa335ee" .. L["Epic"]     .. "|r", x = 132, y = -342 },
    }
    for _, def in ipairs(subDefs) do
        local cb = CreateFrame("CheckButton", nil, pSell, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", pSell, "TOPLEFT", def.x, def.y)
        cb:SetWidth(22); cb:SetHeight(22)
        cb:SetChecked(EAL_DB.autoDeleteUnsellable[def.key])
        local lbl = pSell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", cb, "RIGHT", 1, 0)
        lbl:SetText(def.text)
        cb:SetScript("OnClick", function(self)
            EAL_DB.autoDeleteUnsellable[def.key] = self:GetChecked() and true or false
        end)
        local capturedKey, capturedSpecial = def.key, def.special
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if capturedSpecial then
                GameTooltip:AddLine("|cff9d9d9dDelete ALL Grey items|r")
                GameTooltip:AddLine("|cffff9900Special:|r |cffaaaaaadeletes every grey item|r")
                GameTooltip:AddLine("|cffaaaaaain bags, regardless of vendor price.|r")
                GameTooltip:AddLine("|cffaaaaaaSkips whitelisted names.|r")
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("|cffaaaaaaUseful when you want to skip the trip|r")
                GameTooltip:AddLine("|cffaaaaaato a vendor and just nuke trash.|r")
            else
                GameTooltip:AddLine("|cffff4444Delete unsellable " .. capturedKey .. " items|r")
                GameTooltip:AddLine("|cffaaaaaaWhen master is on, items of this quality|r")
                GameTooltip:AddLine("|cffaaaaaawith no vendor price are deleted.|r")
            end
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- ---- Quick-sell-by-iLvl (was the Actions tab in v4.5.x) -------------
    -- Folded into the Sell tab now that Actions had only one row.
    MakeDivider(pSell, -380)
    local quickSellBtn = CreateFrame("Button", nil, pSell, "GameMenuButtonTemplate")
    quickSellBtn:SetPoint("TOPLEFT", pSell, "TOPLEFT", 18, -392)
    quickSellBtn:SetWidth(266); quickSellBtn:SetHeight(22)
    local function UpdateQuickSellBtnText()
        quickSellBtn:SetText(string.format(L["Sell gear at iLvl %d or below"],
            EAL_DB.ilvlSellThreshold or 199))
    end
    UpdateQuickSellBtnText()
    quickSellBtn:SetScript("OnClick", EAL_PromptSellLowILvl)
    MakeTooltipButton(quickSellBtn, "|cffffd700Quick-sell low-iLvl gear|r", {
        "|cffaaaaaaScans bags for equippable gear at or below|r",
        "|cffaaaaaathe configured item level and sells it at|r",
        "|cffaaaaaathe currently-open vendor.|r",
        " ",
        "|cffaaaaaaFilters: equipment only, vendor price > 0,|r",
        "|cffaaaaaaskips whitelisted items.|r",
        " ",
        "|cffff9900Open a vendor before clicking.|r",
    })

    local ilvlInput = MakeNumericInput(pSell, 300, -390, 42, 4)
    ilvlInput:SetText(tostring(EAL_DB.ilvlSellThreshold or 199))
    ilvlInput:SetScript("OnEnterPressed", function(self)
        local n = tonumber(self:GetText()) or 199
        if n < 1   then n = 1   end
        if n > 999 then n = 999 end
        EAL_DB.ilvlSellThreshold = n
        self:SetText(tostring(n))
        self:ClearFocus()
        UpdateQuickSellBtnText()
        Print("Quick-sell threshold set to iLvl <= |cffffff00" .. n .. "|r.")
    end)
    ilvlInput:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(EAL_DB.ilvlSellThreshold or 199)); self:ClearFocus()
    end)

    -------------------------------------------------------------------------
    -- Tab 3: WHITELIST
    -------------------------------------------------------------------------
    MakeHeader(pWhitelist, L["ITEM WHITELIST"] ..
               "  |cffb9b9b9[A]|raccount  |cff87ceeb[C]|rchar", 18, -124)

    -- Make the whole panel a drop target.  When an item is dropped on
    -- empty panel space, we extract its name and load it into the input
    -- so the user only has to click +Acct/+Char to commit.
    --
    -- The mouse-enabled panel intercepts click events that would normally
    -- propagate to the parent window's drag handler, so the window can't
    -- be moved while this tab is active unless we forward drag start/stop
    -- ourselves. RegisterForDrag + OnDragStart/Stop on the panel lets a
    -- left-click drag on empty panel space move the window; OnReceiveDrag
    -- still fires when the user is holding an item, so drops keep working.
    pWhitelist:EnableMouse(true)
    pWhitelist:RegisterForDrag("LeftButton")
    pWhitelist:SetScript("OnDragStart", function() win:StartMoving() end)
    pWhitelist:SetScript("OnDragStop", function()
        win:StopMovingOrSizing()
        EAL_DB.windowX = win:GetLeft()
        EAL_DB.windowY = win:GetTop() - UIParent:GetHeight()
    end)
    pWhitelist:SetScript("OnReceiveDrag", function(self)
        local cursorType, _, link = GetCursorInfo()
        if cursorType == "item" and link then
            ClearCursor()
            local name = GetItemInfo(link)
            if name then EAL_LoadIntoWhitelistInput(name) end
        end
    end)

    local inputBox = CreateFrame("EditBox", "EAL_BlacklistInput", pWhitelist, "InputBoxTemplate")
    inputBox:SetPoint("TOPLEFT", pWhitelist, "TOPLEFT", 18, -146)
    inputBox:SetWidth(204); inputBox:SetHeight(20)
    inputBox:SetAutoFocus(false); inputBox:SetMaxLetters(64)

    -- Also accept drops directly on the input box so we can override the
    -- default EditBox behavior (which would insert "[Item Name]" with
    -- brackets and color codes).  We strip to the plain name instead.
    inputBox:SetScript("OnReceiveDrag", function(self)
        local cursorType, _, link = GetCursorInfo()
        if cursorType == "item" and link then
            ClearCursor()
            local name = GetItemInfo(link)
            if name then
                self:SetText(name)
                self:SetFocus()
            end
        end
    end)

    local function AddBlacklistEntry(list)
        local text = inputBox:GetText():match("^%s*(.-)%s*$")
        if text == "" then return end
        for _, v in ipairs(list) do
            if v:lower() == text:lower() then
                inputBox:SetText(""); return
            end
        end
        table.insert(list, text); inputBox:SetText("")
        EAL_RefreshBlacklist()
    end
    inputBox:SetScript("OnEnterPressed", function(self)
        AddBlacklistEntry(EAL_DB.blacklist); self:ClearFocus()
    end)

    local addAcctBtn = CreateFrame("Button", nil, pWhitelist, "GameMenuButtonTemplate")
    addAcctBtn:SetPoint("TOPLEFT", pWhitelist, "TOPLEFT", 228, -144)
    addAcctBtn:SetWidth(56); addAcctBtn:SetHeight(22); addAcctBtn:SetText("+Acct")
    addAcctBtn:SetScript("OnClick", function() AddBlacklistEntry(EAL_DB.blacklist) end)
    MakeTooltipButton(addAcctBtn, "|cffb9b9b9Add to Account Whitelist|r", {
        "|cffaaaaaaShared across all characters.|r",
    })

    local addCharBtn = CreateFrame("Button", nil, pWhitelist, "GameMenuButtonTemplate")
    addCharBtn:SetPoint("TOPLEFT", pWhitelist, "TOPLEFT", 286, -144)
    addCharBtn:SetWidth(56); addCharBtn:SetHeight(22); addCharBtn:SetText("+Char")
    addCharBtn:SetScript("OnClick", function() AddBlacklistEntry(EAL_CDB.blacklist) end)
    MakeTooltipButton(addCharBtn, "|cff87ceebAdd to Character Whitelist|r", {
        "|cffaaaaaaApplies only to this character.|r",
    })

    -- Drag-and-drop hint
    local dropHint = pWhitelist:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    dropHint:SetPoint("TOPLEFT", pWhitelist, "TOPLEFT", 18, -396)
    dropHint:SetPoint("TOPRIGHT", pWhitelist, "TOPRIGHT", -18, -396)
    dropHint:SetJustifyH("CENTER")
    dropHint:SetText("|cffaaaaaaTip: drag an item onto this tab, or " ..
                     "|cffffff00Ctrl+Shift+Click|r|cffaaaaaa an item link anywhere.|r")

    local tomeBtn = CreateFrame("Button", nil, pWhitelist, "GameMenuButtonTemplate")
    tomeBtn:SetPoint("TOPLEFT", pWhitelist, "TOPLEFT", 18, -172)
    tomeBtn:SetWidth(264); tomeBtn:SetHeight(22)
    tomeBtn:SetText(L["Whitelist all 'Tome of Echo:' in bags"])
    tomeBtn:SetScript("OnClick", EAL_WhitelistTomes)

    local resetBtn = CreateFrame("Button", nil, pWhitelist, "GameMenuButtonTemplate")
    resetBtn:SetPoint("TOPLEFT", pWhitelist, "TOPLEFT", 286, -172)
    resetBtn:SetWidth(56); resetBtn:SetHeight(22); resetBtn:SetText(L["Clear"])
    resetBtn:GetNormalFontObject():SetTextColor(1, 0.4, 0.4)
    resetBtn:SetScript("OnClick", function()
        StaticPopup_Show("AUTOLOOT_CONFIRM_RESET_WHITELIST")
    end)
    MakeTooltipButton(resetBtn, "|cffff4444Clear Whitelist|r", {
        "|cffaaaaaaClears account + character whitelist.|r",
        "|cffff9900Confirmation required.|r",
    })

    -- v4.12: import/export.  Sits in the right column so the tome button
    -- keeps its full-width look on the left.
    local exportBtn = CreateFrame("Button", nil, pWhitelist, "GameMenuButtonTemplate")
    exportBtn:SetPoint("TOPLEFT", pWhitelist, "TOPLEFT", 366, -172)
    exportBtn:SetWidth(120); exportBtn:SetHeight(22); exportBtn:SetText("Export...")
    exportBtn:SetScript("OnClick", function() EAL_ShowWhitelistIO("export") end)
    MakeTooltipButton(exportBtn, "|cffffd700Export Whitelist|r", {
        "|cffaaaaaaOpens a window with a copy-pasteable string|r",
        "|cffaaaaaacontaining every account + character entry.|r",
        "|cffaaaaaaShare on Discord or paste into an alt to|r",
        "|cffaaaaaamigrate whitelists between characters.|r",
    })

    local importBtn = CreateFrame("Button", nil, pWhitelist, "GameMenuButtonTemplate")
    importBtn:SetPoint("TOPLEFT", pWhitelist, "TOPLEFT", 490, -172)
    importBtn:SetWidth(120); importBtn:SetHeight(22); importBtn:SetText("Import...")
    importBtn:SetScript("OnClick", function() EAL_ShowWhitelistIO("import") end)
    MakeTooltipButton(importBtn, "|cffffd700Import Whitelist|r", {
        "|cffaaaaaaPaste an EBWL:v1:... string.  Entries are|r",
        "|cffaaaaaamerged into your existing whitelist; any|r",
        "|cffaaaaaaduplicates are silently skipped.|r",
    })

    -- Scrollable whitelist
    local TRACK_W = 8
    local listBg = CreateFrame("Frame", nil, pWhitelist)
    listBg:SetPoint("TOPLEFT", pWhitelist, "TOPLEFT", 14, -202)
    listBg:SetWidth(332); listBg:SetHeight(MAX_ROWS * ROW_HEIGHT + 8)
    listBg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    listBg:SetBackdropColor(0, 0, 0, 0.85)
    listBg:EnableMouseWheel(true)
    listBg:SetScript("OnMouseWheel", function(self, delta)
        g_blacklistOffset = g_blacklistOffset - delta
        EAL_RefreshBlacklist()
    end)

    local rowW = 332 - 8 - TRACK_W
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, listBg)
        row:SetWidth(rowW); row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * ROW_HEIGHT)

        local rowBg = row:CreateTexture(nil, "BACKGROUND")
        rowBg:SetAllPoints()
        if i % 2 == 0 then rowBg:SetTexture(0.12, 0.12, 0.12, 0.6)
        else               rowBg:SetTexture(0.06, 0.06, 0.06, 0.6) end

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", 6, 0)
        lbl:SetWidth(rowW - 66); lbl:SetJustifyH("LEFT"); lbl:SetWordWrap(false)

        local removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        removeBtn:SetPoint("RIGHT", -2, 0)
        removeBtn:SetWidth(54); removeBtn:SetHeight(18)
        removeBtn:SetText(L["Remove"])
        removeBtn:GetNormalFontObject():SetTextColor(1, 0.4, 0.4)

        row.label = lbl; row.removeBtn = removeBtn
        row:Hide(); g_blacklistRows[i] = row
    end

    local trackH = MAX_ROWS * ROW_HEIGHT
    local track = CreateFrame("Frame", nil, listBg)
    track:SetWidth(TRACK_W); track:SetHeight(trackH)
    track:SetPoint("TOPRIGHT", -4, -4)
    local trackTex = track:CreateTexture(nil, "BACKGROUND")
    trackTex:SetAllPoints(); trackTex:SetTexture(0.08, 0.08, 0.08, 0.9)
    local thumb = track:CreateTexture(nil, "ARTWORK")
    thumb:SetWidth(TRACK_W - 2); thumb:SetPoint("TOP", track, "TOP", 0, 0)
    thumb:SetTexture(0.65, 0.45, 0.90, 0.9); thumb:Hide()
    g_scrollThumb = thumb

    -------------------------------------------------------------------------
    -- Tab 4: BANK
    -- Auto-deposit-on-open toggle (per-character) and a stash list mirror
    -- of the whitelist UI.  Items in the stash list (union of account +
    -- per-character) are moved into the bank automatically when the
    -- bank window opens (BANKFRAME_OPENED event).
    -------------------------------------------------------------------------
    MakeHeader(pBank, L["BANK SETTINGS"], 18, -124)

    -- Master auto-deposit toggle (per-character).
    local autoDepCb = CreateFrame("CheckButton", nil, pBank, "UICheckButtonTemplate")
    autoDepCb:SetPoint("TOPLEFT", pBank, "TOPLEFT", 18, -144)
    autoDepCb:SetWidth(24); autoDepCb:SetHeight(24)
    autoDepCb:SetChecked(EAL_CDB and EAL_CDB.autoDepositToBank or false)
    local autoDepLbl = pBank:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    autoDepLbl:SetPoint("LEFT", autoDepCb, "RIGHT", 1, 0)
    autoDepLbl:SetText("|cffffd700Auto-deposit stash items|r |cffaaaaaa(this character)|r")
    autoDepCb:SetScript("OnClick", function(self)
        EAL_CDB.autoDepositToBank = self:GetChecked() and true or false
        if EAL_CDB.autoDepositToBank then
            Print("Auto-deposit to bank: |cff44ff44ENABLED|r (this character).")
        else
            Print("Auto-deposit to bank: |cffaaaaaaDISABLED|r (this character).")
        end
    end)
    autoDepCb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cffffd700Auto-deposit on bank open|r")
        GameTooltip:AddLine("|cffaaaaaaWhen you open the bank, items in your|r")
        GameTooltip:AddLine("|cffaaaaaastash list (below) are automatically|r")
        GameTooltip:AddLine("|cffaaaaaamoved from bags into the bank.|r")
        GameTooltip:AddLine("|cffaaaaaaPer-character toggle. Default OFF.|r")
        GameTooltip:Show()
    end)
    autoDepCb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    g_autoDepositCb = autoDepCb

    -- "Deposit now" button
    local depositNowBtn = CreateFrame("Button", nil, pBank, "GameMenuButtonTemplate")
    depositNowBtn:SetPoint("TOPLEFT", pBank, "TOPLEFT", 18, -176)
    depositNowBtn:SetWidth(180); depositNowBtn:SetHeight(22)
    depositNowBtn:SetText("Deposit Stash Now")
    depositNowBtn:SetScript("OnClick", function() EAL_DepositStashItems(true) end)
    MakeTooltipButton(depositNowBtn, "|cffffd700Deposit Stash Now|r", {
        "|cffaaaaaaForce a stash deposit immediately.|r",
        "|cffaaaaaaThe bank window must be open.|r",
        "|cffaaaaaaAlso bound to |cffffff00/eal deposit|r.",
    })

    -- Stash list section
    MakeDivider(pBank, -210)
    MakeHeader(pBank, L["STASH LIST"] ..
               "  |cffb9b9b9[A]|raccount  |cff87ceeb[C]|rchar", 18, -220)

    -- Drop target on the panel.  Forward left-click-drag up to the
    -- window so the user can still drag the settings window from this
    -- tab (mouse-enabled child frames otherwise consume the click).
    pBank:EnableMouse(true)
    pBank:RegisterForDrag("LeftButton")
    pBank:SetScript("OnDragStart", function() win:StartMoving() end)
    pBank:SetScript("OnDragStop", function()
        win:StopMovingOrSizing()
        EAL_DB.windowX = win:GetLeft()
        EAL_DB.windowY = win:GetTop() - UIParent:GetHeight()
    end)
    pBank:SetScript("OnReceiveDrag", function(self)
        local cursorType, _, link = GetCursorInfo()
        if cursorType == "item" and link then
            ClearCursor()
            local name = GetItemInfo(link)
            if name then EAL_LoadIntoListInput(name) end
        end
    end)

    local stashInput = CreateFrame("EditBox", "EAL_StashInput", pBank, "InputBoxTemplate")
    stashInput:SetPoint("TOPLEFT", pBank, "TOPLEFT", 18, -242)
    stashInput:SetWidth(204); stashInput:SetHeight(20)
    stashInput:SetAutoFocus(false); stashInput:SetMaxLetters(64)
    stashInput:SetScript("OnReceiveDrag", function(self)
        local cursorType, _, link = GetCursorInfo()
        if cursorType == "item" and link then
            ClearCursor()
            local name = GetItemInfo(link)
            if name then
                self:SetText(name); self:SetFocus()
            end
        end
    end)

    local function AddStashEntry(list)
        local text = stashInput:GetText():match("^%s*(.-)%s*$")
        if text == "" then return end
        for _, v in ipairs(list) do
            if v:lower() == text:lower() then
                stashInput:SetText(""); return
            end
        end
        table.insert(list, text); stashInput:SetText("")
        EAL_RefreshStashList()
    end
    stashInput:SetScript("OnEnterPressed", function(self)
        AddStashEntry(EAL_DB.stashList); self:ClearFocus()
    end)

    local stashAcctBtn = CreateFrame("Button", nil, pBank, "GameMenuButtonTemplate")
    stashAcctBtn:SetPoint("TOPLEFT", pBank, "TOPLEFT", 228, -240)
    stashAcctBtn:SetWidth(56); stashAcctBtn:SetHeight(22); stashAcctBtn:SetText("+Acct")
    stashAcctBtn:SetScript("OnClick", function() AddStashEntry(EAL_DB.stashList) end)
    MakeTooltipButton(stashAcctBtn, "|cffb9b9b9Add to Account Stash|r", {
        "|cffaaaaaaShared across all characters.|r",
    })

    local stashCharBtn = CreateFrame("Button", nil, pBank, "GameMenuButtonTemplate")
    stashCharBtn:SetPoint("TOPLEFT", pBank, "TOPLEFT", 286, -240)
    stashCharBtn:SetWidth(56); stashCharBtn:SetHeight(22); stashCharBtn:SetText("+Char")
    stashCharBtn:SetScript("OnClick", function() AddStashEntry(EAL_CDB.stashList) end)
    MakeTooltipButton(stashCharBtn, "|cff87ceebAdd to Character Stash|r", {
        "|cffaaaaaaApplies only to this character.|r",
    })

    local stashClearBtn = CreateFrame("Button", nil, pBank, "GameMenuButtonTemplate")
    stashClearBtn:SetPoint("TOPLEFT", pBank, "TOPLEFT", 286, -268)
    stashClearBtn:SetWidth(56); stashClearBtn:SetHeight(22); stashClearBtn:SetText(L["Clear"])
    stashClearBtn:GetNormalFontObject():SetTextColor(1, 0.4, 0.4)
    stashClearBtn:SetScript("OnClick", function()
        StaticPopup_Show("AUTOLOOT_CONFIRM_RESET_STASH")
    end)
    MakeTooltipButton(stashClearBtn, "|cffff4444Clear Stash List|r", {
        "|cffaaaaaaClears account + character stash list.|r",
        "|cffff9900Confirmation required.|r",
    })

    -- Drag-drop hint
    local stashHint = pBank:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    stashHint:SetPoint("TOPLEFT", pBank, "TOPLEFT", 18, -274)
    stashHint:SetPoint("TOPRIGHT", pBank, "TOPRIGHT", -68, -274)
    stashHint:SetJustifyH("LEFT")
    stashHint:SetText("|cffaaaaaaTip: drag an item onto this tab, or |cffffff00Ctrl+Shift+Click|r|cffaaaaaa.|r")

    -- Scrollable stash list (mirror of whitelist scroll)
    local sListBg = CreateFrame("Frame", nil, pBank)
    sListBg:SetPoint("TOPLEFT", pBank, "TOPLEFT", 14, -298)
    sListBg:SetWidth(332); sListBg:SetHeight(MAX_ROWS * ROW_HEIGHT + 8)
    sListBg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    sListBg:SetBackdropColor(0, 0, 0, 0.85)
    sListBg:EnableMouseWheel(true)
    sListBg:SetScript("OnMouseWheel", function(self, delta)
        g_stashOffset = g_stashOffset - delta
        EAL_RefreshStashList()
    end)

    local sRowW = 332 - 8 - 8
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, sListBg)
        row:SetWidth(sRowW); row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * ROW_HEIGHT)

        local rowBg = row:CreateTexture(nil, "BACKGROUND")
        rowBg:SetAllPoints()
        if i % 2 == 0 then rowBg:SetTexture(0.12, 0.12, 0.12, 0.6)
        else               rowBg:SetTexture(0.06, 0.06, 0.06, 0.6) end

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", 6, 0)
        lbl:SetWidth(sRowW - 66); lbl:SetJustifyH("LEFT"); lbl:SetWordWrap(false)

        local removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        removeBtn:SetPoint("RIGHT", -2, 0)
        removeBtn:SetWidth(54); removeBtn:SetHeight(18)
        removeBtn:SetText(L["Remove"])
        removeBtn:GetNormalFontObject():SetTextColor(1, 0.4, 0.4)

        row.label = lbl; row.removeBtn = removeBtn
        row:Hide(); g_stashRows[i] = row
    end

    local sTrack = CreateFrame("Frame", nil, sListBg)
    sTrack:SetWidth(8); sTrack:SetHeight(MAX_ROWS * ROW_HEIGHT)
    sTrack:SetPoint("TOPRIGHT", -4, -4)
    local sTrackTex = sTrack:CreateTexture(nil, "BACKGROUND")
    sTrackTex:SetAllPoints(); sTrackTex:SetTexture(0.08, 0.08, 0.08, 0.9)
    local sThumb = sTrack:CreateTexture(nil, "ARTWORK")
    sThumb:SetWidth(6); sThumb:SetPoint("TOP", sTrack, "TOP", 0, 0)
    sThumb:SetTexture(0.65, 0.45, 0.90, 0.9); sThumb:Hide()
    g_stashScrollThumb = sThumb

    -- ---- Personal Bank sub-section (right column, above Guild Bank) -------
    MakeHeader(pBank, L["PERSONAL BANK"], 380, -124)

    local bankConsolidateBtn = CreateFrame("Button", nil, pBank, "GameMenuButtonTemplate")
    bankConsolidateBtn:SetPoint("TOPLEFT", pBank, "TOPLEFT", 380, -146)
    bankConsolidateBtn:SetWidth(220); bankConsolidateBtn:SetHeight(22)
    bankConsolidateBtn:SetText("Consolidate Bank Stacks")
    bankConsolidateBtn:SetScript("OnClick", function()
        EAL_ConsolidatePersonalBank()
    end)
    MakeTooltipButton(bankConsolidateBtn, "|cffffd700Consolidate Bank Stacks|r", {
        "|cffaaaaaaMerges partial stacks of the same item across|r",
        "|cffaaaaaayour main bank (bag -1) and all bank-bag slots|r",
        "|cffaaaaaa(bags 5..11).  Player bags 0..4 are not touched.|r",
        " ",
        "|cffff9900Open your bank first.|r  Also bound to",
        "|cffffff00/eal bankconsolidate|r |cffaaaaaa(alias |r|cffffff00/eal bc|r|cffaaaaaa).|r",
    })

    local bcHint = pBank:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    bcHint:SetPoint("TOPLEFT", pBank, "TOPLEFT", 380, -178)
    bcHint:SetPoint("TOPRIGHT", pBank, "TOPRIGHT", -14, -178)
    bcHint:SetJustifyH("LEFT")
    bcHint:SetText("|cffaaaaaaMerges partial stacks in main bank + bank bags.|r")

    -- Divider between PERSONAL BANK and GUILD BANK sections
    local rightDivider = pBank:CreateTexture(nil, "ARTWORK")
    rightDivider:SetPoint("TOPLEFT",  pBank, "TOPLEFT",  376, -200)
    rightDivider:SetPoint("TOPRIGHT", pBank, "TOPRIGHT", -14,  -200)
    rightDivider:SetHeight(1)
    rightDivider:SetTexture(0.60, 0.40, 0.85, 0.85)

    -- ---- Guild Bank sub-section (right column in landscape) ---------------
    MakeHeader(pBank, L["GUILD BANK"], 380, -214)

    local gbConsolidateBtn = CreateFrame("Button", nil, pBank, "GameMenuButtonTemplate")
    gbConsolidateBtn:SetPoint("TOPLEFT", pBank, "TOPLEFT", 380, -236)
    gbConsolidateBtn:SetWidth(220); gbConsolidateBtn:SetHeight(22)
    gbConsolidateBtn:SetText("Consolidate Stacks")
    gbConsolidateBtn:SetScript("OnClick", function()
        EAL_ConsolidateGuildBankCurrentTab()
    end)
    MakeTooltipButton(gbConsolidateBtn, "|cffffd700Consolidate Stacks|r", {
        "|cffaaaaaaMerges partial stacks of the same item in|r",
        "|cffaaaaaathe currently-displayed guild bank tab.|r",
        " ",
        "|cffaaaaaaRequires |cffffff00view + deposit|r |cffaaaaaapermission on the|r",
        "|cffaaaaaatab.  Movements count against your daily|r",
        "|cffaaaaaawithdrawal limit on most servers.|r",
        " ",
        "|cffff9900Open the guild bank first.|r  Also bound to",
        "|cffffff00/eal gbconsolidate|r |cffaaaaaa(alias |r|cffffff00/eal gbc|r|cffaaaaaa).|r",
    })

    local gbHint = pBank:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    gbHint:SetPoint("TOPLEFT", pBank, "TOPLEFT", 380, -268)
    gbHint:SetPoint("TOPRIGHT", pBank, "TOPRIGHT", -14, -268)
    gbHint:SetJustifyH("LEFT")
    gbHint:SetText("|cffaaaaaaOperates on the current GB tab.|r")

    -------------------------------------------------------------------------
    -- Tab 5: MAIL
    -- Per-character auto-collect on MAIL_SHOW with sub-toggles for money
    -- vs. items, plus optional cleanup of read empty mail.  COD mail is
    -- always skipped in auto-collect: we never auto-pay a CODAmount.
    -------------------------------------------------------------------------
    MakeHeader(pMail, L["MAIL SETTINGS"], 18, -124)

    -- Master auto-collect toggle (per-character)
    local mailMasterCb = CreateFrame("CheckButton", nil, pMail, "UICheckButtonTemplate")
    mailMasterCb:SetPoint("TOPLEFT", pMail, "TOPLEFT", 18, -144)
    mailMasterCb:SetWidth(24); mailMasterCb:SetHeight(24)
    mailMasterCb:SetChecked(EAL_CDB and EAL_CDB.mailAutoCollect or false)
    local mailMasterLbl = pMail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mailMasterLbl:SetPoint("LEFT", mailMasterCb, "RIGHT", 1, 0)
    mailMasterLbl:SetText("|cffffd700Auto-collect on mailbox open|r |cffaaaaaa(this character)|r")
    mailMasterCb:SetScript("OnClick", function(self)
        EAL_CDB.mailAutoCollect = self:GetChecked() and true or false
        if EAL_CDB.mailAutoCollect then
            Print("Mail auto-collect: |cff44ff44ENABLED|r (this character).")
        else
            Print("Mail auto-collect: |cffaaaaaaDISABLED|r (this character).")
        end
    end)
    mailMasterCb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cffffd700Auto-collect on mailbox open|r")
        GameTooltip:AddLine("|cffaaaaaaWhen you open your mailbox, take money|r")
        GameTooltip:AddLine("|cffaaaaaaand/or attachments per the sub-toggles.|r")
        GameTooltip:AddLine("|cffff9900COD mail is always skipped.|r")
        GameTooltip:Show()
    end)
    mailMasterCb:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Sub-toggles (indented under master)
    MakeCheckbox(pMail, "|cffffd700Collect money|r attachments", 36, -170,
        function() return EAL_CDB and EAL_CDB.mailCollectMoney end,
        function(v) EAL_CDB.mailCollectMoney = v end,
        {
            "|cffffd700Collect money|r",
            "|cffaaaaaaTake the gold/silver/copper sent in each mail.|r",
        })

    MakeCheckbox(pMail, "|cffffd700Collect item|r attachments", 36, -192,
        function() return EAL_CDB and EAL_CDB.mailCollectItems end,
        function(v) EAL_CDB.mailCollectItems = v end,
        {
            "|cffffd700Collect items|r",
            "|cffaaaaaaTake each item attachment from non-COD mails.|r",
            "|cffaaaaaaItems land in your bags; mail with all|r",
            "|cffaaaaaaattachments taken can then be auto-deleted|r",
            "|cffaaaaaa(if the option below is on).|r",
        })

    -- Auto-delete read empty mail
    MakeCheckbox(pMail, "|cffff4444Auto-delete|r read mail with no attachments", 18, -220,
        function() return EAL_CDB and EAL_CDB.mailAutoDeleteRead end,
        function(v) EAL_CDB.mailAutoDeleteRead = v end,
        {
            "|cffff4444Auto-delete read empty mail|r",
            "|cffaaaaaaAfter the auto-collect pass, sweeps the inbox|r",
            "|cffaaaaaaand deletes any mail that is read, has no|r",
            "|cffaaaaaaitems, no money, and no COD.  Irreversible.|r",
            " ",
            "|cffff9900Recommended OFF unless you trust the collect|r",
            "|cffff9900pass to never miss anything you care about.|r",
        })

    -- Manual action row
    MakeDivider(pMail, -250)
    local collectNowBtn = CreateFrame("Button", nil, pMail, "GameMenuButtonTemplate")
    collectNowBtn:SetPoint("TOPLEFT", pMail, "TOPLEFT", 18, -262)
    collectNowBtn:SetWidth(150); collectNowBtn:SetHeight(22)
    collectNowBtn:SetText("Collect Now")
    collectNowBtn:SetScript("OnClick", function() EAL_AutoCollectMail(true) end)
    MakeTooltipButton(collectNowBtn, "|cffffd700Collect Now|r", {
        "|cffaaaaaaForce a collect pass on the open mailbox.|r",
        "|cffaaaaaaUses your current sub-toggle settings.|r",
        "|cffaaaaaaAlso bound to |cffffff00/eal mail|r.",
    })

    local cleanMailBtn = CreateFrame("Button", nil, pMail, "GameMenuButtonTemplate")
    cleanMailBtn:SetPoint("TOPLEFT", pMail, "TOPLEFT", 178, -262)
    cleanMailBtn:SetWidth(164); cleanMailBtn:SetHeight(22)
    cleanMailBtn:SetText("Clean Read Mail")
    cleanMailBtn:GetNormalFontObject():SetTextColor(1, 0.55, 0.35)
    cleanMailBtn:SetScript("OnClick", function() EAL_CleanReadMail() end)
    MakeTooltipButton(cleanMailBtn, "|cffff8855Clean Read Mail|r", {
        "|cffaaaaaaDelete every mail in your inbox that is|r",
        "|cffaaaaaaread, has no money/items, and no COD.|r",
        "|cffff9900Irreversible.|r",
        " ",
        "|cffaaaaaaAlso bound to |cffffff00/eal cleanmail|r.",
    })

    -- COD safety hint
    local mailCodHint = pMail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    mailCodHint:SetPoint("TOPLEFT", pMail, "TOPLEFT", 18, -294)
    mailCodHint:SetPoint("TOPRIGHT", pMail, "TOPRIGHT", -18, -294)
    mailCodHint:SetJustifyH("LEFT")
    mailCodHint:SetText("|cffaaaaaaCOD mail is always skipped \226\128\148 you'll never accidentally pay one.|r")

    -------------------------------------------------------------------------
    -- Tab 6: FILTER  (v4.12)
    -- Per-subclass "always keep" / "always sell" rules that override the
    -- quality toggles.  Whitelist and price-cap still apply on top.  Two
    -- columns of category rows; each row is [icon] [label] [Keep] [Sell].
    -- The buttons are latched: clicking an already-active state clears it.
    -------------------------------------------------------------------------
    MakeHeader(pFilter, "ITEM FAMILY FILTER  |cffb9b9b9(overrides quality ticks)|r", 18, -124)

    local filterHint = pFilter:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    filterHint:SetPoint("TOPLEFT", pFilter, "TOPLEFT", 18, -142)
    filterHint:SetPoint("TOPRIGHT", pFilter, "TOPRIGHT", -18, -142)
    filterHint:SetJustifyH("LEFT")
    filterHint:SetText("|cffaaaaaa|cffb9ff99Keep|r = never sell this family.  " ..
                        "|cffff9955Sell|r = force-sell (needs vendor price).  " ..
                        "Whitelist still wins.|r")

    EAL_DB.familyFilter = EAL_DB.familyFilter or {}

    local ROW_H     = 26
    local COL_X     = { 14, 366 }   -- left / right column starts
    local COL_W     = 340           -- each column's width
    local ROW_Y0    = -164

    local filterButtons = {}   -- key -> { keepBtn, sellBtn }

    local function RefreshFilterRow(key)
        local pair = filterButtons[key]
        if not pair then return end
        local decision = EAL_DB.familyFilter[key]
        -- Latched appearance: use LockHighlight when active.
        if decision == "keep" then pair.keepBtn:LockHighlight() else pair.keepBtn:UnlockHighlight() end
        if decision == "sell" then pair.sellBtn:LockHighlight() else pair.sellBtn:UnlockHighlight() end
    end

    for i, cat in ipairs(FAMILY_CATEGORIES) do
        local col = ((i - 1) % 2) + 1        -- 1 or 2
        local row = math.floor((i - 1) / 2)
        local rowFrame = CreateFrame("Frame", nil, pFilter)
        rowFrame:SetWidth(COL_W); rowFrame:SetHeight(ROW_H)
        rowFrame:SetPoint("TOPLEFT", pFilter, "TOPLEFT",
                          COL_X[col], ROW_Y0 - row * ROW_H)

        local rowBg = rowFrame:CreateTexture(nil, "BACKGROUND")
        rowBg:SetAllPoints()
        rowBg:SetTexture("Interface\\Buttons\\WHITE8X8")
        if row % 2 == 0 then rowBg:SetVertexColor(0.12, 0.10, 0.18, 0.55)
        else                 rowBg:SetVertexColor(0.08, 0.06, 0.14, 0.55) end

        local icon = rowFrame:CreateTexture(nil, "ARTWORK")
        icon:SetTexture(cat.icon)
        icon:SetSize(20, 20)
        icon:SetPoint("LEFT", 4, 0)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        local lbl = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        lbl:SetWidth(180); lbl:SetJustifyH("LEFT"); lbl:SetWordWrap(false)
        lbl:SetText(cat.label)

        local keepBtn = CreateFrame("Button", nil, rowFrame, "UIPanelButtonTemplate")
        keepBtn:SetSize(58, 20)
        keepBtn:SetPoint("RIGHT", -66, 0)
        keepBtn:SetText("Keep")
        keepBtn:GetNormalFontObject():SetTextColor(0.72, 1.00, 0.60)
        local sellBtn = CreateFrame("Button", nil, rowFrame, "UIPanelButtonTemplate")
        sellBtn:SetSize(58, 20)
        sellBtn:SetPoint("RIGHT", -4, 0)
        sellBtn:SetText("Sell")
        sellBtn:GetNormalFontObject():SetTextColor(1.00, 0.60, 0.35)

        local capturedKey = cat.key
        keepBtn:SetScript("OnClick", function()
            if EAL_DB.familyFilter[capturedKey] == "keep" then
                EAL_DB.familyFilter[capturedKey] = nil
            else
                EAL_DB.familyFilter[capturedKey] = "keep"
            end
            RefreshFilterRow(capturedKey)
        end)
        sellBtn:SetScript("OnClick", function()
            if EAL_DB.familyFilter[capturedKey] == "sell" then
                EAL_DB.familyFilter[capturedKey] = nil
            else
                EAL_DB.familyFilter[capturedKey] = "sell"
            end
            RefreshFilterRow(capturedKey)
        end)

        filterButtons[capturedKey] = { keepBtn = keepBtn, sellBtn = sellBtn }
        RefreshFilterRow(capturedKey)
    end

    -- Clear-all button below the grid
    local clearFiltersBtn = CreateFrame("Button", nil, pFilter, "GameMenuButtonTemplate")
    clearFiltersBtn:SetPoint("BOTTOMLEFT", pFilter, "BOTTOMLEFT", 18, 32)
    clearFiltersBtn:SetSize(180, 22)
    clearFiltersBtn:SetText("Clear All Filter Rules")
    clearFiltersBtn:GetNormalFontObject():SetTextColor(1, 0.55, 0.35)
    clearFiltersBtn:SetScript("OnClick", function()
        EAL_DB.familyFilter = {}
        for _, cat in ipairs(FAMILY_CATEGORIES) do RefreshFilterRow(cat.key) end
        Print("Family filter rules cleared.")
    end)
    MakeTooltipButton(clearFiltersBtn, "|cffff8855Clear All Filter Rules|r", {
        "|cffaaaaaaRemoves all Keep/Sell family overrides.|r",
        "|cffaaaaaaThe quality ticks on the Sell tab take|r",
        "|cffaaaaaaover again for every item family.|r",
    })

    -- Bottom hint (always visible across tabs)
    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOM", 0, 14)
    hint:SetText("|cffaaaaaa/eal toggle | sell | deposit | mail | reset   -   right-click minimap = toggle|r")

    -- Restore last-selected tab, or default to General
    local startTab = tonumber(EAL_DB.lastTab) or 1
    if not panels[startTab] then startTab = 1 end
    ShowTab(startTab)

    EAL_UpdateStatus()
    EAL_RefreshBlacklist()
    EAL_RefreshStashList()

    return win
end

-------------------------------------------------------------------------------
-- Blizzard Interface Options panel (slim: opens the main window)
-------------------------------------------------------------------------------
local function EAL_RegisterOptionsPanel()
    local panel = CreateFrame("Frame", "AutoLootOptionsPanel", UIParent)
    panel.name = ADDON_NAME

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("AutoLoot  |cff888888v" .. ADDON_VERSION .. "|r")

    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetWidth(560)
    desc:SetJustifyH("LEFT")
    desc:SetText("Automated loot + vendor cycle using summonable companions. " ..
                 "The main settings window has all options.")

    local openBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    openBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
    openBtn:SetWidth(180); openBtn:SetHeight(24)
    openBtn:SetText("Open AutoLoot settings")
    openBtn:SetScript("OnClick", function()
        if g_optionsFrame then
            g_optionsFrame:Show()
            EAL_UpdateStatus()
            EAL_RefreshBlacklist()
        end
    end)

    local cmdInfo = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cmdInfo:SetPoint("TOPLEFT", openBtn, "BOTTOMLEFT", 0, -24)
    cmdInfo:SetWidth(560)
    cmdInfo:SetJustifyH("LEFT")
    cmdInfo:SetText(
        "|cffffd700Slash commands:|r\n" ..
        "  /eal  or  /autoloot   - open / close the settings window\n" ..
        "  /eal toggle           - enable / disable the loot+sell cycle\n" ..
        "  /eal enable           - explicit enable\n" ..
        "  /eal disable          - explicit disable\n" ..
        "  /eal sell             - force a sell cycle right now\n" ..
        "  /eal ilvlsell         - quick-sell low-iLvl gear (confirmation)\n" ..
        "  /eal deposit          - bank: deposit stash items\n" ..
        "  /eal mail             - mailbox: collect attachments + money\n" ..
        "  /eal cleanmail        - delete read empty mail\n" ..
        "  /eal bankconsolidate  - personal bank: consolidate stacks\n" ..
        "  /eal gbconsolidate    - guild bank: consolidate stacks (current tab)\n" ..
        "  /eal reset            - clear whitelist (confirmation)\n" ..
        "  /eal minimap          - show / hide the minimap button\n" ..
        "  /eal help             - print the command list in chat\n" ..
        "\n" ..
        "|cffffd700Keybindings:|r bind in Escape -> Key Bindings -> AutoLoot."
    )

    -- Credit footer. Shown in the Blizzard options panel so users always
    -- know where to go for upstream support and updates.
    local credit = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    credit:SetPoint("BOTTOMLEFT", 16, 16)
    credit:SetText("|cff777777Created by " .. ADDON_AUTHOR ..
                   "  -  " .. ADDON_URL .. "|r")

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
    return panel
end

-------------------------------------------------------------------------------
-- Event frame
-------------------------------------------------------------------------------
local function MergeDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                target[k] = {}
                for ek, ev in pairs(v) do target[k][ek] = ev end
            else
                target[k] = v
            end
        end
    end
end

local function RunMigrations(db, cdb)
    local from = db.schemaVersion or 1
    if from == CURRENT_SCHEMA then return end

    -- v1 -> v2: introduced per-character whitelist; no data moves, just mark.
    if from < 2 then
        db.schemaVersion = 2
    end

    -- v3 -> v4: Actions tab was removed in v4.6.0 (quick-sell-by-iLvl
    -- moved to the Sell tab) and Mail tab was added.  Remap the stored
    -- lastTab index so users who were last on Actions/Whitelist/Bank
    -- end up on the correct tab in the new layout instead of being
    -- silently shifted by one.
    --   Old: 1=General 2=Sell 3=Actions 4=Whitelist 5=Bank
    --   New: 1=General 2=Sell           3=Whitelist 4=Bank 5=Mail
    local function _v3_to_v4_lastTab(db)
        if db.lastTab == 3 then db.lastTab = 1   -- Actions removed
        elseif db.lastTab == 4 then db.lastTab = 3   -- Whitelist shifted up
        elseif db.lastTab == 5 then db.lastTab = 4   -- Bank shifted up
        end
    end

    -- v2 -> v3: split the single autoDeleteRares boolean into a per-quality
    -- table.  If the user had autoDeleteRares = true under v2, preserve
    -- their existing behavior by enabling the master + Rare quality only.
    if from < 3 then
        db.autoDeleteUnsellable = db.autoDeleteUnsellable or {
            enabled = false, common = false, uncommon = false,
            rare = false, epic = false,
        }
        if db.autoDeleteRares then
            db.autoDeleteUnsellable.enabled = true
            db.autoDeleteUnsellable.rare    = true
        end
        db.autoDeleteRares = nil   -- old field no longer used
        db.schemaVersion   = 3
    end

    if from < 4 then
        _v3_to_v4_lastTab(db)
        db.schemaVersion = 4
    end

    cdb.schemaVersion = CURRENT_SCHEMA
    Print("Migrated settings: schema v" .. from .. " -> v" .. CURRENT_SCHEMA)
end

local function InitDB()
    EAL_SavedDB = EAL_SavedDB or {}
    EAL_CharDB  = EAL_CharDB  or {}
    EAL_DB      = EAL_SavedDB
    EAL_CDB     = EAL_CharDB
    MergeDefaults(EAL_DB,  DEFAULTS)
    MergeDefaults(EAL_CDB, CHAR_DEFAULTS)
    RunMigrations(EAL_DB, EAL_CDB)

    -- Provenance stamp: written to SavedVariables on every load so bug
    -- reports, crash dumps, and user screenshots of their WTF folder
    -- always trace back to the correct upstream project.
    EAL_DB.__origin  = ADDON_URL
    EAL_DB.__author  = ADDON_AUTHOR
    EAL_DB.__ident   = ADDON_IDENT
    EAL_CDB.__origin = ADDON_URL
    EAL_CDB.__author = ADDON_AUTHOR
end

local eventFrame = CreateFrame("Frame", "EAL_EventFrame", UIParent)
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("BANKFRAME_OPENED")
eventFrame:RegisterEvent("MAIL_SHOW")
-- v4.12: react to the critter list finishing loading (early PLAYER_LOGIN
-- races cause "Companion 'X' not found" if we try to summon before the
-- companion list is populated) and to combat-end (so sell cycles
-- deferred while in combat can resume).
eventFrame:RegisterEvent("COMPANION_UPDATE")
eventFrame:RegisterEvent("COMPANION_LEARNED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then InitDB() end

    elseif event == "PLAYER_LOGIN" then
        if not EAL_DB then InitDB() end
        g_optionsFrame = EAL_BuildGUI()
        g_vendorBtn    = EAL_BuildVendorButton()
        g_minimapBtn   = EAL_BuildMinimapButton()
        EAL_RegisterOptionsPanel()
        UpdateMinimapButton()
        Print("v" .. ADDON_VERSION .. " by |cffffd700" .. ADDON_AUTHOR ..
              "|r loaded.  |cffffff00/eal|r to open, or click the minimap button.")

    elseif event == "MERCHANT_SHOW" then
        OnMerchantShow()

    elseif event == "MERCHANT_CLOSED" then
        OnMerchantClosed()

    elseif event == "BAG_UPDATE" then
        bagUpdateDirty = true

    elseif event == "BANKFRAME_OPENED" then
        -- Slight delay so the bank frame is fully populated before scanning.
        After(0.2, function() EAL_DepositStashItems(false) end)

    elseif event == "MAIL_SHOW" then
        -- Inbox isn't necessarily populated on the same frame as MAIL_SHOW;
        -- 0.4s gives it time to settle before we start walking entries.
        After(0.4, function() EAL_AutoCollectMail(false) end)

    elseif event == "COMPANION_UPDATE" or event == "COMPANION_LEARNED" then
        -- Retry any summon that failed because the critter list was empty.
        if pendingSummonName and EAL_DB and EAL_DB.enabled then
            local name = pendingSummonName
            pendingSummonName = nil   -- SummonPet re-latches on failure
            SummonPet(name)
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat ended.  Any sell cycle that StartSellCycle deferred can
        -- now fire.  Small delay so BAG_UPDATE from combat looting settles.
        if pendingSellCycle then
            After(0.5, TryStartDeferredSell)
        end
    end
end)

eventFrame:SetScript("OnUpdate", OnUpdate)

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
SLASH_EBAUTOLOOT1 = "/eal"
SLASH_EBAUTOLOOT2 = "/autoloot"

SlashCmdList["EBAUTOLOOT"] = function(msg)
    if not g_optionsFrame then
        Print("GUI not ready yet.", 1, 0.5, 0.5)
        return
    end

    local cmd = msg and msg:lower():match("^%s*(%S*)") or ""

    if cmd == "reset" then
        StaticPopup_Show("AUTOLOOT_CONFIRM_RESET_WHITELIST")
    elseif cmd == "enable" then
        EAL_DB.enabled = true
        StartLootCycle()
        EAL_UpdateStatus()
    elseif cmd == "disable" then
        EAL_DB.enabled = false
        DismissPet()
        SetState(S_IDLE)
    elseif cmd == "toggle" then
        EAL_DB.enabled = not EAL_DB.enabled
        if EAL_DB.enabled then StartLootCycle()
        else                   DismissPet(); SetState(S_IDLE) end
        EAL_UpdateStatus()
    elseif cmd == "sell" then
        StartSellCycle()
    elseif cmd == "ilvlsell" or cmd == "lowilvl" then
        EAL_PromptSellLowILvl()
    elseif cmd == "deposit" or cmd == "stash" then
        EAL_DepositStashItems(true)
    elseif cmd == "mail" or cmd == "collect" then
        EAL_AutoCollectMail(true)
    elseif cmd == "cleanmail" then
        EAL_CleanReadMail()
    elseif cmd == "gbconsolidate" or cmd == "gbc" then
        EAL_ConsolidateGuildBankCurrentTab()
    elseif cmd == "bankconsolidate" or cmd == "bc" then
        EAL_ConsolidatePersonalBank()
    elseif cmd == "minimap" then
        EAL_DB.showMinimapButton = not EAL_DB.showMinimapButton
        UpdateMinimapButton()
        Print("Minimap button: " .. (EAL_DB.showMinimapButton and "|cff44ff44shown|r" or "|cffaaaaaahidden|r"))
    elseif cmd == "export" then
        EAL_ShowWhitelistIO("export")
    elseif cmd == "import" then
        EAL_ShowWhitelistIO("import")
    elseif cmd == "help" or cmd == "?" then
        Print("Commands: toggle | enable | disable | sell | ilvlsell | deposit | mail | cleanmail | bankconsolidate | gbconsolidate | export | import | reset | minimap | help")
    else
        if g_optionsFrame:IsShown() then
            g_optionsFrame:Hide()
        else
            EAL_UpdateStatus()
            EAL_RefreshBlacklist()
            g_optionsFrame:Show()
        end
    end
end

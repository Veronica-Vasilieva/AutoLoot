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
local ADDON_VERSION = "4.0"
local CURRENT_SCHEMA = 2

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
local SAVAGE_PREFIX_LOWER = "savage "

-- SavedVariables schema
local DEFAULTS = {
    schemaVersion     = CURRENT_SCHEMA,

    -- Core behavior
    enabled           = false,
    lootCompanion     = "Greedy Scavenger",
    vendorCompanion   = "Goblin Merchant",
    sellOnAnyVendor   = false,   -- when false, only auto-sell when we actively triggered the sell cycle
    autoDeleteRares   = false,   -- silently delete rare items with no vendor price (OPT-IN: dangerous)
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

    -- Whitelist scope (union of account + per-character is used at runtime)
    blacklist        = {},        -- account-wide whitelist (name misnomer kept for back-compat)

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
}

local CHAR_DEFAULTS = {
    schemaVersion = CURRENT_SCHEMA,
    blacklist     = {},           -- per-character whitelist
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

-- Money-delta measurement for a single sell session
local sellSessionStartMoney = 0
local sellSessionActive     = false

-- Forward declarations (required — some functions reference each other
-- across the file and Lua's `local function` doesn't hoist)
local EAL_RefreshBlacklist
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

-- Scans all bags for items whose name starts with "Savage " and deletes them
-- one at a time, auto-confirming the DELETE_ITEM popup between each.
local function EAL_DeleteSavageGear()
    if InCombatLockdown() then
        Print("|cffff4444Cannot delete items during combat.|r")
        return
    end

    local toDelete = {}
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name = GetItemInfo(link)
                if name and name:lower():sub(1, #SAVAGE_PREFIX_LOWER) == SAVAGE_PREFIX_LOWER then
                    table.insert(toDelete, { bag = bag, slot = slot })
                end
            end
        end
    end

    if #toDelete == 0 then
        Print("No Savage PvP gear found in bags.")
        return
    end

    local total = #toDelete
    Print("Deleting |cffffff00" .. total .. "|r Savage PvP item(s)...")

    local function DeleteNext(idx)
        if idx > #toDelete then
            Print("|cffffff00" .. total .. "|r Savage PvP item(s) deleted.")
            return
        end
        local item = toDelete[idx]
        local link = GetContainerItemLink(item.bag, item.slot)
        if link then
            local name = GetItemInfo(link)
            if name and name:lower():sub(1, #SAVAGE_PREFIX_LOWER) == SAVAGE_PREFIX_LOWER then
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
        Print("Companion '" .. (name or "?") .. "' not found in your companion list.", 1, 0.3, 0.3)
        return false
    end
    if not active then
        CallCompanion("CRITTER", idx)
        Print("Summoning " .. name .. "...")
    end
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

local function GetCompanionDistance()
    if not UnitPosition then return nil end
    local px, py = UnitPosition("player")
    local cx, cy = UnitPosition("pet")
    if not px or not cx then return nil end
    local dx, dy = px - cx, py - cy
    return math.sqrt(dx * dx + dy * dy)
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

    for bag = 0, 4 do
        if capped then break end
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name, _, quality = GetItemInfo(link)
                if quality and name then
                    local sell =
                        (quality == Q_GREY     and EAL_DB.sellGrey)     or
                        (quality == Q_WHITE    and EAL_DB.sellWhite)    or
                        (quality == Q_UNCOMMON and EAL_DB.sellUncommon) or
                        (quality == Q_RARE     and EAL_DB.sellRare)     or
                        (quality == Q_EPIC     and EAL_DB.sellEpic)

                    if sell and IsBlacklisted(name) then
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
            RepairAllItems()
            Print("All items repaired.")
        end
        SellItems()
    end)
end

local function OnMerchantClosed()
    triggeredSellCycle = false
    if currentState == S_SELLING then
        local free = GetTotalFreeSlots()
        if EAL_DB.enabled and free > 0 then
            After(1, StartLootCycle)
        else
            SetState(S_IDLE)
        end
    end
end

local function CheckCompanionStuck()
    if IsPlayerMountedOrFlying() then return end
    local dist = GetCompanionDistance()
    if dist == nil then return end
    if dist > MAX_COMPANION_DISTANCE then
        Print("Greedy Scavenger is stuck (" .. math.floor(dist) ..
              " yds away) - resummoning...", 1, 0.75, 0.2)
        DismissPet()
        After(0.5, function()
            SummonPet(EAL_DB.lootCompanion)
        end)
    end
end

-- OPT-IN: Scans bags for Rare-quality items with no vendor price and deletes
-- them one at a time. Off by default; controlled by EAL_DB.autoDeleteRares.
local g_deletingRares = false
local function EAL_DeleteUnsellableRares()
    if not EAL_DB.autoDeleteRares then return end
    if g_deletingRares or InCombatLockdown() then return end

    local toDelete = {}
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name, _, quality, _, _, _, _, _, _, _, vendorPrice = GetItemInfo(link)
                if name
                    and quality == Q_RARE
                    and (not vendorPrice or vendorPrice == 0)
                    and not IsBlacklisted(name)
                then
                    table.insert(toDelete, { bag = bag, slot = slot })
                end
            end
        end
    end

    if #toDelete == 0 then return end

    g_deletingRares = true
    local total = #toDelete

    local function DeleteNext(idx)
        if idx > #toDelete then
            g_deletingRares = false
            Print("|cffffff00" .. total .. "|r unsellable rare(s) with no sell price deleted.")
            return
        end
        local item = toDelete[idx]
        local link = GetContainerItemLink(item.bag, item.slot)
        if link then
            local name, _, quality, _, _, _, _, _, _, _, vendorPrice = GetItemInfo(link)
            if name
                and quality == Q_RARE
                and (not vendorPrice or vendorPrice == 0)
                and not IsBlacklisted(name)
            then
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
            end
        end
    end

    -- Stuck check: share the timer interval, skip while mounted.
    if EAL_DB.enabled and currentState == S_LOOTING and not nowMounted then
        bagCheckTimer = bagCheckTimer + elapsed
        if bagCheckTimer >= (EAL_DB.checkInterval or 3) then
            bagCheckTimer = 0
            EAL_UpdateStatus()
            EAL_DeleteUnsellableRares()
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
    end
end

-------------------------------------------------------------------------------
-- Static popup dialogs
-------------------------------------------------------------------------------
StaticPopupDialogs["AUTOLOOT_CONFIRM_DELETE_SAVAGE"] = {
    text         = "Permanently delete ALL items in your bags whose name starts with \"Savage \"?\n\n|cffff4444This cannot be undone.|r",
    button1      = "Delete",
    button2      = "Cancel",
    OnAccept     = function() EAL_DeleteSavageGear() end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

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

StaticPopupDialogs["AUTOLOOT_CONFIRM_AUTODELETE_RARES"] = {
    text         = "Enable automatic deletion of Rare items with no vendor price?\n\n|cffff4444This silently deletes rare items every few seconds. Some rare quest items, tokens, and unique gear have no vendor price and will be destroyed.|r\n\nOnly enable if you understand what this does.",
    button1      = "Enable",
    button2      = "Cancel",
    OnAccept     = function()
        EAL_DB.autoDeleteRares = true
        if g_autoDelCb then g_autoDelCb:SetChecked(true) end
        Print("Auto-delete unsellable rares: |cffff4444ENABLED|r.")
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
    t:SetPoint("TOPLEFT", 14, y)
    t:SetWidth(312); t:SetHeight(1)
    t:SetTexture(0.45, 0.35, 0.15, 0.9)
    return t
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

local function EAL_BuildGUI()
    local win = CreateFrame("Frame", "EAL_Window", UIParent)
    win:SetWidth(340); win:SetHeight(740)
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
    win:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    -- Warmer, darker bg tint with gold-tinged border (WotLK "merchant hall" feel)
    win:SetBackdropColor(0.10, 0.08, 0.06, 0.95)
    win:SetBackdropBorderColor(0.85, 0.68, 0.28, 1)

    -- Vertical parchment-glow gradient overlay: slightly warmer near the top,
    -- fades toward the bottom for depth. Low alpha so text stays readable.
    local bgGrad = win:CreateTexture(nil, "BACKGROUND", nil, 2)
    bgGrad:SetTexture("Interface\\Buttons\\WHITE8X8")
    bgGrad:SetPoint("TOPLEFT",     13, -13)
    bgGrad:SetPoint("BOTTOMRIGHT", -13, 13)
    bgGrad:SetGradientAlpha("VERTICAL",
        0.05, 0.04, 0.03, 0.18,   -- bottom (subtle darken)
        0.22, 0.14, 0.06, 0.10)   -- top (subtle warm glow)

    -- Gold L-bracket accents at each corner
    local function GoldCorner(point, ox, oy)
        local horiz = win:CreateTexture(nil, "OVERLAY")
        horiz:SetTexture("Interface\\Buttons\\WHITE8X8")
        horiz:SetVertexColor(0.90, 0.72, 0.30, 0.95)
        horiz:SetSize(16, 2)
        horiz:SetPoint(point, ox, oy)

        local vert = win:CreateTexture(nil, "OVERLAY")
        vert:SetTexture("Interface\\Buttons\\WHITE8X8")
        vert:SetVertexColor(0.90, 0.72, 0.30, 0.95)
        vert:SetSize(2, 16)
        vert:SetPoint(point, ox, oy)
    end
    GoldCorner("TOPLEFT",      14, -14)
    GoldCorner("TOPRIGHT",    -14, -14)
    GoldCorner("BOTTOMLEFT",   14,  14)
    GoldCorner("BOTTOMRIGHT", -14,  14)

    -- Gold rule under the title bar (with additive glow above and below)
    local function GoldRuleAt(yOffset)
        local rule = win:CreateTexture(nil, "ARTWORK")
        rule:SetTexture("Interface\\Buttons\\WHITE8X8")
        rule:SetVertexColor(0.90, 0.72, 0.30, 1)
        rule:SetPoint("TOPLEFT",  20, yOffset)
        rule:SetPoint("TOPRIGHT", -20, yOffset)
        rule:SetHeight(1)

        local up = win:CreateTexture(nil, "ARTWORK")
        up:SetTexture("Interface\\Buttons\\WHITE8X8")
        up:SetVertexColor(1, 0.80, 0.30)
        up:SetBlendMode("ADD"); up:SetAlpha(0.25)
        up:SetPoint("BOTTOMLEFT",  rule, "TOPLEFT",  0, 0)
        up:SetPoint("BOTTOMRIGHT", rule, "TOPRIGHT", 0, 0)
        up:SetHeight(4)

        local dn = win:CreateTexture(nil, "ARTWORK")
        dn:SetTexture("Interface\\Buttons\\WHITE8X8")
        dn:SetVertexColor(1, 0.80, 0.30)
        dn:SetBlendMode("ADD"); dn:SetAlpha(0.25)
        dn:SetPoint("TOPLEFT",  rule, "BOTTOMLEFT",  0, 0)
        dn:SetPoint("TOPRIGHT", rule, "BOTTOMRIGHT", 0, 0)
        dn:SetHeight(4)
    end
    GoldRuleAt(-34)

    win:Hide()

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("AutoLoot |cffaaaaaa& Sell|r  |cff888888v" .. ADDON_VERSION .. "|r")

    local closeBtn = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() win:Hide() end)

    -- Status row
    MakeDivider(win, -36)
    local statusLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusLabel:SetPoint("TOPLEFT", 18, -48)
    statusLabel:SetWidth(200)
    statusLabel:SetJustifyH("LEFT")
    g_statusLabel = statusLabel

    local fastModeCb = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
    fastModeCb:SetPoint("TOPRIGHT", -11, -42)
    fastModeCb:SetWidth(24); fastModeCb:SetHeight(24)
    fastModeCb:SetChecked(EAL_DB.fastMode)
    local fastModeLbl = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fastModeLbl:SetPoint("RIGHT", fastModeCb, "LEFT", -2, 0)
    fastModeLbl:SetText("|cffff4444Fast Mode|r")
    fastModeCb:SetScript("OnClick", function(self)
        EAL_DB.fastMode = self:GetChecked() and true or false
    end)
    fastModeCb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cffff4444Fast Mode|r")
        GameTooltip:AddLine("|cffff9900Warning: may cause disconnects on|r")
        GameTooltip:AddLine("|cffff9900lower-end hardware.|r")
        GameTooltip:AddLine("|cffaaaaaaDoubles items sold per batch and|r")
        GameTooltip:AddLine("|cffaaaaaahalves the delay between batches.|r")
        GameTooltip:Show()
    end)
    fastModeCb:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Gold earned
    local goldLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    goldLabel:SetPoint("TOPLEFT", 18, -64)
    goldLabel:SetWidth(304)
    goldLabel:SetJustifyH("LEFT")
    g_goldLabel = goldLabel

    -- Row: Enable / Force Sell
    MakeDivider(win, -80)
    local enableBtn = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    enableBtn:SetPoint("TOPLEFT", 18, -92)
    enableBtn:SetWidth(140); enableBtn:SetHeight(26)
    enableBtn:SetText(EAL_DB.enabled and "Disable" or "Enable")
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
    MakeTooltipButton(enableBtn, "|cffff9900Enable / Disable|r", {
        "|cffaaaaaaStart or stop the auto loot+sell cycle.|r",
        "|cffaaaaaaWhen enabled, your loot companion is|r",
        "|cffaaaaaasummoned and bags are monitored.|r",
    })

    local sellNowBtn = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    sellNowBtn:SetPoint("TOPLEFT", 176, -92)
    sellNowBtn:SetWidth(146); sellNowBtn:SetHeight(26)
    sellNowBtn:SetText("Force Sell Now")
    sellNowBtn:SetScript("OnClick", function() StartSellCycle() end)
    MakeTooltipButton(sellNowBtn, "|cffff9900Force Sell Now|r", {
        "|cffaaaaaaSummon the vendor companion and begin|r",
        "|cffaaaaaaa sell cycle even if bags aren't full.|r",
    })

    -- Vendor button row
    MakeDivider(win, -126)
    local vendorHint = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    vendorHint:SetPoint("TOPLEFT", 18, -138)
    vendorHint:SetWidth(210)
    vendorHint:SetJustifyH("LEFT")
    vendorHint:SetText("|cffaaaaaaClick vendor button, then Interact key to sell|r")

    local function UpdateVendorToggleBtn(btn)
        if EAL_DB.vendorBtnShown then btn:SetText("Hide Vendor Btn")
        else                          btn:SetText("Show Vendor Btn") end
    end

    local vendorToggle = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    vendorToggle:SetPoint("TOPLEFT", 232, -134)
    vendorToggle:SetWidth(90); vendorToggle:SetHeight(22)
    UpdateVendorToggleBtn(vendorToggle)
    vendorToggle:SetScript("OnClick", function(self)
        EAL_DB.vendorBtnShown = not EAL_DB.vendorBtnShown
        if g_vendorBtn then
            if EAL_DB.vendorBtnShown then g_vendorBtn:Show() else g_vendorBtn:Hide() end
        end
        UpdateVendorToggleBtn(self)
    end)
    g_vendorBtnToggle = vendorToggle

    -- Companion names row
    MakeDivider(win, -162)
    MakeHeader(win, "COMPANION NAMES", 18, -172)

    -- Explicit dark panel behind the two input rows so the inputs' native
    -- dark bounding box stays readable regardless of the parchment gradient.
    local companionPanel = win:CreateTexture(nil, "ARTWORK")
    companionPanel:SetTexture("Interface\\Buttons\\WHITE8X8")
    companionPanel:SetVertexColor(0, 0, 0, 0.55)
    companionPanel:SetPoint("TOPLEFT",     win, "TOPLEFT",  14, -186)
    companionPanel:SetPoint("BOTTOMRIGHT", win, "TOPLEFT", 326, -236)

    -- Thin gold hairline border around the panel (WotLK inset look)
    local function PanelEdge(tlx, tly, brx, bry)
        local e = win:CreateTexture(nil, "ARTWORK", nil, 1)
        e:SetTexture("Interface\\Buttons\\WHITE8X8")
        e:SetVertexColor(0.55, 0.42, 0.18, 0.85)
        e:SetPoint("TOPLEFT",     win, "TOPLEFT", tlx, tly)
        e:SetPoint("BOTTOMRIGHT", win, "TOPLEFT", brx, bry)
        return e
    end
    PanelEdge( 14, -186, 326, -187)  -- top
    PanelEdge( 14, -235, 326, -236)  -- bottom
    PanelEdge( 14, -186,  15, -236)  -- left
    PanelEdge(325, -186, 326, -236)  -- right

    local lootLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lootLabel:SetPoint("TOPLEFT", 18, -190)
    lootLabel:SetText("Loot:")
    local lootInput = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
    lootInput:SetPoint("TOPLEFT", 72, -188)
    lootInput:SetWidth(250); lootInput:SetHeight(20)
    lootInput:SetAutoFocus(false)
    lootInput:SetMaxLetters(64)
    lootInput:SetText(EAL_DB.lootCompanion or "")
    lootInput:SetScript("OnEnterPressed", function(self)
        local txt = self:GetText():match("^%s*(.-)%s*$")
        if txt ~= "" then EAL_DB.lootCompanion = txt end
        self:ClearFocus()
        Print("Loot companion set to: |cffffff00" .. (EAL_DB.lootCompanion or "?") .. "|r")
    end)

    local vendLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    vendLabel:SetPoint("TOPLEFT", 18, -214)
    vendLabel:SetText("Vendor:")
    local vendInput = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
    vendInput:SetPoint("TOPLEFT", 72, -212)
    vendInput:SetWidth(250); vendInput:SetHeight(20)
    vendInput:SetAutoFocus(false)
    vendInput:SetMaxLetters(64)
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

    -- Quality toggles
    MakeDivider(win, -240)
    MakeHeader(win, "SELL QUALITY", 18, -250)

    local qualityDefs = {
        { Q_GREY,     "sellGrey",      18,  -270 },
        { Q_WHITE,    "sellWhite",    110,  -270 },
        { Q_UNCOMMON, "sellUncommon", 210,  -270 },
        { Q_RARE,     "sellRare",      18,  -294 },
        { Q_EPIC,     "sellEpic",     110,  -294 },
    }
    for _, def in ipairs(qualityDefs) do
        local qIdx, dbKey, cx, cy = def[1], def[2], def[3], def[4]
        local label = "|cff" .. QUALITY_HEX[qIdx] .. QUALITY_LABEL[qIdx] .. "|r"
        MakeCheckbox(win, label, cx, cy,
            function() return EAL_DB[dbKey] end,
            function(v) EAL_DB[dbKey] = v end)
    end

    -- Safety toggles row
    MakeDivider(win, -312)
    MakeHeader(win, "BEHAVIOR", 18, -322)

    MakeCheckbox(win, "|cffffaa00Sell at any vendor|r (not just summoned)", 18, -340,
        function() return EAL_DB.sellOnAnyVendor end,
        function(v) EAL_DB.sellOnAnyVendor = v end,
        {
            "|cffffd700Sell at any vendor|r",
            "|cffaaaaaaWhen OFF (default): only auto-sells when|r",
            "|cffaaaaaathe addon itself triggered the sell cycle.|r",
            "|cffaaaaaaWhen ON: auto-sells at any vendor you open|r",
            "|cffaaaaaa(repair vendors, quest vendors, etc).|r",
        })

    -- Auto-delete rares — opt-in via confirmation popup
    local autoDelCb = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
    autoDelCb:SetPoint("TOPLEFT", 18, -358)
    autoDelCb:SetWidth(24); autoDelCb:SetHeight(24)
    autoDelCb:SetChecked(EAL_DB.autoDeleteRares)
    local autoDelLbl = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    autoDelLbl:SetPoint("LEFT", autoDelCb, "RIGHT", 1, 0)
    autoDelLbl:SetText("|cffff4444Auto-delete unsellable rares|r")
    autoDelCb:SetScript("OnClick", function(self)
        if self:GetChecked() then
            self:SetChecked(false) -- require confirmation before actually enabling
            StaticPopup_Show("AUTOLOOT_CONFIRM_AUTODELETE_RARES")
        else
            EAL_DB.autoDeleteRares = false
            Print("Auto-delete unsellable rares: |cffaaaaaaDISABLED|r.")
        end
    end)
    autoDelCb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cffff4444Auto-delete unsellable rares|r")
        GameTooltip:AddLine("|cffff9900WARNING: silently deletes rare items|r")
        GameTooltip:AddLine("|cffff9900with no vendor price every few seconds.|r")
        GameTooltip:AddLine("|cffaaaaaaSome quest items and tokens have no|r")
        GameTooltip:AddLine("|cffaaaaaavendor price and will be destroyed.|r")
        GameTooltip:AddLine("|cffaaaaaaOFF by default. Use only if you know|r")
        GameTooltip:AddLine("|cffaaaaaawhat this does.|r")
        GameTooltip:Show()
    end)
    autoDelCb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    g_autoDelCb = autoDelCb

    MakeCheckbox(win, "Sound", 210, -358,
        function() return EAL_DB.soundEnabled end,
        function(v) EAL_DB.soundEnabled = v end,
        {
            "|cffffd700Sound|r",
            "|cffaaaaaaPlays sounds on sell completion and|r",
            "|cffaaaaaawhen the vendor companion is ready.|r",
        })

    -- Savage PvP deletion (confirmation required)
    MakeDivider(win, -382)
    local savageBtn = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    savageBtn:SetPoint("TOPLEFT", 18, -392)
    savageBtn:SetWidth(304); savageBtn:SetHeight(22)
    savageBtn:SetText("Delete All Savage PvP Gear from Bags")
    savageBtn:GetNormalFontObject():SetTextColor(1, 0.35, 0.35)
    savageBtn:SetScript("OnClick", function()
        StaticPopup_Show("AUTOLOOT_CONFIRM_DELETE_SAVAGE")
    end)
    MakeTooltipButton(savageBtn, "|cffff4444Delete Savage PvP Gear|r", {
        "|cffaaaaaaScans bags for every item whose name|r",
        "|cffaaaaaastarts with 'Savage ' and deletes them.|r",
        "|cffff9900Confirmation required. Irreversible.|r",
    })

    -- Whitelist section
    MakeDivider(win, -422)
    MakeHeader(win, "ITEM WHITELIST  |cffb9b9b9[A]|raccount  |cff87ceeb[C]|rchar", 18, -432)

    local inputBox = CreateFrame("EditBox", "EAL_BlacklistInput", win, "InputBoxTemplate")
    inputBox:SetPoint("TOPLEFT", 18, -454)
    inputBox:SetWidth(184); inputBox:SetHeight(20)
    inputBox:SetAutoFocus(false)
    inputBox:SetMaxLetters(64)

    local function AddBlacklistEntry(list)
        local text = inputBox:GetText():match("^%s*(.-)%s*$")
        if text == "" then return end
        for _, v in ipairs(list) do
            if v:lower() == text:lower() then
                inputBox:SetText("")
                return
            end
        end
        table.insert(list, text)
        inputBox:SetText("")
        EAL_RefreshBlacklist()
    end

    inputBox:SetScript("OnEnterPressed", function(self)
        AddBlacklistEntry(EAL_DB.blacklist)
        self:ClearFocus()
    end)

    local addAcctBtn = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    addAcctBtn:SetPoint("TOPLEFT", 208, -452)
    addAcctBtn:SetWidth(56); addAcctBtn:SetHeight(22)
    addAcctBtn:SetText("+Acct")
    addAcctBtn:SetScript("OnClick", function() AddBlacklistEntry(EAL_DB.blacklist) end)
    MakeTooltipButton(addAcctBtn, "|cffb9b9b9Add to Account Whitelist|r", {
        "|cffaaaaaaShared across all characters.|r",
    })

    local addCharBtn = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    addCharBtn:SetPoint("TOPLEFT", 266, -452)
    addCharBtn:SetWidth(56); addCharBtn:SetHeight(22)
    addCharBtn:SetText("+Char")
    addCharBtn:SetScript("OnClick", function() AddBlacklistEntry(EAL_CDB.blacklist) end)
    MakeTooltipButton(addCharBtn, "|cff87ceebAdd to Character Whitelist|r", {
        "|cffaaaaaaApplies only to this character.|r",
    })

    local tomeBtn = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    tomeBtn:SetPoint("TOPLEFT", 18, -478)
    tomeBtn:SetWidth(244); tomeBtn:SetHeight(22)
    tomeBtn:SetText('Whitelist all "Tome of Echo:" in bags')
    tomeBtn:SetScript("OnClick", EAL_WhitelistTomes)

    local resetBtn = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    resetBtn:SetPoint("TOPLEFT", 266, -478)
    resetBtn:SetWidth(56); resetBtn:SetHeight(22)
    resetBtn:SetText("Clear")
    resetBtn:GetNormalFontObject():SetTextColor(1, 0.4, 0.4)
    resetBtn:SetScript("OnClick", function()
        StaticPopup_Show("AUTOLOOT_CONFIRM_RESET_WHITELIST")
    end)
    MakeTooltipButton(resetBtn, "|cffff4444Clear Whitelist|r", {
        "|cffaaaaaaClears account + character whitelist.|r",
        "|cffff9900Confirmation required.|r",
    })

    -- Scrollable whitelist
    local TRACK_W = 8
    local listBg = CreateFrame("Frame", nil, win)
    listBg:SetPoint("TOPLEFT", 14, -506)
    listBg:SetWidth(312); listBg:SetHeight(MAX_ROWS * ROW_HEIGHT + 8)
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

    local rowW = 312 - 8 - TRACK_W
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
        lbl:SetWidth(rowW - 66)
        lbl:SetJustifyH("LEFT")
        lbl:SetWordWrap(false)

        local removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        removeBtn:SetPoint("RIGHT", -2, 0)
        removeBtn:SetWidth(54); removeBtn:SetHeight(18)
        removeBtn:SetText("Remove")
        removeBtn:GetNormalFontObject():SetTextColor(1, 0.4, 0.4)

        row.label     = lbl
        row.removeBtn = removeBtn
        row:Hide()
        g_blacklistRows[i] = row
    end

    local trackH = MAX_ROWS * ROW_HEIGHT
    local track = CreateFrame("Frame", nil, listBg)
    track:SetWidth(TRACK_W); track:SetHeight(trackH)
    track:SetPoint("TOPRIGHT", -4, -4)
    local trackTex = track:CreateTexture(nil, "BACKGROUND")
    trackTex:SetAllPoints()
    trackTex:SetTexture(0.08, 0.08, 0.08, 0.9)
    local thumb = track:CreateTexture(nil, "ARTWORK")
    thumb:SetWidth(TRACK_W - 2)
    thumb:SetPoint("TOP", track, "TOP", 0, 0)
    thumb:SetTexture(0.55, 0.45, 0.25, 0.9)
    thumb:Hide()
    g_scrollThumb = thumb

    -- Bottom hint
    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOM", 0, 14)
    hint:SetText("|cffaaaaaa/eal toggle | sell | reset   -   minimap button, right-click to enable|r")

    EAL_UpdateStatus()
    EAL_RefreshBlacklist()

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
        "  /eal  or  /autoloot  - open settings\n" ..
        "  /eal toggle          - enable/disable\n" ..
        "  /eal sell            - force a sell cycle now\n" ..
        "  /eal reset           - clear whitelist (confirmation)\n" ..
        "\n" ..
        "|cffffd700Keybindings:|r bind in Escape -> Key Bindings -> AutoLoot."
    )

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
end

local eventFrame = CreateFrame("Frame", "EAL_EventFrame", UIParent)
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:RegisterEvent("BAG_UPDATE")

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
        Print("v" .. ADDON_VERSION .. " loaded.  |cffffff00/eal|r to open, or click the minimap button.")

    elseif event == "MERCHANT_SHOW" then
        OnMerchantShow()

    elseif event == "MERCHANT_CLOSED" then
        OnMerchantClosed()

    elseif event == "BAG_UPDATE" then
        bagUpdateDirty = true
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
    elseif cmd == "minimap" then
        EAL_DB.showMinimapButton = not EAL_DB.showMinimapButton
        UpdateMinimapButton()
        Print("Minimap button: " .. (EAL_DB.showMinimapButton and "|cff44ff44shown|r" or "|cffaaaaaahidden|r"))
    elseif cmd == "help" or cmd == "?" then
        Print("Commands: toggle | enable | disable | sell | reset | minimap | help")
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

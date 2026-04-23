-------------------------------------------------------------------------------
-- AutoLoot  v3.1
--
-- Automatically loots using the Greedy Scavenger companion pet, then switches
-- to the Goblin Merchant companion to sell unwanted items when bags are full.
--
-- Selling requires the player to interact with the Goblin Merchant NPC once
-- it is summoned.  InteractUnit is Blizzard-UI-only and cannot be called from
-- any addon script or macro — there is no client-side workaround.  The fully
-- automatic solution requires a server-side change: configure the Goblin
-- Merchant companion to send the merchant list to the client on summon
-- (firing MERCHANT_SHOW automatically), which many custom servers support.
-- Auto-sell fires the instant MERCHANT_SHOW fires regardless of how it opened.
--
-- GUI Features:
--   - Enable / Disable the full loot+sell cycle
--   - Per-quality sell toggles: Grey / White / Uncommon / Rare / Epic
--   - Item whitelist: named items are never sold regardless of quality
--   - Live status display with free-slot counter
--
-- Slash commands:  /eal   /autoloot
-------------------------------------------------------------------------------

local ADDON_NAME      = "AutoLoot"
local LOOT_PET_NAME   = "Greedy Scavenger"
local VENDOR_PET_NAME = "Goblin Merchant"

-- Item quality constants (matches GetItemInfo quality return)
local Q_GREY     = 0
local Q_WHITE    = 1
local Q_UNCOMMON = 2
local Q_RARE     = 3
local Q_EPIC     = 4

local QUALITY_LABEL = { [0]="Grey", [1]="White", [2]="Uncommon", [3]="Rare", [4]="Epic" }
local QUALITY_HEX   = { [0]="9d9d9d", [1]="ffffff", [2]="1eff00", [3]="0070dd", [4]="a335ee" }

-- State machine values
local S_IDLE    = "IDLE"
local S_LOOTING = "LOOTING"
local S_SELLING = "SELLING"

-- Companion stuck detection
local MAX_COMPANION_DISTANCE = 5   -- yards; resummon if pet exceeds this from player

-- Per-pulse sell cap: avoids flooding the server with too many UseContainerItem
-- calls in a single MERCHANT_SHOW callback, which can cause low-end clients to
-- disconnect. If more items remain after the cap is hit, additional batches
-- are sold automatically after a short delay while MerchantFrame stays open;
-- if it closes first, the sell cycle still finishes cleanly.
local MAX_SELL_PER_PULSE = 45

-- Fast Mode multipliers: doubles items per batch, halves the batch delay.
local FAST_MODE_BATCH_MULTIPLIER = 2
local FAST_MODE_DELAY_DIVISOR    = 2

-- SavedVariables schema / defaults
local DEFAULTS = {
    enabled       = false,
    sellGrey      = true,
    sellWhite     = false,
    sellUncommon  = false,
    sellRare      = false,
    sellEpic      = false,
    fastMode      = false,
    blacklist     = {},
    checkInterval  = 3,     -- seconds between free-slot checks while looting
    windowX        = 100,
    windowY        = -200,
    vendorBtnX     = 100,   -- on-screen vendor button position (TOPLEFT from UIParent)
    vendorBtnY     = -400,
    vendorBtnShown = true,
}

-------------------------------------------------------------------------------
-- Runtime state
-------------------------------------------------------------------------------
local EAL_DB             -- assigned from SavedVariables on ADDON_LOADED
local currentState       = S_IDLE
local bagCheckTimer      = 0
local waitingForMerchant = false
local wasMounted         = false  -- previous-frame mount state for change detection

-- GUI handles populated by EAL_BuildGUI
local g_statusLabel
local g_enableBtn
local g_vendorBtn                 -- on-screen SecureActionButton (UIParent child)
local g_vendorBtnToggle           -- GUI button that shows/hides g_vendorBtn
local g_blacklistRows   = {}
local g_blacklistOffset = 0   -- hand-rolled scroll offset (no FauxScrollFrame)
local g_scrollThumb               -- visual-only scrollbar thumb
local ROW_HEIGHT        = 22
local MAX_ROWS          = 8

-------------------------------------------------------------------------------
-- 1. TIMER HELPER  (C_Timer does not exist in 3.3.5a)
-------------------------------------------------------------------------------
local pendingTimers = {}

local timerFrame = CreateFrame("Frame")
timerFrame:SetScript("OnUpdate", function(self, elapsed)
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
-- 2. UTILITY
-------------------------------------------------------------------------------

local function Print(msg, r, g, b)
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cffff9900[AutoLoot]|r " .. tostring(msg), r or 1, g or 0.8, b or 0)
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
    for _, entry in ipairs(EAL_DB.blacklist) do
        if entry:lower() == lower then return true end
    end
    return false
end

local TOME_PREFIX       = "Tome of Echo:"
local TOME_PREFIX_LOWER = TOME_PREFIX:lower()

local SAVAGE_PREFIX_LOWER = "savage "

-- Scans all bags, collects every item whose name starts with "Savage ",
-- then deletes them one at a time with a small async delay so the
-- StaticPopup confirmation dialog (shown for Uncommon+ items) can be
-- auto-confirmed between each deletion.
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
                -- Give the confirmation popup a frame to appear, then click OK
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
        -- Slot already empty or item changed — skip to next
        DeleteNext(idx + 1)
    end

    DeleteNext(1)
end

-- Scans all bag slots and adds every item whose name starts with
-- "Tome of Echo:" to the blacklist (if not already present).
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
        EAL_RefreshBlacklist()
        Print("|cffffff00" .. added .. "|r Tome of Echo item(s) whitelisted.")
    else
        Print("No new Tome of Echo items found in bags (already whitelisted or not in bags).")
    end
end

-- Returns companion index (1-based) and whether it is currently summoned.
-- Comparison is case-insensitive so "Greedy scavenger" matches "Greedy Scavenger".
local function FindCompanion(name)
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
        Print("Companion '" .. name .. "' not found in your companion list.", 1, 0.3, 0.3)
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

-- Returns true when the player should not be disturbed by a resummon
-- (airborne or on a ground/flying mount).  Both functions are guarded in
-- case a particular emulator build doesn't expose them.
local function IsPlayerMountedOrFlying()
    if IsFlying  and IsFlying()  then return true end
    if IsMounted and IsMounted() then return true end
    return false
end

-- Returns the 2-D distance in yards between the player and the summoned
-- companion critter.  Companion critters occupy the "pet" unit token when
-- the player has no active combat pet.  Returns nil if either position is
-- unavailable (unit doesn't exist, UnitPosition not supported, etc.).
local function GetCompanionDistance()
    local px, py = UnitPosition("player")
    local cx, cy = UnitPosition("pet")
    if not px or not cx then return nil end
    local dx, dy = px - cx, py - cy
    return math.sqrt(dx * dx + dy * dy)
end

-------------------------------------------------------------------------------
-- 3. STATUS / GUI REFRESH
-------------------------------------------------------------------------------
local function EAL_UpdateStatus()
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
end

local function EAL_RefreshBlacklist()
    if not EAL_DB then return end
    local total = #EAL_DB.blacklist
    -- clamp offset so it never points past the list
    g_blacklistOffset = math.max(0, math.min(g_blacklistOffset,
                                              math.max(0, total - MAX_ROWS)))

    for i = 1, MAX_ROWS do
        local row = g_blacklistRows[i]
        if row then
            local idx = g_blacklistOffset + i
            if idx <= total then
                row.label:SetText(EAL_DB.blacklist[idx])
                local capturedIdx = idx
                row.removeBtn:SetScript("OnClick", function()
                    table.remove(EAL_DB.blacklist, capturedIdx)
                    EAL_RefreshBlacklist()
                end)
                row:Show()
            else
                row:Hide()
            end
        end
    end

    -- reposition the visual scrollbar thumb
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
-- 4. SELLING LOGIC
-------------------------------------------------------------------------------
-- totalSold / totalSkipped accumulate across batches within a single vendor session.
local SELL_BATCH_DELAY = 1.0

local function FinishSelling(totalSold, totalSkipped)
    if totalSold > 0 or totalSkipped > 0 then
        Print("Sold |cffffff00" .. totalSold ..
              "|r item(s). Whitelisted (kept): |cffffff00" .. totalSkipped .. "|r.")
    else
        Print("Nothing to sell with current quality settings.")
    end
    EAL_UpdateStatus()
end

local function SellItems(totalSold, totalSkipped)
    totalSold    = totalSold    or 0
    totalSkipped = totalSkipped or 0
    local sold   = 0
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
                        sell    = false
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

    -- If we hit the cap and the vendor window is still open, wait
    -- BATCH_DELAY seconds, then sell the next batch. Sold items are gone
    -- from the bags so re-scanning from bag 0 naturally picks up the remainder.
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
-- 5. STATE MACHINE
-------------------------------------------------------------------------------
local function SetState(state)
    currentState = state
    EAL_UpdateStatus()
end

local function StartLootCycle()
    if not EAL_DB or not EAL_DB.enabled then return end
    SetState(S_LOOTING)
    bagCheckTimer = 0
    Print("Loot cycle started. Summoning " .. LOOT_PET_NAME .. "...")
    SummonPet(LOOT_PET_NAME)
end

local function StartSellCycle()
    if currentState == S_SELLING then return end
    SetState(S_SELLING)
    Print("Bags full — summoning " .. VENDOR_PET_NAME .. "...")
    DismissPet()

    After(1.5, function()
        local ok = SummonPet(VENDOR_PET_NAME)
        if ok then
            waitingForMerchant = true
            -- If in combat, prompt the player to click the secure button / macro
            if InCombatLockdown() then
                Print("|cffffd700In combat:|r click |cffffff00Target Vendor|r to select the merchant," ..
                      " then |cffffd700right-click its model|r or press your" ..
                      " |cffffff00Interact with Target|r keybind to open the vendor.")
            end
            -- Remind after 8 seconds if window still hasn't opened
            After(8, function()
                if waitingForMerchant and currentState == S_SELLING then
                    Print("|cffffd700Reminder:|r target " .. VENDOR_PET_NAME ..
                          " then right-click it or press Interact with Target.", 1, 1, 0)
                end
            end)
        end
    end)
end

-- Called when any merchant window opens
local function OnMerchantShow()
    waitingForMerchant = false
    if currentState == S_SELLING or EAL_DB.enabled then
        After(0.3, function()
            -- Repair before selling so durability is restored even if the
            -- sell step errors or finds nothing to sell.
            if CanMerchantRepair() then
                RepairAllItems()
                Print("All items repaired.")
            end
            SellItems()
        end)
    end
end

-- Called when merchant window closes
local function OnMerchantClosed()
    if currentState == S_SELLING then
        local free = GetTotalFreeSlots()
        if EAL_DB.enabled and free > 0 then
            After(1, StartLootCycle)
        else
            SetState(S_IDLE)
        end
    end
end

-- Dismisses and re-summons the Greedy Scavenger if it has drifted more than
-- MAX_COMPANION_DISTANCE yards from the player.  Skipped when the player is
-- mounted or flying so the pet isn't needlessly bounced during travel.
local function CheckCompanionStuck()
    if IsPlayerMountedOrFlying() then return end

    local dist = GetCompanionDistance()
    if dist == nil then return end   -- position data not available; skip silently

    if dist > MAX_COMPANION_DISTANCE then
        Print("Greedy Scavenger is stuck (" .. math.floor(dist) ..
              " yds away) — resummoning...", 1, 0.75, 0.2)
        DismissPet()
        After(0.5, function()
            SummonPet(LOOT_PET_NAME)
        end)
    end
end

-- Scans all bags for Rare-quality items that have no vendor sell price and are
-- not on the whitelist, then deletes them one at a time using the same async
-- popup-confirm pattern as EAL_DeleteSavageGear.
-- g_deletingRares prevents re-entrant calls from the bag-check timer.
local g_deletingRares = false

local function EAL_DeleteUnsellableRares()
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
        -- Slot empty or item changed — skip
        DeleteNext(idx + 1)
    end

    DeleteNext(1)
end

-- Per-frame bag check + mount detection
local function OnUpdate(self, elapsed)
    if not EAL_DB then return end

    -- ── Mount state change detection ────────────────────────────────────────
    local nowMounted = IsPlayerMountedOrFlying()
    if nowMounted ~= wasMounted then
        wasMounted = nowMounted

        if nowMounted then
            -- Just mounted: dismiss whichever companion is currently out
            DismissPet()
            if currentState ~= S_IDLE then
                Print("Mounted — companion dismissed.")
            end
        else
            -- Just dismounted: re-summon the correct companion after a short
            -- delay (engine needs a moment before CallCompanion is accepted)
            if EAL_DB.enabled then
                if currentState == S_LOOTING then
                    Print("Dismounted — re-summoning " .. LOOT_PET_NAME .. "...")
                    After(1.5, function() SummonPet(LOOT_PET_NAME) end)
                elseif currentState == S_SELLING then
                    Print("Dismounted — re-summoning " .. VENDOR_PET_NAME .. "...")
                    waitingForMerchant = true
                    After(1.5, function() SummonPet(VENDOR_PET_NAME) end)
                end
            end
        end
    end

    -- ── Bag check + companion stuck detection ───────────────────────────────
    if EAL_DB.enabled and currentState == S_LOOTING and not nowMounted then
        bagCheckTimer = bagCheckTimer + elapsed
        if bagCheckTimer >= (EAL_DB.checkInterval or 3) then
            bagCheckTimer = 0
            EAL_UpdateStatus()
            -- Delete unsellable rares on every tick, regardless of bag state
            EAL_DeleteUnsellableRares()
            if GetTotalFreeSlots() == 0 then
                StartSellCycle()
            else
                -- Only run stuck check when we're not already switching to sell;
                -- avoids a dismiss colliding with the sell-cycle dismiss.
                CheckCompanionStuck()
            end
        end
    end

end

-------------------------------------------------------------------------------
-- 6. ON-SCREEN VENDOR BUTTON
-------------------------------------------------------------------------------
-- A SecureActionButtonTemplate button parented directly to UIParent.
-- Its attribute is set once at creation (outside combat) so it remains
-- functional even when InCombatLockdown() is true.
-- Clicking it runs:  /target Goblin Merchant
-- The player then presses their Interact with Target keybind to open the
-- vendor window — MERCHANT_SHOW fires and the addon handles the rest.
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

    -- Attribute locked in at creation — valid during combat lockdown
    btn:SetAttribute("type", "macro")
    btn:SetAttribute("macrotext", "/target " .. VENDOR_PET_NAME)

    -- Icon
    local tex = btn:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")

    -- Gold border overlay
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    border:SetBlendMode("ADD")
    border:SetWidth(66); border:SetHeight(66)
    border:SetPoint("CENTER")
    border:SetVertexColor(1, 0.75, 0.1, 0.85)

    -- Label above the button
    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("BOTTOM", btn, "TOP", 0, 2)
    lbl:SetText("|cffff9900Vendor|r")

    -- Alt+drag to reposition; save new position to SavedVariables
    btn:SetScript("OnMouseDown", function(self, button)
        if IsAltKeyDown() then self:StartMoving() end
    end)
    btn:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        EAL_DB.vendorBtnX = self:GetLeft()
        EAL_DB.vendorBtnY = self:GetTop() - UIParent:GetHeight()
    end)

    -- Tooltip
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("|cffff9900Target Goblin Merchant|r")
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
-- 7. GUI
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

local function MakeCheckbox(parent, labelText, x, y, getValue, setValue)
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
    return cb
end

local function EAL_BuildGUI()
    -- ----------------------------------------------------------------
    -- Main window  (550 tall to accommodate the extra vendor row)
    -- ----------------------------------------------------------------
    local win = CreateFrame("Frame", "EAL_Window", UIParent)
    win:SetWidth(340); win:SetHeight(550)
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
    win:Hide()

    -- Title bar
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("AutoLoot |cffaaaaaa& Sell|r")

    local closeBtn = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() win:Hide() end)

    -- ----------------------------------------------------------------
    -- Status row  (status text left, Fast Mode checkbox right)
    -- ----------------------------------------------------------------
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

    -- ----------------------------------------------------------------
    -- Row 1: Enable / Disable  +  Force Sell
    -- ----------------------------------------------------------------
    MakeDivider(win, -66)

    local enableBtn = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    enableBtn:SetPoint("TOPLEFT", 18, -80)
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

    local sellNowBtn = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    sellNowBtn:SetPoint("TOPLEFT", 176, -80)
    sellNowBtn:SetWidth(146); sellNowBtn:SetHeight(26)
    sellNowBtn:SetText("Force Sell Now")
    sellNowBtn:SetScript("OnClick", function() StartSellCycle() end)

    -- ----------------------------------------------------------------
    -- Vendor button row
    -- ----------------------------------------------------------------
    MakeDivider(win, -114)

    local vendorHint = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    vendorHint:SetPoint("TOPLEFT", 18, -126)
    vendorHint:SetWidth(210)
    vendorHint:SetJustifyH("LEFT")
    vendorHint:SetText("|cffaaaaaaClick vendor button, then Interact key to sell|r")

    local function UpdateVendorToggleBtn(btn)
        if EAL_DB.vendorBtnShown then
            btn:SetText("Hide Vendor Btn")
        else
            btn:SetText("Show Vendor Btn")
        end
    end

    local vendorToggle = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    vendorToggle:SetPoint("TOPLEFT", 232, -122)
    vendorToggle:SetWidth(90); vendorToggle:SetHeight(22)
    UpdateVendorToggleBtn(vendorToggle)
    vendorToggle:SetScript("OnClick", function(self)
        EAL_DB.vendorBtnShown = not EAL_DB.vendorBtnShown
        if g_vendorBtn then
            if EAL_DB.vendorBtnShown then
                g_vendorBtn:Show()
            else
                g_vendorBtn:Hide()
            end
        end
        UpdateVendorToggleBtn(self)
    end)
    g_vendorBtnToggle = vendorToggle

    -- ----------------------------------------------------------------
    -- Quality sell toggles
    -- ----------------------------------------------------------------
    MakeDivider(win, -150)
    MakeHeader(win, "SELL QUALITY", 18, -160)

    local qualityDefs = {
        { Q_GREY,     "sellGrey",      18,  -180 },
        { Q_WHITE,    "sellWhite",    110,  -180 },
        { Q_UNCOMMON, "sellUncommon", 210,  -180 },
        { Q_RARE,     "sellRare",      18,  -204 },
        { Q_EPIC,     "sellEpic",     110,  -204 },
    }

    for _, def in ipairs(qualityDefs) do
        local qIdx, dbKey, cx, cy = def[1], def[2], def[3], def[4]
        local label = "|cff" .. QUALITY_HEX[qIdx] .. QUALITY_LABEL[qIdx] .. "|r"
        MakeCheckbox(win, label, cx, cy,
            function() return EAL_DB[dbKey] end,
            function(v) EAL_DB[dbKey] = v end)
    end

    -- ----------------------------------------------------------------
    -- Savage PvP gear deletion
    -- ----------------------------------------------------------------
    MakeDivider(win, -222)

    local savageBtn = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    savageBtn:SetPoint("TOPLEFT", 18, -232)
    savageBtn:SetWidth(304); savageBtn:SetHeight(22)
    savageBtn:SetText("Delete All Savage PvP Gear from Bags")
    savageBtn:GetNormalFontObject():SetTextColor(1, 0.35, 0.35)
    savageBtn:SetScript("OnClick", EAL_DeleteSavageGear)

    -- ----------------------------------------------------------------
    -- Whitelist section
    -- ----------------------------------------------------------------
    MakeDivider(win, -262)
    MakeHeader(win, "ITEM WHITELIST  (these items are never sold)", 18, -272)

    local inputBox = CreateFrame("EditBox", "EAL_BlacklistInput", win, "InputBoxTemplate")
    inputBox:SetPoint("TOPLEFT", 18, -294)
    inputBox:SetWidth(224); inputBox:SetHeight(20)
    inputBox:SetAutoFocus(false)
    inputBox:SetMaxLetters(64)

    local function AddBlacklistEntry()
        local text = inputBox:GetText():match("^%s*(.-)%s*$")
        if text == "" then return end
        for _, v in ipairs(EAL_DB.blacklist) do
            if v:lower() == text:lower() then
                inputBox:SetText("")
                return
            end
        end
        table.insert(EAL_DB.blacklist, text)
        inputBox:SetText("")
        EAL_RefreshBlacklist()
    end

    inputBox:SetScript("OnEnterPressed", function(self)
        AddBlacklistEntry()
        self:ClearFocus()
    end)

    local addBtn = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    addBtn:SetPoint("TOPLEFT", 250, -292)
    addBtn:SetWidth(72); addBtn:SetHeight(22)
    addBtn:SetText("Add")
    addBtn:SetScript("OnClick", AddBlacklistEntry)

    local tomeBtn = CreateFrame("Button", nil, win, "GameMenuButtonTemplate")
    tomeBtn:SetPoint("TOPLEFT", 18, -318)
    tomeBtn:SetWidth(304); tomeBtn:SetHeight(22)
    tomeBtn:SetText('Whitelist all "Tome of Echo:" in bags')
    tomeBtn:SetScript("OnClick", EAL_WhitelistTomes)

    -- ----------------------------------------------------------------
    -- Scrollable blacklist  (hand-rolled, mouse-wheel scroll)
    -- ----------------------------------------------------------------
    local TRACK_W = 8   -- width of the slim scrollbar track on the right
    local listBg = CreateFrame("Frame", nil, win)
    listBg:SetPoint("TOPLEFT", 14, -346)
    listBg:SetWidth(312); listBg:SetHeight(MAX_ROWS * ROW_HEIGHT + 8)
    listBg:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    listBg:SetBackdropColor(0, 0, 0, 0.85)

    -- Mouse wheel scrolls the list
    listBg:EnableMouseWheel(true)
    listBg:SetScript("OnMouseWheel", function(self, delta)
        g_blacklistOffset = g_blacklistOffset - delta
        EAL_RefreshBlacklist()
    end)

    -- Row width: full inner width minus the scrollbar track
    local rowW = 312 - 8 - TRACK_W   -- 296px

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, listBg)
        row:SetWidth(rowW); row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * ROW_HEIGHT)

        local rowBg = row:CreateTexture(nil, "BACKGROUND")
        rowBg:SetAllPoints()
        if i % 2 == 0 then
            rowBg:SetTexture(0.12, 0.12, 0.12, 0.6)
        else
            rowBg:SetTexture(0.06, 0.06, 0.06, 0.6)
        end

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

    -- Slim scrollbar: dark track + lighter thumb (visual only, no buttons)
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

    -- ----------------------------------------------------------------
    -- Bottom hint
    -- ----------------------------------------------------------------
    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("BOTTOM", 0, 14)
    hint:SetText("|cffaaaaaa/eal — toggle window  |  /eal enable / disable / reset|r")

    EAL_UpdateStatus()
    EAL_RefreshBlacklist()

    return win
end

-------------------------------------------------------------------------------
-- 8. EVENT FRAME
-------------------------------------------------------------------------------
local gui

local eventFrame = CreateFrame("Frame", "EAL_EventFrame", UIParent)
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_CLOSED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            EAL_SavedDB = EAL_SavedDB or {}
            EAL_DB = EAL_SavedDB
            for k, v in pairs(DEFAULTS) do
                if EAL_DB[k] == nil then
                    EAL_DB[k] = (type(v) == "table") and {} or v
                end
            end
        end

    elseif event == "PLAYER_LOGIN" then
        if not EAL_DB then
            EAL_SavedDB = EAL_SavedDB or {}
            EAL_DB = EAL_SavedDB
            for k, v in pairs(DEFAULTS) do
                if EAL_DB[k] == nil then
                    EAL_DB[k] = (type(v) == "table") and {} or v
                end
            end
        end
        gui       = EAL_BuildGUI()
        g_vendorBtn = EAL_BuildVendorButton()
        Print("v3.1 loaded.  |cffffff00/eal|r to open settings.")

    elseif event == "MERCHANT_SHOW" then
        OnMerchantShow()

    elseif event == "MERCHANT_CLOSED" then
        OnMerchantClosed()
    end
end)

eventFrame:SetScript("OnUpdate", OnUpdate)

-------------------------------------------------------------------------------
-- 9. SLASH COMMANDS
-------------------------------------------------------------------------------
SLASH_EBAUTOLOOT1 = "/eal"
SLASH_EBAUTOLOOT2 = "/autoloot"

SlashCmdList["EBAUTOLOOT"] = function(msg)
    if not gui then
        Print("GUI not ready yet.", 1, 0.5, 0.5)
        return
    end

    local cmd = msg and msg:lower():match("^%s*(%S*)") or ""

    if cmd == "reset" then
        EAL_DB.blacklist = {}
        EAL_RefreshBlacklist()
        Print("Whitelist cleared.")
    elseif cmd == "enable" then
        EAL_DB.enabled = true
        StartLootCycle()
        EAL_UpdateStatus()
    elseif cmd == "disable" then
        EAL_DB.enabled = false
        DismissPet()
        SetState(S_IDLE)
    else
        if gui:IsShown() then
            gui:Hide()
        else
            EAL_UpdateStatus()
            EAL_RefreshBlacklist()
            gui:Show()
        end
    end
end

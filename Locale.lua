-------------------------------------------------------------------------------
-- AutoLoot localisation framework.
--
-- Pattern:
--   local L = AutoLoot_L
--   chatPrint(L["Loot cycle started"])
--
-- L is a table with a __index metatable that falls back to the key itself
-- when no translation exists.  This means an unrecognised locale (or an
-- untranslated string) just shows the original English text, never an error
-- or a missing-key marker.
--
-- To translate, set keys on AutoLoot_L from inside a Locale-XX.lua file:
--   if GetLocale() ~= "deDE" then return end
--   local L = AutoLoot_L
--   L["Enable"] = "Aktivieren"
--   L["Disable"] = "Deaktivieren"
--   ...
--
-- The enUS defaults below double as the canonical key list and as the
-- enUS translation (since key == value).  When adding new strings to the
-- addon, add the enUS entry here so other locale files have a key to
-- override.
-------------------------------------------------------------------------------

AutoLoot_L = setmetatable({}, { __index = function(t, k) return k end })
local L = AutoLoot_L

-- Window / tabs
L["AutoLoot"]              = "AutoLoot"
L["AutoLoot & Sell"]       = "AutoLoot & Sell"
L["General"]               = "General"
L["Sell"]                  = "Sell"
L["Actions"]               = "Actions"
L["Whitelist"]             = "Whitelist"
L["About"]                 = "About"
L["Bank"]                  = "Bank"
L["BANK SETTINGS"]         = "BANK SETTINGS"
L["STASH LIST"]            = "STASH LIST"
L["GUILD BANK"]            = "GUILD BANK"
L["PERSONAL BANK"]         = "PERSONAL BANK"
L["Mail"]                  = "Mail"
L["MAIL SETTINGS"]         = "MAIL SETTINGS"

-- Status / labels
L["by"]                    = "by"
L["Status"]                = "Status"
L["Free Slots"]            = "Free Slots"
L["Lifetime"]              = "Lifetime"
L["IDLE"]                  = "IDLE"
L["LOOTING"]               = "LOOTING"
L["SELLING"]               = "SELLING"
L["Enabled"]               = "Enabled"
L["Disabled"]              = "Disabled"

-- Buttons
L["Enable"]                = "Enable"
L["Disable"]               = "Disable"
L["Force Sell Now"]        = "Force Sell Now"
L["Hide Vendor Btn"]       = "Hide Vendor Btn"
L["Show Vendor Btn"]       = "Show Vendor Btn"
L["Fast Mode"]             = "Fast Mode"
L["Sound"]                 = "Sound"
L["Cancel"]                = "Cancel"
L["Sell"]                  = "Sell"
L["Delete"]                = "Delete"
L["Clear"]                 = "Clear"
L["Remove"]                = "Remove"

-- Headers
L["COMPANION NAMES"]       = "COMPANION NAMES"
L["SELL QUALITY"]          = "SELL QUALITY"
L["BEHAVIOR"]              = "BEHAVIOR"
L["QUICK ACTIONS"]         = "QUICK ACTIONS"
L["ITEM WHITELIST"]        = "ITEM WHITELIST"

-- Quality labels
L["Grey"]                  = "Grey"
L["White"]                 = "White"
L["Common"]                = "Common"
L["Uncommon"]              = "Uncommon"
L["Rare"]                  = "Rare"
L["Epic"]                  = "Epic"

-- Field labels
L["Loot:"]                 = "Loot:"
L["Vendor:"]               = "Vendor:"

-- Behavior toggles
L["Sell at any vendor (not just summoned)"] = "Sell at any vendor (not just summoned)"
L["Auto-delete unsellable"] = "Auto-delete unsellable"

-- Action buttons
L["Sell gear at iLvl %d or below"] = "Sell gear at iLvl %d or below"
L["Whitelist all 'Tome of Echo:' in bags"] = "Whitelist all 'Tome of Echo:' in bags"

-- Chat messages
L["v%s by %s loaded.  %s to open, or click the minimap button."] =
    "v%s by %s loaded.  %s to open, or click the minimap button."
L["Whitelist cleared."]    = "Whitelist cleared."
L["Loot cycle started. Summoning %s..."] = "Loot cycle started. Summoning %s..."
L["Bags full - summoning %s..."] = "Bags full - summoning %s..."
L["All items repaired."]   = "All items repaired."
L["GUI not ready yet."]    = "GUI not ready yet."
L["Commands: toggle | enable | disable | sell | ilvlsell | reset | minimap | help"] =
    "Commands: toggle | enable | disable | sell | ilvlsell | reset | minimap | help"

-- Tooltips
L["Left-click"]            = "Left-click"
L["Right-click"]           = "Right-click"
L["Drag to reposition"]    = "Drag to reposition"
L["Alt+Drag to reposition"] = "Alt+Drag to reposition"
L["Lifetime earned: %s"]   = "Lifetime earned: %s"
L["to open settings"]      = "to open settings"
L["to toggle enable/disable"] = "to toggle enable/disable"

-- About tab
L["Created by"]            = "Created by"
L["Slash commands"]        = "Slash commands"
L["Keybindings"]           = "Keybindings"
L["License"]               = "License"
L["Source-available. Attribution required. See LICENSE for full terms."] =
    "Source-available. Attribution required. See LICENSE for full terms."

return L

# AutoLoot

A WoW 3.3.5a addon that automates the **loot → repair → sell** cycle using two summonable companion pets. Originally built for **Project Ebonhold**, now portable to any 3.3.5a server.

Open with `/eal`, `/autoloot`, or the minimap button.

![AutoLoot preserves quest items, tokens, and your sanity.](https://img.shields.io/badge/WoW-3.3.5a-blue) ![Interface 30300](https://img.shields.io/badge/Interface-30300-green)

---

## Features

### Core loop
- **Auto-loot cycle** — Summons your configured *loot companion* and watches bags. When every slot fills, dismisses it and summons your *vendor companion*.
- **Auto-repair + auto-sell** — The moment any merchant window opens (that the addon triggered), `RepairAllItems()` fires, then qualifying items are sold in batches of **45 per pulse** with a **1.0s pause** between batches. A single summary prints when done.
- **Fast Mode** — Doubles batch size (→ 90) and halves the delay (→ 0.5s) for higher-end hardware. Tooltip warns of possible disconnects on low-end clients.
- **Per-quality sell toggles** — Grey (default on), White, Uncommon, Rare, Epic.
- **Mount-aware** — Dismisses the active companion when you mount; re-summons the correct one 1.5s after dismount.
- **Companion stuck detection** — Re-summons your loot companion if it drifts more than 5 yards away (skipped while mounted).

### Safety & trust
- **No auto-sell at random vendors** — By default, AutoLoot only sells when it actively triggered the cycle. Repair vendors and quest NPCs are *not* touched. There's a separate `Sell at any vendor` toggle if you want the old aggressive behavior.
- **Auto-delete unsellable rares is opt-in** — The "delete rares with no vendor price" behavior is OFF by default and requires an explicit confirmation dialog to enable. (Quest items and some tokens have no vendor price.)
- **Confirmation popups** on every destructive action — `Delete Savage PvP Gear`, `Clear Whitelist`, and `/eal reset` all prompt before executing.

### Customization
- **Configurable companion names** — Loot and vendor companion names are editable fields. Defaults to `Greedy Scavenger` / `Goblin Merchant` (Ebonhold). Works with any companion pets your server provides.
- **Two-scope whitelist** — Account-wide (`[A]`) + per-character (`[C]`), union-merged at sell time. Prefix `+Acct` / `+Char` buttons control scope.
- **One-click "Whitelist Tome of Echo"** — Scans bags and protects every item whose name starts with `Tome of Echo:`. (Ebonhold-specific; harmless elsewhere.)
- **Draggable on-screen Vendor button** — Alt-drag to reposition. Works during combat (SecureActionButton).
- **Draggable minimap button** — Left-click: open settings. Right-click: toggle enable/disable. Status dot goes green when active.
- **Keybindings** (bind in Esc → Key Bindings → AutoLoot): Toggle Window, Toggle Enable/Disable, Force Sell Now.
- **Blizzard Interface Options integration** — AutoLoot appears under `Esc → Interface → AddOns`.
- **Gold-earned tracker** — Per-session delta and lifetime total, displayed in the GUI and minimap tooltip.
- **Sound feedback** — Sell completion and "vendor ready" reminder. Toggleable.
- **All settings persist** via `SavedVariables` (account-wide) and `SavedVariablesPerCharacter`.

---

## Installation

1. **[Download the latest release](https://github.com/Veronica-Vasilieva/AutoLoot/releases)** (zip) or clone this repository.
2. Extract / copy the `AutoLoot` folder into:
   ```
   World of Warcraft/Interface/AddOns/
   ```
   The folder must be named `AutoLoot` exactly.
3. Launch WoW and enable the addon from the AddOns menu on the character-select screen.

### Server setup

AutoLoot needs two summonable companion pets:

| Role | Default name | Purpose |
|---|---|---|
| Loot | `Greedy Scavenger` | Auto-loots nearby corpses |
| Vendor | `Goblin Merchant` | Opens a vendor window when interacted with |

If your server uses different names (or a different language), open the AutoLoot settings window and edit the `Loot` / `Vendor` fields under **COMPANION NAMES**. Press Enter to save.

**Project Ebonhold** users: both companions ship with the server; everything works out of the box.

---

## Slash commands

| Command | Action |
|---|---|
| `/eal` (or `/autoloot`) | Toggle the settings window |
| `/eal toggle` | Enable/disable the loot+sell cycle |
| `/eal enable` / `/eal disable` | Explicit on/off |
| `/eal sell` | Force a sell cycle now |
| `/eal reset` | Clear whitelist (confirmation required) |
| `/eal minimap` | Show/hide the minimap button |
| `/eal help` | Print the command list |

---

## Workflow

1. Open the window with `/eal` or the minimap button.
2. Tick the quality tiers you want sold (Grey is on by default).
3. (Optional) Add items to the **Whitelist** using `+Acct` or `+Char`, or one-click **"Whitelist all Tome of Echo:"**.
4. Click **Enable** — the loot companion is summoned and bag monitoring begins.
5. When bags fill, the vendor companion is summoned automatically.
6. Interact with the vendor — auto-repair runs, then qualifying items sell in batches. Keep the vendor window open until the summary prints.
7. After the vendor window closes, the loot companion is re-summoned and looting resumes.

### Selling in combat

`InteractUnit` is a protected Blizzard-UI function that cannot be called from any addon or macro. The workaround:

1. The on-screen **Vendor** button (coin icon, gold border) appears on login. Alt-drag to reposition.
2. Click the button to target the vendor companion (works during combat lockdown).
3. Press your **Interact with Target** keybind (`Esc → Key Bindings → Targeting → Interact With Target`) to open the vendor window.
4. Auto-repair + auto-sell fire the moment `MERCHANT_SHOW` triggers.

Toggle the Vendor button's visibility from **Show/Hide Vendor Btn** in the settings window.

> **Server-side fast-path:** A fully seamless flow (zero player interaction) requires the vendor companion to send its merchant list on summon, firing `MERCHANT_SHOW` automatically. If your server supports this, the on-screen Vendor button becomes unnecessary.

---

## GUI overview

```
┌─────────────────────────────────────────┐
│        AutoLoot & Sell   v4.0           │
├─────────────────────────────────────────┤
│ Status: LOOTING  Free Slots: 12         │
│                        [ ] Fast Mode    │
│ Lifetime: 12g 35s (287 items)           │
├─────────────────────────────────────────┤
│ [ Enable/Disable ]    [ Force Sell Now ]│
├─────────────────────────────────────────┤
│ Click vendor button, then Interact key  │
│ to sell               [Show Vendor Btn] │
├─────────────────────────────────────────┤
│ COMPANION NAMES                         │
│ Loot:   [Greedy Scavenger            ]  │
│ Vendor: [Goblin Merchant             ]  │
├─────────────────────────────────────────┤
│ SELL QUALITY                            │
│ [x] Grey  [ ] White  [ ] Uncommon       │
│ [ ] Rare  [ ] Epic                      │
├─────────────────────────────────────────┤
│ BEHAVIOR                                │
│ [ ] Sell at any vendor (not just summ.) │
│ [ ] Auto-delete unsellable rares  [x] Sound
├─────────────────────────────────────────┤
│ [ Delete All Savage PvP Gear from Bags ]│
├─────────────────────────────────────────┤
│ ITEM WHITELIST  [A]account  [C]char     │
│ [Item Name           ] [+Acct] [+Char]  │
│ [ Whitelist Tome of Echo: ]    [Clear]  │
│ ┌───────────────────────────────────┐   │
│ │ [A] Hearthstone          [Remove] │   │
│ │ [C] Tome of Echo: Fire   [Remove] │   │
│ └───────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

The minimap button and on-screen Vendor button float separately — drag them where you like.

---

## Compatibility

- **WoW version:** 3.3.5a (Interface 30300)
- **Tested server:** Project Ebonhold / Valanior
- **Dependencies:** none hard; `ProjectEbonhold` is an OptionalDep (enables Tome of Echo whitelisting)
- **Locale:** English (companion names are user-editable, so other locales work with manual config)

---

## Contributors

- [@Veronica-Vasilieva](https://github.com/Veronica-Vasilieva) (Nu) — original author and maintainer
- [@zaxlofful](https://github.com/zaxlofful) (Zachary Laughlin) — reduced sell batch size / increased inter-batch delay to prevent disconnects; Fast Mode toggle

See [CHANGELOG.md](CHANGELOG.md) for full version history.

---

## License

AutoLoot is **source-available, not open-source in the OSI sense.** See [LICENSE](LICENSE) for the full terms. Short version:

- **You may** use, install, modify for personal use, study the source, and contribute back.
- **You may** publish a public fork — but only under a clearly different name that does not contain "AutoLoot", with a README that prominently credits the original project and links to this repo.
- **You may not** rebrand, repackage, or upload this addon (modified or unmodified) under a different author's name to CurseForge, WoWInterface, private-server addon packs, or anywhere else.
- **You may not** sell it, bundle it as a paid feature, or place it behind a paywall.
- **Attribution is non-optional.** The LICENSE file, contributors list, CHANGELOG, and the original `## Author:` line in the `.toc` must be preserved in every copy and derivative.

Private-server communities are explicitly welcome to bundle unmodified copies in their free addon packs, provided attribution is preserved.

This license exists because prior projects by the author have been stolen and republished under other names. Attribution is required, not requested.

For licensing questions or permission requests, [open an issue](https://github.com/Veronica-Vasilieva/AutoLoot/issues).

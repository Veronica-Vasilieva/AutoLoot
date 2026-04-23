# AutoLoot

A WoW 3.3.5a addon for **Project Ebonhold** that automates the full loot → repair → sell cycle using two custom companion pets: the **Greedy Scavenger** (auto-looter) and the **Goblin Merchant** (vendor).

Open with `/eal` or `/autoloot`.

---

## Features

- **Auto-loot cycle** — Summons the Greedy Scavenger and polls your bags every 3 seconds. When every slot is full it dismisses the Scavenger and summons the Goblin Merchant.
- **Auto-repair + auto-sell** — The moment any merchant window opens, `RepairAllItems()` runs (if supported), then qualifying items are sold in batches of **45 per pulse** with a **1.0s pause** between batches. A single summary prints when done. Batching prevents disconnects from flooded `UseContainerItem` calls on large inventories.
- **Fast Mode** — Optional toggle that doubles batch size (45 → 90) and halves the delay (1.0s → 0.5s). Intended for higher-end hardware; tooltip warns of possible disconnects on lower-end machines. Persists between sessions.
- **Per-quality sell toggles** — Grey, White, Uncommon, Rare, Epic. Grey defaults to on; everything else off.
- **Item whitelist** — Named items are never sold regardless of quality. Add via input box, or use the one-click **"Whitelist all Tome of Echo: in bags"** button.
- **Delete Savage PvP gear** — One-click button that scans all bags and deletes every item whose name starts with `Savage `. Deletions are processed one-at-a-time with automatic confirmation of the `DELETE_ITEM` popup (required for Uncommon+). Blocked during combat.
- **Auto-delete unsellable rares** — On every bag-check tick, rare-quality items with no vendor price (and not whitelisted) are automatically deleted using the same async popup-confirmation flow.
- **On-screen vendor button** — A draggable `SecureActionButtonTemplate` button targets the Goblin Merchant on click. Works in and out of combat (attribute is locked in at creation, before combat lockdown). Alt+Drag to reposition; position is saved.
- **Mount-aware companions** — Dismisses active companion when you mount; re-summons the correct pet (Scavenger or Merchant) 1.5s after dismount.
- **Companion stuck detection** — If the Greedy Scavenger drifts more than 5 yards from you, it is auto-dismissed and re-summoned. Skipped while mounted or airborne.
- **Persistent settings** — Window position, vendor button position, whitelist, quality toggles, and Fast Mode all saved via `SavedVariables`.

---

## Installation

1. Clone or download this repository.
2. Copy the `AutoLoot` folder into:
   ```
   World of Warcraft/Interface/AddOns/
   ```
3. Launch WoW and enable the addon from the AddOns menu on the character-select screen.

**Requires** the `ProjectEbonhold` base addon and the **Greedy Scavenger** + **Goblin Merchant** companions in your critter list.

---

## Slash commands

| Command | Action |
|---|---|
| `/eal` | Toggle the settings window |
| `/eal enable` | Enable the loot+sell cycle |
| `/eal disable` | Disable and dismiss any active pet |
| `/eal reset` | Clear the whitelist |
| `/autoloot` | Alias for `/eal` |

---

## Workflow

1. Open the window with `/eal`.
2. Tick the quality tiers you want sold (Grey is on by default).
3. Add any keepers to the **Whitelist**, or one-click **"Whitelist all Tome of Echo: in bags"**.
4. Click **Enable** — the Greedy Scavenger is summoned and bag monitoring begins.
5. When bags fill, the Scavenger is dismissed and the Goblin Merchant is summoned.
6. Interact with the merchant to open its window — auto-repair fires, then qualifying items sell in batches. Keep the window open until the summary prints.
7. After the vendor window closes, the Scavenger is re-summoned and looting resumes.

### Selling in combat

`InteractUnit` is a protected Blizzard-UI function and cannot be called from any addon or macro. The workaround:

1. The on-screen **Vendor** button (coin icon, gold border) appears on login. Alt+Drag to reposition.
2. Click the button to target the Goblin Merchant (works during combat lockdown).
3. Press your **Interact with Target** keybind (`Esc → Key Bindings → Targeting → Interact With Target`) to open the vendor window.
4. Auto-repair + auto-sell fire the instant `MERCHANT_SHOW` triggers.

Toggle the button's visibility from the **Show/Hide Vendor Btn** button in the `/eal` window.

> **Server-side note:** Fully automatic selling (zero player interaction) requires the Goblin Merchant companion to send the merchant list on summon, firing `MERCHANT_SHOW` automatically. Once configured server-side, the on-screen vendor button becomes unnecessary.

---

## GUI Overview

```
┌─────────────────────────────────────────┐
│           AutoLoot & Sell               │
├─────────────────────────────────────────┤
│ Status: LOOTING  Free Slots: 12         │
│                        [ ] Fast Mode    │
├─────────────────────────────────────────┤
│ [ Enable/Disable ]    [ Force Sell Now ]│
├─────────────────────────────────────────┤
│ Click vendor button, then Interact key  │
│ to sell               [Show Vendor Btn] │
├─────────────────────────────────────────┤
│ SELL QUALITY                            │
│ [x] Grey  [ ] White  [ ] Uncommon       │
│ [ ] Rare  [ ] Epic                      │
├─────────────────────────────────────────┤
│ [ Delete All Savage PvP Gear from Bags ]│
├─────────────────────────────────────────┤
│ ITEM WHITELIST                          │
│ [Item Name Input            ] [  Add  ] │
│ [ Whitelist all "Tome of Echo:" in bags]│
│ ┌───────────────────────────────────┐   │
│ │ Hearthstone              [Remove] │   │
│ │ Tome of Echo: Fire       [Remove] │   │
│ └───────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

The on-screen Vendor button floats separately from this window — Alt+Drag to position.

---

## Contributors

- [@zaxlofful](https://github.com/zaxlofful) (Zachary Laughlin) — reduced sell batch size / increased inter-batch delay to prevent disconnects on large inventories; Fast Mode toggle.

---

## Compatibility

- **WoW version:** 3.3.5a (Interface 30300)
- **Server:** Project Ebonhold / Valanior
- **Dependencies:** ProjectEbonhold

See [CHANGELOG.md](CHANGELOG.md) for full version history.

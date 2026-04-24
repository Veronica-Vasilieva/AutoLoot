# Changelog — AutoLoot

## [4.0.2] - 2026-04-24

### Legal
- **Added `LICENSE` file — custom source-available license.** Prior projects by the author have been stolen and republished under other names, so AutoLoot now ships with a license that explicitly requires attribution, prohibits rebranding and repackaging as original work, mandates that public forks use a clearly different addon name and prominently credit upstream, and prohibits commercial redistribution. Private-server communities remain explicitly welcome to bundle unmodified copies in free addon packs. See `LICENSE` for full terms.
- **Added `## X-License:` line to `.toc`** so addon managers surface the license in the addon list.
- **README `License` section rewritten** to summarize the new terms and link to `LICENSE`.

## [4.0.1] - 2026-04-24

### Visual
- **Companion-name inputs now sit on an explicit dark inset panel** — the parchment gradient was drowning out the InputBoxTemplate's native dark bounding boxes, making the `Loot:` / `Vendor:` fields hard to read against the WotLK reskin. Added an ARTWORK-layer black panel (55% alpha) with a gold hairline border around both rows so the inputs read clearly regardless of the gradient. Also dropped the parchment gradient alpha further (bottom 0.60 → 0.18, top 0.45 → 0.10) so the background accent stays decorative instead of dominant.

## [4.0] - 2026-04-23

Major "wider world" release — portability, discoverability, and safety overhaul.

### Fixed
- **Forward-reference bug in `EAL_WhitelistTomes`** — previously the "Whitelist all Tome of Echo:" button would throw "attempt to call a nil value" when it tried to refresh the whitelist, because `EAL_RefreshBlacklist` was declared `local` *after* `EAL_WhitelistTomes` was defined, so the name resolved to the global namespace (nil) at runtime. Added a proper forward declaration and hoisted both `EAL_RefreshBlacklist` and `EAL_UpdateStatus` to the forward-decl block.
- **Accidental auto-sell at non-sell vendors** — previously `OnMerchantShow` would trigger the sell cycle whenever `EAL_DB.enabled` was true, meaning walking past a repair vendor or quest-NPC merchant would silently sell your bags. Now only auto-sells when the addon actively triggered the sell cycle (`triggeredSellCycle` flag), unless the user opts into the new `Sell at any vendor` toggle.
- **Silent auto-deletion of rare items** — the "auto-delete unsellable rares" behavior was previously unconditional and hidden, running every 3 seconds and destroying any rare without a vendor price (including quest items, unique tokens, and certain soulbound gear). Now OFF by default, gated behind a dedicated GUI toggle with a confirmation popup that explains the danger.

### Added
- **Minimap button** — hand-rolled, draggable, no LibDBIcon dependency. Left-click opens settings; right-click toggles enable/disable. Status dot turns green when active. Position is saved as an angle around the minimap.
- **Blizzard Interface Options panel** — registers under `Esc → Interface → AddOns → AutoLoot` with a summary, an "Open AutoLoot settings" button, and a slash-command reference.
- **Keybindings** via `Bindings.xml` — three bindable actions: Toggle window, Toggle enable/disable, Force Sell Now. Set them in `Esc → Key Bindings → AutoLoot`.
- **Configurable companion names** — loot and vendor companion names are now editable fields in the GUI (defaults `Greedy Scavenger` and `Goblin Merchant`). Makes AutoLoot work on any private server or locale that uses different companion names.
- **Per-character whitelist** — `SavedVariablesPerCharacter` now holds a second whitelist scope. Entries show with `[A]` (account) or `[C]` (character) prefixes in the list. `+Acct` / `+Char` buttons add to either scope. Effective whitelist at sell time is the union. Existing account-wide entries are preserved.
- **Gold-earned counter** — per-sell session delta is calculated from `GetMoney()` and printed (`Earned this session: 12g 35s`). Running lifetime total is displayed in the status row and persists in SavedVariables.
- **Sound feedback** — `AuctionWindowClose` plays on sell completion; `TellMessage` on the 8s "vendor ready" reminder. Toggle in GUI.
- **Confirmation popups** — "Delete All Savage PvP Gear" and "Clear Whitelist" now require `StaticPopup` confirmation. `/eal reset` also now prompts for confirmation.
- **`/eal toggle` and `/eal sell` slash commands** — wired up to the new keybinding handlers; `/eal minimap` toggles the minimap button.
- **Schema version + migration hook** — `schemaVersion` field in both SavedVariables tables; `RunMigrations` runs on load if the stored version is older than `CURRENT_SCHEMA`. Enables future SavedVariables changes without breaking existing users.
- **`X-Category: Inventory` and `X-Website`** in the `.toc` for addon-manager integration.
- **Tooltips on every destructive button** (Savage delete, Clear whitelist, Enable/Disable, Force Sell, whitelist scope buttons, sound, auto-delete rares).

### Changed
- **`ProjectEbonhold` moved from `Dependencies` to `OptionalDeps`** — AutoLoot now loads on any 3.3.5a server. Ebonhold-specific features (Tome of Echo whitelisting, Savage PvP deletion) remain available but non-Ebonhold servers can use everything else.
- **Polling replaced by `BAG_UPDATE` event** — bag-fullness detection is now event-driven instead of a 3-second `OnUpdate` poll. Sell cycle triggers instantly when the last slot fills; idle CPU drops to near-zero. Companion stuck-check still runs on the `bagCheckTimer` interval (where bag polling used to live).
- **Author field in `.toc`** updated to `Veronica-Vasilieva`.
- **`Notes` line** updated for wider audience; `"Project Ebonhold"` qualifier dropped.
- **Version bumped to `4.0`** — counts as a major due to `.toc` dependency change, SavedVariables schema addition, and UI reshape.

### Removed
- The silent "auto-delete rares every tick" behavior. Replaced by the opt-in toggle described above. Existing saves start with `autoDeleteRares = false`.

### Visual
- **WotLK-era dark/gold reskin** — warmer, darker parchment tint (`SetBackdropColor(0.10, 0.08, 0.06)`), gold-tinged border (`0.85, 0.68, 0.28`), subtle vertical gradient overlay (gold-ember top fading to near-black bottom), gold L-bracket corner accents, and a gold rule with additive-blended glow under the title bar. All textures use the 3.3.5a-safe `WHITE8X8 + SetVertexColor` pattern.
- **Window height bumped to 740** so the full whitelist + hint row fit without clipping (was 550 in v3.x, 630 pre-layout, now 740).
- **Companion name input boxes shifted right** (x=56 → x=72) so the "Vendor:" label no longer overlaps the input's left cap.

---

## [3.1] - 2026-04-16

### Added
- **Fast Mode** checkbox in the status row (contributed by @zaxlofful, PR #4). When enabled, doubles `MAX_SELL_PER_PULSE` (45 → 90) and halves `SELL_BATCH_DELAY` (1.0s → 0.5s) per sell pass. Toggling takes effect on the next batch. A tooltip warns that this may cause disconnects on lower-end hardware. Setting persisted via `SavedVariables`.

### Removed
- Dual high-end / standard release model dropped. Fast Mode replaces the need for a separate high-end zip — users can toggle it on or off in-game.

---

## [3.0] - 2026-04-15

### Added
- **Delete All Savage PvP Gear** button in the GUI (red text, between the quality toggles and the whitelist panel). Scans all bags for items whose name starts with `"Savage "` and deletes them one at a time. Each deletion is async: `PickupContainerItem` + `DeleteCursorItem` fires, then a 50 ms delay allows the `DELETE_ITEM` confirmation popup (shown for Uncommon+ items) to appear and be auto-confirmed via `StaticPopup_FindVisible` + `Button1:Click()`, then a further 150 ms delay before the next item. Blocked during combat (`InCombatLockdown()`).

---

## [2.9] - 2026-04-15

### Changed
- `MAX_SELL_PER_PULSE` reduced from 80 → **45** items per batch to prevent disconnects on larger inventories (contributed by @zaxlofful, PR #1).
- Inter-batch delay increased from 0.5 s → **1.0 s** (`SELL_BATCH_DELAY`) for the same reason.
- Extracted `FinishSelling(totalSold, totalSkipped)` helper — deduplicates the summary print/status update that previously appeared in two branches of `SellItems`.
- Added guard in the batch continuation callback: if `MerchantFrame` closes between the delay firing and the next sell pass, `FinishSelling` is called cleanly instead of attempting to sell against a closed vendor window.
- `EAL_UpdateStatus()` now called on every bag-check tick so the free-slot counter stays current while looting.

> **High-end hardware users:** A separate release `EbonholdAutoLoot-v2.9-highend` is available with the original `MAX_SELL_PER_PULSE = 80` / `SELL_BATCH_DELAY = 0.5 s` settings for machines that do not experience disconnects with the larger batch size.

---

## [2.8] - 2026-04-09

### Changed
- README fully rewritten to reflect all features from v2.2 onward: on-screen vendor button, mount-aware companion management, item whitelist (renamed from blacklist), Tome of Echo one-click whitelisting, updated GUI diagram, and corrected selling-in-combat instructions.
- Fixed arrow glyph (`→`) in vendor hint text — replaced with a plain comma as the character is unsupported in WoW 3.3.5a's font.

---

## [2.7] - 2026-04-09

### Changed
- Renamed all player-facing "blacklist" text to "whitelist": GUI section header now reads `ITEM WHITELIST`, sell summary message now says "Whitelisted (kept):", and the `/eal reset` confirmation prints "Whitelist cleared." Internal variable and function names unchanged.

---

## [2.6] - 2026-04-09

### Added
- **"Whitelist all Tome of Echo: in bags"** button in the blacklist panel. Scans all bag slots and adds every item whose name begins with `Tome of Echo:` to the blacklist (skipping duplicates). Prints how many were added. Uses a prefix-match (`string.sub` against `"tome of echo:"`) so no regex escaping is needed.

---

## [2.5] - 2026-04-06

### Changed
- `SellItems()` now sells in batches of up to 80 items while the vendor window stays open. After each full batch it waits **0.5 seconds** then automatically sells the next batch, repeating until all qualifying items are gone. Totals are accumulated across batches and a single summary line is printed at the end. This prevents a flood of `UseContainerItem` calls in one frame tick that could disconnect low-end clients, without requiring the player to reopen the vendor.

## [2.4] - 2026-04-06

### Changed
- `SellItems()` now caps at **80 `UseContainerItem` calls per pulse** via `MAX_SELL_PER_PULSE = 80`. Once the cap is hit the inner and outer bag loops break immediately, preventing a flood of sell packets in a single `MERCHANT_SHOW` callback that could disconnect low-end clients. A chat notice is printed when the cap is reached, reminding the player to reopen the vendor to sell the remaining items.

---

## [2.3] - 2026-04-06

### Added
- **Mount-aware companion management**: `OnUpdate` now tracks `IsPlayerMountedOrFlying()` across frames. On mount → dismisses whichever companion is currently out. On dismount → re-summons the correct companion after a 1.5s delay (engine requires a brief pause before `CallCompanion` is accepted after dismounting): Greedy Scavenger if in `S_LOOTING`, Goblin Merchant if in `S_SELLING`. No re-summon occurs if the addon is disabled or in `S_IDLE`.
- Bag check and stuck detection are skipped while mounted to avoid interfering with the dismount re-summon flow.

---

## [2.2] - 2026-04-06

### Added
- **On-screen vendor button** (`EAL_VendorBtn`): a 60×60 `SecureActionButtonTemplate` button parented directly to `UIParent`. Its `type=macro` / `macrotext=/target Goblin Merchant` attribute is set once at creation (outside combat) so it fires correctly even during combat lockdown — no `PreClick` toggling, no `SetAttribute` calls in combat. Features a coin icon, gold border overlay, "Vendor" label, tooltip, and **Alt+Drag** to reposition with position saved to `SavedVariables`.
- **Show/Hide Vendor Btn** toggle in the GUI replaces the old "Bind F5" button. State persisted via `vendorBtnShown` in `SavedVariables`.

### Removed
- Macro + keybind approach (`VendorBind` macro, `SetBinding("F5", ...)`, `SaveBindings`). Replaced entirely by the on-screen secure button.

---

## [2.1] - 2026-04-06

### Changed
- Vendor macro reworked to match the `VendorBind` pattern. Creates a **per-character** macro (`VendorBind`) with `/target Goblin Merchant` and immediately binds **F5** to it via `SetBinding` + `SaveBindings(2)`. The previous approach used a global macro slot and left keybinding to the player; this version wires the key automatically. F5 targets the NPC — the player then presses their separate **Interact with Target** key to open the vendor.
- GUI button relabelled from "Create Macro" to "Bind F5" to reflect the actual action.

### Fixed
- Previous v2.0 code called two `SetBinding` calls on the same key (macro + INTERACTTARGET), with the second silently overwriting the first. Corrected to a single `SetBinding` for the targeting macro only.

---

## [2.0] - 2026-04-06

### Added
- **Vendor macro** (`EAL Merchant`): automatically created in your general Macro book every time you log in. The macro runs `/targetexact Goblin Merchant`, letting you target the vendor companion during combat. Once targeted, use your **Interact with Target** keybind or right-click the NPC to open the vendor window and trigger the auto-sell. A **"Create Macro"** button in the GUI lets you recreate or refresh it at any time while out of combat.

### Changed
- Window height expanded to 496px to accommodate the new vendor macro row between the Enable/Force Sell buttons and the quality toggles.

---

## [1.9] - 2026-04-06

### Changed
- Blacklist scroll UI simplified: removed Up/Down button controls. Scrolling is now mouse-wheel only. A slim 8px scrollbar track with a proportional amber thumb on the right edge of the list gives a clean visual position indicator — it moves as you scroll but is not clickable. The thumb hides when all items fit without scrolling.

---

## [1.8] - 2026-04-06

### Fixed
- Blacklist items now display correctly and Remove buttons now work. Root cause: `FauxScrollFrameTemplate` was still broken despite the v1.7 attempt — even with rows parented directly to the scroll frame, the template's internal scroll child movement conflicted with manual row positioning. Replaced entirely with a hand-rolled list: rows are parented directly to `listBg` at fixed offsets, a `g_blacklistOffset` integer tracks the scroll position, and Up/Down buttons plus mouse wheel (`OnMouseWheel`) update the offset and call `EAL_RefreshBlacklist`. No WoW scroll API is used at all.

---

## [1.7] - 2026-04-06

### Fixed
- Blacklist items now appear in the scroll panel after being added. Root cause: rows were parented to a `listContainer` frame that was set as the `ScrollFrame`'s scroll child. `FauxScrollFrameTemplate` manages row visibility manually via a logical offset and is not designed to work with a scroll child — the ScrollFrame widget was physically moving `listContainer` (and its children) on every scroll event, fighting the FauxScrollFrame offset logic and preventing rows from rendering in the correct positions. Fixed by removing `listContainer` and `SetScrollChild` entirely; rows are now parented directly to the scroll frame, which is the standard FauxScrollFrame pattern.
- Added `scrollFrame.offset = 0` initialisation and `or 0` fallback in `EAL_RefreshBlacklist` so `FauxScrollFrame_GetOffset` never returns nil on first paint.

---

## [1.6] - 2026-04-06

### Added
- Auto-repair on merchant open: calls `RepairAllItems()` before selling whenever `CanMerchantRepair()` returns true. Repair runs first so durability is restored regardless of whether the sell step finds anything. Prints "All items repaired." to chat when triggered.

---

## [1.5] - 2026-04-06

### Removed
- `CreateVendorMacro()`, `VENDOR_MACRO_NAME`, `VENDOR_MACRO_BODY` constants, the "Create Macro" GUI button, and the `/eal macro` slash command. `CreateMacro` and `InteractUnit` both require hardware events or non-combat context and could not be made to work reliably.
- "IN-COMBAT VENDOR" GUI section removed entirely.

### Changed
- Window height reduced to 460 px; quality toggles and blacklist shifted up to fill the space.
- Header comment updated to document the hard limitation: `InteractUnit` is Blizzard-UI-only with no client-side workaround. The fully automatic selling path requires the server to fire `MERCHANT_SHOW` automatically when the Goblin Merchant companion is summoned.

---

## [1.4] - 2026-04-06

### Fixed
- `/eal` and the window close button now work during combat. The `InCombatLockdown()` guards added in v1.3 were overly conservative — they are only required when a frame contains `SecureActionButtonTemplate` children, which was removed in v1.3. Plain frames with regular buttons and checkboxes can be shown and hidden freely at any time.

---

## [1.3] - 2026-04-06

### Fixed
- `/eal` no longer triggers "Interface action failed because of an AddOn". Root cause: `SecureActionButtonTemplate` cannot be parented to a regular addon-controlled frame — the engine blocks `Show`/`Hide` on any frame that has secure children.

### Changed
- Removed the `SecureActionButtonTemplate` "Target Vendor" button from the GUI entirely. The action-bar macro (`/eal macro`) is the correct and fully supported in-combat approach.
- Replaced the two-button vendor row with a single "Create Macro" button and an instruction hint label.
- Added `InCombatLockdown()` guard to the `/eal` slash command and the window close button so the GUI is never shown or hidden during combat lockdown.
- Removed `pulseTimer`, `g_interactBtn`, and `g_interactBtnGlow` runtime variables.
- Window height reduced back to 510 px.

---

## [1.2] - 2026-04-06

### Added
- Companion stuck detection: every bag-check tick, if the Greedy Scavenger is more than 5 yards from the player it is dismissed and re-summoned automatically.
- `IsPlayerMountedOrFlying()` — stuck detection is suppressed while the player is on a mount or airborne so the pet is not needlessly bounced during travel.
- `GetCompanionDistance()` — uses `UnitPosition("player")` and `UnitPosition("pet")` for a 2-D yard distance; returns `nil` gracefully if position data is unavailable.

### Changed
- Stuck check shares the existing `bagCheckTimer` interval (default 3 s) with no additional `OnUpdate` overhead.
- Stuck check is skipped on the same tick that triggers a sell cycle to prevent a dismiss colliding with the sell-cycle dismiss.

---

## [1.1] - 2026-04-06

### Added
- `SecureActionButtonTemplate` "Target Vendor" button in the GUI — targets the Goblin Merchant as a hardware event, works during combat lockdown.
- `EBVendor` macro generator (`/eal macro` or "Create Macro" button) — writes a `/targetexact Goblin Merchant` macro to the player's macro book, ready to drag to an action bar for in-combat use.
- Button pulse animation while state is SELLING to prompt the player to interact.
- Tooltips on both the Target Vendor and Create Macro buttons explaining the correct in-combat vendor flow.

### Changed
- Removed `/script InteractUnit('target')` from macro body — `InteractUnit` is Blizzard-UI-only and blocked in all macro/addon contexts regardless of hardware event status.
- In-combat vendor flow updated: addon targets the NPC; player opens vendor via right-click or Interact with Target keybind.
- Status bar and chat messages updated to reflect the correct two-step combat interaction.
- Window height increased to 552px to accommodate the new vendor button row.

### Removed
- `S_QUEUED` state and `sellQueued` flag.
- `PLAYER_REGEN_ENABLED` / `PLAYER_REGEN_DISABLED` event listeners and combat-queue logic.

---

## [1.0] - 2026-04-05

### Added
- Auto-loot cycle using the Greedy Scavenger companion pet.
- Bag-full detection (polls every 3 seconds via `OnUpdate`).
- Auto-switch to Goblin Merchant companion when bags are full.
- Auto-sell on `MERCHANT_SHOW` — sells all qualifying items the moment any vendor window opens.
- Per-quality sell toggles: Grey (default on), White, Uncommon, Rare, Epic.
- Item blacklist with scrollable list, add-by-name input, and per-entry Remove buttons.
- Case-insensitive companion name matching (`FindCompanion`).
- Live status display showing current state (IDLE / LOOTING / SELLING) and free bag slot count.
- Enable/Disable toggle and Force Sell Now button.
- Draggable, persistent window position saved via `SavedVariables`.
- Slash commands: `/eal`, `/autoloot`, `/eal enable`, `/eal disable`, `/eal reset`.

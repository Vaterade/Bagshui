# Changelog OctoWoW – Bagshui

> Branch `octowow` = the state from Dinkleberrrg's "OctoWoW – HD Upgrade" install (WoW 1.12).

**Base:** absir/Bagshui `05d269b` (2024-12-31)

## Changes

### Code

- Bag slot buttons read `OnUpdate` elapsed time from `arg1`.
- Bags that contain items can be swapped (`Components/Inventory.BagSwap.lua`). Trying to replace an equipped bag moves its items to free slots, equips the new bag, then moves the items in, keeping their slot numbers where possible. At the bank, the other side's free slots count too (bank slots for bags, bag slots for bank bags). Items stay outside when the new bag is smaller or is a profession bag that didn't replace the same type.

### Additional files

The addon folder contains these files from the original install:

| File | Note |
|---|---|
| Components/Inventory.Actions.lua | probably from a different Bagshui version; **not** loaded by the .toc |
| Locale/zhCN.lua | Chinese translation; **not** loaded by the .toc |
| Images/Icons/Clam.blp, Disenchant.blp, Mask.blp, PickLock.blp | additional icons |
| Fonts/Prototype.ttf | "Prototype" font, consistent across the UI (also in ShaguPlates and MSBT) |

These files are only kept so that the fork matches the installed state exactly.

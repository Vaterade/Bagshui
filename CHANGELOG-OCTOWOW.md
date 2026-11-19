# Changelog OctoWoW – Bagshui

> Branch `octowow` = Bagshui 1.5.15, the last upstream release, plus the changes below.

**Base:** `acid9000/Bagshui` `3b5e33b` (2025-09-18). The original `veechs/Bagshui` repo couldn't be reached, so this is a re-upload of 1.5.15. It matches `talex00/Bagshui` apart from that fork's Russian translation.

The last commit on the 1.0.5 install this replaces is `ff9018d`, which includes our own bag swap code. 1.5.15's built-in swap makes that code unnecessary.

## Changes

### Code

- Bag slot buttons read `OnUpdate` elapsed time from `arg1`. Upstream still has this bug: the parameter is nil on 1.12.

### Features

- **Mail to Alts** (`Components/MailToAlts.lua`; new file, so a full client restart is needed).
  - Right-click an item: *Mail Item To* marks every copy of that item for a character on the
    realm; *Mail <Category> To* marks the category it sits in. An item's mark wins over its
    category's, and *Keep* exempts an item from its category. Marks are account-wide, stored
    in `BagshuiData.mailToAlts`, and shown in the item tooltip.
  - At a mailbox, a panel beside the mail window (or Aegis: Courier's window) lists the marked
    items in the bags by recipient, with a checkbox per item. It opens by itself when there's
    something to send; otherwise a button opens it, as does `/bagshui alts`.
  - With Courier's window open, a recipient's button fills Courier's Send tab (attachments
    and recipient; up to Courier's 12) and Courier sends. Otherwise Bagshui sends: one mail per
    stack, each waiting for `MAIL_SEND_SUCCESS`, with retries on `MAIL_FAILED`.
  - Soulbound, quest and conjured items are left out, and so is the current character.
  - Hooks into upstream files are marked `OctoWoW:` in `Inventory.Menus.lua`,
    `Inventory.Ui.ItemButton.lua`, `Locale/enUS.lua` and `Bagshui.xml`.

### Additional files

| File | Note |
|---|---|
| Fonts/Prototype.ttf | "Prototype" font from the OctoWoW HD Upgrade install; nothing in Bagshui references it |

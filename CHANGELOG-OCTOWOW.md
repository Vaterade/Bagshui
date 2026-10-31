# Changelog OctoWoW – Bagshui

> Branch `octowow` = Bagshui 1.5.15, the last upstream release, plus the changes below.

**Base:** `acid9000/Bagshui` `3b5e33b` (2025-09-18). The original `veechs/Bagshui` repo couldn't be reached, so this is a re-upload of 1.5.15. It matches `talex00/Bagshui` apart from that fork's Russian translation.

The last commit on the 1.0.5 install this replaces is `ff9018d`, which includes our own bag swap code. 1.5.15's built-in swap makes that code unnecessary.

## Changes

### Code

- Bag slot buttons read `OnUpdate` elapsed time from `arg1`. Upstream still has this bug: the parameter is nil on 1.12.

### Additional files

| File | Note |
|---|---|
| Fonts/Prototype.ttf | "Prototype" font from the OctoWoW HD Upgrade install; nothing in Bagshui references it |

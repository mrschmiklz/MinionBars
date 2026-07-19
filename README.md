# MinionBars

Health bars for every minion you control in **World of Warcraft: Wrath of the
Lich King** (patch 3.3.5). Built for multi-summon classes (e.g. necromancers)
where only the primary pet gets a real unit token — extra summons are tracked
via the combat log and nameplates.

## Features

- Health bar per minion, main pet first, stable row order
- Exact HP for the primary pet and any extra unit tokens the client exposes
- Approximate HP for other summons via nameplates, target, and mouseover
- Life Force usage counter with configurable cap (`/mb cap N`)
- Auto-hide when empty, draggable window (position saved per character)
- Combat-log discovery for summons and deaths

## Installation

1. Download or clone this repo.
2. Copy into your WoW `Interface\AddOns` folder:
   ```
   <your WoW folder>\Interface\AddOns\MinionBars\
   ```
3. Layout must be:
   ```
   Interface\AddOns\MinionBars\MinionBars.toc
   Interface\AddOns\MinionBars\MinionBars.lua
   ```
4. Fully restart the client if the addon is new; `/reload` is enough for updates.
5. Enable **MinionBars** on the character select AddOns screen.

## Slash commands

| Command | Description |
|---------|-------------|
| `/mb` | Show help |
| `/mb show` | Show the frame (stays visible even when empty) |
| `/mb hide` | Hide the frame |
| `/mb reset` | Clear the roster and re-sync the main pet |
| `/mb autohide` | Toggle hide-when-no-minions |
| `/mb cap N` | Set your Life Force cap (default 4) |
| `/mb probe` | List which pet/minion unit tokens your client exposes |
| `/mb debug` | Log combat-log flags for troubleshooting |

Turn nameplates on (**V**) for best health tracking on summons without a unit token.

## Compatibility

- **Game:** World of Warcraft — Wrath of the Lich King (3.3.5a)
- **Interface:** 30300
- **Language:** English clients only (combat log parsing)
- No libraries, no dependencies, two files

## License

MIT — use and modify freely.

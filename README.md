# 死神VS火影 Pocket

A port of 5DPLAY Game Studio's *Bleach vs Naruto* (死神vs火影) to Pocket2D.
The characters, assists, stages, faces and music are the original game's,
converted from 5DPLAY's public repositories; the fighting rules are a Lua port
of the original ActionScript kernel.

- The original roster and assists, with their alternate forms, from the
  original select grid.
- Single and team (3 vs 3) modes: arcade along the original mission ladders
  (by the player's series, with each stage's HP and attack multipliers),
  versus (two players), against the CPU, CPU vs CPU, and training.
- The original moves: chains, skills, throws, air moves, ultimates with
  cut-ins, bankai transformations, guard and guard break, quick get-up,
  burst / substitution, assists, bullets and summoned attackers.
- Best of three rounds (single) or until a team runs out (team), 60-second
  timer, the original HUD, round banners and the CPU's difficulty tables.
- MUSOU (无双) mode: the world map's areas and missions, waves of mooks and
  bosses against a team of three that levels up, coins to buy fighters; the
  progress is saved.
- NET PLAY (联机对战): versus on two computers: on the same LAN (found
  automatically), over a virtual LAN (Tailscale, ZeroTier, Radmin VPN), with
  connection codes the players exchange, or with a room code from a room
  server. Rollback netcode by default.

## Controls

| | Player 1 | Player 2 |
| --- | --- | --- |
| Move | A / D | ← / → |
| Up / down modifier, guard (down) | W / S | ↑ / ↓ |
| Attack | J | Keypad 1 or `,` |
| Jump | K | Keypad 2 or `.` |
| Dash | L | Keypad 3 or `/` |
| Skill | U | Keypad 4 or `;` |
| Ultimate | I | Keypad 5 or `'` |
| Assist / burst | O | Keypad 6 or `]` |

As in the original: S+J and W+J are skills, U / S+U / W+U are 招, I / W+I /
S+I are ultimates (100 / 100 / 300 energy), J+K transforms when the character
can, direction + J / U throws at close range.
Menus (as in the original): W/A/S/D to choose, J/K/L/U/I/O or Enter to
confirm (player 2 confirms with its attack key on the select screen), Escape
or Backspace to go back or, during a fight, to pause. On the select screen an
alternate form opens around its character; move onto it to pick it.
OPTION sets the CPU level, key mode, life, time, sound and music volume and
HP display; they are saved.
In MUSOU, O switches to the next team member. On the world map the mouse
works as in the original (click an area, drag, wheel to zoom, the face opens
the team); with the keyboard W/A/S/D move between open areas, J or Enter
selects (the current area asks for its next mission), U opens the team and
Escape leaves.

## Playing over the network

NET PLAY on the title menu. Both players use their own player 1 keys; the
host plays player 1, the guest player 2. On the select screen each player
picks with J; elsewhere either player's Enter confirms and Escape goes back or
pauses for both.

- **Same network**: LAN HOST, and the friend picks LAN JOIN, where the room
  shows up by itself (UDP ports 27778 and 27779; allow the game through the
  firewall when Windows or macOS asks).
- **Virtual LAN**: both install Tailscale, ZeroTier or Radmin VPN and join the
  same network. The host picks LAN HOST, which lists its addresses (the virtual
  one highlighted); the friend picks LAN JOIN. ZeroTier and Radmin rooms show
  up by themselves; with Tailscale choose "手动输入地址" and type the host's
  100.x address.
- **Connection codes** (no server): CODE HOST shows a code (Ctrl+C / ⌘C copies
  it); the friend picks CODE JOIN and pastes it (Ctrl+V / ⌘V), then sends their
  own code back, which the host pastes if the friend does not get through by
  themselves. This works on most home networks; when both networks are strict
  (the host screen warns about a symmetric NAT) use a virtual LAN or a room
  code instead.
- **Room code**: CREATE ROOM shows a four-letter room code; the friend picks
  JOIN ROOM and types it. This needs a room server (the engine's
  `tools/room_server`, see the engine's `docs/development/netplay.md`) named in
  `netplay.json` beside `game.config`: `{"server": "SERVER_IP:27777"}` (or the
  `POCKET_NET_SERVER` environment variable).
- MODE picks single or team versus. The host's life, time and key mode
  options apply to both.
- NETCODE: ROLLBACK (default) lets inputs act at once and corrects the few
  ticks the other player's input arrived late for; DELAY waits for both
  inputs, adding the network delay to every input. The corner shows the ping
  and the deepest correction (or the delay).

Both computers need the same version of the game.

## Setting up the assets

The assets are not stored in this repository. They come from three Git
submodules and are converted locally into ignored folders:

```bash
git submodule update --init --depth 1 BleachVsNaruto/external/TagAssets BleachVsNaruto/external/BleachVsNaruto BleachVsNaruto/external/FlashSrc
```

The converter needs Java, [FFDec](https://github.com/jindrapetrik/jpexs-decompiler)
(installed as `~/.local/share/ffdec/ffdec-run`, a script that runs `ffdec.jar`
headless) and Python with Pillow:

```bash
~/.local/share/bvn-venv/bin/python tools/convert_bvn.py --jobs 5
```

```bash
~/.local/share/bvn-venv/bin/python tools/convert_maps.py
```

```bash
~/.local/share/bvn-venv/bin/python tools/convert_effects.py
```

```bash
~/.local/share/bvn-venv/bin/python tools/convert_ui.py
```

```bash
~/.local/share/bvn-venv/bin/python tools/convert_musou_ui.py
```

`convert_musou_ui.py` runs after `convert_maps.py` (it cuts the faces it
converted). `convert_bvn.py` renders every character and assist (about an hour for the
whole roster); `--only ichigo naruto` converts a few, `--missing` only the
unconverted ones and `--lua-only` re-translates scripts from cached frames.

## Running

From the engine checkout (`~/Desktop/pocket2d`):

```bash
./build/sdl3-release/game --project ../pocket2d-games/BleachVsNaruto
```

Regression tests (a CPU vs CPU match started through the title menu, select
and VS screens, and a MUSOU mission from the title menu to its end; need the
converted assets):

```bash
python3 tools/pocket test ../pocket2d-games/BleachVsNaruto
```

Agents can call `start_battle` (`p1`, `p2` or `p1_team` / `p2_team` lists, `p1_assist`, `p2_assist`, `map`,
`mode`: `watch` / `cpu` / `pvp` / `training`, `level` 1-6, `skip_intro`),
`set_qi`, `set_hp`, `end_match` (`winner`), `goto` (`stage`: `title`,
`select`, `option`, `credits`, `howtoplay`, `logo`, `winner`, `continue`,
`gameover`, `congratulations`, `worldmap`, `netplay`), `set_option`, `options`, `net_host`
(`how`: `room` / `lan` / `code`, `port`, `team`, `netcode`, `relay`, `stun`, `discovery_port`), `net_join`
(`how` with `room`, `address` or `code`), `net_code_connect`, `net_discover`, `net_state`, `net_bench` and
`net_synctest` on the `Game` actor,
and for MUSOU `musou_start` (`area`, `mission`, `team`, `auto`, `ai_level`, `fresh`, `skip_intro`),
`musou_state`, `musou_debug`, `musou_data` and `musou_dialog`.
Runs that should not touch your saved options can set `POCKET_SAVE_ROOT` to a
scratch directory.

Netplay test (two games playing a session through a local room server;
`--relay`, `--discover` (LAN discovery), `--code` (connection codes through a
local STUN server), `--lan --lag 60 --loss 0.1` (over a proxy adding 60 ms each
way and 10% loss) and `--lockstep` pick other ways):

```bash
python3 ../pocket2d-games/BleachVsNaruto/tools/net_test.py
```

Rollback test (the engine's sync test, which restores and resimulates six
ticks every tick, over CPU battles and a VS PEOPLE match from the select):

```bash
python3 ../pocket2d-games/BleachVsNaruto/tools/rollback_test.py
```

## Credits and licenses

- Characters, stages, faces, sounds and music: *Bleach vs Naruto* by 剑jian and
  5DPLAY Game Studio, from
  [BleachVsNaruto_TagAssets](https://github.com/5DPLAY-Game-Studio/BleachVsNaruto_TagAssets)
  (no license stated); the game configuration and the kernel this port follows
  come from [BleachVsNaruto](https://github.com/5DPLAY-Game-Studio/BleachVsNaruto)
  (GPL-3.0); the shared effects, their sounds, the fight HUD and the interface screens come from
  [BleachVsNaruto_FlashSrc](https://github.com/5DPLAY-Game-Studio/BleachVsNaruto_FlashSrc)
  (GPL-3.0). This port is a private, non-commercial fan project.
- *Bleach* and *Naruto* characters belong to their rights holders.
- `fonts/bvn.ttf`: a subset of Noto Sans CJK SC (SIL Open Font License 1.1).

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
Menus: W/A/S/D to choose, J or Enter to confirm, K or Backspace to go back,
I to switch a character's alternate form on the select screen.

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

`convert_bvn.py` renders every character and assist (about an hour for the
whole roster); `--only ichigo naruto` converts a few, `--missing` only the
unconverted ones and `--lua-only` re-translates scripts from cached frames.

## Running

From the engine checkout (`~/Desktop/pocket2d`):

```bash
./build/sdl3-release/game --project ../pocket2d-games/BleachVsNaruto
```

Regression test (a CPU vs CPU match started from the title menu; needs the
converted assets):

```bash
python3 tools/pocket test ../pocket2d-games/BleachVsNaruto
```

Agents can call `start_battle` (`p1`, `p2` or `p1_team` / `p2_team` lists, `p1_assist`, `p2_assist`, `map`,
`mode`: `watch` / `cpu` / `pvp` / `training`, `level` 1-6, `skip_intro`),
`set_qi` and `set_hp` on the `Game` actor.

## Credits and licenses

- Characters, stages, faces, sounds and music: *Bleach vs Naruto* by 剑jian and
  5DPLAY Game Studio, from
  [BleachVsNaruto_TagAssets](https://github.com/5DPLAY-Game-Studio/BleachVsNaruto_TagAssets)
  (no license stated); the game configuration and the kernel this port follows
  come from [BleachVsNaruto](https://github.com/5DPLAY-Game-Studio/BleachVsNaruto)
  (GPL-3.0); the shared effects, their sounds and the fight HUD come from
  [BleachVsNaruto_FlashSrc](https://github.com/5DPLAY-Game-Studio/BleachVsNaruto_FlashSrc)
  (GPL-3.0). This port is a private, non-commercial fan project.
- *Bleach* and *Naruto* characters belong to their rights holders.
- `fonts/bvn.ttf`: a subset of Noto Sans CJK SC (SIL Open Font License 1.1).

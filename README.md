# 死神VS火影 Pocket

A two-player fighting game in the spirit of the classic Flash game *Bleach vs
Naruto*, written from scratch on Pocket2D. Characters are drawn from rotated
bars in code; there is no imported character art.

- Four fighters: 黑崎一护, 朽木露琪亚 (Bleach) and 漩涡鸣人, 宇智波佐助 (Naruto).
- Light-attack chains, a launcher, air attacks, guarding, dashes, combo scaling.
- Each fighter has a special (30 energy) and an ultimate (100 energy, with a
  cut-in): 月牙天冲 / 天锁斩月, 白涟 / 月白 (freezes), 螺旋丸 / 多重影分身,
  豪火球 / 麒麟.
- Single player against the CPU, two players on one keyboard, or CPU vs CPU.
- Best of three rounds, 99-second timer, two stages (空座町 · 夜, 木叶隐村).

## Controls

| | Player 1 | Player 2 |
| --- | --- | --- |
| Move | A / D | ← / → |
| Jump | W | ↑ |
| Guard (hold) | S | ↓ |
| Light attack | J | Keypad 1 or `,` |
| Heavy attack | K | Keypad 2 or `.` |
| Special | L | Keypad 3 or `/` |
| Ultimate | U | Keypad 4 or `;` |
| Dash | I | Keypad 5 or `'` |

Menus: W/S and A/D to choose, J or Enter to confirm, K or Backspace to go back.
Light attacks chain up to three hits; a connecting light or heavy attack can be
cancelled into the special or the ultimate.

## Running

From the engine checkout (`~/Desktop/pocket2d`):

```bash
./build/sdl3-release/game --project ../pocket2d-games/BleachVsNaruto
```

Regression test (a CPU-vs-CPU match through the menus):

```bash
python3 tools/pocket test ../pocket2d-games/BleachVsNaruto
```

Agents can call `start_match` (`mode`: `cpu`/`pvp`/`watch`, `p1`/`p2`:
`ichigo`/`rukia`/`naruto`/`sasuke`, `stage`, `skip_intro`), `set_energy` and
`set_hp` on the `Game` actor.

## Assets

- `fonts/bvn.ttf`: a subset of Noto Sans CJK SC (SIL Open Font License 1.1).
  After adding new Chinese text, rebuild it with
  `tools/make_assets.py --font NotoSansCJKsc-Regular.otf`.
- `audio/*.wav`: synthesized by `tools/make_assets.py`.
- Bleach and Naruto characters belong to their rights holders; this is a
  private fan project.

# BleachVsNaruto guidance

A port of 5DPLAY's *Bleach vs Naruto* (Flash, AS3). Original assets come from
the submodules under `external/`; everything converted from them is ignored
(`images/bvn/`, `audio/bvn/`, `data/bvn/`, `component_types/generated/`, `.cache/`).

## Pipeline

- `tools/convert_bvn.py`: per character/assist SWF, FFDec `swf2xml` + script
  export (deobfuscated), then renders the action sprites with FFDec. Animated
  children (the idle breathing lives in one), bullets and attackers (children
  named in `fire` / `addAttacker`) are removed from the form timelines and
  rendered as their own sprites. Frames are cropped and de-duplicated; per
  frame it records the image offset, `bdmn` body, `*atm` hit boxes, named child
  positions (`@name`), animated children with their placement serial and
  matrix, and timeline sounds. Scripts are translated by `tools/as3lua.py`.
  Output: `data/bvn/BVNF_<id>.lua` (assists: `BVNF_fz_<id>`), loaded on demand by
  `BVNRuntime.Character` through `Application.GetProjectDirectory()`; the
  whole roster would take ~100 MB of Lua heap if loaded at startup, beyond the
  agent's 64 MiB budget. A battle keeps only its own characters.
- `tools/convert_maps.py`: map layers (`bg`, `map`, `front`, `front_fix`, logos
  stripped), bounds lines, floors and spawn points into `BVNMaps`; faces, BGM
  and the 5DPLAY config (`fighter.json`, `assist.json`, `map.json`,
  `select.xml`) into `BVNConfig`.
- `tools/convert_effects.py`: the shared effect library (hit / guard sparks,
  dust, ultimate flashes) and its sounds from the FlashSrc effect XFL: a small
  XFL timeline compositor (bitmap and symbol instances, decompiled bitmap-fill
  shapes, classic tweens, alpha) plus decoders for `bin/*.dat` bitmaps
  (0x0305 ARGB, 0x0303 palette) and raw PCM sounds. Output: `BVNFxData`.
- `tools/convert_ui.py`: interface symbols (the fight HUD) from the FlashSrc
  ui XFL as part trees: static images plus the named children the original
  FightUI code drives, exported at their settled `fadin_fin` frame. `BVNHud`
  draws them with overrides (bar scales, digits, faces). `tools/xfl.py` is the
  shared XFL reader and compositor; XFL bitmap-fill matrices scale by 20
  (twips) but translate in pixels.
- `tools/swfxml.py` reads FFDec XML timelines (Flash ignores a non-move
  placement on an occupied depth; obfuscated SWFs rely on that); `tools/as3lua.py` turns AS3
  classes into Lua tables (`fields`, `methods`, `frames`). Helpers it calls
  live in `BVNRuntime` (AS3 truthiness, arrays, deterministic random).

## Runtime

- Engine rule: each component file exports exactly one global named like the
  file, and files load in an unspecified order, so never capture another
  module at file scope (use lazy lookups such as the `D` proxy for BVNDraw).
- `BVNClip`: a playing sprite (Flash frame-entry scripts, children keep their
  playhead while their placement serial persists, `Draw` composes matrices).
- `BVNFighter`: FighterMain / FighterMC / FighterMcCtrler and the floor, air,
  hurt and defense handlers. `BVNCtrl` holds the `$mc_ctrler`,
  `$effect_ctrler` and `$fighter_ctrler` objects the scripts call.
- `BVNBullet`: bullets, attackers, assists. `BVNInput`: buffered predicates.
  `BVNAI`: the original rate tables. `BVNBattle`: tick order (60 Hz logic,
  timelines every 2nd tick), hits, push, camera, rounds, HUD. `BVNEffects`:
  hit-stop, slow motion, shake, flashes and stand-in sparks. `BVNMenu`,
  `BVNGame`: menus, arcade, results.
- Rules and constants follow the original kernel (`external/BleachVsNaruto`,
  `CORE_KernelLogic/src/net/play5d/game/bvn/`). Keep its quirks unless the
  owner asks otherwise.

## Open work

- Not ported yet: the original title, select and loading screens (our own
  layout uses the original faces and config), survivor and musou modes.

## Testing

`tools/pocket check` and an agent run of `start_battle` in `watch` mode from
the engine root. Run output stays under the engine's ignored `build/`.

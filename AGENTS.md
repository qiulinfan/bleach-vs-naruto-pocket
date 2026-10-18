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
  (twips) but translate in pixels. The out-of-battle screens (`SCREENS`) are
  exported as movies, `data/bvn/ui/<name>.lua`, loaded on demand: per frame a
  flat draw list of library bitmaps (and rasterized solid / gradient vector
  shapes, colour transforms baked) with full matrices, `slot` / `slotEnd`
  markers around named instances, static text runs, plus labels, stop() and
  COMPLETE frames and frame sounds (`audio/bvn/ui/`). Movie clips play by
  their own clock, so frames the root holds (stop(), last frame) get `hold`
  extra frames when a screen asks for them. It also writes the font1 glyphs,
  select.xml's layout and cell offsets, and `text_chars` (the movies' text, so
  `tools/make_assets.py --font` keeps those characters in `fonts/bvn.ttf`).
  Masks are ignored (SP_ct, the congratulations shine) and skew is dropped.
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
- `BVNBullet`: bullets, attackers, assists. `BVNInput`: key predicates in the
  original's default classic mode (a held button repeats); `BVNInput.classic =
  false` gives the standard mode (6-tick press buffer, quick double jump).
  `BVNAI`: the original rate tables. `BVNBattle`: GameCtrl's tick order (60 Hz
  logic, timelines every 2nd tick; effects, camera and interface keep running
  while the game is paused), hits, push, GameStartCtrl / FightUI end /
  GameEndCtrl / GameRoundCtrl, and the camera: GameCamera on the 800x600
  stage (auto zoom 800 / dx * 0.8 in [1, 2.5], 3.5 on one target, eased by
  1 / tween), drawn at 1.2x with the extra 16:9 width showing more map.
  `BVNEffects`: EffectCtrl and its handlers (freeze, slow motion and
  background blur, shine, the stage shake, afterimages, the black backdrop of
  ultimates / ghost steps / substitution / bursts with the cut-in face, fire /
  ice / shock / buff / steel colour effects). Fighter colour offsets are drawn
  as a multiplier for negative and an additive pass for positive offsets.
  Scripts that reach FighterMain objects directly get `BVNClip.Facade`
  (AS3 property names mapped to the runtime's fields); `$self_main` / `$key`
  getters, bound method callbacks and stage ENTER_FRAME listeners are
  supported.
- Out of battle, `BVNGame` follows MainGame's stage flow: boot
  (GameLoadingStage) → LogoStage → MenuStage → HowToPlayStage (arcade) →
  SelectFighterStage → LoadingStage (VS, team order) → fight → WinnerStage /
  GameOverStage (continue) / CongratulateStage for arcade (MessionModel), back
  to select for the versus modes. A stage is a table with `Update(g)` /
  `Draw(g)`; `g:Go(stage)` switches. `BVNMenu`: title menu (MenuBtnGroup) and
  select (cursor search, alternate forms, random cells, the select-mode
  flows, map). `BVNScreenFlow`: the other stages. `BVNScreenDialog`:
  SetBtnGroup, ConfrimUI, PauseDialog with the move list. `BVNScreenSetting`:
  OPTION. `BVNSettings`: ConfigVO, saved with `Save` in slot `config`.
  `BVNTrans`: TransUI / QuickTransUI (`In`, `Out`, `Quick`, `Update`, `Draw`,
  `Busy`, `Covered`), also used by the battle. `BVNScreen`: movie player
  (30 fps UI frames), font1 text, the 800x600 → 1.2x layout, GameInputer-style
  input (`Down(kind, "menu" | 1 | 2)`). Screens draw in world space at the
  menu camera (rotation works); engine text is always drawn above images, so
  `BVNScreen.textFloor` hides text under dialogs and transitions.
- Agent commands besides the fight ones: `goto` (`stage`: title, select,
  option, credits, howtoplay, logo, winner, continue, gameover,
  congratulations; `mode`, `team`, `p1` / `p1_team`), `end_match`
  (`winner`), `set_option` (`key`, `value`, `save`) and `options`.
- Rules and constants follow the original kernel (`external/BleachVsNaruto`,
  `CORE_KernelLogic/src/net/play5d/game/bvn/`). Keep its quirks unless the
  owner asks otherwise.

## Open work

- Not ported yet: the musou mode (`GoWorldMap` returns to the title, marked
  STUB; its mooks `xb/*` are converted), the language stage, LAN play, mouse
  input on the screens. `BVNGame.StartSurvivor` plays an arcade ladder; the
  battle plays survivor fights as one round each.
- Screen approximations: the continue screen shows the loser's win portrait
  instead of the fighter in its lose pose; the loading bar fills over 0.5 s
  (nothing loads asynchronously); text uses `fonts/bvn.ttf`, not the Flash
  fonts or glow filters; options without an engine equivalent (key and
  joystick setup, QUALITY, DISPLAY MODE) are left out. SHOW HP is saved in
  `BVNSettings.showHp` for the HUD to read. The battle keeps hit and KO
  points in `score`, which BVNGame adds when the match ends.
- HUD approximations (BVNHud): the qi bar segments, HP bar easing, hit counter
  animation, 1P / 2P markers, HP text and the training input history are
  simpler than FightUI / QiBar / FightBar. Background blur is a three-copy
  horizontal smear; the glow filter is an additive halo.

## Testing

`tools/pocket check` and `tools/pocket test` from the engine root;
`scenarios/watch_match.scenario.json` drives the original menus (SINGLE
WATCH, select, map, VS screen) to a finished CPU match. Screens can be opened
directly with the `goto` command for rendered checks. Set `POCKET_SAVE_ROOT`
to a scratch directory for any run (options are saved). Run output stays
under the engine's ignored `build/`.

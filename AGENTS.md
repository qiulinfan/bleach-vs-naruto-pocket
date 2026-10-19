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
- `tools/convert_musou_ui.py`: the MUSOU mode's data and art. The world map
  and missions (`config/musou/map1/*.json`) go to
  `component_types/generated/BVNMusouConfig.lua` with the big map's layout;
  interface movies (`$musou$MC_ui` and its bars, `game_start_mc`, the dialogs,
  the map point) are exported with convert_ui's `Screens` walker as
  `data/bvn/ui/musou_*.lua` (bitmaps in `images/bvn/ui/musou/<doc>/`). Masks are
  pre-rendered there: the bright map seen through each area's soft circle, and
  the faces cut by their mask layers (`faces[bar|mini|boss|enemy|big][id]`,
  drawn at their content slot). The wave ring is 73 pre-drawn images.
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
- MUSOU (`BVNMusou*`): `BVNMusouData` holds MusouModel / MusouPlayerData /
  MusouLogic (money, owned fighters with level and exp, the team, opened areas
  and passed missions; saved in slot `musou`). `BVNMusouMap` is WorldMapStage
  and LoadingMusouStage, `BVNMusouDialog` DialogManager with the confirm /
  alert, team (MusouStateDialog), fighter (MusouSelectDialog) and pause dialogs,
  `BVNMusouHud` MusouUI. `BVNMusouBattle` is MusouCtrl + MusouFighterEventCtrl
  on `BVNBattle.Battle` (methods it does not define resolve there): teams 1 / 2
  with any number of fighters, the player's team of three (only one on the
  stage, switched by the assist key, the others regenerate), waves / repeats /
  enemy creators, EnemyFighterAICtrl (`Mook` input) and EnemyBossAICtrl (BVNAI
  level 2 with bankai, ghost steps, bursts, super ultimates and throws off),
  targets by FighterMain.getCurrentTarget, the boss intro / KO, the result
  banners and the per-instance musou fighter rules (weak mook hits, dying mooks
  flying further, level-gated inputs, musou enemy hit / guard effect tables on
  the battle's own `fx`). The original is mouse driven; the mouse works and
  the keyboard drives a pointer (map: arrows between open areas, attack /
  confirm selects, skill opens the team; dialogs: arrows, select, back).
- NET PLAY (`BVNNet`): the engine's netplay (`Net`). Configured with
  `local_prefix = "p1_"`, sides p1_ / p2_, shared confirm / back, automatic
  delay, `game = "bleach_vs_naruto"` (LAN discovery), NETCODE rollback (default,
  max 8 ticks) or lockstep, and `Net.Track(_G)`. Links: room code, LAN /
  virtual LAN (direct host with discovery; the host screen lists
  `Net.LocalAddresses()`), connection codes (CODE HOST / JOIN, clipboard copy
  and paste). The host's payload carries the version string (`VERSION`; bump
  it when gameplay changes), MODE (team) and the life / time / key-mode
  options. The first session tick (`BVNNet.Start`) on both machines seeds
  `BVNRuntime.seed` from the session, applies the payload, clears
  transitions, screen input and picks and opens the VS PEOPLE select. While
  `BVNScreen.net` is set, "menu" input is either player, each side selects
  with its own attack (confirm is shared), and `AnyKey` ignores raw keys.
  GoMenu during a session ends it (`BVNNet.Stop`, both machines return to the
  NET PLAY screen); a lost peer does the same with a message. Every 60 ticks
  `BVNNet.Hash` (seed, round, time, fighters' x / y / hp / qi / energy / state
  / dir, sprite count) goes to `Net.Checksum`; a desync shows a red warning.
  Room codes, addresses and codes are typed with raw keys before the session
  starts.
- Rollback: the snapshots walk everything reachable from the globals, so all
  gameplay state must live in Lua tables (it does) and stay deterministic: no
  raw keys, mouse, time or `math.random` in anything a session reaches (musou
  is not reachable from NET PLAY), and no `pairs` over tables keyed by tables
  or functions where the order matters (the stage's ENTER_FRAME listeners are
  a list for that reason). Converted data is static (`Net.Static`: the
  generated globals in `BVNGame.Init`, characters in `BVNRuntime.Character`,
  UI movies in `BVNScreen.Load`) and must not be changed. A battle snapshot is
  about 8,300 tables and closures: about 1 ms to save, 2.6 ms to restore;
  a tick is about 0.4 ms. Snapshots keep up to ten states alive (Lua heap up
  to ~85 MB in team battles), so agent runs with rollback pass
  `--lua-heap-budget 268435456`.
- Agent commands besides the fight ones: `goto` (`stage`: title, select,
  option, credits, howtoplay, logo, winner, continue, gameover,
  congratulations, worldmap, netplay; `mode`, `team`, `p1` / `p1_team`),
  `net_host` (`how` = room / lan / code, `port`, `team`, `netcode`, `relay`,
  `stun`, `discovery_port`), `net_join` (`how` with `room`, `address` or
  `code`), `net_code_connect` (`code`), `net_discover` (`on`), `net_state`,
  `net_bench` (snapshot cost), `net_synctest` (`frames`), `end_match`
  (`winner`), `set_option` (`key`, `value`, `save`) and `options`; for musou
  `musou_start` (`area`, `mission`, `team`, `auto` / `ai_level` for a CPU
  team, `fresh`, `skip_intro`), `musou_state`, `musou_debug` (`kill`: mooks /
  boss / all, `hp`, `qi`, `time`, `wave`), `musou_data` (`reset`, `money`,
  `level`, `fighters`, `team`, `open`, `pass`, `current`, `save`) and
  `musou_dialog` (`name`: state / select / confirm / alert).
- Rules and constants follow the original kernel (`external/BleachVsNaruto`,
  `CORE_KernelLogic/src/net/play5d/game/bvn/`). Keep its quirks unless the
  owner asks otherwise.

## Open work

- Not ported yet: the language stage, mouse input on the screens (the musou
  world map and dialogs take it). The Flash LAN PLAY is replaced by NET PLAY.
- NET PLAY: the engine's deterministic math makes Lua's float math the same
  on every platform (macOS arm64 and Linux x86_64 checked); a Windows x64
  machine against a Mac has not been played yet.
- Musou approximations: the fighter list jumps between pages instead of
  sliding (no scrollRect clipping); the coin button's add-money (an ad SDK
  hook) does nothing; the time reads MM:SS (KyoTimerFormat is not in the
  sources); the HUD clips that the original plays natively run at 60 fps,
  startKOmc at 30 as in renderStartAndKO; texts use `fonts/bvn.ttf` (rerun
  `tools/make_assets.py --font` after adding Chinese text). `BVNGame.StartSurvivor` plays an arcade ladder; the
  battle plays survivor fights as one round each.
- Screen approximations: the continue screen shows the loser's win portrait
  instead of the fighter in its lose pose; the loading bar fills over 0.5 s
  (nothing loads asynchronously); text uses `fonts/bvn.ttf`, not the Flash
  fonts or glow filters; options without an engine equivalent (key and
  joystick setup, QUALITY, DISPLAY MODE) are left out. SHOW HP is saved in
  `BVNSettings.showHp` for the HUD to read. The battle keeps hit and KO
  points in `score`, which BVNGame adds when the match ends.
- HUD (BVNHud, BVNHudParts): FightUI with every build's BITMAP_UI = true
  (bars appear without their slide animations; `BVNHud.BITMAP_UI = false`
  plays them). Fighters log their FighterInputCmd text in `trainingInputs` for
  the training input history. Background blur is a three-copy horizontal
  smear; the glow filter is an additive halo.
- CPU (BVNAI): FighterAICtrl + FighterAILogic; the AI object is the
  fighter's input, its flags answer the same predicates as keys.

## Testing

`tools/pocket check` and `tools/pocket test` from the engine root;
`scenarios/watch_match.scenario.json` drives the original menus (SINGLE
WATCH, select, map, VS screen) to a finished CPU match;
`scenarios/musou_mission.scenario.json` goes from the title through MUSOU
ACRADE, the world map, the mission confirm and LoadingMusouStage to MISSION
COMPLETE in area p1's first mission (Game.musou_result 1 = complete, 2 =
failed). Screens can be opened
directly with the `goto` command for rendered checks. `tools/net_test.py`
plays a NET PLAY session between two headless games (room server, `--relay`,
`--discover`, `--code`, `--lan --lag MS --loss F` through a lossy proxy,
`--lockstep`) and checks both machines stay in the same state;
`tools/rollback_test.py` runs the engine's rollback sync test over CPU
battles, a team battle and a VS PEOPLE match from the select. Set `POCKET_SAVE_ROOT`
to a scratch directory for any run (options are saved). Run output stays
under the engine's ignored `build/`.

## Source repository

The port's code is GPL-3.0 (as the original kernel). This repository,
[qiulinfan/bleach-vs-naruto-pocket](https://github.com/qiulinfan/bleach-vs-naruto-pocket),
is its only source and development home; the source for every released build
must be here. pocket2d-games links it as the submodule `BleachVsNaruto` (its
history up to pocket2d-games 960c7af came along): commit and push here, then
move the pointer in pocket2d-games. Never commit converted assets or local
configuration (`netplay.json`).

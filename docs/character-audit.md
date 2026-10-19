# Character asset audit

Every fighter, assist and musou mook of `fighter.json` / `assist.json` (77
select entries, 42 assists, 11 mooks), converted with `tools/convert_bvn.py`
and checked two ways. The tables at the end are generated; this part is
written by hand.

## How it was checked

- **Static, against the SWF** (`tools/audit_bvn.py --json`): blank rendered
  frames where the SWF timeline shows a shape, bitmap or text (FFDec's
  `render2` against the `swf2xml` timeline, with masks, alpha and invisible
  fills taken into account); frame images missing on disk; screen / lighten /
  add / subtract / multiply placements left inside a child that is flattened
  into its parent (they would be lost or drawn as a black box); each select
  entry's start form (main_mc frame `start_frame + 1`) and every main_mc frame
  the form scripts jump to; sprites whose bounds outgrow the canvas FFDec
  rendered; frames mostly made of opaque near-black pixels (looked at by
  hand); frame scripts the generated Lua defines but never registers;
  children drawn on their own that a mask covers.
- **In battle, the real runtime** (`tools/battle_audit.py`, agent protocol,
  headless): per fighter a battle against Naruto with qi, energy and assist
  topped up before every move: idle, walk, the J chain, S+J, W+J, U, S+U, W+U,
  I, W+I, S+I, jump and air J, dash, J+K (transformation where there is one),
  J after it and the assist; 40 to 50 captured frames per fighter on a contact
  sheet. Per assist two calls from Ichigo; per mook a CPU battle. Engine and
  script diagnostics are collected, and the form at the start and the end is
  recorded. Sheets and `report.json` go to the engine's ignored
  `build/bvn-audit/battle/`.

## Fixed

Runtime (`component_types/`):

- **Forms follow main_mc.** A select entry starts on main_mc frame
  `start_frame + 1`, `doWanKai` moves to the next or a given frame, and a
  form's own `parent.gotoAndStop(n)` / `nextFrame()` now builds that frame's
  form. These had done nothing, so 须佐佐助 never reached its Susanoo form and
  byakuya's bankai never switched between its sword and swordless forms.
- **Attackers advance like FighterAttacker / Assister.renderAnimate**: every
  tick unless their controller holds them. A clip's own `stop()` on frame 1
  had frozen attackers on screen for good (deidara's clay birds).
- **Detached sprites keep their placement.** A bullet, attacker or follow
  effect keeps the scale, rotation, alpha and colour transform its child had
  in the fighter's frame (an attacker with its x scale reset to 1, as
  FighterAttacker's `direct` does), and a bullet's hit area is measured as
  placed, as `getBounds(owner)` does. About 40 characters place such children
  scaled or translucent: aizen's 断空 barrier was an opaque narrow slab instead
  of a translucent wall, tensa's bullets (placed at 0.42) were drawn and hit
  2.4 times too large, madara's `zh3atm` bullet (placed at 2.8 × 5.1) far too
  small.
- Scripts reaching another fighter get its controllers; the layer has
  `swapChildren` (aizen's 黑棺); `getDefinitionByName` gives `MainGame.I`
  (hinata, suigetsu); `new <sound>().play()` plays; ulquiorra's ultimate can
  lay its bitmap over the map backdrop.
- Blended children draw as Flash blends them: screen / lighten / add
  additively with the whole subtree, subtract and multiply / darken through the
  engine's multiply blend (pocket2d), with the placement's alpha, colour
  multipliers and offsets, and colour matrix filters as image variants.

Converter (`tools/`):

- Subtract and multiply children are rendered apart instead of being flattened
  as black boxes (ichigo's 万解 and hollow ultimates, tensa, aizen, ulquiorra,
  itachi's 天照); a plain child holding a blended one deeper down is split out;
  children under a mask stay in their parent's frames, where FFDec applies the
  mask; a child placed with a blend stays apart for the instance's whole life
  (lee's 表莲华 floated above the ground, an aura was missing).
- FFDec pads a sprite's canvas by the reach of its filters; frames were placed
  from the unpadded bounds, so 20 sprites were drawn shifted by up to 20 px
  (lee's and sasuke's base forms among them).
- **Frame scripts lost to a line break**: FFDec wraps the long
  `addFrameScript(...)` call, sometimes between `this` and `.frameN`, and those
  scripts were never registered: one or two per character in 22 characters,
  often the `idle()` or `endAct()` that ends a move. Konan's 上必杀 (W+I) ran
  past its end into her 超必杀 and waited forever for a landing; the audit now
  checks that every frame script is registered.
- The translator handles `++n` / `a = b = c` inside expressions (karin's
  上必杀 loop, naruto_hermit's 空中必杀), `new X().y` and
  `getDefinitionByName`, and folds an obfuscator's `§§push(x); switch(n) {}
  §§pop()` no-op FFDec leaves undecompiled: fz_jiraiya's assist never defined
  its attacks (it hit for nothing, now 300 damage) and sasuke_susanoo_old's
  ultimate never ended its darkened screen. No script is left untranslated.

## Results

- Static: every converted character passes except the legitimately blank
  frames below and byakuya_old's 卍解 entry (see forms). No missing images, no
  blended child left inside a flattened one, no sprite outgrowing its canvas,
  no unregistered frame script.
- Battle: 130 runs (77 fighters, 42 assists, 11 mooks), no script or engine
  error, no captured frame where the fighter drew nothing. The contact sheets
  were reviewed by eye (a judgment, not a pixel comparison with Flash); the
  notes column holds what the review found or fixed. The
  "start→end" column is the main_mc frame (form) at the start and after the
  fixed move list, which does not always trigger a transformation.

## 须佐佐助 (sasuke_susanoo) and other forms

The select entry 须佐佐助 starts, as in the original, on main_mc frame 2: the
鹰佐助 form. J+K moves to frame 3 (佐助), and 上必杀 in that form moves to
frame 4, the Susanoo form, which the port now reaches (checked in battle:
J+K, then W+I, and the giant purple Susanoo stands behind him); before, the
form's `parent.gotoAndStop(4)` did nothing. The second entry
(sasuke_susanoo2, sasuke.swf frame 3) is a winged Sasuke, not a Susanoo, in
the original too. The original therefore does not start in
the Susanoo form either. Starting there would mean changing the select entry
(`start_frame: 3`), a gameplay change against the original, left to the owner.

All other select entries start on a form that exists, and every frame the form
scripts jump to holds a form, except byakuya_old: its 卍解 entry asks for main
frame 3 while the SWF places one form only, a quirk of the original data (the
original shows the same form).

## Remaining

- Legitimately blank frames: sasuke_susanoo (2) and ulquiorra (5) have frames
  whose content is fully transparent or hidden in the SWF as well.
- fz_soifong, fz_yin and minato have no main_mc and are not in the roster.
- Masks over children drawn on their own (blended, split, animated) would
  draw them unmasked; no character has one (the static audit checks it).

## Looked at and found as authored

- Blocky scaled effects: the art is bitmaps with smoothed fills, and the PC
  build runs at quality LOW, where Flash does not smooth bitmaps; the port
  draws the same. The setting page has the original's QUALITY again: at BEST
  the fight smooths them, as the original's BEST.
- kenshin's S+I "navy rectangle": the 4:3 game area inside the 16:9 capture
  while the stage is darkened (the HUD spans the same width).
- toushirou_bankai's white ice after its ultimate: FFDec's own frames flash
  white and fade into the ice (a colour transform in the SWF).
- deidara's long dark backdrop: his 超必杀 holds its cinematic from main
  frame 762 to 866 (104 frames), and uryuu_ginreigojiaku's ultimate is as long.
- Lee's green silhouettes, ulquiorra's dark smoke, aizen's black 黑棺 and
  gaara_old's black dash silhouette (a solid black shape in the SWF) are the
  SWFs' own art.

## Per character

Generated by `tools/audit_report.py` from the static audit's JSON, the battle
audit's `report.json` files and the review notes. "blank" counts rendered
frames that are empty where the SWF shows something; "nested blends" counts
blended children left inside flattened ones.

### Fighters

| id | name | SWF | forms (main frames) | blank | nested blends | battle form start→end | errors | visual review |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ichigo | 黑崎·一护 | ichigo @2 | 2/3/4/5 | 0 | 0 | 2→3 |  | 万解 / hollow ultimates no longer black boxes |
| ichigo_bankai | 黑崎·一护 卍解 | ichigo @3 | 2/3/4/5 | 0 | 0 | 3→5 |  |  |
| ichigo_vizored_half | 黑崎·一护 半虚 | ichigo @4 | 2/3/4/5 | 0 | 0 | 4→5 |  |  |
| ichigo_vizored | 黑崎·一护 虚化 | ichigo @5 | 2/3/4/5 | 0 | 0 | 5→5 |  |  |
| ichigo_zero | 黑崎·一护 零段 | ichigo_zero @2 | 2/3/4 | 0 | 0 | 2→3 |  |  |
| ogihci | 黑崎·一护 内虚 | ichigo_zero @3 | 2/3/4 | 0 | 0 | 3→3 |  |  |
| ogihci_bankai | 黑崎·一护 内虚 卍解 | ichigo_zero @4 | 2/3/4 | 0 | 0 | 4→4 |  |  |
| rukia | 朽木·露琪亚 义骸 | rukia @2 | 2/3 | 0 | 0 | 2→3 |  |  |
| rukia_shikai | 朽木·露琪亚 始解 | rukia @3 | 2/3 | 0 | 0 | 3→3 |  |  |
| renji | 阿散井·恋次 | renji @2 | 2 | 0 | 0 | 2→2 |  |  |
| kenpachi | 更木·剑八 | kenpachi @2 | 2 | 0 | 0 | 2→2 |  |  |
| ikkaku | 斑目·一角 | ikkaku @2 | 2 | 0 | 0 | 2→2 |  |  |
| gin | 市丸·银 | gin @2 | 2 | 0 | 0 | 2→2 |  |  |
| chad | 茶渡·泰虎 | chad @2 | 2 | 0 | 0 | 2→2 |  |  |
| uryuu | 石田·雨龙 | uryuu @2 | 2/3 | 0 | 0 | 2→3 |  |  |
| uryuu_ginreigojiaku | 石田·雨龙 银岭弧雀 | uryuu @3 | 2/3 | 0 | 0 | 3→3 |  | long ultimate is the move's length |
| toushirou | 日番谷·东狮郎 | toushirou @2 | 2/3 | 0 | 0 | 2→2 |  |  |
| toushirou_bankai | 日番谷·东狮郎 卍解 | toushirou @3 | 2/3 | 0 | 0 | 3→3 |  | white ice after the ultimate is FFDec's own white flash |
| byakuya | 朽木·白哉 | byakuya @2 | 2/3/4 | 0 | 0 | 2→3 |  | bankai switches sword / swordless forms |
| byakuya_bankai | 朽木·白哉 卍解 | byakuya @3 | 2/3/4 | 0 | 0 | 3→3 |  |  |
| ulquiorra | 乌尔奇奥拉·西法 | ulquiorra @2 | 2/3 | 5 | 0 | 2→2 |  | subtract effects drawn; dark smoke is the art; 5 blank frames as in the SWF |
| ulquiorra_resurreccion | 乌尔奇奥拉·西法 归刃 | ulquiorra @3 | 2/3 | 5 | 0 | 3→3 |  |  |
| aizen | 蓝染·惣右介 | aizen @2 | 2/3 | 0 | 0 | 2→2 |  | 断空 barrier translucent and at its placed size; 黑棺 black is the art |
| aizen_gz | 蓝染·惣右介 叛变 | aizen @3 | 2/3 | 0 | 0 | 3→3 |  |  |
| mayuri | 涅·茧利 | mayuri @2 | 2 | 0 | 0 | 2→2 |  |  |
| orihime | 井上·织姬 | orihime @2 | 2 | 0 | 0 | 2→2 |  |  |
| grimmjow | 葛力姆乔·贾卡杰克 | grimmjow @2 | 2 | 0 | 0 | 2→2 |  |  |
| soifon | 碎蜂 | soifon @2 | 2 | 0 | 0 | 2→2 |  |  |
| starrk | 柯雅泰·史塔克 | starrk @2 | 2 | 0 | 0 | 2→2 |  |  |
| yoruichi | 四枫院·夜一 | yoruichi @2 | 2 | 0 | 0 | 2→2 |  |  |
| tensa | 天锁斩月 | tensa @2 | 2 | 0 | 0 | 2→2 |  | bullets at their placed 0.42 scale |
| naruto | 漩涡·鸣人 | naruto @2 | 2/3/4 | 0 | 0 | 2→3 |  |  |
| naruto_oneTail | 漩涡·鸣人 一尾 | naruto @3 | 2/3/4 | 0 | 0 | 3→4 |  |  |
| naruto_fourTail | 漩涡·鸣人 四尾 | naruto @4 | 2/3/4 | 0 | 0 | 4→4 |  |  |
| naruto_hermit | 漩涡·鸣人 仙人 | naruto_hermit @2 | 2/3 | 0 | 0 | 2→3 |  | 空中必杀 hold translated |
| naruto_kurama | 漩涡·鸣人 九尾 | naruto_hermit @3 | 2/3 | 0 | 0 | 3→3 |  |  |
| sakura | 春野·樱 | sakura @2 | 2 | 0 | 0 | 2→2 |  |  |
| sakura_sr | 春野·樱 三忍 | sakura_sr @2 | 2 | 0 | 0 | 2→2 |  |  |
| sasuke | 宇智波·佐助 | sasuke @2 | 2/3 | 0 | 0 | 2→3 |  |  |
| sasuke_mantra | 宇智波·佐助 咒怨 | sasuke @3 | 2/3 | 0 | 0 | 3→3 |  |  |
| sasuke_susanoo | 宇智波·佐助 须佐能乎 | sasuke_susanoo @2 | 2/3/4 | 2 | 0 | 2→2 |  | starts 鹰佐助 as the original; J+K then 上必杀 reaches Susanoo (was unreachable) |
| sasuke_susanoo2 | 宇智波·佐助 须佐能乎2 | sasuke @3 | 2/3 | 0 | 0 | 3→3 |  |  |
| karin | 漩涡·香磷 | karin @2 | 2 | 0 | 0 | 2→2 |  | 上必杀 loop translated |
| juggo | 天秤·重吾 | juggo @2 | 2 | 0 | 0 | 2→2 |  |  |
| itachi | 宇智波·鼬 | itachi @2 | 2 | 0 | 0 | 2→2 |  | 天照 multiply drawn (was a black box) |
| deidara | 迪达拉 | deidara @2 | 2 | 0 | 0 | 2→2 |  | clay birds no longer frozen; long dark backdrop is the 104-frame cinematic |
| kakashi | 旗木·卡卡西 | kakashi @2 | 2/3 | 0 | 0 | 2→3 |  |  |
| kakashi_kamui | 旗木·卡卡西 神威 | kakashi @3 | 2/3 | 0 | 0 | 3→3 |  |  |
| lee | 李·洛克 | lee @2 | 2/3 | 0 | 0 | 2→2 |  | base form placed correctly (filter padding); 表莲华 on the ground; green silhouettes are the SWF's colour transform |
| lee_domen | 李·洛克 杜门 | lee @3 | 2/3 | 0 | 0 | 3→3 |  |  |
| neji | 日向·宁次 | neji @2 | 2 | 0 | 0 | 2→2 |  |  |
| gaara | 我爱罗 | gaara @2 | 2 | 0 | 0 | 2→2 |  |  |
| temari | 手鞠 | temari @2 | 2 | 0 | 0 | 2→2 |  |  |
| jiraiya | 自来也 | jiraiya @2 | 2 | 0 | 0 | 2→2 |  |  |
| orochimaru | 大蛇丸 | orochimaru @2 | 2 | 0 | 0 | 2→2 |  |  |
| killerbee | 奇拉比 | killerbee @2 | 2 | 0 | 0 | 2→2 |  |  |
| pain | 佩恩 | pain @2 | 2 | 0 | 0 | 2→2 |  |  |
| konan | 小南 | konan @2 | 2 | 0 | 0 | 2→2 |  | 上必杀 no longer runs into 超必杀 and hangs (lost frame script) |
| obito | 宇智波·带土 | obito @2 | 2/3 | 0 | 0 | 2→3 |  |  |
| obito_trueColors | 宇智波·带土 真面目 | obito @3 | 2/3 | 0 | 0 | 3→3 |  |  |
| madara | 宇智波·斑 | madara @2 | 2 | 0 | 0 | 2→2 |  | effects additive (were black boxes); zh3atm bullet at its placed size |
| kimimaro | 君麻吕 | kimimaro @2 | 2 | 0 | 0 | 2→2 |  |  |
| hinata | 日向·雏田 | hinata @2 | 2 | 0 | 0 | 2→2 |  | script error fixed (getDefinitionByName) |
| suigetsu | 鬼灯·水月 | suigetsu @2 | 2 | 0 | 0 | 2→2 |  | script error fixed (getDefinitionByName) |
| kenshin | 绯村·剑心 | kenshin @2 | 2/3 | 0 | 0 | 2→3 |  | S+I rectangle is the 4:3 game area while darkened |
| kenshin_slash | 绯村·剑心 拔刀斋 | kenshin @3 | 2/3 | 0 | 0 | 3→3 |  |  |
| deidara_old | [旧版] 迪达拉 | deidara_old @2 | 2 | 0 | 0 | 2→2 |  |  |
| gaara_old | [旧版] 我爱罗 | gaara_old @2 | 2 | 0 | 0 | 2→2 |  | black dash silhouette is the SWF's own shape |
| itachi_old | [旧版] 宇智波·鼬 | itachi_old @2 | 2 | 0 | 0 | 2→2 |  |  |
| pain_old | [旧版] 佩恩 | pain_old @2 | 2 | 0 | 0 | 2→2 |  |  |
| sasuke_susanoo_old | [旧版] 宇智波·佐助 须佐能乎 | sasuke_susanoo_old @2 | 2 | 0 | 0 | 2→2 |  | ultimate ends its darkened screen (an undecompiled no-op) |
| obito_old | [旧版] 宇智波·带土 | obito_old @2 | 2/3 | 0 | 0 | 2→2 |  |  |
| naruto_hermit_old | [旧版] 漩涡·鸣人 黄金 | naruto_hermit_old @2 | 2 | 0 | 0 | 2→2 |  |  |
| juggo_old | [旧版] 天秤·重吾 | juggo_old @2 | 2 | 0 | 0 | 2→2 |  |  |
| byakuya_bankai_old | [旧版] 朽木·白哉 卍解 | byakuya_old @3 | 2 | 0 | 0 | 2→2 |  |  |
| ulquiorra_old | [旧版] 乌尔奇奥拉·西法 | ulquiorra_old @2 | 2/3 | 0 | 0 | 2→3 |  |  |
| soifon_old | [旧版] 碎蜂 | soifon_old @2 | 2 | 0 | 0 | 2→2 |  |  |

### Assists

| id | name | SWF | forms | blank | nested blends | battle | errors | visual review |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| kon | 魂 | fz_kon | 1 | 0 | 0 | 12 shots |  |  |
| orihime | 井上·织姬 | fz_orihime | 1 | 0 | 0 | 12 shots |  |  |
| yoruichi | 四枫院·夜一 | fz_yoruichi | 1 | 0 | 0 | 12 shots |  |  |
| uryuu | 石田·雨龙 | fz_uryuu | 1 | 0 | 0 | 12 shots |  |  |
| kenpachi | 更木·剑八 | fz_kenpachi | 1 | 0 | 0 | 12 shots |  |  |
| ichigo_hollow | 黑崎·一护 牛头 | fz_ichigo_hollow | 1 | 0 | 0 | 12 shots |  |  |
| yachiru | 草鹿·八千流 | fz_yachiru | 1 | 0 | 0 | 12 shots |  |  |
| starrk | 柯雅泰·史塔克 | fz_starrk | 1 | 0 | 0 | 12 shots |  |  |
| halibel | 蒂雅·赫丽贝尔 | fz_halibel | 1 | 0 | 0 | 12 shots |  |  |
| grimmjow | 葛力姆乔·贾卡杰克 | fz_grimmjow | 1 | 0 | 0 | 12 shots |  |  |
| soifon | 碎蜂 | fz_soifon | 1 | 0 | 0 | 12 shots |  |  |
| nemu | 涅·音梦 | fz_nemu | 1 | 0 | 0 | 12 shots |  |  |
| ichigo_padipata | 黑崎·一护 修行 | fz_ichigo_padipata | 1 | 0 | 0 | 12 shots |  |  |
| yamamoto | 山本·元柳斎重国 | fz_yamamoto | 1 | 0 | 0 | 12 shots |  |  |
| gin | 市丸·银 | fz_gin | 1 | 0 | 0 | 12 shots |  |  |
| rangiku | 松本·乱菊 | fz_rangiku | 1 | 0 | 0 | 12 shots |  |  |
| byakuya | 朽木·白哉 | fz_byakuya | 1 | 0 | 0 | 12 shots |  |  |
| ikkaku | 斑目·一角 | fz_ikkaku | 1 | 0 | 0 | 12 shots |  |  |
| gaara | 我爱罗 | fz_gaara | 1 | 0 | 0 | 12 shots |  |  |
| temari | 手鞠 | fz_temari | 1 | 0 | 0 | 12 shots |  |  |
| ino | 山中·井野 | fz_ino | 1 | 0 | 0 | 12 shots |  |  |
| tenten | 天天 | fz_tenten | 1 | 0 | 0 | 12 shots |  |  |
| itachi | 宇智波·鼬 | fz_itachi | 1 | 0 | 0 | 12 shots |  |  |
| hinata | 日向·雏田 | fz_hinata | 1 | 0 | 0 | 12 shots |  |  |
| tsunate | 纲手 | fz_tsunate | 1 | 0 | 0 | 12 shots |  |  |
| tsuchikage | 大野木 | fz_tsuchikage | 1 | 0 | 0 | 12 shots |  |  |
| minato | 波风·水门 | fz_minato | 1 | 0 | 0 | 12 shots |  |  |
| jiraiya | 自来也 | fz_jiraiya | 1 | 0 | 0 | 12 shots |  | attacks defined again (an undecompiled no-op): hits for 300 |
| suigetsu | 鬼灯·水月 | fz_suigetsu | 1 | 0 | 0 | 12 shots |  |  |
| sai | 佐井 | fz_sai | 1 | 0 | 0 | 12 shots |  |  |
| madara | 宇智波·斑 | fz_madara | 1 | 0 | 0 | 12 shots |  |  |
| kimimaro | 君麻吕 | fz_kimimaro | 1 | 0 | 0 | 12 shots |  |  |
| shikamaru | 奈良·鹿丸 | fz_shikamaru | 1 | 0 | 0 | 12 shots |  |  |
| obito_trueColors | 宇智波·带土 真面目 | fz_obito_trueColors | 1 | 0 | 0 | 12 shots |  |  |
| sakura | 春野·樱 | fz_sakura | 1 | 0 | 0 | 12 shots |  |  |
| hiruko | 蝎 | fz_hiruko | 1 | 0 | 0 | 12 shots |  |  |
| yls | 千手·扉间 | fz_yls | 1 | 0 | 0 | 12 shots |  |  |
| kabuto | 药师·兜 | fz_kabuto | 1 | 0 | 0 | 12 shots |  |  |
| naruto | 漩涡·鸣人 | fz_naruto | 1 | 0 | 0 | 12 shots |  |  |
| renji | 阿散井·恋次 | fz_renji | 1 | 0 | 0 | 12 shots |  |  |
| utakata | 泡沫 | fz_utakata | 1 | 0 | 0 | 12 shots |  |  |
| shishio | 志志雄·真实 | fz_shishio | 1 | 0 | 0 | 12 shots |  |  |

### Musou mooks

| id | name | SWF | forms | blank | nested blends | battle | errors | visual review |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| xb_ninja_1 | 忍者小兵1 | xb/ninja1 | 2 | 0 | 0 | 8 shots |  |  |
| xb_ninja_2 | 胖忍者兵 | xb/ninja2 | 2 | 0 | 0 | 8 shots |  |  |
| xb_ninja_earth1 | 土影小兵1 | xb/ninja_earth1 | 2 | 0 | 0 | 8 shots |  |  |
| xb_ninja_fire1 | 火影小兵1 | xb/ninja_fire1 | 2 | 0 | 0 | 8 shots |  |  |
| xb_ninja_fire2 | 火影小兵2 | xb/ninja_fire2 | 2 | 0 | 0 | 8 shots |  |  |
| xb_ninja_sand1 | 风影小兵1 | xb/ninja_sand1 | 2 | 0 | 0 | 8 shots |  |  |
| xb_ninja_thunder1 | 雷影小兵1 | xb/ninja_thunder1 | 2 | 0 | 0 | 8 shots |  |  |
| xb_bear1 | 熊1 | xb/bear1 | 2 | 0 | 0 | 8 shots |  |  |
| xb_bird1 | 鸟1 | xb/bird1 | 2 | 0 | 0 | 8 shots |  |  |
| xb_dog1 | 狗1 | xb/dog1 | 2 | 0 | 0 | 8 shots |  |  |
| xb_pig1 | 野猪1 | xb/pig1 | 2 | 0 | 0 | 8 shots |  |  |

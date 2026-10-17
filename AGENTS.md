# BleachVsNaruto guidance

- One component, `BVNGame`, owns the whole game (title, select, fight, result).
  `BVNData` holds characters, poses and move timing; `BVNRig` draws fighters
  from pose angles; `BVNFx` draws projectiles and particles; `BVNStage` draws
  backgrounds; `BVNDraw` wraps drawing in screen pixels (camera fixed at
  (6.4, 3.6), zoom 1, so world units are pixels / 100).
- Randomness comes from `rand(g)` (seeded LCG) so replays stay deterministic.
- World draws (`D.Rect`, rigs) always sit under UI draws (`D.UI`, text); keep
  anything that must cover a rig in world space with a lower sorting order.
- New Chinese text needs the font subset rebuilt (`tools/make_assets.py --font`).
- Test with `tools/pocket check` and `tools/pocket test` from the engine root.

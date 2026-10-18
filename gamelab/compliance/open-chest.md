# Compliance manifest — open-chest (spawn a bronze chest in town, press Use, loot reaches the inventory)
Run: `gamelab/results/20261017-192415-open-chest-lab` (PASS, 21.1 s)   Date: 2026-10-17
Build/mod version: Steam build 25509441 (`exe_sha256` 6ddd9e7d…), gamelab-probe 0.1.0; probe/hands/pilot trees dirty vs HEAD (`run.json` `mods`)

## Phase 0 — Loop closed
- [x] 0.1 Preflight kills strays and aborts on failure — evidence: `gamelab/lock.py`
  `acquire` refuses (exit 4) while a lab `HWR2.exe` is alive, on a stale or live lock, and after a
  dirty teardown (`REFUSED stale lock ...`, `REFUSED another GameLab run holds the lock`,
  `REFUSED previous run did not tear down cleanly`, each exit 4). Scratch `saves/` and `appdata/`
  are wiped per run. The build gate exits 3.
- [x] 0.1 Isolation verified on the LIVE process, not the args — evidence: this run's `live[0]`:
  `image` = `C:\FastProjects\HammerwatchPlus\gamelab\env\userdata\game\HWR2.exe`,
  `image_in_gamelab`, `known_folder_hooked`, `swap_hooked`, `in_job` and `child_of_runner` are all
  true, and `log_launch_path` matches. The user's cfg, install `res/` and saves are asserted
  unchanged (PASS).
- [x] 0.2 First-run gates enumerated and seeded — evidence: the lab cfg seeds windowed 640x360,
  mute and `g_save_slot_cloud 0`. The only gate on a fresh profile is the main menu, passed by a
  posted Enter. The null-save pass reaches `PickCharacterWindow` with no other modal.
- [x] 0.3 Heartbeat logs phase variable every second — evidence: `gl.jsonl` `hb` events carry
  `frames`, `phase`, `window`, `cmds` and `exceptions`. Gap: heartbeats start at the session; the
  menu span is covered by `wait_log` on `Started menu level`.
- [x] 0.4 Runner owns lifetime; TIMEOUT distinct from FAIL — evidence:
  `gamelab/results/20261017-185729-timeout-selftest-lab`, verdict `TIMEOUT`, exit 6.
  - `error`: `RunTimeout: scenario deadline passed before step ... 'never reached'`.
  - "collected before the deadline" PASS; teardown clean; isolation assertions still evaluated.
- [x] 0.5 Null-payload smoke run green on two consecutive cold runs — evidence: `null-payload` PASS
  at `20261017-063240` and `20261017-185715` (13.5 s), plus the two cold runs earlier on 2026-10-17.

## Phase 1 — Instruments
- [x] 1.1 Capture instrument validated against known content — evidence: `PrintWindow` on the hidden
  desktop returns a blank image (RE_NOTES 2026-10-17); the in-process `SwapBuffers` hook gives correct
  640x360 frames; `python -m gamelab.observe` on a run without shots exits 1.
  Added this session: the console panel is in a frame taken right after a console reply and gone
  100 ms later (`console-slide` 20261017-191646), so `Session.shot` waits `SHOT_SETTLE` = 0.25 s after
  the console closes.
- [x] 1.2 Renderer channel captured AND read by a BLIND observer this run
  - Frame + `sha256[:12]` (from `python -m gamelab.observe gamelab/results/20261017-192415-open-chest-lab`, exit 0):
    `C:\FastProjects\HammerwatchPlus\gamelab\results\20261017-192415-open-chest-lab\shots\end.png  f2a9e7e99989`
  - Observer: a fresh subagent given only the absolute frame path and the playbook prompt, unmodified.
  - Observer output, verbatim and unedited:
    ```
    I looked at `C:\FastProjects\HammerwatchPlus\gamelab\results\20261017-192415-open-chest-lab\shots\end.png`. It is only 640x360, so I also enlarged three parts of it to read them: the top-left box, the bottom bar and the area around the player. Most of the small text is too blurry to read exactly. Where I give a reading below, I say how sure I am.

    **(a) Things drawn on top of the world**
    1. A dark grey box with a frame, at the top left (about x 8–195, y 8–75).
    2. A bar along the bottom centre (about x 215–425, y 330–360). From left to right it holds:
       - a character portrait
       - a slot with an orange border holding a mace or staff
       - a slot with an orange border holding a round brown item, with a small number under it
       - a small column with a "0"-like number above a grey pot or flask icon
       - a red bar and a blue bar, each with numbers on it
       - an orange eight-sided slot holding a grey blade or arrowhead icon, with a number
       - an empty dark eight-sided slot
    3. There are no tooltips or other dialogs.

    **(b) On-screen text**
    - In the top-left box:
      - Line 1 is blurry. My best reading is "Try moving around", but I'm not sure.
      - Line 2 is four key boxes. The first three look like "W", "S", "A". The fourth is not readable (possibly "D").
      - Line 3 looks like "You can also dash forward with", but I'm not sure. It ends in a blank grey key box with no visible label.
    - On the red bar: the numbers look like "150/150", but they are not legible.
    - On the blue bar: the numbers look like "120/120", but they are not legible.
    - Under the brown item slot: one or two digits, not legible.
    - In the orange eight-sided slot: one or two digits, not legible.
    - The small number above the flask: possibly "0", but not legible.
    - There is no other text on screen.

    **(c) Player character**
    - A small figure stands in the middle of a grassy clearing (about x 318, y 180).
    - It has light or bald hair, a brown and blue outfit, and something red and white at its side, maybe a shield or cape.
    - There is a white or light-blue shape on the ground at its feet.
    - The portrait in the bottom bar shows a person with long brown hair and a headband.
    - Visible gear is the mace or staff icon and the round brown item icon.
    - Class: not visible. No stat panel is visible.
    - A brown horse or similar four-legged animal stands on the dirt path just up and to the right of the player (about x 345, y 155).

    **(d) Errors, loading states and empty slots**
    - The last key box in the top-left box is blank, with no label.
    - The right-most eight-sided slot in the bottom bar is empty.
    - I saw no error message and no loading screen or spinner.
    - I saw no chest or chest-open effect.

    **Scene**
    - Autumn forest seen from above, with green and orange-yellow trees.
    - Dirt paths meet near the centre right.
    - There are log fences or barricades, wooden cross-shaped barriers and grey rock piles.
    - There is a red shape at the top edge (about x 180, y 0).

    I wrote three enlarged crops to `C:\tmp\claude\` (`end_tl.png`, `end_hud.png`, `end_player.png`).
    ```
  - Reconciliation vs the structured probe (`overlays` c14, `state` c3.0, `inv` c13, `near`):
    - **Tutorial panel** — agrees. The probe reports `tutorial: "intro_move"`. The text is the game's
      `.tutorial.intro.move1/move2` (`language/english/dialogue.lang:24-25`). The blank key-cap is
      assumed to be the Dash key; not verified.
    - **No dialogs** — agrees: `windows: []`.
    - **No chest** — agrees: `near` count 1 → 0 ("chest gone"; boundary "chest -> loot -> town store").
    - **Loot toasts** — the observer reported "no other text"; the probe reports two `LootLog`
      announces ("Got: icn-stone", "Got: icn-wood"). **Resolved in the probe's favour:** the `loot_log`
      style (`announcestyles.sval.json:808`) is anchored bottom-right (`text-anchor` 1,1, `offset` -30,-26),
      grey 0.5, 11 px Arial, 5000 ms. An enlarged crop of x 440–640, y 270–360 (`C:\tmp\claude\end_br.png`,
      a non-blind check by me) shows a faint grey "Got" at about (580, 330) over grass. It is present
      but nearly invisible, which is why the observer missed it.
    - **HP bar** — the observer's guess "150/150 (not legible)" vs the probe's `hp 160/160`. It
      flags itself as illegible, so this is not a contradiction. Mana "120/120" agrees with `mana 120/120`.
    - **Class** — the probe says `paladin`; the observer sees a mace/staff and a round brown item
      (shield). Consistent, not confirmable.
    - **Earlier observer (run 190827) saw a console panel** that no probe reported. Root cause: shots
      were taken during the console's slide-out (console-slide 20261017-191646). Fixed by
      `SHOT_SETTLE`; this run's observer reports no console.
    - **Unexplained, harmless:** the red shape at the top edge (x 180, y 0) and the light shape at the
      player's feet. Neither is probed. Assumed to be scenery and the player's selection ring; not verified.
    - **Verdict:** no unexplained contradiction of an asserted fact. The run stands as PASS.
- [x] 1.3 Open dialogs/modals enumerated; set empty or expected — evidence: the `overlays` verb
  enumerates window-manager windows, the active tutorial, HUD announces and the boss bar. It is asserted
  before Use (`{"windows": [], "tutorial": "intro_move", "announces": [], "bossBar": false}`) and at the end,
  where `announce_styles: ["loot_log"]` is allowed, with a reason, since the pickup just happened. Both PASS.
- [x] 1.4 Every hook/probe body wrapped so a throw cannot escape — evidence:
  `gamelab/results/20261017-185641-probe-selftest-lab` PASS.
  - Assertions: "a throwing verb returns a failed reply", "the probe still answers after the throw",
    "the game is still in town" and "no script errors in our files (the throw was caught)".
  - The heartbeat counts it: `"cmds":5,"exceptions":1`.
- [x] 1.5 Each new hook proved to fire, with context logged — evidence: the probe constructor logs
  `boot` with `version`/`level` (`menu` in run.json: `level: levels/town.lvl`, `boots: 1`); `hb` counts
  `cmds`; the shim reports `known_folder_hooked` and `swap_hooked`.
- [x] 1.6 Cheapest legitimate reference obtained and diffed (or absence stated) — evidence: no reference
  save exists or is needed. The run's own before/after `inv` replies are the reference: c6 all zero vs c13
  `wood 3, stone 1`.

## Phase 2 — State reached
- [x] 2.1 Every construction mirrors a cited game path; no hand-assembled objects — evidence: the
  character comes from `gl char` (mirrors `CreateCharacterWindow`). The chest comes from
  `Resources::GetUnitProducer("items/chests/cache_bronze.unit").Produce`. It is opened by the real
  `Use` key, not by a call.
- [x] 2.2 Every field read back through a DIFFERENT path than wrote it — evidence: the spawn reply
  (unit 868) is re-read by the scene query `near` (boundary "spawn -> scene": unit 868 → 868,
  name → name) and by `usables` (`canUse`, `top`). The fixture is read back via `state`.
- [x] 2.3 Populated / legal / governed-thing-exists checked per field — evidence: the materials went
  0 → 4 (`assert_more`); "loot is one cache_bronze can drop": gained `{wood: 3, stone: 1}` against the
  chest's pools (stone 1-1, wood 1-3 ×3). The `usables` `canUse` check shows the game would allow the use.
- [x] 2.4 S verified green before being used to debug — evidence: fixture readback, enabled mods and
  lab profile all PASS before the first step.

## Phase 3 — Transitions
- [x] 3.1 Boundary table emitted, context AND identity boundaries — evidence: `run.json`
  `boundaries`, 4 rows, all `ok`:
  - `menu -> session` (context): version survives, boots survives, phase changes no_record → town;
  - `spawn -> scene` (identity): unit and name survive;
  - `chest -> loot -> town store` (identity): `count` changes 1 → 0;
  - `town store before -> after pickup` (identity): store survives `town`; materials change
    all-zero → `wood 3, stone 1`.
- [x] 3.2 Probed both sides of every boundary row — evidence: every row has a `before` and an `after`
  cell, measured on each side. The menu side of `menu -> session` comes from the probe's menu reply
  (`menu` in run.json, `phase: no_record` at `_t` 8.5).

## Phase 4 — Discipline
- [x] 4.1 No retained change lacking a demonstrated failure it fixes — evidence: each fix this session
  has its failure:
  - `SHOT_SETTLE`: the observer saw a console in 190827, measured by console-slide.
  - `restore_noactivate`: open-chest-minimized 185553 was INVALID with no end frame; it was PASS at 190846.
  - The `loot_log` allowance: open-chest 185532 FAIL on the toast.
  - `e_cheats` first: watch-overlays 185339 cvars stayed 0.
  - Explore gating: learned.json was written by scenario runs.
- [x] 4.2 No speculative fix applied to an unobserved hang — evidence: no hang in this scenario.
  floor-soak's "no mission heartbeat" was diagnosed first (the player stayed on DeadMenu), and the
  DeadMenu MenuAccept followed.
- [x] 4.3 Ruled-out list maintained — evidence: `docs/RE_NOTES.md`. It includes "time scale is safe"
  (measured invalid), "mods don't run at the menu" and the `.sval` preprocessor.
- [x] 4.4 Repro minimised — evidence: `gamelab/scenarios/open-chest.json`; `open-chest-minimized`
  drops the shots and still passes (20261017-190846).

## Coverage statement (required, prose)
Checks cover:
- isolation of the live process (image path, known-folder redirect, job membership);
- the user's config, saves and install `res/` unchanged;
- focus never left the user's window (412 samples at 50 ms);
- fixture readback;
- the chest spawn/use/despawn through two read paths;
- the loot reaching the town store and being a legal drop for the chest;
- overlays enumerated before and after;
- four boundary rows probed on both sides;
- four non-blank frames, one read by a blind observer and reconciled.

Checks do NOT cover:
- which exact roll the loot is (the RNG is unseeded; only legality is asserted);
- watch mode;
- any mission (non-town) state, which pilot-floor covers separately;
- multiplayer;
- HP digits on screen (illegible at 640x360).

Pre-mortem — five ways this is still wrong that the checks cannot see. Four were investigated.
1. The materials could come from something other than the chest. **Investigated:** the gain is a legal
   cache_bronze drop, `near` sees no material units left, and the before state is all zero on a fresh town.
2. The Use key could hit a different usable. **Investigated:** `usables` shows exactly the chest with
   `top: true` just before the key.
3. The frame could show a different moment than the probe. **Investigated:** the overlays reply (c14)
   comes just before the end shot, and the toast the probe reported is in the frame (faint "Got",
   bottom-right).
4. The observer could miss low-contrast HUD text. **Investigated:** it did (the toast). Small grey text
   at 640x360 needs a crop; the reconciliation step caught it.
5. Not investigated: whether a script-spawned `cache_bronze` rolls differently from a level-placed one.

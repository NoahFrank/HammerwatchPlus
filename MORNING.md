# Morning notes - decisions made overnight, please flesh out

Everything below was decided by Claude while you slept so the build could keep
moving. Each item says what was built, what was guessed, and what to look at.

## Phase 2 (QoL / co-op batch) - built, boot-verified, needs in-game passes

Chat commands are the settings UI for now: type `/hwp help` in chat. `/hwp set
<key> <value>` stores a setting in your own town record (persists per save
slot, per machine). A real settings tab is on the list below.

| Module | Guess to review |
|---|---|
| `laststats` | Notice board position (-440,110) next to the fountain of `town_square_4` is a guess; `/hwp set laststats.board_x N` / `board_y` moves it live (re-enter town). Per-skill damage lines are not in the snapshot (no player actor at snapshot time). |
| `deathrecap` | 10 s window, top 5 sources, panel 96 px under the top edge. Source names come from unit paths (`lich_king` -> "Lich King"), no attacker = "Hazards". Chat line goes to everyone (`deathrecap.chat` to disable). |
| `petwait` | Puzzle detection = producer path `doodads/buttons/*` or contains `puzzle`, radius 120 around the **owner**, checked every 400 ms. Classmaps on `MiniPetWalking`/`MiniPetFlying` - the log line `classmap active` on the first pet spawn confirms classmaps work on unit behaviours; if it never appears, the fallback is overriding the two base files. |
| `architect` | Everyone can pick alterations from their own run-start loadout; sponsors pay their picks in full, the host's picks are split evenly (`architect.split`, default on). **Not done:** the town-fountain entry point and "host approval" mode. Refunds are moot: nothing is charged until the run starts. |
| `chatlinks` | Uses the vanilla hold-context-key linking (nobody knew it existed?) and adds a persistent chat line; `/hwp link [slot]`. Typing `[item]` in the chat box and hover tooltips need a custom chat widget - skipped. |
| `colors` | Tints projectile units with `SetMultiplyColor` (multiplies the sprite, so dark sprites stay dark). Presets: contrast, deuteranopia, protanopia, tritanopia; per-team hex overrides. AoE/effect telegraphs are not tinted. |
| `groupcombo` | 2/3/4 players in combo: +5/10/15 % damage and speed, +1/2/3 s combo sustain; everyone in combo: 2 s invulnerability, 30 s cooldown. Numbers in `tweak/hwp/buffs_groupcombo.sval`. |
| `weaponswap` | Hotkey is an SDL scancode setting (X = 27) because scripts cannot add bindings to the controls menu; `/hwp swapkey 21 R` changes it. Flow: press to stash, equip other weapons, press to toggle. HUD line under the top edge. |

Decisions that need you:

1. **Settings GUI**: a tab in the options menu vs. a HWP book/NPC in town vs.
   keep chat commands. Chat commands are built; the rest is not.
2. **Fountain sponsor entry point** for architect buffs (plan said "fountain or
   loadout"; loadout is done). The well unit is at local (104,16) of every
   `town_square_*` prefab; square 4 sits at world (-608,128). Doing it means an
   interact behaviour on the well (classmap or a spawned invisible NPC next to
   it).
3. Whether the group-combo bonus should also give regen (plan said "regen and
   damage"); currently damage + speed + combo duration.
4. Death recap: keep the chat announce on by default?
5. Weapon swap in town: allowed now; disallow?

## Still to build (Phases 3-7)

Phase 3 ace chests/keys/General Merchant/red legendaries, Phase 4 Firearms
Specialist, Phase 5 fishing/farming, Phase 6 pets + progression + spec reworks
+ strongboxes/abyss, Phase 7 HoH1 campaign/classes/wave mode. See
`docs/` and the plan file for details; progress notes get appended here.

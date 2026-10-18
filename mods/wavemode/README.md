# wavemode

**Wave Arena**: a Hammerwatch 1 Survival / HoH1 Arena style mode on top of
the vanilla `SurvivalMission` level module (the one the Celestial Ruins
DLC uses). A statue in town starts it; every boss kill raises your arena
rank, and the rank is the arena's NG+ level next time.

- **Mission** `hwp_wave_arena` (set `hwp_wave`): one generated keep floor
  (bandits, elites, density 1.2) with the survival module: 10 minute clock,
  XP goal 15000, 4 spawn events (the vanilla shade / phantom / cult / wisp
  events from `missions_heaven_actions.sval`), boss = `actors/hwp/wave_boss.unit`,
  a copy of the valor spirit warrior with its `stat-reward valor` removed so
  arena clears never raise the heaven DLC valor rank (keep it in sync with
  `actors/bosses/spirits/warrior/boss_spirit_warrior.unit` after patches),
  `progress-rank-multiplier` 0.25 so the XP goal grows with rank,
  `max-rank-reward` 3.
- **Statue** `doodads/hwp/wave_statue.unit` (the vanilla valor statue
  sprite) with interact class `HWPWaveShopContent`, a
  `MissionSurvivalShopContent` subclass: the rank it offers is the HWP
  setting `wave.rank` (host-synced) instead of the heaven `valor` stat, the
  entry is never NG+-gated, and `GetBoonDetails` does not append a boon
  skill (the vanilla one null-derefs on a boon without a skill). Host:
  `MissionManager::SetMission` + the loadout menu with
  `MissionSpecSurvival(rank)`; client: HWP request `wave.start`, the host
  gets the vanilla "X wants to start" yes/no dialog and `HWPWaveClientStarter`
  opens the loadout menu at the host's rank (the vanilla `RequestStartingMap`
  only treats the number as NG+ for the heaven set, ours would be rescaled
  from an item level).
- **Boon** `hwp_wave_boon` (`tweak/hwp/buffs_wave_boon.sval`): shown in the
  survival window; same valor armour bonus as the vanilla warrior boon.
- **Rank up.** The killer's machine sees `PlayerKilledActor` for an actor
  with the `boss` tag while the current mission is `hwp_wave_arena`; the
  host awards `max(1, g_survivalReward)` (the survival module's own 1..3
  speed reward) once per floor, saves `wave.rank` in the town record and
  broadcasts `wave.awarded`; a client sends `wave.bosskill` and the host
  checks the mission before awarding.
- Host spawns the statue (`HWP::Town::Placeable`) 0.6 s after the town loads at `wave.statue_x/y`
  (default -1500,250, right of the campaign portal); `hwp wave here`
  moves it, `hwp wave rank <n>` sets the rank (host), `hwp wave` shows
  the state. `wave.enabled` turns it off.
- Known limits for the morning: the arena uses heaven enemies for the
  spawn events (they exist for everyone, the DLC only gates the missions);
  the boss is the valor spirit, not an arena champion of its own; the
  rank has no cap.

## Test checklist

1. `python -m gamelab run mod-wavemode --mode lab`: `[HWP:wave] self-check done: mission ok, boon ok, 4/4 spawn
   actions, rank 0`; no missing unit lines.
2. Town: the statue stands right of the portal. Interact opens the survival
   window with "Wave Arena", the Arena Champion boon and rank 0; Start
   opens the loadout menu and the run begins on a keep floor with the
   survival bar on the HUD.
3. Kill until the bar fills: spawn events fire at the checkpoints, the
   spirit warrior appears; kill it -> chat shows "Arena rank up! Rank N"
   and `hwp wave` agrees back in town; the statue now offers rank N.
4. Let the clock run out: everyone dies (vanilla survival rule); no rank.
5. `hwp wave rank 5` then start: the arena is NG+5 (enemy levels up).
6. Co-op: a client can start the arena (request to the host) and a client
   boss kill still raises the host's rank.

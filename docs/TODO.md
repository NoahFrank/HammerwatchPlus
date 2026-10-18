# TODO - later

Things to flesh out after the current test pass. Testing of what is built
comes first; see the test plan.

## Maps: real new world types

The three map-drop missions in `mods/maps` (Goblin Warrens, Sunken
Dungeon, High Court) are new combinations of vanilla themes: their floors use
existing tilesets, level generators and enemy schemes (Goblin Warrens starts
in the forest, the vine world). Give them, or new maps, their own look:

- new themes / tilesets (or recoloured vanilla ones) per map
- level generator settings or hand-made prefab rooms for new layouts
- map-specific modifiers and a boss that is not a reused act boss
- possibly HoH1-imported tilesets for a map, via `import_hoh1.py`
  (never committed)

## Weapons: matching icon and ground sprite for the Bulwark

The Bulwark now uses the unused base tower-shield model when equipped, but
its inventory icon and dropped sprite are still the small heater shield (the
base game has no tower-shield icon). Needs a drawn icon / ground sprite.

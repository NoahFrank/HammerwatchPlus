---
name: game-screenshot
description: Capture a screenshot of Heroes of Hammerwatch II (hidden, muted, never focused) into .screenshots/ and look at it. Use when you need to see the game - a mod's NPC, UI, a scenario's state.
---

# game-screenshot

1. Run, from the repo root:

   ```
   python tools/game_screenshot.py [scenario]
   ```

   With no argument it boots the `screenshot` scenario (a level-1 paladin in town) and
   takes one frame. With a scenario name it runs that scenario and keeps every frame it
   takes (its `shot` steps plus the automatic `end` shot).

2. Every captured frame is printed as `SHOT <path>` (under `.screenshots/`, which is
   gitignored). **Read each path with the Read tool** to see the image. Never report
   what a screenshot shows without reading it.

3. The exit code is the run's: 0 PASS, 1 FAIL, 2 preflight, 3 build mismatch (re-pin),
   4 lock held / dirty teardown (`python -m gamelab reset`), 5 INVALID, 6 TIMEOUT. On
   anything but 0, say so, and say which frames you did get.

Rules this inherits from GameLab (CLAUDE.md): the game only ever runs `--mode lab`
(the tool passes it), so no window appears on the user's desktop and focus is never
taken. Never start `HWR2.exe` directly to take a screenshot, and never use PrintWindow
or a desktop grab: on the hidden desktop PrintWindow returns a blank frame
(`capture-printwindow` scenario). The in-process capture is the only path.

To frame something specific, write a scenario with `shot` steps (see
`gamelab/scenarios/capture-passive.json`) and pass its name.

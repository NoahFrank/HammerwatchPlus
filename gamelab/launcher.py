"""Outer GameLab launcher: preflight, then the inner runner on a hidden desktop, then the
checks that only the outside can make (the user's config and saves untouched, focus never
left the user's window).

    python -m gamelab run <scenario> --mode lab     # programmatic runs: always --mode lab
    python -m gamelab run <scenario>                # a human at the keyboard: watch mode

Preflight, in order, any failure aborts before the game starts (docs/PLAYBOOK.md P6 item 1):
  0. save backups confirmed on this machine (`python -m gamelab doctor --confirm-saves`)
  1. tools/saves.py backup         2. build-id gate (exit 3)
  3. tools/env_link.py --verify    4. environment resolution (here) + live verification
                                      of the running process (gamelab/runner.py)

One run at a time, and never after a dirty teardown (gamelab/lock.py; exit 4,
`python -m gamelab reset` clears it). `--accept-build-drift` lets one run past the build
gate and stamps "build_drift": true into its run.json.

Verdicts (exit code): PASS (0), FAIL (1: an assertion failed), INVALID (5: the run itself
cannot be trusted: the user's config or saves changed, focus moved, or probes and the
renderer disagreed), TIMEOUT (6: the scenario's deadline passed; whatever was collected
is still in run.json, flagged "partial").
"""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tools"))
from gamelab import env, lock, winproc  # noqa: E402
import gamepaths  # noqa: E402
import hidden_desktop  # noqa: E402
import pin_build  # noqa: E402
import saves  # noqa: E402

SCENARIOS = REPO / "gamelab" / "scenarios"
RESULTS = REPO / "gamelab" / "results"
INVALIDATING = ("user config unchanged", "user saves unchanged", "install res/ unchanged",
                "focus never left the user's window", "no game-tree window on the input desktop",
                "foreground never the game tree from launch to first frame")


def sha(p: Path) -> str | None:
    return hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None


def mods_version() -> dict:
    """Mod sources as deployed into the GameLab game dir: git tree id + dirty flag per mod."""
    out = {}
    for m in env.environments()["gamelab"]["mods"]:
        tree = subprocess.run(["git", "rev-parse", f"HEAD:mods/{m}"], cwd=REPO, capture_output=True, text=True).stdout.strip()
        dirty = bool(subprocess.run(["git", "status", "--porcelain", f"mods/{m}"], cwd=REPO, capture_output=True, text=True).stdout.strip())
        out[m] = {"tree": tree or None, "dirty": dirty}
    return out


def preflight(mode: str, accept_drift: bool = False, mods: list[str] | None = None) -> tuple[list[str], list[str]]:
    errors = [f"saves: {p}" for p in saves.confirmation_problems()]
    if errors:
        return errors, []
    code = saves.backup(quiet=True)
    if code:
        errors.append(f"saves.py backup failed (exit {code})")
    mism = pin_build.mismatch()
    if mism and not accept_drift:
        print("build gate:", "; ".join(mism))
        sys.exit(pin_build.EXIT_BUILD_MISMATCH)
    if mism:
        print("BUILD DRIFT accepted for this run:", "; ".join(mism))
    problems = env.link(fix=True, mods=mods)
    errors += [f"env_link: {p}" for p in problems]
    gl = env.environments()["gamelab"]
    user_data = Path(gl["user_data"].replace("<repo>", str(REPO))).resolve()
    if env.GAME.resolve() != user_data and user_data not in env.GAME.resolve().parents:
        errors.append(f"gamelab game dir {env.GAME} is not the declared user_data {user_data}")
    profile = env.cvars((env.SETTINGS / mode / "HWR2.exe.cfg").read_text())
    if mode == "lab" and any(float(v) != 0 for k, v in profile.items() if k.startswith("snd_volume")):
        errors.append("lab profile is not muted on disk")
    if profile.get("g_save_slot_cloud") not in ("0", "false"):
        errors.append("profile enables cloud saves (g_save_slot_cloud must be 0)")
    return errors, mism


def run(scenario_name: str, mode: str, accept_drift: bool = False) -> int:
    scenario_path = Path(scenario_name) if scenario_name.endswith(".json") else SCENARIOS / f"{scenario_name}.json"
    scenario_name = scenario_path.stem
    scenario = json.loads(scenario_path.read_text(encoding="utf-8"))
    errors, drift = preflight(mode, accept_drift, scenario.get("mods"))
    if errors:
        for e in errors:
            print("PREFLIGHT", e)
        return 2
    try:
        lock.acquire(scenario_name, mode)
    except lock.Refused as e:
        print("REFUSED", e)
        return lock.EXIT_REFUSED
    try:
        return _run(scenario_path, scenario_name, scenario, mode, drift)
    except BaseException as e:
        lock.release(scenario_name, [f"launcher raised {type(e).__name__}: {e}"])
        raise


def _run(scenario_path: Path, scenario_name: str, scenario: dict, mode: str, drift: list[str]) -> int:
    results = RESULTS / f"{time.strftime('%Y%m%d-%H%M%S')}-{scenario_name}-{mode}"
    results.mkdir(parents=True)
    config = gamepaths.real_config()
    config_before = sha(config)
    res_before = env.install_res_snapshot()
    saves_before = saves.snapshot()
    cmd = [sys.executable, "-m", "gamelab.runner", str(scenario_path), str(results), "--mode", mode]
    timeout = scenario.get("timeout", 300) * 3          # fixture passes + the run itself
    timeout = scenario.get("outer_timeout", timeout)   # test hook: kill before the runner's own deadline
    t0 = time.time()
    timed_out = False
    with winproc.ForegroundSampler(game_dir=str(env.GAME.resolve()) if mode == "lab" else None) as fg:
        try:
            done = hidden_desktop.run(cmd, cwd=REPO, timeout=timeout, visible=(mode == "watch"))
            inner_code, stdout, stderr = done.returncode, done.stdout, done.stderr
        except subprocess.TimeoutExpired as e:
            inner_code, stdout, stderr = None, str(e.stdout or ""), f"timeout after {timeout}s"
            timed_out = True
    (results / "runner.out.txt").write_text(f"{stdout}\n--- stderr ---\n{stderr}", encoding="utf-8")
    inner_path = results / "inner.json"
    inner = json.loads(inner_path.read_text(encoding="utf-8")) if inner_path.exists() else {"error": "runner wrote no inner.json"}
    assertions = list(inner.get("assertions", []))

    def outer(name, ok, detail=""):
        assertions.append({"name": name, "ok": bool(ok), "detail": detail})

    outer("user config unchanged", sha(config) == config_before, str(config))
    res_after = env.install_res_snapshot()
    outer("install res/ unchanged", res_after == res_before,
          ", ".join(sorted(k for k in set(res_before) | set(res_after) if res_before.get(k) != res_after.get(k))))
    changed = saves.diff(saves_before, saves.snapshot())
    outer("user saves unchanged", not changed, ", ".join(changed))
    report = fg.report()
    if mode == "lab":
        # every switch is listed; only one the user's own input does not explain invalidates
        outer("focus never left the user's window", not report["unexplained"], json.dumps(report))
        outer("no game-tree window on the input desktop", report["window_scans"] > 0 and not report["game_windows_on_input_desktop"],
              f"{report['window_scans']} scans, leaks {report['game_windows_on_input_desktop']}")
    else:
        # watch: the window is visible and the human may click it, but from launch to the
        # first frame the foreground must never belong to the GameLab tree (no focus steal)
        first = inner.get("first_frame_at")
        stolen = [sw for sw in report["switches"] if sw.get("ours") and (first is None or fg.t0 + sw["t"] < first)]
        outer("foreground never the game tree from launch to first frame", first is not None and not stolen,
              json.dumps({"first_frame_s": round(first - fg.t0, 2) if first else None, "stolen": stolen}))
    failed = [a for a in assertions if not a["ok"]]
    shot_fail = [a for a in failed if a["name"].startswith("shot ")]
    probes_ok = not [a for a in failed if not a["name"].startswith("shot ")]
    if any(a["name"] in INVALIDATING for a in failed) or (shot_fail and probes_ok):
        verdict = "INVALID"
    elif timed_out or inner.get("timeout"):
        verdict = "TIMEOUT"
    elif failed or "error" in inner or inner_code != 0:
        verdict = "FAIL"
    else:
        verdict = "PASS"
    dirty = [f"{a['name']}: {a['detail']}" for a in assertions if a["name"].endswith("exited cleanly") and not a["ok"]]
    if not (results / "inner.json").exists():
        dirty.append("runner wrote no inner.json")
    elif inner.get("partial"):
        dirty.append("runner was killed before it finished (inner.json is partial)")
    teardown = lock.release(results.name, dirty)
    record = {"verdict": verdict, "build_drift": bool(drift), "teardown": teardown, "scenario": scenario_name, "mode": mode, "environment": "gamelab",
              "build": pin_build.live(), "fixture": inner.get("fixture"), "mods": mods_version(),
              "seconds": round(time.time() - t0, 1), "foreground": report, "error": inner.get("error"),
              "assertions": assertions, "live": inner.get("live"), "passes": inner.get("passes"),
              "partial": bool(inner.get("partial")), "menu": inner.get("menu"),
              "boundaries": inner.get("boundaries"), "travel_revision": inner.get("travel_revision"),
              "explore": inner.get("explore")}
    (results / "run.json").write_text(json.dumps(record, indent=1), encoding="utf-8")
    if inner.get("boundaries"):
        (results / "boundaries.md").write_text(boundary_table(inner["boundaries"]), encoding="utf-8")
    for a in assertions:
        print(f"  [{'PASS' if a['ok'] else 'FAIL'}] {a['name']}" + (f"  -- {a['detail']}" if a["detail"] and not a["ok"] else ""))
    if inner.get("error"):
        print("  error:", inner["error"])
    if drift:
        print("  BUILD DRIFT: this run is not comparable to clean runs")
    if not teardown["clean"]:
        print("  dirty teardown:", "; ".join(teardown["reasons"]))
    print(f"{verdict}  {scenario_name} ({mode}) in {record['seconds']}s -> {results.relative_to(REPO)}")
    return {"PASS": 0, "FAIL": 1, "INVALID": 5, "TIMEOUT": 6}[verdict]


def boundary_table(rows: list[dict]) -> str:
    """The run's boundary rows (repro playbook 3.1) as a markdown table."""
    out = ["| boundary | kind | copies | re-initialises | probed | before | after | ok |",
           "|---|---|---|---|---|---|---|---|"]
    for r in rows:
        for c in r["cells"] or [{"path": "-", "rule": "", "before": "", "after": ""}]:
            out.append(f"| {r['name']} | {r['kind']} | {r['copies']} | {r['reinit']} | {c['rule']} `{c['path']}` "
                       f"| `{json.dumps(c['before'])}` | `{json.dumps(c['after'])}` | {'yes' if r['ok'] else 'NO'} |")
    return "\n".join(out) + "\n"

"""python -m gamelab run <scenario> [--mode lab|watch]   (see gamelab/launcher.py)
python -m gamelab list
python -m gamelab reset     # after a refused run: kill lab game processes, wipe scratch
python -m gamelab doctor [--fix] [--confirm-saves] [--smoke]   # fresh clone: is this machine ready (gamelab/doctor.py)"""
import argparse
import sys

from gamelab import launcher


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["doctor"]:
        from gamelab import doctor
        return doctor.main(argv[1:])
    ap = argparse.ArgumentParser(prog="python -m gamelab", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="run one scenario")
    r.add_argument("scenario")
    r.add_argument("--mode", choices=("lab", "watch"), default="watch",
                   help="watch (default, for a human at the keyboard) or lab; programmatic runs always pass --mode lab")
    r.add_argument("--accept-build-drift", action="store_true",
                   help="run despite a build-id mismatch; the run is stamped build_drift")
    sub.add_parser("list", help="list scenarios")
    sub.add_parser("doctor", help="fresh clone: check (--fix) every prerequisite, --confirm-saves")
    sub.add_parser("reset", help="clear a refused state: kill lab game processes, wipe scratch, mark clean")
    a = ap.parse_args(argv)
    if a.cmd == "list":
        for p in sorted(launcher.SCENARIOS.glob("*.json")):
            print(p.stem)
        return 0
    if a.cmd == "reset":
        from gamelab import lock
        return lock.reset()
    return launcher.run(a.scenario, a.mode, a.accept_build_drift)


if __name__ == "__main__":
    sys.exit(main())

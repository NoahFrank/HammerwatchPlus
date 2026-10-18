#!/usr/bin/env python3
"""
release.py - build the player packages from a clean checkout and publish them as a GitHub release.

    release.py 0.2.0                  # dry run: build v0.2.0 from HEAD into dist/release/v0.2.0/
    release.py 0.2.0 --publish        # ...and create the GitHub release as a draft (review, then Publish)
    release.py 0.2.0 --publish --no-draft      # publish at once
    release.py 0.2.0 --ref <commit> --prerelease

The packages are built from the files committed at the ref only (a temporary `git worktree`),
so uncommitted edits and everything generated from the player's own installs stay out. The
one thing a release takes from outside the commit is the HoH2 base in gamecode/sdk/hoh2/
(HWP_GAMECODE points the checkout at this repo's): tools/class_units.py makes the
class-swapped base units from it, tools/make_pet_dyes.py the vanilla pets' dye copies. Any
other untracked file under mods/ after the build, or a committed file the build rewrote,
stops the release.

Refuses (exit 1) when the version is not X.Y.Z[-suffix], the tag already exists, gamecode/ is
missing, the installed game is not the pinned build (tools/pin_build.py --show), or
`build.py --check` finds override problems; with --publish also when the ref is not on
<remote>/main or the release already exists. --publish needs the GitHub CLI (`gh auth login`)
and an account that can create releases on the remote's repo (default remote: origin).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build  # noqa: E402
import class_units  # noqa: E402
import hwr_archive as hwr  # noqa: E402
import gamepaths as paths  # noqa: E402

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$")
DYE_DIR = "mods/pets/players/pets/hwp/dye/"


def run(cmd: list[str], cwd: Path = paths.REPO, env=None, check: bool = True) -> subprocess.CompletedProcess:
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if check and r.returncode != 0:
        sys.exit(f"failed ({r.returncode}): {' '.join(cmd)}\n{(r.stdout + r.stderr).strip()}")
    return r


def git(*args: str, cwd: Path = paths.REPO, check: bool = True) -> str:
    return run(["git", *args], cwd=cwd, check=check).stdout.strip()


def github_repo(remote: str) -> str:
    url = git("remote", "get-url", remote)
    m = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?/?$", url)
    if not m:
        sys.exit(f"remote {remote} is not a GitHub repo: {url}")
    return m.group(1)


def preflight(args) -> tuple[str, str, dict]:
    """-> (tag, commit sha, build pin); exits on anything that makes the release wrong"""
    if not VERSION_RE.match(args.version):
        sys.exit(f"version {args.version!r}: want X.Y.Z or X.Y.Z-suffix (no leading v)")
    tag = "v" + args.version
    sha = git("rev-parse", "--verify", f"{args.ref}^{{commit}}")
    if git("tag", "--list", tag):
        sys.exit(f"tag {tag} already exists here")
    if not paths.BASE_HOH2.is_dir():
        sys.exit(f"{paths.BASE_HOH2} missing: run `python -m gamelab doctor --fix` (or tools/bootstrap.py)")
    pin = run([sys.executable, str(paths.TOOLS / "pin_build.py"), "--show"], check=False)
    if pin.returncode != 0:
        sys.exit(f"installed game is not the pinned build; re-dump and re-pin first (tools/pin_build.py)\n{pin.stdout.strip()}")
    if args.publish:
        if shutil.which("gh") is None:
            sys.exit("--publish needs the GitHub CLI (gh)")
        git("fetch", args.remote, "main")
        if run(["git", "merge-base", "--is-ancestor", sha, f"{args.remote}/main"], check=False).returncode != 0:
            sys.exit(f"{sha[:10]} is not on {args.remote}/main: merge it first, releases come from main")
        repo = github_repo(args.remote)
        if run(["gh", "release", "view", tag, "--repo", repo], check=False).returncode == 0:
            sys.exit(f"release {tag} already exists on {repo}")
        if git("ls-remote", "--tags", args.remote, f"refs/tags/{tag}"):
            sys.exit(f"tag {tag} already exists on {args.remote}")
    return tag, sha, json.loads((paths.GAMELAB / "build_id.json").read_text(encoding="utf-8"))


def allowed_untracked(wt: Path) -> set[str]:
    """the repo-relative files the build may make from the HoH2 base: class-swapped units"""
    out = set()
    for d in sorted((wt / "mods").iterdir()):
        cfg_path = d / "module.json"
        if not cfg_path.is_file():
            continue
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
        out |= {f"mods/{d.name}/{rel}" for rel in class_units.units_for(cfg.get("class_swaps") or {})}
    return out


def check_checkout(wt: Path) -> None:
    """everything under mods/ the build left behind is committed or made from the HoH2 base"""
    changed = git("status", "--porcelain", "--untracked-files=no", cwd=wt)
    if changed:
        sys.exit(f"the build rewrote committed files (commit the regenerated versions first):\n{changed}")
    allowed = allowed_untracked(wt)
    bad = []
    for rel in git("ls-files", "--others", "--", "mods", cwd=wt).splitlines():
        name = rel.rsplit("/", 1)[-1]
        if rel in allowed or name.startswith("."):
            continue
        if rel.startswith(DYE_DIR) and not name.startswith("hwp_"):  # vanilla pets' dyes (make_pet_dyes.py)
            continue
        bad.append(rel)
    if bad:
        sys.exit(f"{len(bad)} untracked file(s) in the release checkout that the release must not ship "
                 f"(first: {', '.join(bad[:5])})")


def build_in_checkout(sha: str, out_dir: Path) -> tuple[list[Path], dict[str, dict]]:
    tmp = Path(tempfile.mkdtemp(prefix="hwp-release-"))
    wt = tmp / "src"
    git("worktree", "add", "--detach", str(wt), sha)
    try:
        env = dict(os.environ, HWP_GAMECODE=str(paths.GAMECODE))
        tools = wt / "tools"
        print(run([sys.executable, str(tools / "build.py"), "--check"], cwd=wt, env=env).stdout.strip())
        print(run([sys.executable, str(tools / "build.py")], cwd=wt, env=env).stdout.strip())
        check_checkout(wt)
        if out_dir.exists():
            shutil.rmtree(out_dir)
        out_dir.mkdir(parents=True)
        packages = []
        for p in sorted((wt / "dist").glob("*.bin")):
            packages.append(Path(shutil.copy2(p, out_dir / p.name)))
        modules = {d.name: hwr.read_info_xml(d) for d in sorted((wt / "mods").iterdir())
                   if (out_dir / f"{build.PACKAGE_PREFIX}{d.name}.bin").is_file()}
        return packages, modules
    finally:
        git("worktree", "remove", "--force", str(wt), check=False)
        shutil.rmtree(tmp, ignore_errors=True)
        git("worktree", "prune", check=False)


def write_sums(out_dir: Path, packages: list[Path]) -> Path:
    sums = out_dir / "SHA256SUMS.txt"
    sums.write_text("".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in packages),
                    encoding="utf-8", newline="\n")
    return sums


def write_notes(out_dir: Path, tag: str, sha: str, pin: dict, modules: dict) -> Path:
    rows = "\n".join(f"| `{build.PACKAGE_PREFIX}{mid}.bin` | {meta.get('name', mid)} | {meta.get('description', '')} |"
                     for mid, meta in modules.items())
    text = f"""HammerwatchPlus {tag}, built from `{sha[:10]}` for Heroes of Hammerwatch II \
{pin.get('game_version', '?')} (Steam build {pin.get('build_id', '?')}).

## Installing
1. Download `{build.ALL_NAME}.bin` (every module), or `{build.PACKAGE_PREFIX}core.bin` plus the \
`{build.PACKAGE_PREFIX}<module>.bin` files you want. Every module needs core.
2. Drop them into `<Steam>/steamapps/common/Heroes of Hammerwatch 2/mods/`. Remove older \
HammerwatchPlus `.bin` files.
3. Start the game, open **Resource Mods** and enable them. Everyone in the lobby runs the same \
version of the same modules.
4. In game, open the console (the key left of 1) and type `hwp help`.

Content from Heroes of Hammerwatch 1 (the HoH1 pets, the real HoH1 rooms of the Forsaken Tower) \
is not in these packages: it is imported from your own HoH1 install, see the README.

`SHA256SUMS.txt` lists each file's SHA-256.

## Packages
| File | Module | What it does |
|---|---|---|
| `{build.ALL_NAME}.bin` | HammerwatchPlus | All of the below in one package. |
{rows}
"""
    notes = out_dir / "NOTES.md"
    notes.write_text(text, encoding="utf-8", newline="\n")
    return notes


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("version", help="X.Y.Z (tagged vX.Y.Z)")
    ap.add_argument("--ref", default="HEAD", help="commit to release (default HEAD)")
    ap.add_argument("--remote", default="origin", help="git remote whose GitHub repo gets the release")
    ap.add_argument("--publish", action="store_true", help="create the GitHub release (default: build only)")
    ap.add_argument("--no-draft", action="store_true", help="with --publish: publish at once, not as a draft")
    ap.add_argument("--prerelease", action="store_true", help="mark the release a pre-release")
    args = ap.parse_args(argv)

    tag, sha, pin = preflight(args)
    out_dir = paths.DIST / "release" / tag
    print(f"building {tag} from {sha[:10]} in a clean checkout")
    packages, modules = build_in_checkout(sha, out_dir)
    sums = write_sums(out_dir, packages)
    notes = write_notes(out_dir, tag, sha, pin, modules)
    print(f"{len(packages)} packages, {sums.name}, {notes.name} -> {out_dir.relative_to(paths.REPO)}")
    if not args.publish:
        print(f"dry run: nothing published. Publish with: python tools/release.py {args.version} --publish"
              + (f" --ref {sha}" if args.ref != "HEAD" else ""))
        return 0

    repo = github_repo(args.remote)
    cmd = ["gh", "release", "create", tag, *map(str, packages), str(sums), "--repo", repo, "--target", sha,
           "--title", f"HammerwatchPlus {tag}", "--notes", notes.read_text(encoding="utf-8"), "--generate-notes"]
    if not args.no_draft:
        cmd.append("--draft")
    if args.prerelease:
        cmd.append("--prerelease")
    url = run(cmd).stdout.strip()
    print(f"{'draft ' if not args.no_draft else ''}release {tag} on {repo}: {url}")
    if not args.no_draft:
        print("review it on GitHub and press Publish (the tag is made then)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

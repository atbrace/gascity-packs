#!/usr/bin/env python3
"""Detect packs whose shipped bytes no longer match their source of truth.

`validate_registry.py` proves a release entry is *internally* consistent: the
recorded hash matches the pack content at the recorded commit. It cannot see a
release that is merely *old*. A pin that is stale but self-consistent passes
validation silently, so a merged pack fix keeps sitting in git while every
consumer keeps materializing the previously released bytes.

That is a silent no-op for the one class of change where silence is worst —
merge guards, halt conditions, verify gates. This module closes the gap with
four checks:

release-drift
    Pack content at the target ref differs from the newest published
    `[[pack.release]]` hash. The release needs re-stamping before consumers
    can see the change.

city-import-stale
    A city's `[imports.<pack>] version = "sha:..."` pin lags the newest
    published release commit, so the city materializes older pack bytes.

city-import-foreign-origin
    A city resolves a pack from a different repository than the one this pack
    repo pushes to. This is the failure no pin or release can express: the
    merge lands here, the city reads there, and both look internally current.
    Re-stamping cannot fix it — the bytes are published where nobody reads.

city-fork-stale / city-fork-unanchored
    A city shadows a pack formula with a local copy under `<city>/formulas/`.
    The sibling `.<name>.forkbase` file records the upstream file hash the
    fork was taken from. When upstream moves past that anchor the override
    silently swallows the newer version; with no anchor at all the fork
    cannot be reconciled with upstream by any mechanical means.

Run with `--changed-since <ref>` to gate CI on the packs a change actually
touches, leaving pre-existing drift visible as a warning instead of failing
unrelated work.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass, asdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import validate_registry  # noqa: E402  (needs REPO_ROOT on sys.path)

SHA_PIN_RE = re.compile(r"^sha:([0-9a-f]{40})$")


def repo_slug(url: str) -> str | None:
    """`owner/repo` for a git remote URL or a GitHub tree/blob URL, else None."""
    if not url:
        return None
    path = url.split("://", 1)[-1].split("@", 1)[-1]
    if "://" not in url:
        path = path.replace(":", "/", 1)  # scp-style git@host:owner/repo
    parts = [p for p in path.split("/") if p]
    if len(parts) < 3:  # need host, owner, repo
        return None
    owner, repo = parts[1], parts[2].removesuffix(".git")
    return f"{owner}/{repo}" if owner and repo else None


def origin_slug(root: Path) -> str | None:
    """`owner/repo` of the remote this pack repository pushes to, else None."""
    out = subprocess.run(
        ["git", "-C", str(root), "remote", "get-url", "origin"],
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0:
        return None
    return repo_slug(out.stdout.strip())


@dataclass(frozen=True)
class Finding:
    kind: str
    pack: str
    detail: str
    fatal: bool


def pack_content_hash(root: Path, commit: str, pack_path: str) -> str | None:
    """Canonical pack content hash — the same scheme registry releases record."""
    return validate_registry.git_pack_content_hash(root, commit, pack_path)


def latest_release(pack: dict) -> dict | None:
    """Newest release entry, i.e. the one consumers resolve by default."""
    releases = pack.get("release", [])
    if not isinstance(releases, list) or not releases:
        return None
    return releases[-1]


def registry_packs(registry_path: Path) -> list[tuple[str, str, dict]]:
    """Yield (name, pack_path, pack) for registry entries with a local path."""
    with registry_path.open("rb") as handle:
        data = tomllib.load(handle)
    packs = []
    for pack in data.get("pack", []):
        name = pack.get("name", "")
        pack_path = validate_registry.source_pack_path(pack.get("source", ""))
        if name and pack_path:
            packs.append((name, pack_path, pack))
    return packs


def changed_paths(root: Path, base: str, ref: str) -> set[str]:
    """Files changed on `ref` since it diverged from `base`."""
    out = subprocess.run(
        ["git", "-C", str(root), "diff", "--name-only", f"{base}...{ref}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0:
        raise SystemExit(f"could not diff {base}...{ref}: {out.stderr.strip()}")
    return {line for line in out.stdout.splitlines() if line}


def _touched(pack_path: str, paths: set[str]) -> bool:
    prefix = pack_path + "/"
    return any(p.startswith(prefix) for p in paths)


def check_release_drift(
    root: Path,
    registry_path: Path,
    ref: str = "HEAD",
    changed_since: str | None = None,
) -> list[Finding]:
    """Compare each pack's content at `ref` against its newest release hash."""
    touched = changed_paths(root, changed_since, ref) if changed_since else None
    findings: list[Finding] = []
    for name, pack_path, pack in registry_packs(registry_path):
        release = latest_release(pack)
        if release is None:
            continue
        current = pack_content_hash(root, ref, pack_path)
        if current is None or current == release.get("hash", ""):
            continue
        fatal = touched is None or _touched(pack_path, touched)
        findings.append(
            Finding(
                kind="release-drift",
                pack=name,
                fatal=fatal,
                detail=(
                    f"{pack_path}/ content at {ref} does not match published release "
                    f"{release.get('version', '?')}\n"
                    f"      released hash: {release.get('hash', '?')} (commit "
                    f"{release.get('commit', '?')[:12]})\n"
                    f"      current hash:  {current}\n"
                    f"      consumers resolving {name} still receive the released bytes.\n"
                    f"      re-stamp with: make registry-publish PACK={name} "
                    f'VERSION=<next> DESCRIPTION="..."'
                ),
            )
        )
    return findings


def _upstream_formula_hash(root: Path, ref: str, pack_path: str, stem: str) -> str | None:
    """sha256 of a pack's formula file at `ref`, or None when absent."""
    obj = f"{ref}:{pack_path}/formulas/{stem}.toml"
    if not validate_registry.git_object_exists(root, obj):
        return None
    blob = validate_registry.git_bytes(root, "cat-file", "blob", obj)
    return hashlib.sha256(blob).hexdigest()


def check_city_drift(
    root: Path,
    city: Path,
    registry_path: Path,
    ref: str = "HEAD",
) -> list[Finding]:
    """Compare a city's import pins and formula overrides against the packs."""
    packs = registry_packs(registry_path)
    findings: list[Finding] = []

    city_pack = city / "pack.toml"
    if city_pack.exists():
        with city_pack.open("rb") as handle:
            imports = tomllib.load(handle).get("imports", {})
        by_name = {name: (pack_path, pack) for name, pack_path, pack in packs}
        pushes_to = origin_slug(root)
        for import_name, spec in imports.items():
            if import_name not in by_name or not isinstance(spec, dict):
                continue
            resolves = repo_slug(str(spec.get("source", "")))
            if pushes_to and resolves and resolves != pushes_to:
                findings.append(
                    Finding(
                        kind="city-import-foreign-origin",
                        pack=import_name,
                        fatal=True,
                        detail=(
                            f"{city_pack} resolves {import_name} from {resolves}, but this "
                            f"pack repository pushes to {pushes_to}\n"
                            f"      merges landing here never reach that city, whatever the pin says.\n"
                            f"      re-stamping a release cannot fix this: the bytes are published\n"
                            f"      to a repository the city does not read.\n"
                            f"      point the import at {pushes_to}, or push releases to {resolves}."
                        ),
                    )
                )
            pin = SHA_PIN_RE.match(str(spec.get("version", "")))
            release = latest_release(by_name[import_name][1])
            if pin is None or release is None:
                continue
            released = release.get("commit", "")
            if pin.group(1) == released:
                continue
            findings.append(
                Finding(
                    kind="city-import-stale",
                    pack=import_name,
                    fatal=True,
                    detail=(
                        f"{city_pack} pins {import_name} at {pin.group(1)[:12]} but the "
                        f"newest release {release.get('version', '?')} is {released[:12]}\n"
                        f"      this city materializes older {import_name} bytes."
                    ),
                )
            )

    formulas_dir = city / "formulas"
    if not formulas_dir.is_dir():
        return findings
    for entry in sorted(formulas_dir.iterdir()):
        if entry.is_symlink() or entry.suffix != ".toml" or not entry.is_file():
            continue
        stem = entry.stem
        upstream = next(
            (
                (name, pack_path, digest)
                for name, pack_path, _ in packs
                if (digest := _upstream_formula_hash(root, ref, pack_path, stem)) is not None
            ),
            None,
        )
        if upstream is None:
            continue  # city-local formula, nothing upstream to drift from
        name, pack_path, current = upstream
        anchor = formulas_dir / f".{stem}.forkbase"
        if not anchor.exists():
            findings.append(
                Finding(
                    kind="city-fork-unanchored",
                    pack=name,
                    fatal=True,
                    detail=(
                        f"{entry} shadows {pack_path}/formulas/{stem}.toml with no "
                        f".{stem}.forkbase anchor\n"
                        f"      upstream changes to this formula cannot be detected.\n"
                        f"      record the base it was forked from:\n"
                        f"        git show {ref}:{pack_path}/formulas/{stem}.toml | "
                        f"shasum -a 256 | cut -d' ' -f1 > {anchor}"
                    ),
                )
            )
            continue
        recorded = anchor.read_text(encoding="utf-8").strip()
        if recorded == current:
            continue
        findings.append(
            Finding(
                kind="city-fork-stale",
                pack=name,
                fatal=True,
                detail=(
                    f"{entry} was forked from {pack_path}/formulas/{stem}.toml at "
                    f"{recorded[:12]}, but upstream is now {current[:12]}\n"
                    f"      this override silently shadows the newer upstream formula.\n"
                    f"      reconcile, then refresh the anchor:\n"
                    f"        git diff {recorded} -- {pack_path}/formulas/{stem}.toml"
                ),
            )
        )
    return findings


def render(findings: list[Finding]) -> str:
    if not findings:
        return "pack drift: ok"
    lines = [f"pack drift: {len(findings)} finding(s)"]
    for f in findings:
        label = "FATAL  " if f.fatal else "warning"
        lines.append(f"  {label} {f.kind} [{f.pack}]: {f.detail}")
    fatal = sum(1 for f in findings if f.fatal)
    if fatal:
        lines.append(f"\n{fatal} fatal finding(s): merged pack changes are not reaching consumers.")
    else:
        lines.append("\nno fatal findings (pre-existing drift outside this change).")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="pack repository root")
    parser.add_argument("--registry", type=Path, help="registry path (default: <root>/registry.toml)")
    parser.add_argument("--ref", default="HEAD", help="git ref to treat as current pack content")
    parser.add_argument(
        "--changed-since",
        help="only fail for packs changed since this ref; report other drift as a warning",
    )
    parser.add_argument("--city", type=Path, help="also check this city's pins and formula overrides")
    parser.add_argument("--json", action="store_true", help="emit machine-readable output")
    args = parser.parse_args(argv)

    root = args.root.resolve()
    registry = args.registry or root / "registry.toml"

    findings = check_release_drift(root, registry, args.ref, args.changed_since)
    if args.city:
        findings += check_city_drift(root, args.city, registry, args.ref)

    if args.json:
        print(
            json.dumps(
                {"ok": not any(f.fatal for f in findings), "findings": [asdict(f) for f in findings]},
                indent=2,
            )
        )
    else:
        print(render(findings))
    return 1 if any(f.fatal for f in findings) else 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Verify, or with ``--fix`` refresh, each pinned release-asset sha256 in this repo's workflows.

A workflow that downloads a release binary pins it by version and by the asset's sha256. The
``# renovate:`` annotation lets Renovate bump the ``*_VERSION`` line, but Renovate cannot bump
the ``*_SHA256`` line: the ``github-releases`` datasource gives the tag's commit digest, not the
asset's file checksum. GitHub publishes a SHA-256 for each release asset (the ``digest`` field),
so this script reads that digest and compares it with the pinned ``*_SHA256``.

Two modes:

* verify (default): a stale hash fails, and the script prints the correct value. It never
  changes the tree.
* ``--fix``: a stale hash is rewritten in the workflow file from GitHub's published digest.
  The self-hosted Renovate runs this as a ``postUpgradeTask`` on a version bump, so the new
  hash lands in the same commit as the bump.

Both modes fail closed: if a pin cannot be fetched, found or parsed, the exit code is 1.

The script is stdlib-only, so a bare ``python3`` with no venv runs it. This is what the
Renovate ``postUpgradeTask`` gets.

Exit codes: ``0`` every pin verified (or, with ``--fix``, is now reconciled), or GitHub
publishes no digest for an asset; ``1`` a pin disagrees with GitHub's digest (verify mode), or a
pin could not be verified.

Adapted from clauster's ``scripts/check_binary_dep_pins.py``, without its ``deps.py`` part.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class _WorkflowPin:
    """One ``*_VERSION`` + ``*_SHA256`` release-asset pin in a workflow file.

    ``tag`` gives the release tag for the pinned version and ``asset`` gives the downloaded
    asset's name, so both follow a version bump.
    """

    path: str  # workflow file, relative to the repo root
    owner: str
    repo: str
    version_re: re.Pattern[str]  # one capture group: the pinned version value
    sha_re: re.Pattern[str]  # one capture group: the current 64-hex sha256 (the rewrite target)
    tag: Callable[[str], str]  # version -> release tag (e.g. "2.6.0" -> "v2.6.0")
    asset: Callable[[str], str]  # version -> downloaded asset name


_WORKFLOW_PINS: tuple[_WorkflowPin, ...] = (
    # lint.yml downloads the linux amd64 tarball, whose name holds the version. The version is
    # bare (e.g. "2.6.0") and the release tags have a "v" prefix (e.g. "v2.6.0").
    _WorkflowPin(
        path=".github/workflows/lint.yml",
        owner="jdx",
        repo="jactionlint",
        version_re=re.compile(r'JACTIONLINT_VERSION:\s*"([^"]+)"'),
        sha_re=re.compile(r'JACTIONLINT_SHA256:\s*"([0-9a-f]{64})"'),
        tag=lambda v: f"v{v}",
        asset=lambda v: f"jactionlint_{v}_linux_amd64.tar.gz",
    ),
)


def _fetch_release(owner: str, repo: str, tag: str) -> dict:
    """Return the GitHub release JSON for ``owner/repo`` at ``tag`` (raises on failure)."""
    api = f"https://api.github.com/repos/{owner}/{repo}/releases/tags/{tag}"
    # Fixed https://api.github.com host. owner, repo and tag come from _WORKFLOW_PINS.
    req = urllib.request.Request(api, headers={"Accept": "application/vnd.github+json"})
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def _find_asset(release: dict, asset_name: str) -> dict | None:
    """Return the release asset object named ``asset_name``, or None if the release has none."""
    for asset in release.get("assets", []):
        if isinstance(asset, dict) and asset.get("name") == asset_name:
            return asset
    return None


def _resolve_digest(
    owner: str, repo: str, tag: str, asset: str, current_sha: str
) -> tuple[str, str | None]:
    """Compare one release asset's published digest with ``current_sha``.

    Returns ``(status, value)``. ``status`` is one of:

    * ``"ok"``: the pin matches. ``value`` is ``None``.
    * ``"mismatch"``: the pin is stale. ``value`` is the correct sha256.
    * ``"warn"``: the asset exists, but GitHub publishes no sha256. ``value`` is a reason.
    * ``"error"``: the asset could not be fetched or found, or GitHub published a malformed
      digest. ``value`` is the failure detail.
    """
    try:
        release = _fetch_release(owner, repo, tag)
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        return "error", f"could not fetch {owner}/{repo}@{tag} to verify: {exc}"
    asset_obj = _find_asset(release, asset)
    if asset_obj is None:
        names = ", ".join(
            a.get("name", "?") for a in release.get("assets", []) if isinstance(a, dict)
        )
        return "error", f"release {tag} has no asset named {asset} (has: {names})"
    digest = asset_obj.get("digest")
    if not (isinstance(digest, str) and digest.startswith("sha256:")):
        return "warn", f"GitHub publishes no sha256 for {asset}, pinned {current_sha}"
    published = digest.removeprefix("sha256:")
    if re.fullmatch(r"[0-9a-f]{64}", published) is None:
        # A malformed digest is not a new pin: writing it would replace a good hash with a value
        # that always fails the sha256sum -c step. Refuse it.
        return "error", f"GitHub published a malformed sha256 for {asset}: {digest!r}"
    if published == current_sha:
        return "ok", None
    return "mismatch", published


def _repo_root() -> Path:
    """Return the repository root (this script lives in ``<root>/scripts/``)."""
    return Path(__file__).resolve().parent.parent


def _resolve_workflow_pin(pin: _WorkflowPin, root: Path) -> tuple[str, str | None, str | None]:
    """Resolve one workflow pin. Return ``(status, value, current_sha)``.

    A missing or unparseable VERSION or SHA256 line is an ``"error"``: the pin exists to be
    verified, so a pin that the regex cannot read must never pass.
    """
    path = root / pin.path
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return "error", f"could not read {pin.path}: {exc}", None
    vmatch = pin.version_re.search(text)
    smatch = pin.sha_re.search(text)
    if vmatch is None or smatch is None:
        return "error", f"could not find the VERSION/SHA256 pin in {pin.path}", None
    version, current_sha = vmatch.group(1), smatch.group(1)
    status, value = _resolve_digest(
        pin.owner, pin.repo, pin.tag(version), pin.asset(version), current_sha
    )
    return status, value, current_sha


def _missing_pins(text: str, path_name: str, replacements: dict[str, str]) -> list[str]:
    """Return a note for each ``old`` sha256 absent from ``text`` (an empty list means all ok)."""
    return [
        f"could not locate sha256 {old} in {path_name} to rewrite"
        for old in replacements
        if text.count(old) == 0
    ]


def _apply_fixes(path: Path, replacements: dict[str, str]) -> list[str]:
    """Rewrite each stale ``old`` sha256 to its ``new`` value in ``path``. Return failure notes.

    All or nothing: if any ``old`` value is missing, the file stays untouched.
    """
    text = path.read_text(encoding="utf-8")
    notes = _missing_pins(text, path.name, replacements)
    if notes:
        return notes
    for old, new in replacements.items():
        text = text.replace(old, new)
    if replacements:
        path.write_text(text, encoding="utf-8")
    return notes


def main(argv: list[str] | None = None) -> int:
    """Verify (or, with ``--fix``, refresh) every pinned sha256 against GitHub's digest."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fix",
        action="store_true",
        help="rewrite a stale sha256 in place from GitHub's published digest (postUpgradeTask)",
    )
    args = parser.parse_args(argv)

    failures = 0
    # Path -> {old sha256: new sha256}, one entry for each workflow file.
    fixes: dict[Path, dict[str, str]] = {}

    root = _repo_root()
    for pin in _WORKFLOW_PINS:
        status, value, current_sha = _resolve_workflow_pin(pin, root)
        if status == "error":
            print(f"FAIL {pin.path}: {value}")
            failures += 1
        elif status == "warn":
            print(f"WARN {pin.path}: {value}")
        elif status == "ok":
            print(f"OK   {pin.path}: sha256 matches GitHub's published digest")
        elif value is not None and current_sha is not None:  # mismatch
            if args.fix:
                fixes.setdefault(root / pin.path, {})[current_sha] = value
                print(f"FIX  {pin.path}: sha256\n       was:  {current_sha}\n       now:  {value}")
            else:
                print(
                    f"FAIL {pin.path}: sha256 mismatch\n"
                    f"       pinned:    {current_sha}\n"
                    f"       published: {value}   <- update the *_SHA256 in this workflow to this"
                )
                failures += 1

    total = sum(len(repl) for repl in fixes.values())
    if args.fix and fixes and not failures:
        # Change the tree only when every pin verified. Find every pin in every file before
        # writing any, so a failure in one file leaves all files untouched.
        notes = [
            note
            for path, repl in fixes.items()
            for note in _missing_pins(path.read_text(encoding="utf-8"), path.name, repl)
        ]
        if notes:
            for note in notes:
                print(f"FAIL {note}")
                failures += 1
        else:
            for path, repl in fixes.items():
                for note in _apply_fixes(path, repl):
                    print(f"FAIL {note}")
                    failures += 1
            if not failures:
                print(f"wrote {total} refreshed sha256 pin(s)")
    elif args.fix and fixes:
        print(
            f"SKIP not rewriting {total} stale pin(s): "
            f"{failures} pin(s) could not be verified, refusing a partial fix"
        )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

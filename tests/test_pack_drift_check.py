from __future__ import annotations

import hashlib
import subprocess
import textwrap

from scripts import pack_drift_check

_PACK_TOML = b'[pack]\nname = "gastown"\nschema = 2\n'
_FORMULA_V1 = b"# formula v1\n"
_FORMULA_V2 = b"# formula v2 with the merge guard\n"


def run_git(root, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def _init_repo(root) -> None:
    run_git(root, "init")
    run_git(root, "config", "user.email", "test@example.com")
    run_git(root, "config", "user.name", "Test User")


def _commit_pack(root, formula_bytes: bytes, message: str) -> str:
    formulas = root / "gastown" / "formulas"
    formulas.mkdir(parents=True, exist_ok=True)
    (root / "gastown" / "pack.toml").write_bytes(_PACK_TOML)
    (formulas / "mol-refinery-patrol.toml").write_bytes(formula_bytes)
    run_git(root, "add", "gastown")
    run_git(root, "commit", "-m", message)
    return run_git(root, "rev-parse", "HEAD")


def _write_registry(root, commit: str, content_hash: str) -> None:
    (root / "registry.toml").write_text(
        textwrap.dedent(
            f"""\
            schema = 1

            [[pack]]
            name = "gastown"
            description = "Default Gas Town coding workflow pack."
            source = "https://github.com/gastownhall/gascity-packs/tree/main/gastown"
            source_kind = "git"

              [[pack.release]]
              version = "0.1.0"
              ref = "main"
              commit = "{commit}"
              hash = "{content_hash}"
              description = "Release."
            """
        ),
        encoding="utf-8",
    )


def _pack_hash(root, commit: str) -> str:
    return pack_drift_check.pack_content_hash(root, commit, "gastown")


def _repo_pinned_at_head(tmp_path):
    """Repo with one pack whose registry release matches HEAD exactly."""
    _init_repo(tmp_path)
    commit = _commit_pack(tmp_path, _FORMULA_V1, "add gastown")
    _write_registry(tmp_path, commit, _pack_hash(tmp_path, commit))
    return commit


def _repo_drifted(tmp_path):
    """Repo whose pack content moved one commit past its registry release."""
    pinned = _repo_pinned_at_head(tmp_path)
    head = _commit_pack(tmp_path, _FORMULA_V2, "fix(gastown): add merge guard")
    return pinned, head


# --- release drift -------------------------------------------------------


def test_no_release_drift_when_release_matches_head(tmp_path) -> None:
    _repo_pinned_at_head(tmp_path)
    findings = pack_drift_check.check_release_drift(tmp_path, tmp_path / "registry.toml", "HEAD")
    assert findings == []


def test_release_drift_detected_when_content_moves_past_pin(tmp_path) -> None:
    _repo_drifted(tmp_path)
    findings = pack_drift_check.check_release_drift(tmp_path, tmp_path / "registry.toml", "HEAD")
    assert [f.kind for f in findings] == ["release-drift"]
    assert findings[0].pack == "gastown"
    assert findings[0].fatal is True


def test_release_drift_reports_both_hashes(tmp_path) -> None:
    pinned, head = _repo_drifted(tmp_path)
    findings = pack_drift_check.check_release_drift(tmp_path, tmp_path / "registry.toml", "HEAD")
    detail = findings[0].detail
    assert _pack_hash(tmp_path, pinned) in detail
    assert _pack_hash(tmp_path, head) in detail


def test_changed_since_keeps_touched_pack_fatal(tmp_path) -> None:
    pinned, _ = _repo_drifted(tmp_path)
    findings = pack_drift_check.check_release_drift(
        tmp_path, tmp_path / "registry.toml", "HEAD", changed_since=pinned
    )
    assert [f.fatal for f in findings] == [True]


def test_changed_since_downgrades_untouched_pack_to_warning(tmp_path) -> None:
    """Pre-existing drift in a pack this diff did not touch must not fail CI."""
    _, head = _repo_drifted(tmp_path)
    (tmp_path / "README.md").write_text("unrelated\n", encoding="utf-8")
    run_git(tmp_path, "add", "README.md")
    run_git(tmp_path, "commit", "-m", "docs: unrelated change")
    findings = pack_drift_check.check_release_drift(
        tmp_path, tmp_path / "registry.toml", "HEAD", changed_since=head
    )
    assert [f.kind for f in findings] == ["release-drift"]
    assert findings[0].fatal is False


# --- city drift ----------------------------------------------------------


def _write_city(tmp_path, *, forkbase: str | None, import_sha: str | None):
    city = tmp_path / "city"
    (city / "formulas").mkdir(parents=True)
    (city / "formulas" / "mol-refinery-patrol.toml").write_bytes(b"# locally forked\n")
    if forkbase is not None:
        (city / "formulas" / ".mol-refinery-patrol.forkbase").write_text(forkbase + "\n", encoding="utf-8")
    imports = ""
    if import_sha is not None:
        imports = textwrap.dedent(
            f"""\
            [imports.gastown]
            source = "https://github.com/gastownhall/gascity-packs/tree/main/gastown"
            version = "sha:{import_sha}"
            """
        )
    (city / "pack.toml").write_text(
        '[pack]\nname = "gc"\nschema = 2\n\n' + imports, encoding="utf-8"
    )
    return city


def test_city_fork_current_when_forkbase_matches_head(tmp_path) -> None:
    _repo_pinned_at_head(tmp_path)
    current = hashlib.sha256(_FORMULA_V1).hexdigest()
    city = _write_city(tmp_path, forkbase=current, import_sha=None)
    findings = pack_drift_check.check_city_drift(tmp_path, city, tmp_path / "registry.toml", "HEAD")
    assert findings == []


def test_city_fork_stale_when_upstream_moved_past_forkbase(tmp_path) -> None:
    """The gcp-di8 failure: a city override silently shadows newer pack bytes."""
    _repo_drifted(tmp_path)
    stale = hashlib.sha256(_FORMULA_V1).hexdigest()
    city = _write_city(tmp_path, forkbase=stale, import_sha=None)
    findings = pack_drift_check.check_city_drift(tmp_path, city, tmp_path / "registry.toml", "HEAD")
    assert [f.kind for f in findings] == ["city-fork-stale"]
    assert findings[0].fatal is True
    assert "mol-refinery-patrol" in findings[0].detail


def test_city_fork_without_forkbase_is_unanchored(tmp_path) -> None:
    _repo_pinned_at_head(tmp_path)
    city = _write_city(tmp_path, forkbase=None, import_sha=None)
    findings = pack_drift_check.check_city_drift(tmp_path, city, tmp_path / "registry.toml", "HEAD")
    assert [f.kind for f in findings] == ["city-fork-unanchored"]
    assert findings[0].fatal is True


def test_city_import_pin_behind_latest_release(tmp_path) -> None:
    pinned, _ = _repo_drifted(tmp_path)
    _write_registry(tmp_path, run_git(tmp_path, "rev-parse", "HEAD"), _pack_hash(tmp_path, "HEAD"))
    current = hashlib.sha256(_FORMULA_V2).hexdigest()
    city = _write_city(tmp_path, forkbase=current, import_sha=pinned)
    findings = pack_drift_check.check_city_drift(tmp_path, city, tmp_path / "registry.toml", "HEAD")
    assert [f.kind for f in findings] == ["city-import-stale"]
    assert pinned[:12] in findings[0].detail


def test_city_import_pin_matching_latest_release_is_clean(tmp_path) -> None:
    _repo_pinned_at_head(tmp_path)
    head = run_git(tmp_path, "rev-parse", "HEAD")
    current = hashlib.sha256(_FORMULA_V1).hexdigest()
    city = _write_city(tmp_path, forkbase=current, import_sha=head)
    findings = pack_drift_check.check_city_drift(tmp_path, city, tmp_path / "registry.toml", "HEAD")
    assert findings == []


def test_city_backup_and_symlink_entries_are_ignored(tmp_path) -> None:
    _repo_pinned_at_head(tmp_path)
    current = hashlib.sha256(_FORMULA_V1).hexdigest()
    city = _write_city(tmp_path, forkbase=current, import_sha=None)
    (city / "formulas" / "mol-refinery-patrol.toml.bak-gcp-di8").write_bytes(b"old\n")
    (city / "formulas" / "mol-elsewhere.toml").symlink_to(tmp_path / "nowhere.toml")
    findings = pack_drift_check.check_city_drift(tmp_path, city, tmp_path / "registry.toml", "HEAD")
    assert findings == []


# --- CLI -----------------------------------------------------------------


def test_main_exits_zero_when_clean(tmp_path, capsys) -> None:
    _repo_pinned_at_head(tmp_path)
    assert pack_drift_check.main(["--root", str(tmp_path)]) == 0
    assert "ok" in capsys.readouterr().out


def test_main_exits_nonzero_on_fatal_drift(tmp_path, capsys) -> None:
    _repo_drifted(tmp_path)
    assert pack_drift_check.main(["--root", str(tmp_path)]) == 1
    out = capsys.readouterr().out
    assert "release-drift" in out
    assert "gastown" in out


def test_main_warning_only_drift_exits_zero(tmp_path, capsys) -> None:
    _, head = _repo_drifted(tmp_path)
    (tmp_path / "README.md").write_text("unrelated\n", encoding="utf-8")
    run_git(tmp_path, "add", "README.md")
    run_git(tmp_path, "commit", "-m", "docs: unrelated change")
    exit_code = pack_drift_check.main(["--root", str(tmp_path), "--changed-since", head])
    assert exit_code == 0
    assert "warning" in capsys.readouterr().out


def test_main_json_output_lists_findings(tmp_path, capsys) -> None:
    import json

    _repo_drifted(tmp_path)
    pack_drift_check.main(["--root", str(tmp_path), "--json"])
    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is False
    assert payload["findings"][0]["kind"] == "release-drift"


# --- import origin -------------------------------------------------------


def _set_origin(root, url: str) -> None:
    run_git(root, "remote", "add", "origin", url)


def test_repo_slug_parses_https_ssh_and_tree_urls() -> None:
    slug = pack_drift_check.repo_slug
    assert slug("https://github.com/gastownhall/gascity-packs/tree/main/gastown") == "gastownhall/gascity-packs"
    assert slug("https://github.com/atbrace/gascity-packs.git") == "atbrace/gascity-packs"
    assert slug("git@github.com:atbrace/gascity-packs.git") == "atbrace/gascity-packs"
    assert slug("https://github.com/atbrace/gascity-packs") == "atbrace/gascity-packs"
    assert slug("") is None


def test_city_import_from_foreign_repo_is_flagged(tmp_path) -> None:
    """The gcp-di8/gcp-4u7 failure: merges land on a repo the city never reads.

    The pin can be perfectly current and the release freshly stamped; if the
    city resolves a different repo than the one the refinery pushes to, the
    merged bytes are still unreachable.
    """
    _repo_pinned_at_head(tmp_path)
    _set_origin(tmp_path, "https://github.com/atbrace/gascity-packs.git")
    head = run_git(tmp_path, "rev-parse", "HEAD")
    current = hashlib.sha256(_FORMULA_V1).hexdigest()
    city = _write_city(tmp_path, forkbase=current, import_sha=head)
    findings = pack_drift_check.check_city_drift(tmp_path, city, tmp_path / "registry.toml", "HEAD")
    assert [f.kind for f in findings] == ["city-import-foreign-origin"]
    assert findings[0].fatal is True
    assert "atbrace/gascity-packs" in findings[0].detail
    assert "gastownhall/gascity-packs" in findings[0].detail


def test_city_import_matching_push_remote_is_clean(tmp_path) -> None:
    _repo_pinned_at_head(tmp_path)
    _set_origin(tmp_path, "https://github.com/gastownhall/gascity-packs.git")
    head = run_git(tmp_path, "rev-parse", "HEAD")
    current = hashlib.sha256(_FORMULA_V1).hexdigest()
    city = _write_city(tmp_path, forkbase=current, import_sha=head)
    findings = pack_drift_check.check_city_drift(tmp_path, city, tmp_path / "registry.toml", "HEAD")
    assert findings == []


def test_import_origin_check_silent_without_origin_remote(tmp_path) -> None:
    """No remote configured (fresh clone-less checkout) is not evidence of drift."""
    _repo_pinned_at_head(tmp_path)
    head = run_git(tmp_path, "rev-parse", "HEAD")
    current = hashlib.sha256(_FORMULA_V1).hexdigest()
    city = _write_city(tmp_path, forkbase=current, import_sha=head)
    findings = pack_drift_check.check_city_drift(tmp_path, city, tmp_path / "registry.toml", "HEAD")
    assert findings == []

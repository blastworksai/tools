"""Tests for stage.sh, offline: a local bare repository stands in for GitHub
(STAGE_REMOTE_BASE), so no network and no gh login are needed."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

STAGE = Path(__file__).resolve().parent.parent / "stage.sh"
GIT_ENV = {
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.invalid",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
}


def git(*args: str, cwd: Path) -> str:
    env = {**os.environ, **GIT_ENV}
    return subprocess.run(
        ["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True
    ).stdout.strip()


@pytest.fixture()
def world(tmp_path: Path) -> dict:
    """A fake 'GitHub' holding owner/proj.git with main, a PR ref and a branch."""
    work = tmp_path / "work"
    work.mkdir()
    git("init", "--quiet", "-b", "main", cwd=work)
    (work / "a.txt").write_text("one\n")
    (work / "gone.txt").write_text("old body\n")
    git("add", "a.txt", "gone.txt", cwd=work)
    git("commit", "--quiet", "-m", "base", cwd=work)
    git("checkout", "--quiet", "-b", "feature", cwd=work)
    (work / "a.txt").write_text("one\ntwo\n")
    git("rm", "--quiet", "gone.txt", cwd=work)
    git("commit", "--quiet", "-am", "change", cwd=work)
    head = git("rev-parse", "HEAD", cwd=work)
    git("checkout", "--quiet", "main", cwd=work)
    (work / "b.txt").write_text("main moved on\n")
    git("add", "b.txt", cwd=work)
    git("commit", "--quiet", "-m", "main moves", cwd=work)

    remote_base = tmp_path / "gh"
    bare = remote_base / "owner" / "proj.git"
    bare.parent.mkdir(parents=True)
    git("clone", "--quiet", "--bare", str(work), str(bare), cwd=tmp_path)
    git("update-ref", "refs/pull/7/head", head, cwd=bare)
    git("remote", "add", "origin", "https://github.com/owner/proj.git", cwd=work)
    return {"tmp": tmp_path, "work": work, "head": head, "remote_base": remote_base}


def stage(world: dict, *args: str, **env: str) -> subprocess.CompletedProcess:
    full = {
        **os.environ,
        **GIT_ENV,
        "BW_REVIEW_ROOT": str(world["tmp"] / "stage"),
        "STAGE_REMOTE_BASE": str(world["remote_base"]),
        **env,
    }
    return subprocess.run(
        ["bash", str(STAGE), *args], env=full, capture_output=True, text=True
    )


def meta(out: Path) -> dict:
    return dict(line.split(": ", 1) for line in (out / "meta.txt").read_text().splitlines())


@pytest.mark.parametrize("head", ["7", "pull/7/head", "feature", "origin/feature", "FULL"])
def test_stages_three_dot_diff_in_private_mirror(world: dict, head: str) -> None:
    head = world["head"] if head == "FULL" else head
    r = stage(world, "owner/proj", "origin/main", head)
    assert r.returncode == 0, r.stderr
    lines = r.stdout.splitlines()
    out = Path(lines[-1])
    mirror = world["tmp"] / "stage" / "repos" / "owner__proj.git"
    assert lines[-2] == f"mirror: {mirror}"
    assert out == world["tmp"] / "stage" / world["head"][:12]
    assert (out / "files.txt").read_text().split() == ["M", "a.txt", "D", "gone.txt"]
    patch = (out / "diff.patch").read_text()
    assert "+two" in patch and "b.txt" not in patch  # three-dot: main's own move is absent
    assert "old body" not in patch  # -D: a deleted file is a header only
    assert meta(out)["head_sha"] == world["head"]
    for d in (world["tmp"] / "stage", mirror.parent, mirror, out):
        assert d.stat().st_mode & 0o777 == 0o700


def test_a_local_path_is_not_a_repository_name(world: dict) -> None:
    r = stage(world, str(world["work"]), "main", "7")
    assert r.returncode == 2 and "not owner/name" in r.stderr


def test_default_root_is_under_xdg_cache_home(world: dict) -> None:
    cache = world["tmp"] / "xdg"
    env = {
        **os.environ,
        **GIT_ENV,
        "XDG_CACHE_HOME": str(cache),
        "STAGE_REMOTE_BASE": str(world["remote_base"]),
    }
    env.pop("BW_REVIEW_ROOT", None)
    r = subprocess.run(
        ["bash", str(STAGE), "owner/proj", "main", "7"], env=env, capture_output=True, text=True
    )
    assert r.returncode == 0, r.stderr
    assert Path(r.stdout.splitlines()[-1]) == cache / "bw-code-review" / world["head"][:12]


def test_default_root_without_xdg_is_under_home_cache(world: dict) -> None:
    home = world["tmp"] / "home"
    home.mkdir()
    env = {
        **os.environ,
        **GIT_ENV,
        "HOME": str(home),
        "STAGE_REMOTE_BASE": str(world["remote_base"]),
    }
    env.pop("BW_REVIEW_ROOT", None)
    env.pop("XDG_CACHE_HOME", None)
    r = subprocess.run(
        ["bash", str(STAGE), "owner/proj", "main", "7"], env=env, capture_output=True, text=True
    )
    assert r.returncode == 0, r.stderr
    assert Path(r.stdout.splitlines()[-1]) == home / ".cache" / "bw-code-review" / world["head"][:12]


def test_wrong_argument_count_prints_usage(world: dict) -> None:
    r = stage(world, "owner/proj", "main")
    assert r.returncode == 2 and "usage: stage.sh <owner/name> <base-branch> <head>" in r.stderr


def test_no_fetch_uses_what_the_mirror_holds(world: dict) -> None:
    missing = stage(world, "owner/proj", "main", "7", STAGE_NO_FETCH="1")
    assert missing.returncode == 1 and "could not observe" in missing.stderr
    assert stage(world, "owner/proj", "main", "7").returncode == 0
    again = stage(world, "owner/proj", "main", "7", STAGE_NO_FETCH="1")
    assert again.returncode == 0, again.stderr
    assert meta(Path(again.stdout.splitlines()[-1]))["fetched"] == "no (STAGE_NO_FETCH=1)"


def test_fetch_failure_is_could_not_observe(world: dict) -> None:
    r = stage(world, "owner/proj", "main", "99")
    assert r.returncode == 1
    assert "could not observe: <what>', not a defect" in r.stderr


@pytest.mark.parametrize("repo", ["not-a-slug", "a/../b", "/nonexistent/dir/x"])
def test_bad_repo_is_refused(world: dict, repo: str) -> None:
    assert stage(world, repo, "main", "7").returncode == 2

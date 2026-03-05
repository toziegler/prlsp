"""Git repo/branch/remote detection."""

import re
import subprocess
from dataclasses import dataclass


@dataclass
class GitInfo:
    root: str
    branch: str
    owner: str
    repo: str


def _run_git(args: list[str], cwd: str) -> str | None:
    try:
        result = subprocess.run(
            ["git"] + args,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def _parse_remote(url: str) -> tuple[str, str] | None:
    # SSH: git@github.com:owner/repo.git
    m = re.match(r"git@github\.com:([^/]+)/([^/]+?)(?:\.git)?$", url)
    if m:
        return m.group(1), m.group(2)
    # HTTPS: https://github.com/owner/repo.git
    m = re.match(r"https://github\.com/([^/]+)/([^/]+?)(?:\.git)?$", url)
    if m:
        return m.group(1), m.group(2)
    return None


def detect_git_info(workspace_path: str) -> GitInfo | None:
    root = _run_git(["rev-parse", "--show-toplevel"], workspace_path)
    if not root:
        return None

    branch = _run_git(["rev-parse", "--abbrev-ref", "HEAD"], workspace_path)
    if not branch:
        return None

    remote_url = _run_git(["remote", "get-url", "origin"], workspace_path)
    if not remote_url:
        return None

    parsed = _parse_remote(remote_url)
    if not parsed:
        return None

    owner, repo = parsed
    return GitInfo(root=root, branch=branch, owner=owner, repo=repo)

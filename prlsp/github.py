"""GitHub API layer: gh CLI wrappers + MockGitHub test double."""

import json
import logging
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class ReviewComment:
    database_id: int
    body: str
    author: str


@dataclass
class ReviewThread:
    thread_id: str
    path: str
    line: int
    is_resolved: bool
    comments: list[ReviewComment] = field(default_factory=list)


def _run_gh(args: list[str]) -> str | None:
    try:
        result = subprocess.run(
            ["gh"] + args,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        logger.error("gh %s failed: %s", " ".join(args), result.stderr.strip())
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        logger.error("gh command error: %s", e)
    return None


THREADS_QUERY = """
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          line
          path
          comments(first: 50) {
            nodes {
              databaseId
              body
              author { login }
            }
          }
        }
      }
    }
  }
}
"""


class GitHubAPI:
    def find_pr(self, owner: str, repo: str, branch: str) -> tuple[int, str] | None:
        """Returns (pr_number, head_sha) or None."""
        out = _run_gh([
            "pr", "list",
            "--repo", f"{owner}/{repo}",
            "--head", branch,
            "--json", "number,headRefOid",
            "--limit", "1",
        ])
        if not out:
            return None
        prs = json.loads(out)
        if prs:
            return prs[0]["number"], prs[0]["headRefOid"]
        return None

    def fetch_review_threads(self, owner: str, repo: str, pr_number: int) -> list[ReviewThread]:
        out = _run_gh([
            "api", "graphql",
            "-f", f"query={THREADS_QUERY}",
            "-f", f"owner={owner}",
            "-f", f"repo={repo}",
            "-F", f"pr={pr_number}",
        ])
        if not out:
            return []
        data = json.loads(out)
        threads = []
        for node in data["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]:
            if node["line"] is None:
                continue
            comments = [
                ReviewComment(
                    database_id=c["databaseId"],
                    body=c["body"],
                    author=c["author"]["login"] if c["author"] else "ghost",
                )
                for c in node["comments"]["nodes"]
            ]
            threads.append(ReviewThread(
                thread_id=node["id"],
                path=node["path"],
                line=node["line"],
                is_resolved=node["isResolved"],
                comments=comments,
            ))
        return threads

    def resolve_thread(self, thread_id: str) -> bool:
        mutation = """
        mutation($threadId: ID!) {
          resolveReviewThread(input: {threadId: $threadId}) {
            thread { isResolved }
          }
        }
        """
        out = _run_gh([
            "api", "graphql",
            "-f", f"query={mutation}",
            "-f", f"threadId={thread_id}",
        ])
        return out is not None

    def reply_to_comment(self, owner: str, repo: str, pr_number: int, comment_id: int, body: str) -> bool:
        out = _run_gh([
            "api",
            f"repos/{owner}/{repo}/pulls/{pr_number}/comments/{comment_id}/replies",
            "-f", f"body={body}",
        ])
        return out is not None

    def create_review_comment(self, owner: str, repo: str, pr_number: int,
                              commit_id: str, path: str, line: int, body: str) -> bool:
        payload = json.dumps({
            "commit_id": commit_id,
            "body": "",
            "event": "COMMENT",
            "comments": [{
                "path": path,
                "line": line,
                "side": "RIGHT",
                "body": body,
            }],
        })
        result = subprocess.run(
            ["gh", "api", f"repos/{owner}/{repo}/pulls/{pr_number}/reviews",
             "--input", "-"],
            input=payload,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            logger.error("create_review_comment failed: %s", result.stderr.strip())
        return result.returncode == 0


class MockGitHub:
    def __init__(self, fixture_path: str):
        with open(fixture_path) as f:
            data = json.load(f)
        self._threads: list[ReviewThread] = []
        for t in data["threads"]:
            comments = [
                ReviewComment(database_id=c["database_id"], body=c["body"], author=c["author"])
                for c in t["comments"]
            ]
            self._threads.append(ReviewThread(
                thread_id=t["thread_id"],
                path=t["path"],
                line=t["line"],
                is_resolved=t.get("is_resolved", False),
                comments=comments,
            ))

    def find_pr(self, owner: str, repo: str, branch: str) -> tuple[int, str] | None:
        return 1, "mock_sha"

    def fetch_review_threads(self, owner: str, repo: str, pr_number: int) -> list[ReviewThread]:
        return self._threads

    def resolve_thread(self, thread_id: str) -> bool:
        for t in self._threads:
            if t.thread_id == thread_id:
                t.is_resolved = True
                return True
        return False

    def reply_to_comment(self, owner: str, repo: str, pr_number: int, comment_id: int, body: str) -> bool:
        for t in self._threads:
            for c in t.comments:
                if c.database_id == comment_id:
                    t.comments.append(ReviewComment(
                        database_id=comment_id + 1000,
                        body=body,
                        author="you",
                    ))
                    return True
        return False

    def create_review_comment(self, owner: str, repo: str, pr_number: int,
                              commit_id: str, path: str, line: int, body: str) -> bool:
        import random
        self._threads.append(ReviewThread(
            thread_id=f"PRRT_mock_{random.randint(1000,9999)}",
            path=path,
            line=line,
            is_resolved=False,
            comments=[ReviewComment(database_id=random.randint(9000, 9999), body=body, author="you")],
        ))
        return True

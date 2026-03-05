"""Entry point: python -m prlsp [--mock path]"""

import argparse
import logging
import sys

from prlsp.github import MockGitHub
from prlsp.server import create_server


def main():
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    )

    parser = argparse.ArgumentParser(description="GitHub PR Review LSP Server")
    parser.add_argument("--mock", metavar="PATH", help="Path to mock comments JSON fixture")
    args = parser.parse_args()

    github = None
    if args.mock:
        logging.getLogger(__name__).info("Mock mode: loading %s", args.mock)
        github = MockGitHub(args.mock)

    server = create_server(github=github)
    server.start_io()


if __name__ == "__main__":
    main()

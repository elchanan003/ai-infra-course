#!/usr/bin/env python3
"""Sync job (task 2.3): upload lab/model/ to s3://models/<repo>/<commit>/ plus a SHA256SUMS object.

Reads the endpoint and the RW identity from the environment (verify provides them):
  S3_ENDPOINT  S3_ACCESS_KEY  S3_SECRET_KEY   and lab/REPOS.env (REPO, COMMIT).
Contract: every file under lab/model/ (relative path as key suffix) and an object `SHA256SUMS`
(sha256sum format, relative paths) under the same prefix. Create the bucket `models` if it does not exist.
Use boto3 with path-style addressing: Config(s3={"addressing_style": "path"}).
"""
import os, sys


def main():
    # TODO
    raise NotImplementedError


if __name__ == "__main__":
    main()

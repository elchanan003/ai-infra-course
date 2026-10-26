#!/usr/bin/env python3
"""Sync job (task 2.3) - reference solution."""
import hashlib, os, boto3
from botocore.client import Config
from botocore.exceptions import ClientError

HERE = os.path.dirname(os.path.abspath(__file__))


def env_file(path):
    d = {}
    for l in open(path):
        l = l.strip()
        if "=" in l and not l.startswith("#"):
            k, v = l.split("=", 1); d[k] = v
    return d


def main():
    repos = env_file(os.path.join(HERE, "REPOS.env"))
    s3 = boto3.client("s3", endpoint_url=os.environ["S3_ENDPOINT"], aws_access_key_id=os.environ["S3_ACCESS_KEY"],
                      aws_secret_access_key=os.environ["S3_SECRET_KEY"], region_name="us-east-1", config=Config(s3={"addressing_style": "path"}))
    try:
        s3.head_bucket(Bucket="models")
    except ClientError:
        s3.create_bucket(Bucket="models")
    prefix = "%s/%s/" % (repos["REPO"], repos["COMMIT"]); root = os.path.join(HERE, "model"); sums = []
    for d, _, fs in os.walk(root):
        for fn in sorted(fs):
            p = os.path.join(d, fn); rel = os.path.relpath(p, root)
            if rel.startswith(".cache"):
                continue
            h = hashlib.sha256(open(p, "rb").read()).hexdigest(); sums.append("%s  %s\n" % (h, rel))
            s3.upload_file(p, "models", prefix + rel)
    s3.put_object(Bucket="models", Key=prefix + "SHA256SUMS", Body="".join(sorted(sums)).encode())
    print("synced %d files to s3://models/%s" % (len(sums), prefix))


if __name__ == "__main__":
    main()

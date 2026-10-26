# 02 — Hint ladder

## Task 2.1 download, manifest, header (2.1.x)
- H1: set `HF_ENDPOINT` to the mirror and disable Xet, then try `hf download --help`. Which flags pin the commit and restrict files?
- H2: concept: pin `--revision <commit>`; repeat `--include` once per pattern (one flag with several space-separated patterns is read as one filename); `--local-dir` gives plain files you can hash. The repo also holds decoys (pickle `.bin`, ONNX, README).
- H3: `HF_ENDPOINT=http://127.0.0.1:18071 HF_HUB_DISABLE_XET=1 platform/.venv/bin/hf download REPO --revision COMMIT --include "*.json" --include "*.txt" --include "*.safetensors" --local-dir lab/model`. Manifest: `cd lab/model && sha256sum <files> > ../model.sha256`. Header: first 8 bytes little-endian = N, then N bytes of JSON; per tensor `shape` and `dtype`. Shard count = distinct files in the index `weight_map`.
- H4: `.tutor/solve-answers.sh` (sections 2.1).

## Task 2.2 pickle scanner (2.2.x)
- H1: `python3 -m pickletools FILE | head -40` on a benign and a hostile file; what differs?
- H2: concept: `GLOBAL "mod name"` and `STACK_GLOBAL` (module and name are the two strings pushed just before it) import callables; `REDUCE` calls them. Zip checkpoints keep the pickle in `*/data.pkl`. Strings are just data.
- H3: iterate `pickletools.genops`; remember the last strings pushed (and memo get/put) to resolve `STACK_GLOBAL`; allow-list the globals a real checkpoint needs (`collections.OrderedDict`, `torch._utils._rebuild_tensor_v2`, `torch.*Storage`...), flag everything else; wrap parsing in try/except and call parse failures dangerous; `zipfile` for `PK` files.
- H4: `.tutor/solution/pickle_scan.py`.

## Task 2.3 S3 least privilege (2.3.x)
- H1: `platform/stack/README.md` lists two identities (rw, ro). Which one belongs to which side?
- H2: concept: serving pods read, only the sync job writes; ETag != sha256, so keep a `SHA256SUMS` object. A read-only identity gets `403 AccessDenied` on PUT/DELETE; a wrong key gets another error code.
- H3: boto3 client with `endpoint_url`, `region_name="us-east-1"`, `Config(s3={"addressing_style": "path"})`; create bucket `models` if `head_bucket` fails; keys `REPO/COMMIT/<relative path>`; put the hashes in `SHA256SUMS` under the same prefix. `lab/s3-serve.env` = the ro key pair.
- H4: `.tutor/solution/s3-sync.py`, `.tutor/solution/s3-serve.env`.

## Task 2.4 serve offline and prove it (2.4.x)
- H1: `docker network inspect aiinfra-airgap`: who is the DNS server there? Why would a container on this network still be able to leak a DNS query?
- H2: concept: offline env vars are client settings; isolation is the network. The tripwire counts DNS queries (HTTPS never reaches its HTTP sink). Your loader test needs a populated HF cache (`HF_HOME`) with the pinned commit and `HF_HUB_OFFLINE=1`. Without a branch ref, only `--revision <commit>` finds the snapshot offline.
- H3: `HF_HOME=$PWD/lab/hf-cache hf download REPO --revision COMMIT --include ...` fills the cache (layout `hub/models--org--name/{blobs,refs,snapshots}`); verify mounts it at `/hf`, so `HF_HOME=/hf`. run.sh: `docker run -d --name aiinfra-lab02-serve --label course=aiinfra --network aiinfra-airgap --dns 172.29.231.2 -v ...models:/models:ro IMAGE -m /models/GGUF --host 0.0.0.0 --port 8080`.
- H4: `.tutor/solution/airgap/`.

## Task 2.5 registry and ORAS (2.5.x)
- H1: after `docker push`, compare `docker images --digests` with what the registry says (`curl -sI -H 'Accept: ...' .../manifests/<tag>`, header `Docker-Content-Digest`). Do they agree on this host?
- H2: concept: tags move, digests do not; with the containerd store the pushed manifest can differ from the local index digest; always record the registry's value. ORAS: `--artifact-type` for the artifact, `file:mediaType` for each layer.
- H3: `docker tag IMG localhost:18050/aiinfra/llama:server-b11889 && docker push ...`; `docker run ... localhost:18050/aiinfra/llama@sha256:...`; `cd ~/.cache/aiinfra-course/models && oras push --plain-http --artifact-type application/vnd.aiinfra.model.v1 127.0.0.1:18050/aiinfra/models/gguf:q4 FILE:application/vnd.aiinfra.gguf` prints the manifest digest.
- H4: `.tutor/solve-answers.sh` (section 2.5).

## Task 2.6 the damaged bundle (2.6.x)
- H1: `cd lab/incoming && sha256sum -c SHA256SUMS`: what does it say, and what does it NOT say?
- H2: concept: a hash check finds corrupt files but a file that is absent is not "checked" the way you think; also look at what serving needs (tokenizer). Repair only what is broken; `hf download --include <file> --local-dir lab/incoming` replaces files whose hash differs.
- H3: loop over `SHA256SUMS`: missing file vs different hash (keep expected and actual). Re-fetch exactly those names from the mirror at the pinned commit.
- H4: `.tutor/solve-answers.sh` (section 2.6).

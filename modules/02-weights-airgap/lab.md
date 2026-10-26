# 02 — Lab: move a model across an air gap and serve it provably offline

Time: ~3 h. Guidance level: moderate. Profiles: `store llm` (hf-mirror, SeaweedFS, registry, tripwire, llama.cpp). **Everything graded is real**; the stand-ins are: the hf-mirror plays an enterprise Hub proxy; the `aiinfra-airgap` Docker network (`internal: true`, DNS = tripwire) plays the isolated network; the hostile pickles are inert (their payload only touches a canary file); the "model loader" used to prove offline loading is the course's mock-vllm, which resolves a repo id with the real `huggingface_hub` and checks tokenizer, shards and hashes at start-up like a real engine would (its generation is simulated, its model loading is not).

Tools: `platform/.venv/bin/{hf,python,picklescan}`, `oras` in `~/.local/bin`, `docker`, `jq`, `sha256sum`. See `lab/README.md` for endpoints. Lab containers use ports 18125-18129 and the name prefix `aiinfra-lab02-`; always label them `course=aiinfra`.

## Starting state
`./prepare-lab.sh` converges to `store llm`, assigns a hidden per-learner variant (`.state/`), generates a synthetic **sharded** HF repo (3-5 shards, a varying number of tensors, a decoy pickle `.bin`, an ONNX file and a README) into the mirror's cache, writes `lab/REPOS.env` (repo id, pinned commit, GGUF file name), `lab/pickles/` (5 checkpoint files), and `lab/incoming/` (a copy of the bundle that "arrived through the transfer", damaged). It never prints answers.

## Ownership
| Path | Status |
|---|---|
| `lab/REPOS.env`, `lab/pickles/*`, `lab/incoming/*` (as delivered), `lab/README.md` | given |
| `lab/model/`, `lab/model.sha256`, `lab/answers/header.json` | yours — task 2.1 (starter: empty / templates) |
| `lab/pickle_scan.py` | yours — task 2.2 (starter: stub that calls everything safe) |
| `lab/s3-sync.py`, `lab/s3-serve.env` | yours — task 2.3 |
| `lab/hf-cache/`, `lab/airgap/run.sh`, `lab/airgap/offline.env` | yours — task 2.4 |
| `lab/registry/answers.env` (+ the commands you run) | yours — task 2.5 |
| `lab/answers/incident.json`, the repaired `lab/incoming/` | yours — task 2.6 |
| `platform/`, `mock/`, module scripts, `.state/`, `.lib/` | given — do not modify |

## Task 2.1 — Download through the mirror, record a manifest, read the header
**Goal:** a reproducible download of a pinned commit, an integrity manifest, and the numbers inside the files.
1. Point the Hub client at the mirror (`HF_ENDPOINT`), disable Xet, and download the repo from `REPOS.env` at its pinned commit into `lab/model/` with `hf download --local-dir`. Download only what serving needs (`*.json`, `*.txt`, `*.safetensors`); the repo contains decoy files you must not pull.
2. Write `lab/model.sha256` (`sha256sum` format, `<hash>  <path relative to lab/model/>`, one line per downloaded file; `cd lab/model && sha256sum -c ../model.sha256` must pass).
3. Read the safetensors headers yourself (do not use library calls to count) and fill `lab/answers/header.json`: `shards` (distinct shard files), `tensors` (all tensors in all shards), `total_params` (sum of shape products), `dtypes` (sorted list of dtype names as written in the headers).

Success criteria:
- `2.1.1` every serving file of the pinned commit is in `lab/model/` and matches the source hash; `model.sha256` lists them all and verifies.
- `2.1.2` no decoy or unneeded files were downloaded (BLOCKED until 2.1.1 passes).
- `2.1.3` `header.json` equals the values verify computes from the files (the counts differ per learner).

Concept: theory 2.1, 3.

## Task 2.2 — A pickle scanner that never executes the file
**Goal:** `lab/pickle_scan.py FILE...` reports dangerous opcodes statically. Contract is in the file's docstring (one JSON line per file with `verdict` and `findings`; exit 1 if any file is dangerous; unparseable = dangerous; raw pickles and PyTorch zip checkpoints; never `pickle.load`).
Then run `picklescan` on the same files and compare verdicts (not scored, but look at where it differs and why).
The 5 files in `lab/pickles/` are a mix of hostile and benign. Benign ones look like real checkpoints (`collections.OrderedDict`, `torch._utils._rebuild_tensor_v2`, `torch.*Storage`, one of them in protocol 4) and one contains the text `os.system` only as string data.

Success criteria:
- `2.2.1` both hostile files are flagged (one raw protocol-4 file, one wrapped in a zip) and verify's per-file runs exit 1.
- `2.2.2` zero false positives on the three benign files (BLOCKED until 2.2.1 passes).
- `2.2.3` the canary file that executing a hostile pickle would create does not exist (BLOCKED until 2.2.1 passes).
- `2.2.4` a truncated pickle is reported dangerous with exit 1.

Concept: theory 2.2, 4.

## Task 2.3 — Weights into internal S3 with least privilege
**Goal:** the sync job writes, the serving side can only read.
1. `lab/s3-sync.py` (contract in its docstring): upload everything under `lab/model/` to `s3://models/<repo>/<commit>/` and add a `SHA256SUMS` object (`<hash>  <relative path>` lines). It reads the endpoint and the **RW** identity from `S3_ENDPOINT`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` (verify runs it with the RW identity from `platform/stack/README.md`).
2. `lab/s3-serve.env` is what the serving side uses (same variable names): put the **RO** identity there.

Success criteria:
- `2.3.1` after verify runs your sync, all objects are under the prefix and readable with the credentials in `lab/s3-serve.env`; their hashes match the source and `SHA256SUMS` (BLOCKED until 2.1.1 passes).
- `2.3.2` a `PutObject` with the serving credentials is denied with 403 `AccessDenied` (BLOCKED until 2.3.1 passes: a denial means nothing if the same identity cannot read).
- `2.3.3` a `DeleteObject` with the serving credentials is denied too.

Concept: theory 5.

## Task 2.4 — Serve it on the air-gapped network, prove it
**Goal:** a llama-server on `aiinfra-airgap` answering a completion while the tripwire stays silent, and an offline configuration that really keeps Hugging Face client code local.
1. `lab/airgap/run.sh` (contract in the file): container `aiinfra-lab02-serve`, label `course=aiinfra`, attached to `aiinfra-airgap` only, DNS = the tripwire (`172.29.231.2`), the GGUF named in `REPOS.env` mounted read-only from `~/.cache/aiinfra-course/models`, no Hugging Face download flag.
2. Populate an HF cache for the pinned commit in `lab/hf-cache/` (use `HF_HOME` so the layout is `hub/models--org--name/...`). verify mounts it at `/hf` in a container on the air-gapped network and starts a model loader with `--model <repo> --revision <commit>` and `--env-file lab/airgap/offline.env`. Write that env file so the loader starts from the cache and does not touch the network. You can look at the tripwire yourself: `curl -s http://127.0.0.1:18072/hits` (reset: `curl -X DELETE`).

Success criteria:
- `2.4.1` a completion from an in-network probe against your container returns text.
- `2.4.2` your container is on `aiinfra-airgap` only, uses the tripwire as DNS, is not started with a download flag, and the tripwire counted **zero** DNS queries while it started and served.
- `2.4.3` the loader with **your** `offline.env` starts from your cache and the tripwire stays at zero. verify first runs a control (same loader without offline settings) that must trip the wire; if it does not, 2.4.3 is BLOCKED (a silent wire proves nothing).

Concept: theory 7.2. HTTPS never reaches the sink; the DNS query log is the counter.

## Task 2.5 — Mirror an engine image and a model into the internal registry
**Goal:** run an image by digest from the internal registry, and ship a GGUF as an OCI artifact.
1. Tag the llama.cpp image as `localhost:18050/aiinfra/llama:server-b11889`, push it. Read the **registry's** manifest digest (header `Docker-Content-Digest`), not `docker images --digests`. Run a container from `localhost:18050/aiinfra/llama@sha256:<digest>` (label `course=aiinfra`, name `aiinfra-lab02-llama-digest`, any port in 18125-18129; mount the models directory and serve the GGUF from `REPOS.env`).
2. `oras push` that GGUF to `127.0.0.1:18050/aiinfra/models/gguf:q4` with `--plain-http`, artifact type `application/vnd.aiinfra.model.v1` and layer media type `application/vnd.aiinfra.gguf`. Pull it into a scratch directory and compare hashes.
3. Record `IMAGE_DIGEST`, `ARTIFACT_DIGEST` (the manifest digest of the artifact), `GGUF_SHA256` in `lab/registry/answers.env`.

Success criteria:
- `2.5.1` `IMAGE_DIGEST` equals the digest the registry reports for a tag of `aiinfra/llama`.
- `2.5.2` a running course container was created from the reference `localhost:18050/aiinfra/llama@<IMAGE_DIGEST>`.
- `2.5.3` `oras pull` of `aiinfra/models/gguf@<ARTIFACT_DIGEST>` yields your variant's GGUF (verify compares with the file in the models cache), and the manifest's artifactType and layer media type are as specified.

Concept: theory 6, 6.1.

## Task 2.6 — Troubleshooting (planted): the bundle that arrived through the transfer
**Goal:** find what the transfer broke, repair only that, and prove the bundle is good.

`lab/incoming/` is the serving set as it arrived, with `SHA256SUMS` produced on the connected side. It does not load. The mirror still holds the source.
1. Compare the bundle with its manifest; check completeness for serving (not only hashes).
2. Fill `lab/answers/incident.json`: `missing` (file names) and `corrupt` (list of `{file, expected_sha256, actual_sha256}`; `actual` is the hash of the damaged file as it arrived, so write the answer before repairing).
3. Re-fetch **only** the broken files from the mirror at the pinned commit into `lab/incoming/`, then re-verify the whole bundle.

Success criteria:
- `2.6.1` `incident.json` names exactly the missing and the corrupt file of your variant with the right hashes.
- `2.6.2` every file matches `SHA256SUMS`, and no good file was replaced (modification times of untouched files are unchanged).
- `2.6.3` the bundle loads: verify starts the mock-vllm loader on it (tokenizer present, index and shards consistent, headers parse, hashes match).

Concept: theory 2.4, 3.2.

## Wrap-up
`./verify.sh` (about 3-5 minutes), `./cleanup.sh` (removes lab containers, local registry tags, the S3 and registry data volumes and the synthetic mirror repo; never `lab/`), `./verify-clean.sh`.

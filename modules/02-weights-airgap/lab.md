# 02 — Lab: move a model across an air gap and serve it provably offline

DRAFT (phase 1): task design, criteria ids and ownership are fixed; items marked (P2) are confirmed in phase 2 against `platform/stack/README.md` and `mock/README.md`.

Time: ~3 h. Guidance level: moderate. Profiles: `store llm` (hf-mirror, SeaweedFS, registry, tripwire, llama.cpp). **Everything is real**; stand-ins: the hf-mirror plays an enterprise Hub proxy, the `aiinfra-airgap` Docker network plays the isolated network, malicious pickles are inert (their payload only touches a canary file).

Use the venv tooling (`platform/.venv`: `hf`, `boto3`, `picklescan`, `safetensors`) and `oras` (`platform/bin`) (P2).

## Starting state
`./prepare-lab.sh` converges to `store llm`, seeds a per-learner variant in `.state/` (which repos the mirror serves, how many shards and tensors, which pickle files are hostile, which shard of the incoming bundle is damaged), and writes `lab/REPOS.env` (repo ids and pinned commits), `lab/pickles/` (5 numbered files), `lab/incoming/` (a synced bundle with a transfer manifest). It never prints answers.

## Ownership
| Path | Status |
|---|---|
| `lab/REPOS.env`, `lab/pickles/*`, `lab/incoming/*`, `lab/bin/*` | given |
| `lab/model/`, `lab/model.sha256` | yours — task 2.1 (starter: empty) |
| `lab/answers/header.json` | yours — task 2.1 |
| `lab/pickle_scan.py` | yours — task 2.2 (starter: stub that reports nothing) |
| `lab/s3-sync.py`, `lab/s3-serve.env` | yours — task 2.3 |
| `lab/airgap/run.sh`, `lab/airgap/offline.env` | yours — task 2.4 |
| `lab/registry/answers.env` | yours — task 2.5 (+ the commands you run) |
| `lab/answers/incident.json`, repaired `lab/incoming/` | yours — task 2.6 |
| `platform/`, `mock/`, module scripts, `.state/` | given |

## Task 2.1 — Download through the mirror, record a manifest, read the header
**Goal:** reproducible download of a pinned commit, an integrity manifest, and the numbers inside the files.
1. Point the client at the mirror (`HF_ENDPOINT`, endpoints in `platform/stack/README.md`), disable Xet, and download the **sharded** repo from `REPOS.env` at its pinned commit into `lab/model/` with `hf download --local-dir`. Download only what serving needs (`*.json`, `*.safetensors`, tokenizer files); the repo also contains decoy files you must not pull.
2. Write `lab/model.sha256` (`sha256sum`-style, relative paths) for every downloaded file.
3. Read the safetensors headers yourself (no `safetensors` library calls to count) and write `lab/answers/header.json`: `shards`, `tensors`, `total_params`, `dtypes` (sorted list).

Success criteria:
- `2.1.1` every file in the pinned commit that serving needs is in `lab/model/` and matches the source hash; `model.sha256` verifies with `sha256sum -c`.
- `2.1.2` no decoy/unneeded files were downloaded (include patterns used).
- `2.1.3` `header.json` equals the values verify computes live from the files (counts differ per learner).

Concept: theory 2.1, 3.

## Task 2.2 — A pickle scanner that never executes the file
**Goal:** `lab/pickle_scan.py FILE...` reports dangerous opcodes statically.

Contract: exit code 0 if all files look safe, 1 if any is flagged; prints one JSON object per file `{"file", "verdict": "safe"|"dangerous", "findings": [{"opcode", "module", "name"}]}`. Files may be raw pickles or PyTorch zip checkpoints (scan every `*.pkl` member). A file you cannot parse is **dangerous**. Use `pickletools.genops`; do not call `pickle.load`.
Then run `picklescan` on the same files and note where it agrees or disagrees (no scored output, but look at the differences).
The 5 files in `lab/pickles/` are: some hostile, some benign (benign ones look like real checkpoints: `collections.OrderedDict`, `torch._utils._rebuild_tensor_v2`, a string literal that contains the text `os.system`).

Success criteria:
- `2.2.1` both hostile files are flagged (one uses protocol-4 `STACK_GLOBAL`, one is wrapped in a zip).
- `2.2.2` zero false positives on the benign files.
- `2.2.3` the canary file that executing a hostile file would create does not exist (your scanner did not load it).
- `2.2.4` a truncated pickle is reported dangerous (exit 1), not skipped.

Concept: theory 2.2, 4.

## Task 2.3 — Weights into internal S3 with least privilege
**Goal:** the sync job writes, the serving side can only read.
1. Using the RW identity (`platform/stack/README.md`), upload the model from task 2.1 to `s3://models/<repo>/<commit>/` plus a `SHA256SUMS` object (script: `lab/s3-sync.py`, `boto3`, path-style addressing).
2. `lab/s3-serve.env` is what the serving side uses: put the **RO** identity there.

Success criteria:
- `2.3.1` all objects present under the prefix; downloading them with `lab/s3-serve.env` credentials reproduces the hashes in `SHA256SUMS`.
- `2.3.2` a `PutObject` with the credentials in `lab/s3-serve.env` is denied with 403 `AccessDenied` (the pair: same call with the RW identity succeeds — verify's own precondition).
- `2.3.3` a `DeleteObject` with the serve credentials is denied.

Concept: theory 5.

## Task 2.4 — Serve it on the air-gapped network, prove it
**Goal:** a llama-server on `aiinfra-airgap` answering a completion while the tripwire stays silent.
1. `lab/airgap/run.sh` starts the engine container (name `aiinfra-lab02-serve`, label `course=aiinfra`, network `aiinfra-airgap`, local GGUF mounted read-only, **no `-hf` flag**).
2. `lab/airgap/offline.env` holds the environment variables for any Hugging Face client code that runs in that network (verify runs a fixed probe `lab/bin/probe_hf.py` inside the air-gapped network with your env file and a populated cache).
3. Check the tripwire yourself (`curl` its `/hits` endpoint from inside the network or via the stack helper; see README) before and after.

Success criteria:
- `2.4.1` a completion from an in-network probe against your container returns 200 with a non-empty answer.
- `2.4.2` the tripwire saw **zero** DNS queries for external names during start-up and serving of your container.
- `2.4.3` verify's HF probe with **your** `offline.env` loads the model config from the cache and the tripwire stays at zero.
- `2.4.4` (control, verify's own, unscored precondition `2.4.P`) the same probe **without** offline settings produces at least one tripwire hit — proving the wire works. If it does not, results are BLOCKED.

Concept: theory 7.2. Note: HTTPS never reaches the sink; the DNS log is the counter.

## Task 2.5 — Mirror an engine image and a model into the internal registry
**Goal:** run an image by digest from the internal registry, and ship a GGUF as an OCI artifact.
1. Tag the llama.cpp image into `localhost:18050/aiinfra/llama` and push. Read the **registry's** manifest digest (not `docker images`). Run an engine container from `localhost:18050/aiinfra/llama@sha256:<digest>`.
2. `oras push` the Q4 GGUF as `localhost:18050/aiinfra/models/<name>:q4` with artifact type `application/vnd.aiinfra.model.v1` and layer media type `application/vnd.aiinfra.gguf`. Pull it into a scratch directory and compare hashes.
3. Record `IMAGE_DIGEST`, `ARTIFACT_DIGEST`, `GGUF_SHA256` in `lab/registry/answers.env`.

Success criteria:
- `2.5.1` `IMAGE_DIGEST` equals the registry's manifest digest for `aiinfra/llama` (the local index digest does not pass).
- `2.5.2` a running course container was created from the digest reference.
- `2.5.3` `oras pull` of the recorded artifact yields a file with `GGUF_SHA256`; the manifest's artifactType and layer media type are as specified.

Concept: theory 6, 6.1.

## Task 2.6 — Troubleshooting (planted): the bundle that arrived through the transfer
**Goal:** find what the transfer broke, repair only that, and prove the bundle is good.

`lab/incoming/` is a copy of the sharded model that arrived on the inside, with `SHA256SUMS` produced on the connected side. It does not work: the loader's checks fail. The mirror still holds the source.
1. Compare the bundle with `SHA256SUMS`; check completeness for serving (not only hashes).
2. Fill `lab/answers/incident.json`: `missing` (list of files), `corrupt` (list of `{file, expected_sha256, actual_sha256}`).
3. Re-fetch **only** the broken files from the mirror (pinned commit), and re-verify the whole bundle.

Success criteria:
- `2.6.1` `incident.json` names exactly the missing and the corrupt file(s) of your variant with correct expected and actual hashes.
- `2.6.2` every file in `lab/incoming/` matches `SHA256SUMS` and no good file was re-downloaded (modification times of untouched files unchanged).
- `2.6.3` the bundle passes the serving-readiness check: tokenizer present, index and shards consistent, headers parse, tensor names in the index match the shards.

Concept: theory 2.4, 3.2.

## Wrap-up
`./verify.sh` (about 5-8 minutes), `./cleanup.sh` (removes containers, S3 data, registry content and the tripwire log it created; never `lab/`), `./verify-clean.sh`.

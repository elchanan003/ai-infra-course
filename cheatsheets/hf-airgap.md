# Cheatsheet: Hugging Face Hub, mirrors and air-gapped weights

(huggingface_hub 2.3.0, `hf` CLI. `huggingface-cli` and `TRANSFORMERS_OFFLINE` are legacy: do not use.)

## hf CLI
```bash
hf download ORG/REPO --include "*.safetensors" --include "config.json" --include "tokenizer*" --revision COMMIT --local-dir DIR
hf download ORG/REPO file.gguf --local-dir DIR           # single file
hf cache ls ; hf cache rm <revision-or-repo>              # inspect/clean the cache
hf auth login | hf auth whoami
hf upload / hf repo ...                                   # publishing
```
Always give explicit `--include` patterns (a repo can hold 5 formats of the same weights, 10x the bytes). Pin `--revision` to a commit hash, not `main`.

## Environment
| Var | Effect |
|---|---|
| `HF_HOME` | root of cache + token (default `~/.cache/huggingface`) |
| `HF_HUB_CACHE` | model cache dir (default `$HF_HOME/hub`) |
| `HF_ENDPOINT` | Hub base URL (point at the internal mirror, e.g. `http://127.0.0.1:18071`) |
| `HF_HUB_OFFLINE=1` | the hub library makes no network calls, resolves from cache only |
| `HF_TOKEN` | auth token |
| `HF_HUB_DISABLE_TELEMETRY=1`, `DO_NOT_TRACK=1` | no usage pings |
`HF_HUB_OFFLINE` only governs huggingface_hub. It does not stop other libraries, pip, a tokenizer that fetches a remote file, or telemetry. Air gap is a **network property**; env vars are a hint. Prove it with a tripwire/DNS log, not with env vars.

## Cache layout
```
$HF_HUB_CACHE/models--ORG--NAME/
  blobs/<sha256 or etag>        actual files (content-addressed)
  refs/main                     commit hash of a branch
  snapshots/<commit>/file ->    symlinks into blobs
```
Copy the whole `models--*` directory tree (preserving symlinks) or use `--local-dir` for a flat directory and ship a sha256 manifest.

## Integrity and safety
- `sha256sum -c MANIFEST` after every hop (mirror -> S3 -> node). Compare against a manifest created on the connected side.
- safetensors file: 8-byte little-endian header length N, then N bytes JSON (`dtype`, `shape`, `data_offsets` per tensor, optional `__metadata__`), then raw data. Reading the header executes nothing; counting tensors/shards from it is safe.
- Pickle (`.bin`, `.pt`, `.pkl`) executes code on load (`GLOBAL`/`STACK_GLOBAL` + `REDUCE` opcodes). Scan statically with `picklescan` / `pickletools`, never `torch.load` an unscanned file. A clean scan is not proof of safety (scanners have bypasses): prefer safetensors, only load from trusted sources, load in an isolated environment.
- Missing sidecar files (`tokenizer.json`, `config.json`, `generation_config.json`) are a common sync bug: serving fails at start; compare file lists, not just sizes.
- One flipped byte in a shard passes `ls`; only hashes catch it.

## Mirror (course: hf-mirror on :18071, 4 endpoints)
model revision info (`/api/models/ORG/NAME/revision/REV`), tree (`/api/models/.../tree/REV`), `HEAD /ORG/NAME/resolve/REV/FILE`, `GET /ORG/NAME/resolve/REV/FILE`. Clients: set `HF_ENDPOINT`; XET-backed repos may need `HF_HUB_DISABLE_XET=1` against a plain mirror.

## Moving across the gap
1. Connected side: `hf download` with includes + pinned revision -> manifest (`sha256sum`) -> scan -> review.
2. Transfer: object store (SeaweedFS S3, RO and RW identities) or OCI artifact (`oras push REG/models/NAME:TAG file.gguf` / `oras pull`) -> registry digest is the identity.
3. Air-gapped side: verify manifest, load into `HF_HUB_CACHE` or `--local-dir`, serve with `HF_HUB_OFFLINE=1` on an `internal` network.
4. Images: copy by digest into the internal registry; run by digest; registry digest != local `.Id` with the containerd store (compare `RepoDigests`).
Checks that matter: tripwire hits == 0 for the offline serve, a control run without offline settings hits the tripwire.

## Quick diagnostics
| Symptom | Likely cause |
|---|---|
| `OfflineModeIsEnabled` / cannot find file in cache | file never downloaded (includes too narrow) or wrong `HF_HUB_CACHE` |
| 401/403 | token missing, gated repo, wrong mirror |
| works online, tripwire hit in offline run | another library/tokenizer phoning home; `HF_HUB_OFFLINE` unset in the container env |
| model loads but garbage output | wrong tokenizer/chat template or bad shard |

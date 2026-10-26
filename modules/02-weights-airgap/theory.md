# 02 — Weights and the air gap: Hugging Face cache and mirrors, safetensors, pickle scanning, S3, OCI artifacts, provably offline serving

Time: ~4.5 h (about 1.5 h theory, 3 h lab). Profiles: `store llm`. **Everything in this module is real** (hf-mirror, SeaweedFS, registry, ORAS, the tripwire, llama.cpp); the only stand-ins are named below. Versions: huggingface_hub 2.3.0 (`hf` CLI), safetensors 0.8, picklescan 1.0.5, ORAS 1.3.6, `registry:3`, SeaweedFS 4.51.

What is a stand-in: the **hf-mirror** is a small course-owned service that speaks the Hugging Face Hub API from a local cache. In a real air-gapped company that role is played by Artifactory/Nexus-style proxies or an internal Hub mirror; the client side (`HF_ENDPOINT`) is identical. SeaweedFS plays "internal S3" (MinIO's community repo was archived in April 2026; you will still meet MinIO, Ceph RGW, or vendor appliances). The **air gap** is an `internal: true` Docker network whose DNS is the tripwire; a real one is a physically or logically separate network where data moves through a controlled transfer.

## 1. Why weights are an infrastructure problem

| Property | Consequence |
|---|---|
| Size: 1 GB (small) to 140 GB (70B FP16) to 800 GB (frontier MoE) | Downloads take hours; storage, caching and bandwidth planning matter; copies must be verified |
| Provenance: files from the public internet, from strangers | Supply-chain risk: poisoned weights, malicious serialisation, typosquatted repos |
| Executable formats exist (pickle) | "Loading a model" can mean "running attacker code" |
| Immutable once published, but identified by mutable names (`main`, tags) | Without pinning to a commit or digest you cannot reproduce or audit a deployment |
| Needed at every cold start | The storage path (S3/NVMe/registry) is on the critical path of scale-up and recovery |
| Air-gapped sites | Nothing may fetch anything at runtime; every hidden download is an outage or a violation |

## 2. Formats

### 2.1 safetensors
A safetensors file is: **8 bytes** little-endian unsigned integer `N` (header length) + **N bytes of JSON header** + raw tensor bytes.
```
[ u64 LE: N ][ JSON header (N bytes) ][ data ... ]
header = { "__metadata__": {"format":"pt"},
           "model.embed_tokens.weight": {"dtype":"BF16","shape":[151936,896],"data_offsets":[0,272257024]}, ... }
```
- `data_offsets` are relative to the end of the header; tensors are contiguous, so a loader can `mmap` the file and take zero-copy views. No code is executed: a parser reads a bounded JSON header and slices bytes. (The library caps the header at 100 MB and validates offsets, shapes and file length; those checks exist because a hostile header is the remaining attack surface.)
- Large models are **sharded**: `model-00001-of-00004.safetensors`, ... plus `model.safetensors.index.json` with `weight_map: {tensor_name: shard_file}` and `metadata.total_size`. A missing or truncated shard is a classic partial-sync failure: the index references a file that is not there, or sizes differ.
- Reading the header yourself (lab task 2.1) is a 6-line program and a good debugging tool: tensor count, dtypes (is this really BF16? FP8?), total parameter count from shapes, whether two shards overlap.

### 2.2 Pickle-based checkpoints (`.bin`, `.pt`, `.pth`, `.ckpt`)
PyTorch's legacy format is a **zip** containing `data.pkl` (a pickle of the state dict) and raw tensor storages. Python's pickle is a small stack machine; relevant opcodes: `GLOBAL` / `STACK_GLOBAL` (import `module.name` and push it), `REDUCE` (call the top-of-stack callable with the next item as arguments), `INST`/`OBJ`/`NEWOBJ`/`BUILD` (construct objects, call `__setstate__`). A malicious file simply does `GLOBAL os system` + `REDUCE` with a command string: **unpickling = arbitrary code execution as the loading user**. This is a property of the format, not a bug in a library.
- `torch.load(..., weights_only=True)` uses a restricted unpickler that only allows tensors, primitive containers and a small allow-list; it is the **default since PyTorch 2.6**. It is a mitigation with a track record of bypasses, not a guarantee. Old code and `weights_only=False` still exist everywhere.
- A realistic benign checkpoint legitimately references `torch._utils._rebuild_tensor_v2`, `torch.FloatStorage` / `torch.BFloat16Storage`, `collections.OrderedDict`. A scanner that flags every `GLOBAL` has too many false positives; one that allow-lists too widely misses attacks. That tension is the whole difficulty.
- Other executable surfaces: `trust_remote_code=True` (runs Python from the model repo: modelling code, tokenizers), Keras Lambda layers, joblib/sklearn pickles, `.npy` with `allow_pickle=True`, custom tokenizer code.

### 2.3 GGUF
Single self-describing binary for llama.cpp: magic `GGUF`, version (3), tensor count, metadata KV count (architecture, tokenizer, chat template, hyperparameters), tensor infos, then 32-byte-aligned tensor data, usually quantised. No code execution, but the **chat template** in the metadata is a Jinja template rendered by the server: still data you should treat as input. vLLM's GGUF support is experimental; the usual flow is HF safetensors for vLLM, GGUF for llama.cpp/Ollama.

### 2.4 What a model "repository" contains
`config.json` (architecture and geometry), `generation_config.json`, `tokenizer.json` / `tokenizer_config.json` / `special_tokens_map.json` (or `tokenizer.model`), `chat_template` (inside tokenizer config or separate), weights (`*.safetensors`, index), sometimes `*.py` (remote code), README/licence. **Serving needs more than the weights**: a model that loads but has no `tokenizer.json` fails at first request, not at startup, in some stacks. Verify completeness, not just checksums.

## 3. The Hugging Face cache and `hf`

### 3.1 Layout (`HF_HUB_CACHE`, default `$HF_HOME/hub`, `HF_HOME` default `~/.cache/huggingface`)
```
hub/models--HuggingFaceTB--SmolLM2-360M-Instruct/
   blobs/<sha256 or git-sha1>             <- the actual bytes, named by content hash/etag
   refs/main                              <- text file: commit sha that "main" pointed to
   snapshots/<commit-sha>/config.json     <- symlinks into ../../blobs/<hash>
                          model.safetensors
```
- Files are stored once in `blobs/` (named by their ETag: sha256 for LFS/large files, git blob sha1 for small text files) and presented through **symlinks** in `snapshots/<commit>/`. Consequences: copying the cache with a tool that dereferences or drops symlinks (zip on some platforms, some SMB/NFS shares, `docker cp` flows) gives an empty or doubled cache; use `tar`/`rsync -a` or, better, `hf download --local-dir` to materialise plain files you can checksum.
- `revision` can be a branch, tag or **commit sha**. `main` moves; **pin the commit** in anything that must be reproducible (the lab's hf-mirror serves a fixed commit per repo).
- Environment variables that matter (all current in huggingface_hub 2.x): `HF_HOME`, `HF_HUB_CACHE`, `HF_ENDPOINT` (point the client at a mirror), `HF_TOKEN`, `HF_HUB_OFFLINE=1` (never touch the network; fail if a file is not cached), `HF_HUB_DISABLE_XET=1`, `HF_HUB_DISABLE_TELEMETRY=1`, `HF_HUB_DOWNLOAD_TIMEOUT`. `TRANSFORMERS_OFFLINE` is legacy: the Hub client's variable is what counts now. The old `huggingface-cli` is replaced by **`hf`**.
- `hf download REPO --revision <sha> --include "*.json" --include "*.safetensors" --local-dir DIR`: **always give explicit `--include` patterns** (repeat the flag; one flag with spaces is treated as one filename). A model repo often carries 2-4x more files than you need (ONNX, GGUF, TF, `.h5` variants): SmolLM2-360M-Instruct is ~724 MB of safetensors but several GB of everything else.
- `hf cache ls` / `hf cache rm` inspect and clean the cache (run `hf cache --help` on your version; the old `scan-cache` command was folded into these).
- **Xet**: the Hub now stores large files with the Xet protocol; `hf` uses it by default and asks the endpoint for a read token. A mirror that implements only the classic API must be used with `HF_HUB_DISABLE_XET=1` (the course sets it).
- A mirror must implement four calls for `hf download` to work: model revision info (`GET /api/models/{repo}/revision/{rev}`), the file tree (`GET /api/models/{repo}/tree/{sha}`), `HEAD /{repo}/resolve/{rev}/{path}` (size + ETag + commit header), and `GET /{repo}/resolve/{sha}/{path}` (bytes, ideally with `Range` support for resume).

### 3.2 Integrity: what the ETag does and does not give you
- For LFS-stored files the ETag **is the sha256 of the content**; the client can verify what it downloaded. For small git-stored files it is the git blob sha1. So the hash is free for weights but not uniform across files.
- A hash you read from the same server as the file only proves the transfer was not corrupted, not that the file is the one you intended. **Integrity** (no corruption) and **authenticity** (it came from who you think) are different: for authenticity you need a hash/signature obtained out of band (a signed manifest produced on the connected side; the OpenSSF model-signing project / Sigstore is the emerging standard).
- Practice: on the connected side compute `SHA256SUMS` for every file of a pinned commit; carry it separately from the data; verify on the inside before anything is promoted. Verify **again** after storing in S3 and before loading, because every copy is a chance to corrupt.

## 4. Scanning and trust

### 4.1 What scanners do
**picklescan** (v1.0.5), **modelscan** (ProtectAI), **fickling** and Hugging Face's own pipeline walk the pickle opcode stream *without executing it* and report dangerous imports: `os`, `posix`, `subprocess`, `builtins.eval/exec`, `socket`, `runpy`, `shutil`, `importlib`... Typical steps: for zip checkpoints open each member ending in `.pkl`; iterate opcodes with `pickletools.genops`; resolve `STACK_GLOBAL` (its module and name come from the two preceding string pushes); match against a deny list and/or allow list; report findings with the opcode position.
Writing the minimum version yourself (lab task 2.2) teaches the technique and its limits.

### 4.2 Why "scanner passed" is not "safe"
1. **Deny lists are incomplete.** A long series of bypasses of deny-list scanners has been published (alternative import paths, obscure callables, nested or malformed archives, file-extension tricks, opcodes the scanner did not understand). New ones appear; scanners add them: you are always behind.
2. **Not everything is pickle.** Malicious `modeling_*.py` (remote code), tokenizers, Lambda layers, and "safe" formats whose loaders have bugs are outside the opcode scan.
3. **Scanning is not provenance.** A model can be clean of malware and still be backdoored in its behaviour (poisoned weights) or simply not the model you asked for.
4. A parse that fails or an archive the scanner skips must be a **fail**, not a pass.

### 4.3 What teams actually do
Layered controls: (a) **policy: safetensors only** — reject `.bin/.pt/.pkl` at the gate unless converted in a sandbox; (b) pin sources (allow-listed orgs, commit shas, hashes in the manifest); (c) scan **in quarantine** (a throwaway sandbox with no network) before promotion to the internal mirror; (d) never run `trust_remote_code=True` from unreviewed repos — vendor and review the code, or use engine-native implementations; (e) serve with a non-root user, read-only root filesystem, no egress; (f) record the digest of what is running (module 05/08 evidence, module 10 postmortems).

## 5. Object storage for weights (S3 API)

- Why S3 (or similar): shared by many nodes, scalable, access-controlled, cheap per TB, versionable. How it is consumed: an init container or sidecar syncs the model to node-local NVMe before the engine starts; some engines can stream tensors directly (vLLM `--load-format runai_streamer`, Tensorizer), others mount a bucket through a CSI driver; **never** point an engine at slow remote storage and expect fast cold starts.
- **Identities and least privilege.** Two identities per bucket: **RW** for the sync pipeline (the only thing that can write), **RO** for the serving side (Read + List). A serving pod that can `PutObject`/`DeleteObject` on the weights bucket can be turned into a model-tampering tool. In SeaweedFS this is `s3.json` identities with actions `Read,List` vs `Admin,Read,Write,List,Tagging`; a read-only identity gets `403 AccessDenied` on PUT/DELETE, while a bad key gets `InvalidAccessKeyId`: two different failures, keep them apart when debugging.
- **Integrity in S3**: object ETags are *not* sha256 (multipart uploads produce `md5-of-md5s-N`); store the sha256 as object metadata or as a manifest object next to the data and verify after download.
- **Layout and immutability**: `s3://models/<org>/<model>/<commit-sha>/...` plus a small `manifest.json`; never overwrite a published prefix; enable versioning / object lock if the store supports it; promotion = writing a pointer or a new prefix.
- **Throughput maths** (do it for your cluster): transfer time = size / effective bandwidth. 140 GB at 10 Gb/s line rate (1.25 GB/s) = 112 s; at a realistic 60% = ~190 s; from one S3 node to 20 pods at once the node's NIC is shared 20 ways: 20 × 140 GB = 2.8 TB leaving one machine, so cache on the node (hostPath/local NVMe) and pull once per node, not once per pod.
- MinIO: the community repository was archived on 2026-04-25 (no new images); existing deployments keep running and are common, but new builds choose SeaweedFS, Ceph RGW, Garage, RustFS, or a vendor product.

## 6. Models and engines as OCI artifacts

An OCI registry stores **content-addressable blobs** with a **manifest** that lists them. It is not only for container images:
- **ORAS** (`oras push/pull`, v1.3.6) pushes arbitrary files with an `artifactType` and per-layer `mediaType` (e.g. `application/vnd.aiinfra.model.v1`, layer `application/vnd.aiinfra.gguf`): `oras push --plain-http REG/models/qwen:q4 model.gguf:application/vnd.aiinfra.gguf`. `oras pull` restores the file; the manifest digest identifies the whole artifact.
- Higher level: **KitOps ModelKit**, and Kubernetes patterns that mount an OCI artifact as a volume (KServe "modelcar" sidecar images; Kubernetes image volumes, beta in 1.33 behind a feature gate: verify the gate on your cluster). The appeal: the registry you already operate (auth, replication, retention, scanning, air-gap mirroring) now also distributes weights.
- Limits: registries are tuned for many mid-size layers, not 140 GB single blobs: check max blob size, upload timeouts and storage backend behaviour; chunk large models into layers per shard.

### 6.1 Tag vs digest
A **tag** (`llama:server-b11889`) is a mutable pointer; a **digest** (`@sha256:…`) is the immutable identity of a manifest. Deploy by digest (or at least record it): "same tag, different bytes" is a real incident type, and in an air gap you are the only party who can notice.
- **Pitfall (verified on this host)**: with Docker's containerd image store, `docker push` of a locally multi-arch image may push **only the single-platform manifest**, so the digest in the registry differs from the "index digest" `docker images --digests` shows locally. Always take the digest from the **registry's response** (`Docker-Content-Digest` header, `oras manifest fetch --descriptor`, `skopeo inspect`) and compare that with what is running (`docker inspect` → `RepoDigests`, or the container's image reference by digest) — never compare against a local image `Id`.
- Mirroring engine images: `docker pull` on the connected side, `docker save`, transfer with a hash, `docker load`, `docker tag`, `docker push` to the internal registry; or `oras cp` / `skopeo copy` / `crane copy` between registries (preserves digests when copying the full multi-arch index). Pin by digest in compose/Helm (`image: registry:5000/llama@sha256:…`).

## 7. The air gap

### 7.1 Pipeline
```
 connected side                                       |   air-gapped side
 download (pinned commit) → hash → scan (quarantine) →| transfer (media/diode) → verify hashes → re-scan (optional) →
 sign manifest                                        |   store (S3/OCI, immutable prefix) → deploy by digest → serve offline
```
Controls at each arrow: allow-listed sources, pinned commits, SHA256SUMS or signed manifest, scanner in a sandbox, a human or policy gate before promotion, immutable storage paths, and a record (what, from where, which hash, who approved).

### 7.2 "Offline" configuration is not isolation
- `HF_HUB_OFFLINE=1`, `local_files_only=True`, `HF_HOME`/`HF_HUB_CACHE` pointing at a populated cache and `--model /path` (a local directory, not a repo id) make the **HF client** stay local. They do not stop anything else in the process, the image or the cluster from calling out.
- Common hidden phone-homes: `HF_HUB_DISABLE_TELEMETRY` / `DO_NOT_TRACK`; vLLM usage statistics (`VLLM_NO_USAGE_STATS=1`); `tiktoken` downloading BPE files (`TIKTOKEN_CACHE_DIR` with pre-seeded files); LiteLLM fetching its model-price map from GitHub (`LITELLM_LOCAL_MODEL_COST_MAP=True`); Open WebUI version checks and model downloads (`OFFLINE_MODE`, `ENABLE_VERSION_UPDATE_CHECK=false`); `transformers` downloading tokenizers/configs for a repo id; Python packages fetched at container start; image pulls from public registries.
- So the proof is **network-level**: run the workload on a network with no route out (`internal: true`), point its DNS at a **tripwire** that answers every name with a sink and logs every query, then show zero queries for external names during startup and serving. Always run the **control**: the same workload without the offline settings must trip the wire, otherwise a silent tripwire proves nothing (maybe the wire is cut).
- In the lab: the tripwire's DNS **query log** is the authoritative hit counter, because HTTPS never reaches the sink's HTTP log (the TLS handshake fails or targets the host name only via DNS/SNI). AAAA queries may be refused: harmless. Containers on an internal network cannot publish ports to the host, so probes run as short-lived containers *inside* the network.
- In production the equivalents are egress policies (NetworkPolicy default-deny, firewall at the cluster boundary), a deny-all DNS or a sinkhole, and egress logs reviewed as evidence.

### 7.3 Cold start budget
Total time to first token after a deploy = scheduling + image pull + **weight transfer** + load into VRAM + compile/graph capture. Weight transfer dominates for large models. Reduce it with node-local caches (pre-pulled DaemonSet), prefetching on node join, sharded parallel downloads, and keeping a couple of warm spares. Measure each phase; "the pod is Pending/ContainerCreating for 12 minutes" is usually the pull, not the engine.

## 8. What the lab does and does not show
- Real: hf client against a mirror via `HF_ENDPOINT`, safetensors header parsing, pickle scanning of hostile (but inert) files (they are built so that executing them would only `touch` a canary file you can check), S3 identities and 403s, registry digests, ORAS, network-level offline proof.
- Simplified: one small model instead of 100+ GB, a local mirror instead of an enterprise proxy, no real malware (payloads are inert canaries), no signature infrastructure (we use SHA256SUMS), one machine instead of a diode between networks, no CSI/Kubernetes distribution of weights.
- In production the dominant problems are volume (transfer time, storage), process (who approves a model, how the manifest is signed, audit trail) and the long tail of hidden network calls — not the cleverness of a scanner.

## Key takeaways
1. A model is a set of files: weights **and** config/tokenizer; verify completeness and integrity of the whole set, pinned to a commit.
2. safetensors = 8-byte length + JSON header + raw bytes: no code execution; pickle = a program: loading it is running it. Policy: safetensors only.
3. HF cache = `blobs` (content) + `snapshots` (symlinks) + `refs`; use `hf download --local-dir` with explicit `--include` and a pinned revision; `HF_ENDPOINT` points at an internal mirror (four API calls).
4. Integrity ≠ authenticity: hashes must travel out of band; verify at every hop (download, transfer, store, load).
5. Scanners find known-bad patterns in pickles; they do not prove safety. Layer: format policy, provenance, quarantine, sandboxed serving.
6. Weights in S3: RW only for the pipeline, RO for serving; immutable prefixes by commit; sha256 manifest next to the data; node-local caching for cold start.
7. OCI registries distribute engines and (via ORAS) models; deploy by digest and read the digest from the registry, not from the local image store.
8. `HF_HUB_OFFLINE` and friends are client settings; only network isolation plus a tripwire with a control run proves "offline".

## Check yourself
1. A safetensors file starts with the bytes `00 01 00 00 00 00 00 00`. How long is the JSON header and where does tensor data begin?
2. Name three reasons a clean picklescan report does not mean a model is safe to load.
3. Why do you compare the manifest hash of a downloaded model against a hash from a different channel than the download itself?
4. Your serving pods use the same S3 key as the sync job. What can go wrong, and what is the minimal fix?
5. A run with `HF_HUB_OFFLINE=1` on an internal network produced zero tripwire hits. What second experiment do you need before claiming the setup is air-gap safe?

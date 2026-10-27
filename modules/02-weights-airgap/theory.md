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

## 9. What `hf download` does on the wire (and why a mirror needs exactly four endpoints)

For `hf download org/name --revision R --include P1 --include P2 --local-dir D` with `HF_ENDPOINT=E`:
1. `GET E/api/models/org/name/revision/R` → JSON with the **commit sha** and the list of files (`siblings`). A branch/tag name is resolved to a sha here; a sha resolves to itself. The client filters the list with your `--include` patterns (fnmatch, where `*` also matches `/`).
2. `GET E/api/models/org/name/tree/<sha>?recursive=true` → per-file size, `oid` and (for LFS files) the LFS `oid` = sha256. This is how the client knows the expected hash of large files.
3. Per file: `HEAD E/org/name/resolve/<sha>/<path>` → `Content-Length`, `ETag`, `X-Repo-Commit`, optionally `X-Linked-Etag`/`X-Linked-Size` (LFS). The client decides: already present with that ETag? skip; else download.
4. `GET E/org/name/resolve/<sha>/<path>` (with `Range` when resuming a `.incomplete` partial file) → bytes. After the download the client checks the size, and for LFS files the sha256 against the ETag.
5. Writes: into the cache (`blobs/<etag>`, `snapshots/<sha>/<path>` symlink, `refs/<branch>` when a branch name was used) or, with `--local-dir`, plain files plus a `.cache/huggingface/` metadata folder that records the commit and ETag per file so the next run can skip unchanged files.
Details worth knowing:
- With a **commit sha** as revision, no `refs/main` is written. An offline `snapshot_download("org/name")` (revision `main`) then fails with "not in cache" while `--revision <sha>` works. This bites people who populate a cache with a pinned sha and then start an engine without pinning the same sha.
- **Resume** works through `Range`; a mirror without range support turns every interrupted 20 GB shard into a restart. **Parallelism**: files are fetched in parallel (`--max-workers`); a single huge shard is one stream unless the Xet protocol is used.
- **Xet**: huggingface_hub 2.x uses the Xet content-addressed protocol for repos stored that way, calling `GET .../xet-read-token/<sha>`. Mirrors that implement only the classic API answer 404 and clients configured with `HF_HUB_DISABLE_XET=1` use the classic `resolve` path. Enterprise proxies state which they support.
- **Gated models** (Llama, Gemma): licence acceptance and `HF_TOKEN` are required on the *connected* side; inside the air gap there is nothing to gate: record the licence and approval in your manifest instead.
- **Tokens never go in images or manifests**; the connected-side pipeline holds them in a secret store.

## 10. safetensors in more depth

A concrete file (a toy checkpoint with two tensors), as bytes:
```
00000000  b6 00 00 00 00 00 00 00  7b 22 5f 5f 6d 65 74 61  |........{"__meta|   <- N = 0xb6 = 182 header bytes
00000008  ...                       {"__metadata__":{"format":"pt"},
                                     "w":{"dtype":"BF16","shape":[2,3],"data_offsets":[0,12]},
                                     "b":{"dtype":"F32","shape":[2],"data_offsets":[12,20]}}      (padded with spaces to 8-byte alignment)
000000be  <12 bytes of w><8 bytes of b>                                                           <- data starts at 8 + 182 = 190
```
Parsing it takes six lines and no dependencies:
```python
import json, struct
def read_header(path):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        return n, json.loads(f.read(n))        # data begins at 8 + n
```
Integrity rules a loader enforces (and your own validator should): the header length is bounded (the reference implementation refuses headers larger than 100 MB); `data_offsets` are `[begin, end)` byte offsets relative to the data buffer; tensors must tile the buffer **contiguously without gaps or overlaps**; `end - begin` must equal `prod(shape) × dtype size`; the last `end` must equal file size − (8 + n). A truncated download violates the last rule, which is why safetensors files fail loudly at load instead of silently producing garbage: it is the cheapest corruption detector you have before you compute a single hash.
- **dtype names** you will see: `F32`, `F16`, `BF16`, `F8_E4M3`, `F8_E5M2`, `I8`, `I32`, `I64`, `U8`, `BOOL`. A "FP8 model" is mostly `F8_E4M3` tensors plus `BF16`/`F32` scale tensors. Counting dtypes in the headers tells you in seconds whether the artefact is what the ticket said.
- **Parameter count** = sum over tensors of the product of `shape` (tied embeddings appear once). Compare with the model card: a mismatch means a missing shard or a different checkpoint.
- **Sharding**: `model.safetensors.index.json` has `metadata.total_size` (bytes of all tensors) and `weight_map` (tensor name → shard file). Validate three things: every shard named in the map exists, every tensor in each shard's header appears in the map exactly once, and the byte total equals `total_size`. The course's loader check (2.6.3) performs exactly these.
- **Loading**: libraries `mmap` the file and create tensor views, so start-up cost is page-cache/IO bound; a cold read from network storage is the real cold-start cost (section 17). `safe_open` can read one tensor without touching the rest, which is how tensor-parallel workers read only their slice.
- **Converting** a pickle checkpoint to safetensors means *loading the pickle once*: do it in a throw-away sandbox (no network, read-only input mount, dropped capabilities), then ship only the safetensors. Treat the converter's host as compromised-by-design.
- **Not covered by safetensors**: tokenizers, chat templates (Jinja executes in a sandboxed environment in the libraries, but treat templates as input), `config.json` `auto_map` entries that point to remote code, and any `*.py` in the repo.

## 11. Pickle internals and scanner design

### 11.1 A hostile pickle, disassembled
`pickle.dumps` of an object whose `__reduce__` returns `(os.system, ("touch /tmp/x",))` at protocol 4 contains (via `python -m pickletools`):
```
 0: \x80 PROTO      4
 2: \x95 FRAME      ...
11: \x8c SHORT_BINUNICODE 'posix'          <- module name string
18: \x94 MEMOIZE
19: \x8c SHORT_BINUNICODE 'system'         <- attribute name string
27: \x94 MEMOIZE
28: \x93 STACK_GLOBAL                       <- import posix.system, push it
29: \x94 MEMOIZE
30: \x8c SHORT_BINUNICODE 'touch /tmp/x'
...
    \x85 TUPLE1 ; \x52 REDUCE                <- call posix.system('touch /tmp/x')
```
At protocol 0-3 the same import is a single `GLOBAL 'posix system'` opcode. A scanner that only looks for `GLOBAL` misses every protocol-4 file. `STACK_GLOBAL` has no operands: the names are whatever strings were pushed before it, possibly fetched from the **memo** (`BINGET`) rather than pushed again, so a correct scanner tracks pushes and memo puts/gets. (Python's `os.system` pickles as `posix.system` on Linux and `nt.system` on Windows: deny-lists must include the platform modules.)

### 11.2 Where the danger is, and the three kinds of scanner
- Dangerous opcodes: `GLOBAL`, `STACK_GLOBAL`, `INST`, `OBJ` (import/instantiate), `REDUCE`, `NEWOBJ`, `NEWOBJ_EX`, `BUILD` (calls `__setstate__`), `EXT1/2/4` (extension registry). Benign checkpoints also use some of these, so the *target* of the import decides.
- **Deny-list scanners** (picklescan's approach, modelscan's severity tables): flag known-dangerous callables (`os`, `subprocess`, `builtins.eval/exec/compile/open`, `socket`, `shutil`, `runpy`, `importlib`, `pty`, `ctypes`, ...). Weakness: any dangerous callable not on the list (or reachable through an allowed module, e.g. a function in `numpy` or `pandas` that evaluates strings) passes. This is where published bypasses come from.
- **Allow-list scanners**: permit only what a tensor checkpoint legitimately needs (`collections.OrderedDict`, `torch._utils._rebuild_tensor_v2`, `torch.*Storage`, `numpy` array reconstruction) and flag everything else. Fewer bypasses, more false positives for exotic but legitimate files; you maintain the list. This is what `torch.load(weights_only=True)` does at load time.
- **Restricted unpickling** (`find_class` override) is the runtime equivalent of an allow-list and should wrap *every* place your own code unpickles anything.
Your lab scanner is an allow-list scanner; picklescan is a deny-list scanner. Running both and comparing is the exercise.

### 11.3 Archive and container tricks a scanner must survive
PyTorch zip checkpoints (`archive/data.pkl`, one or more pickles, raw tensor storages); nested archives; files whose **extension lies** (a `.safetensors` that is a pickle, a `.bin` that is a zip); several pickles concatenated in one stream (a second `STOP`-terminated pickle after the first); huge files (scan time, memory); corrupted zips that Python's `zipfile` and PyTorch's reader interpret differently. Decisions: classify by **magic bytes**, not by name; scan every pickle member; treat parse errors and unknown structures as **dangerous**; cap sizes and time.

### 11.4 Scan, then what?
A scan result belongs to one **hash**: record `sha256 → scanner name + version + verdict + date` in your manifest, rescan when the scanner's rules change (new bypasses are added over time), and never let a file move between zones under a different name without its record. Scanning at scale is a pipeline stage (quarantine bucket → scanner job in a sandbox → promote or reject), not a developer habit.

## 12. Model supply chain: controls that actually get used
| Threat | Example | Control |
|---|---|---|
| Executable format | pickle checkpoint, Keras Lambda, `trust_remote_code` | safetensors-only policy; review/vendor remote code; sandboxed conversion |
| Typosquat / impersonation | `meta-Ilama/...` (capital I) org lookalike | allow-list of orgs and repo ids; no free-text `--model` in prod |
| Moving target | `main` changes, files replaced | pin commit sha, SHA256SUMS, immutable internal prefix |
| Poisoned behaviour | fine-tune with a trigger phrase | provenance (who trained it), evals including red-team prompts, staged rollout; scanning cannot detect this |
| Licence violation | non-commercial licence in a product | licence field in the manifest, legal approval gate |
| Dependency drift | a different tokenizer/chat template revision | pin tokenizer files in the same commit; hash all files |
| Tampering in transit/storage | bit flips, malicious replacement | hashes at each hop, signed manifest, RO credentials for serving |
**Model bill of materials** (what a good record contains): source URL and commit, licence, list of files with sha256 and sizes, converter/quantiser name and version if you produced it, scanner verdicts, who approved and when, which environments received it. A signed manifest (OpenSSF model-signing / Sigstore tooling, or an internal key) turns the hash list into an authenticity statement: verify the signature on the inside before promoting.
**Approval workflow example**: request (repo, commit, purpose, licence) → automated checks (format policy, licence field, size) → sandboxed scan/convert → hash manifest + signature → human approval for new orgs or new formats → transfer → inside verification → promote to the immutable prefix `models/<org>/<name>/<commit>/` → deployment references the prefix and the manifest digest.

## 13. Mirrors and proxies in real companies
- **Pull-through proxy** (a remote repository in Artifactory or similar, `HF_ENDPOINT` pointing at it): developers on the *connected* side fetch through it; it caches, logs and can block by policy. It is not an air-gap tool by itself (it must reach the internet).
- **Curated internal mirror / registry** inside the gap: populated only by the transfer pipeline; clients use `HF_ENDPOINT=https://hub.internal/...`; no upstream. The product's URL form differs (some use a dedicated API path per repository key): follow the vendor's documentation and test `hf download` with an explicit `--include`, because partial API coverage is the usual failure.
- Operational questions to settle: retention (models are huge; who deletes superseded commits?), per-team access, audit logs (who downloaded what), staleness (how fast can an urgent model reach production?), disaster recovery (the mirror is now the only copy), and capacity (a few hundred GB per model family adds up to tens of TB).
- Alternatives to a Hub-compatible mirror: S3/NFS directories of pinned snapshots (engines load from a path, no `HF_ENDPOINT` needed), OCI registries (module section 6), or an ML registry (MLflow, Harbor-hosted OCI). The pattern that scales: **the inside never talks the Hub protocol**; deployments point at a path or a digest produced by the pipeline.

## 14. Object storage for weights, in detail
- **Layout**: `models/<org>/<name>/<commit-sha>/<files>` plus `manifest.json` (file list, sizes, sha256, scan verdicts, signature). One immutable prefix per commit; "latest" is a pointer your deployment tooling resolves, never an overwrite.
- **Credentials as policy**. SeaweedFS identities list `actions`: `Read`, `List`, `Write`, `Tagging`, `Admin` (and bucket-scoped variants like `Read:models`). RO = `Read, List`; RW = + `Write, Tagging, Admin`. The equivalent AWS-style policy for serving is `s3:GetObject` and `s3:ListBucket` on the prefix only. Put the sync identity in the pipeline's secret store; mount the RO identity into pods as a Kubernetes Secret, scoped per namespace.
- **Multipart uploads and checksums**: uploads above a threshold (commonly 8-64 MB) are split into parts; the resulting ETag is `md5(md5(part1)||md5(part2)...)-N` and is useless as a content hash. Use S3 additional checksums (SHA-256) where the store supports them, or your own metadata/manifest.
- **Throughput**: one TCP stream to S3 rarely exceeds 100-200 MB/s; fast loaders use many parallel range GETs (8-32 streams) — `s5cmd`, `rclone`, `aws s3 sync` with high concurrency, or the engine's streaming loader. Model load time = size ÷ achievable bandwidth: 140 GB at 1 GB/s is 2.3 minutes, at 100 MB/s it is 23 minutes.
- **Presigned URLs** give time-limited access without sharing credentials (useful for the transfer step); keep expiry short.
- **Versioning and object lock** (where supported) protect against accidental overwrite and ransomware-style deletion; lifecycle rules expire old commits.
- **The node-local cache pattern** (what most teams converge on):
```yaml
initContainers:
- name: fetch-model
  image: registry.internal/tools/s5cmd@sha256:...
  args: ["sync", "s3://models/org/name/<commit>/*", "/models/"]     # RO credentials from a Secret
  volumeMounts: [{name: models, mountPath: /models}]
volumes:
- name: models
  hostPath: {path: /var/lib/models, type: DirectoryOrCreate}        # node-local NVMe, shared by pods on the node
```
A DaemonSet that pre-pulls the models a node will run turns a 20-minute cold start into a few seconds of page-cache warm-up. Verify the cache by hash on start (cheap for a manifest of sizes, expensive for a full re-hash: decide per environment).

## 15. OCI artifacts in more depth
An ORAS-pushed artifact is a normal OCI image manifest:
```json
{ "schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "artifactType": "application/vnd.aiinfra.model.v1",
  "config": {"mediaType": "application/vnd.oci.empty.v1+json", "digest": "sha256:44136f...", "size": 2},
  "layers": [{"mediaType": "application/vnd.aiinfra.gguf", "digest": "sha256:<file sha256>", "size": 397808192,
              "annotations": {"org.opencontainers.image.title": "qwen2.5-0.5b-instruct-q4_k_m.gguf"}}] }
```
- The **layer digest is the file's sha256**; the **manifest digest** (what you record and deploy by) covers the whole descriptor list. Pulling by manifest digest therefore pins every file and the metadata.
- **Referrers**: signatures, SBOMs, scan reports attach to an artifact by digest (`oras attach`, the OCI 1.1 referrers API; `registry:3` supports it), so provenance travels with the model without changing its digest.
- **Large blobs**: check registry limits (max blob size, upload timeouts, reverse-proxy body limits). For a 140 GB model use one layer per shard (parallel and resumable) rather than one 140 GB layer.
- **Retention and garbage collection**: deleting a manifest does not free blobs; the registry needs garbage collection (and delete enabled, as in the lab). Without a retention policy a registry used for weights fills a disk quietly.
- **Air-gap transfer of images**: `docker save`/`load` loses multi-arch indexes when you save one platform; `skopeo copy --all` or `crane copy` / `oras cp` between registries (or to an OCI layout directory and back) preserves the index and digests. Always compare the digest after the hop.
- **In Kubernetes**: reference images by digest in manifests (`image: registry.internal/llama@sha256:...`); admission policies can require digests and a trusted registry prefix. Mounting a model artifact as a volume (image volume source, beta in 1.33 and behind a feature gate there; KServe's modelcar pattern as the older route) lets the container runtime's existing pull and cache machinery distribute weights.

## 16. Offline checklist: every component that may phone home
| Component | Behaviour | Switch / fix |
|---|---|---|
| Hugging Face client | resolves repo ids over the network | `HF_HUB_OFFLINE=1`, local path or pinned cache + `--revision <sha>`; `HF_HUB_DISABLE_TELEMETRY=1` |
| `transformers`/tokenizers | downloads missing files for a repo id | give a local directory; same offline flags |
| vLLM | usage statistics; downloads for a repo id; JIT/compile caches | `VLLM_NO_USAGE_STATS=1`, `DO_NOT_TRACK=1`, local `--model` path, persistent `VLLM_CACHE_ROOT` |
| llama.cpp | `-hf`/`--hf-repo` downloads | never use them in the gap; mount the GGUF |
| tiktoken-based code | downloads BPE files on first use | pre-seed `TIKTOKEN_CACHE_DIR` |
| LiteLLM | fetches its model price/context map from GitHub at start | `LITELLM_LOCAL_MODEL_COST_MAP=True` |
| Open WebUI | version check, model downloads | `OFFLINE_MODE=true`, `ENABLE_VERSION_UPDATE_CHECK=false`, embeddings via the gateway |
| Langfuse, Grafana, others | telemetry/update checks | their `TELEMETRY_ENABLED=false` / `check_for_updates=false` style settings |
| Python/pip, apt, npm in images | install at container start | bake dependencies into images; no install at runtime |
| Container runtime | pulls missing images from public registries | `pull_policy: never`/internal registry mirrors; digests |
| OS | NTP, DNS, package mirrors, certificate revocation checks | internal NTP/DNS/mirrors; document exceptions |
**How to prove it**: (1) isolate at the network layer (no default route, DNS to a sinkhole that logs every query); (2) run the *whole* lifecycle (start, health, first request, a few minutes idle, restart) and keep the log; (3) run a **control** with one offline setting removed and show the sinkhole reacts; (4) keep the evidence (queries, container logs, versions, digests) with the deployment record. In production the sinkhole is your firewall/DNS logging plus a default-deny egress policy; the lab's tripwire is the same idea at small scale. For deeper evidence use `strace -f -e trace=connect` on the process or a packet capture on the namespace's interface.

## 17. Cold-start arithmetic
`time to first request = schedule + image pull + weights transfer + load into VRAM + compile/graph capture`
| Phase | 8B FP16 (16 GB) | 70B FP8 (70 GB) | 70B FP16 (140 GB) |
|---|---|---|---|
| image pull (10 GB image, cached on node: 0 s; cold at 1 GB/s: 10 s) | 0-10 s | 0-10 s | 0-10 s |
| weights from node NVMe (3 GB/s, cold page cache) | 5 s | 23 s | 47 s |
| weights from S3 at 1 GB/s | 16 s | 70 s | 140 s |
| weights from S3 at 150 MB/s (single stream) | 107 s | 7.8 min | 15.6 min |
| host → GPU copy (PCIe, ~20 GB/s effective) | ~1 s | ~4 s | ~7 s |
| engine init, compile/profiling, CUDA graphs | 1-3 min | 2-5 min | 3-8 min |
When a node dies at 03:00 and the replacement pulls from a cold S3 stream, the service is degraded for ~20 minutes: the argument for node-local caches, warm spares and parallel range downloads is made with this table. Measure your own: the interesting number is the **95th percentile** over a week of rollouts, not the best case.

## 18. How the lab maps to this theory
| Task | Concept | Section |
|---|---|---|
| 2.1 | hf download mechanics, pinned commit, include patterns, safetensors header | 3, 9, 10 |
| 2.2 | pickle opcodes, allow-list scanner, never execute | 2.2, 4, 11 |
| 2.3 | least-privilege S3, hashes beside objects | 5, 14 |
| 2.4 | offline flags vs network isolation, tripwire, control run | 7.2, 16 |
| 2.5 | digests vs tags, registry digest, ORAS artifact | 6, 6.1, 15 |
| 2.6 | completeness vs hash check, targeted repair | 2.4, 3.2, 10 |

## 19. The pipeline as code (sketch you can adapt)

### 19.1 Connected side: download, hash, scan, package
```bash
set -euo pipefail
REPO=org/name; COMMIT=<40-hex sha from the approval ticket>; OUT=staging/$REPO/$COMMIT
export HF_HUB_DISABLE_XET=1 HF_HUB_DISABLE_TELEMETRY=1            # token comes from the secret store, never the script
hf download "$REPO" --revision "$COMMIT" --local-dir "$OUT" \
   --include "*.json" --include "*.txt" --include "*.safetensors" --include "tokenizer.model"
( cd "$OUT" && find . -type f -not -path './.cache/*' | sort | xargs sha256sum ) > "$OUT.SHA256SUMS"
python verify_safetensors.py "$OUT"          # headers parse, offsets tile the file, index total_size matches
test -z "$(find "$OUT" -name '*.bin' -o -name '*.pt' -o -name '*.pkl' -o -name '*.py')"   # policy: no executable formats
jq -n --arg repo "$REPO" --arg commit "$COMMIT" --arg licence "$LICENCE" --slurpfile files <(sums_to_json "$OUT.SHA256SUMS") \
   '{repo:$repo, commit:$commit, licence:$licence, files:$files[0], scanned_by:"policy+headers", approved_by:"<ticket>"}' > "$OUT.manifest.json"
sign "$OUT.manifest.json"                    # internal key or Sigstore/model-signing tooling
tar --sort=name --owner=0 --group=0 -cf transfer-$COMMIT.tar -C staging "$REPO/$COMMIT" "$REPO/$COMMIT.SHA256SUMS"   # (not for >TBs: use the transfer tool's own chunking)
sha256sum transfer-$COMMIT.tar > transfer-$COMMIT.tar.sha256
```
### 19.2 Inside: verify, store, promote
```bash
sha256sum -c transfer-$COMMIT.tar.sha256 && tar -xf transfer-$COMMIT.tar
verify_signature "$MANIFEST"                              # authenticity
( cd "$DIR" && sha256sum -c ../$COMMIT.SHA256SUMS )       # integrity of every file
python verify_safetensors.py "$DIR"                       # completeness: tokenizer, index, shards
s5cmd sync "$DIR/" "s3://models/$REPO/$COMMIT/"            # RW identity, only this job has it
verify_remote_hashes "s3://models/$REPO/$COMMIT/"          # re-read with the RO identity and compare
publish_pointer "$REPO" "$COMMIT"                          # a small object/db row; deployments reference the commit prefix
```
A **manifest** worth having (abridged):
```json
{"repo":"org/name","commit":"3f9c...","licence":"apache-2.0","files":[{"path":"model-00001-of-00004.safetensors","sha256":"ab12...","size":4976698672}],
 "checks":{"format_policy":"pass","headers":"pass","scanner":"picklescan 1.0.5: n/a (no pickle)"},"approved_by":"CHG-1234","created":"2026-10-26T09:00:00Z"}
```
Every step is idempotent and logged; the transfer step is the only manual (or media-based) one.

## 20. Troubleshooting weights: symptom → check
| Symptom | Check | Typical cause |
|---|---|---|
| `hf download` gets 404 on a file listed in the repo | `HEAD` the resolve URL with `curl -I`; look at `X-Error-Code` | mirror lacks the file/revision; revision typo; Xet token request failing (set `HF_HUB_DISABLE_XET=1`) |
| `hf download` downloads gigabytes you did not expect | list `siblings` first (`hf download --dry-run` if available, or the revision JSON) | missing `--include`; ONNX/GGUF/TF variants in the repo |
| Engine says "not found in cache" with `HF_HUB_OFFLINE=1` | `ls $HF_HOME/hub/models--*/refs`, `snapshots` | cache populated with a sha but started with `main`; wrong `HF_HOME`; symlinks lost in copy |
| Engine fails at first request, not start-up | does the dir contain `tokenizer.json` / `tokenizer_config.json` / chat template? | incomplete sync (weights copied, tokenizer forgotten) |
| `SafetensorError: MetadataIncompleteBuffer` / "HeaderTooLarge" | `ls -l` against the manifest size; read the first 8 bytes | truncated or corrupted file |
| Loads, but outputs are garbage | hash every shard; compare dtype set with the model card | a flipped byte in a weights shard that kept the file length; wrong dtype/quantisation config |
| Model loads on one node, not another | hash on both; check disk-full and permissions of the cache dir | partial copy to the second node, root-owned files |
| Pods Pending/ContainerCreating for ages | `kubectl describe pod` (image pull vs volume), registry logs | image pull from a slow/overloaded registry; init container syncing from S3 |
| Tripwire reports queries after "offline" settings | read the query log: which host, which process (stop containers one by one) | telemetry, tokenizer/tiktoken download, model-cost-map fetch, update check |
| `403 AccessDenied` on PUT from a pod | which identity is mounted? | that is the design: serving is read-only; the sync job needs the RW identity |
| `InvalidAccessKeyId` | the key id itself | typo, wrong environment's secret |
| Registry digest differs from `docker images --digests` | `curl -I` the manifest, read `Docker-Content-Digest` | containerd image store pushes a single-platform manifest; record the registry's digest |

## 21. Worked example: a shard with one flipped byte
A deployment fails with `RuntimeError: Error loading checkpoint shard 'model-00003-of-00004.safetensors': sha256 mismatch`. The file has the right size and its header parses, so the cheap checks (size, header) pass and only the hash catches it.
1. `cd bundle && sha256sum -c SHA256SUMS` → `model-00003-of-00004.safetensors: FAILED` (and `... No such file` lines for files that never arrived: the check output has two different failure kinds).
2. Record evidence for the incident: expected hash (manifest), actual hash (`sha256sum`), `ls -l` size and mtime, `cmp` against a good copy to count differing bytes (`cmp -l a b | wc -l` → 1: a single flipped byte, typical of storage or memory faults rather than truncation).
3. Repair only the broken file from the source of truth: `hf download REPO --revision COMMIT --include model-00003-of-00004.safetensors --local-dir bundle` (the client sees a size-equal file whose hash differs from the LFS oid and downloads it again).
4. Re-run the whole check, then the loader. Do **not** re-download everything: on a 140 GB model that turns a minute into hours and destroys the evidence that the other files were intact.
5. Root cause hunting: the transfer medium, the copy tool without checksums (`cp` over NFS, `rsync` without `--checksum` after an interrupted run), failing RAM/disk on the staging host. Add a hash verification step at the hop where the byte flipped.
The same procedure for a missing `tokenizer.json`: `sha256sum -c` never mentions a file that is not in the manifest and, if the manifest was generated from the damaged tree, not even missing ones. **A manifest must come from the source of truth, and completeness is checked against it, not against what happens to be on disk.**

## 22. Capacity planning for the weights store
- Per model: FP16 params × 2 bytes (70B → 140 GB); quantised variants (FP8 70 GB, INT4 ~37 GB) and fine-tunes multiply the count. A team keeping 3 families × 3 precisions × 2 versions = 18 artefacts averages 60 GB → ~1.1 TB.
- Mirror/registry copies: connected staging (1x), inside S3 (1x, replicated 2-3x by the store), registry for images (10-20 GB per engine image, many versions), node-local caches (1x per node that runs the model): budget **5-10x the raw size** and monitor free space; a full disk during a promotion is a self-inflicted outage.
- Bandwidth: the transfer link/media sets the lead time for an urgent model: 140 GB over a 1 Gb/s controlled link (~110 MB/s) is 21 minutes; over physical media it is the courier time plus verification.
- Retention: keep the last N approved commits per model, expire the rest, and never delete a commit that a running deployment references (check before GC).

## 23. Format and distribution decision table
| Question | safetensors (HF layout) | GGUF | pickle (`.bin/.pt`) | ONNX / TensorRT engine |
|---|---|---|---|---|
| Code execution on load | no | no (template is data) | **yes** | no (but custom ops/plugins) |
| Used by | vLLM, SGLang, transformers, TGI | llama.cpp, Ollama | legacy PyTorch | ONNX Runtime, TensorRT-LLM |
| Self-contained | no: config + tokenizer are separate files | yes: weights + tokenizer + template + hyperparameters | no | engine plans are hardware- and version-specific |
| Sharding | index JSON + N files | single file (splits possible) | per-file | per build |
| Quantised variants | AWQ/GPTQ/FP8 as separate repos/checkpoints | many k-quant files per model | rare | build-time |
| Verification | per-file sha256; header validation | file sha256; metadata sanity | sha256 + scanning + sandbox | sha256 + exact GPU/driver match |
| Policy recommendation | **default** | default for CPU/edge | reject or convert in a sandbox | accept only as internal build output |
TensorRT engine plans are not portable between GPU architectures or TensorRT versions: they are build products to be stored with the exact build environment, not downloads.

## 24. Tokenizer, chat template and generation config are part of the model
- The same weights with a different **chat template** answer differently and break tool calling; the template lives in `tokenizer_config.json` (key `chat_template`), a separate `chat_template.jinja`, or GGUF metadata. Pin and hash it with the weights.
- `generation_config.json` supplies default sampling and EOS tokens; engines read it unless overridden (vLLM has a flag to ignore it). A missing or different file changes stop behaviour: "the model never stops" is often a wrong EOS id.
- Special tokens and padding settings are tokenizer files too. Treat the *set* `{weights, config, tokenizer files, template, generation config}` as the deployable unit and name it by its commit.
- When you **convert or quantise** internally, you create a new artefact: give it its own repository/prefix, record the converter version and command line, and re-run evaluations; do not overwrite the original.

## 25. Numbers worth remembering
| Quantity | Value |
|---|---|
| safetensors header limit | 100 MB; length field = 8 bytes little-endian |
| bytes per parameter | FP32 4, FP16/BF16 2, FP8/INT8 1, INT4 ~0.5 (+ scales ≈ 0.53-0.56) |
| 70B model | FP16 140 GB (130 GiB), FP8 70 GB, INT4 ~37 GB |
| transfer time | size ÷ bandwidth: 140 GB at 1.25 GB/s (10 Gb/s line rate) = 112 s; realistically 2-3x that |
| hf cache blob names | sha256 (LFS files), git sha1 (small files) |
| registry digest | `sha256:` of the manifest bytes; layer digest = sha256 of the blob |
| lab ports | mirror 18071, S3 18070, registry 18050, tripwire 18072 (hits), module 02 containers 18125-18129 |
| S3 identities in the lab | `rw` (Admin, Read, Write, List, Tagging), `ro` (Read, List) |

## 26. Incident walk-throughs

### 26.1 "The model loads on the laptop, not in the cluster"
1. Is the whole set present? A serving directory needs `config.json`, tokenizer files, `generation_config.json` (optional but changes sampling), the safetensors index and every shard it names. Compare the index `weight_map` values with the files on disk: a missing shard fails late (at first access of that tensor) in some loaders.
2. Do the hashes match the manifest? `sha256sum -c` against the manifest produced on the connected side. A truncated copy usually shows as a header whose declared offsets exceed the file size (safetensors loaders check this).
3. Is the cache layout what the client expects? With `HF_HUB_OFFLINE=1`, `from_pretrained("org/name")` resolves through `HF_HUB_CACHE/models--org--name/refs/<revision>` then `snapshots/<commit>`; a directory copied without the `refs` file fails with a "not found in cache" error even though the blobs are there. Loading from a plain path (`/models/name`) avoids that class of problem.

### 26.2 "Offline mode is on and the tripwire still fires"
The usual suspects, each of which the lab's control run teaches you to prove rather than assume: a telemetry or update-check call (`HF_HUB_DISABLE_TELEMETRY`, a tokenizer that wants `tiktoken` files downloaded on first use), `trust_remote_code` pulling code from the Hub, a dataset or tokenizer referenced by repo id inside `config.json`, a DNS lookup that happens before the library decides to stay local, and a health-check sidecar. The DNS query log is the evidence because it shows the hostname even when the connection is TLS.

### 26.3 "A third-party checkpoint scanned clean"
Walk the three layers: format (was there any pickle at all? convert or reject), provenance (who published it, is the commit pinned, does the hash match the publisher's), and containment (load it only in a sandbox with no network and no credentials, `--cap-drop ALL`, read-only root, separate user). A clean scan only means no known-bad pattern was seen; scanners have been bypassed with unusual opcodes, nested archives and stdlib callables nobody put on the denylist.

### 26.4 "The registry has the image but the node pulls the wrong one"
Tags move. The deployment says `aiinfra/llama:prod`, someone re-pushed `prod`, and a node that pulled later runs a different build. Pull by digest (`repo@sha256:...`), take the digest from the registry's `Docker-Content-Digest` header (for a multi-arch tag, that is the index digest), and record it in the deployment manifest. Local `docker images --digests` can show a different digest than the registry for the same content under the containerd image store, so never use it as the source of truth.

## 27. Intake ticket template for a new model
| Field | Why |
|---|---|
| Source repo and pinned commit | reproducibility and rollback |
| License and gated status | legal review; gated repos need an approved token on the connected side only |
| Formats present (safetensors / pickle / GGUF) | pickle means reject or convert in a sandbox |
| Sha256 of every file, stored out of band | integrity at each hop |
| Scan result and scanner version | evidence, not proof |
| Size and expected cold-start time | capacity of the weights store and node cache |
| Chat template and generation config reviewed | behaviour changes without weight changes |
| Target engine and version tested | loader compatibility (e.g. a new architecture needs a newer engine) |
| Approver and date | audit trail |

## 28. Review questions an on-call engineer should be able to answer
- Where are the weights for production right now, by digest or commit, and who can overwrite them?
- If the connected side is unreachable for a week, can we still scale out, and from where do new nodes get weights?
- What proves that serving pods cannot reach the internet, and when was that last tested?
- If a model is found malicious tomorrow, how do we find every place it was copied (S3 prefix, node caches, registry artifacts)?

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

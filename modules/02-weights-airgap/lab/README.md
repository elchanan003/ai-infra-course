# Module 02 workspace

- `REPOS.env`, `pickles/`, `incoming/` are created by `../prepare-lab.sh` (they differ per learner).
- Connected side (tasks 2.1, 2.6): the mirror is `http://127.0.0.1:18071` (a stand-in for an enterprise Hub proxy); use the
  venv tools: `platform/.venv/bin/hf`, `platform/.venv/bin/python`, `platform/.venv/bin/picklescan`; `oras` is in `~/.local/bin`.
- S3: endpoint `http://127.0.0.1:18070`, identities rw / ro in `platform/stack/README.md`. Registry: `127.0.0.1:18050` (plain http).
- Tripwire: `curl -s http://127.0.0.1:18072/hits` (host side) - the air-gap network's DNS server.
- Lab containers use ports 18125-18129 (127.0.0.1 only) and the name prefix `aiinfra-lab02-`.

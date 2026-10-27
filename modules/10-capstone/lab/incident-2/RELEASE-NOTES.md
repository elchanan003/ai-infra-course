# Release 2026.10.26 - serving replica A (given)
Changes in the flags of replica A (all other flags unchanged):
| change | before | after | reason given in the PR |
|---|---|---|---|
| `--max-num-seqs` | 24 | 80 | "let the batch tenants run more requests in parallel" |
| prefix caching | default (on) | `--no-enable-prefix-caching` | "while we check a cache-correctness report" |
| `--seed` | 0 | 1234 | "reproducible evals" |
| `--uvicorn-log-level` | info | warning | "less log noise" |
| `--disable-log-stats` | - | added | "less log noise" |
Not changed: model, `--max-model-len`, `--gpu-memory-utilization` (0.77), the GPU, the traffic mix.

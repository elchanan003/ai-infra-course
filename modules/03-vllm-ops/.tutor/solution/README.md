The reference solution is generated for the learner's seeded variant: `python3 modules/03-vllm-ops/harness/gen.py solution <dir>` writes the config files;
`.tutor/apply-solution.sh` also replays the scenarios for `answers/ttft.env` and `answers/pressure.env`, installs everything into lab/ (after a backup) and restarts the mocks.
Reference values: 3.2 `--kv-cache-dtype fp8 --max-model-len <floor> --gpu-memory-utilization 0.92`; 3.3 util 0.90 + `--max-num-seqs 16`; 3.6 `--max-num-seqs 56`; 3.8 util 0.85.
After apply-solution.sh the generated tree is in `.tutor/solution/lab/` (git-ignored runtime artifact is fine).

# AI Infrastructure & Platform (LLMOps) Onboarding Course

Hands-on course: LLM serving internals, vLLM ops, weights and air-gap, LiteLLM gateway, clients and agents (Open WebUI, Aider, Continue, MCP, RAG), AI observability, GPUs on Kubernetes.
No GPU on the lab host: parts are simulated and the tutor says so each time.

## How to use
```bash
cd ~/ai-infra-course
claude            # or codex / gemini — any agent; it reads CLAUDE.md / AGENTS.md
```
Say "continue" (or "בוא נמשיך"). The tutor reads `PROGRESS.md`, tells you where you are, and continues.
Switching account/agent or coming back after a break is safe: all state is in `PROGRESS.md` (and git history).

## Layout
| Path | What |
|---|---|
| `SYLLABUS.md` | modules, hours, schedule |
| `PROGRESS.md` | your progress (maintained by the tutor) |
| `modules/NN-*/` | `theory.md`, `lab.md`, `quiz.md`, `lab/` (your workspace), `prepare-lab.sh`, `verify.sh`, `cleanup.sh`, `verify-clean.sh` |
| `cheatsheets/` | vLLM flags/metrics, LiteLLM, VRAM/KV math, HF air-gap, GPU/k8s/DCGM, MCP/agents |
| `mock/` | simulated vLLM, DCGM, nvidia-smi, HF mirror, tripwire (`mock/README.md` = contract) |
| `platform/` | `setup.sh` (connected side, run once), `doctor.sh`, `stack.sh`, `k8s.sh`, `lib.sh` |

## Manual lab commands
```bash
platform/doctor.sh                       # environment health
platform/stack.sh up gw llm              # converge to exactly these profiles
modules/01-serving-internals/prepare-lab.sh    # start a lab
modules/01-serving-internals/verify.sh         # check your work
modules/01-serving-internals/cleanup.sh        # tear down
```
UIs (over Tailscale, or localhost on the server): Open WebUI http://100.127.87.65:18080, Grafana http://100.127.87.65:18030, Prometheus http://100.127.87.65:18090, LiteLLM http://100.127.87.65:18040 (`/ui`).

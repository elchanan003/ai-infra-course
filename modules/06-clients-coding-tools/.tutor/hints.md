# 06 — Hints (H1 nudge, H2 concept, H3 partial, H4 full)

## 6.1 Open WebUI -> gateway
- H1: Which URL does the Open WebUI *container* use to reach LiteLLM? Is `localhost` right?
- H2: Connections live in Open WebUI's stored (PersistentConfig) configuration; compose env only seeds the first boot. The admin API mirrors the UI.
- H3: `POST /api/v1/auths/signin` -> token; `POST /openai/config/update` with `OPENAI_API_BASE_URLS:["http://litellm:4000/v1"]`, `OPENAI_API_KEYS:[<lab-owui key>]`; also set Ollama off. Keys: `provision.sh` with the `key` field to fix the value.
- H4: `.tutor/solution/openwebui/connect.sh` and `provision.sh`.

## 6.2 Aider
- H1: Run Aider by hand in `lab/aider/repo` with `--message`. What does it ask or complain about?
- H2: The model name needs the `openai/` prefix; headless needs `--yes-always`; the scripted reply is a SEARCH/REPLACE block, so the edit format must be `diff` (the default for an unknown model is not).
- H3: `--model openai/agent --edit-format diff --no-auto-commits --no-gitignore --no-show-model-warnings --no-check-update --no-analytics --no-stream --map-tokens 0`; env: `OPENAI_API_BASE`, `OPENAI_API_KEY`.
- H4: solution `aider/run.sh` and `aider.env`.

## 6.3 Continue
- H1: Read `replay.py`: which endpoint does it call for each role, and with which fields?
- H2: Each `models:` entry has its own `apiBase`, `apiKey`, `model`, `roles`. Autocomplete uses the completions endpoint with `prompt` + `suffix`, a FIM-capable alias and a small `maxTokens`.
- H3: chat entry: model `chat`, roles chat/edit/apply, key lab-continue-chat; autocomplete entry: model `coder`, roles [autocomplete], key lab-continue-fim.
- H4: solution `continue/config.yaml`.

## 6.4 dissect
- H1: `jq '.messages[0].content|length'`, `.tools|length`, `.messages|length`, `[.messages[]|select(.role=="tool")]|length`.
- H2: The spend log row has `prompt_tokens` for the request id in `captured/README.txt`.
- H3: P = L x (SYSTEM_CHARS + TOOLS_CHARS) / TOTAL_CHARS; d = (L - P) / assistant messages; session = 25 P + d x 25 x 26 / 2.
- H4: apply-solution computes the numbers exactly this way (see its python block).

## 6.5 slow model list
- H1: Time `GET /api/models`; read the Open WebUI log.
- H2: Stored configuration: `GET /ollama/config`. A dead Ollama URL with the Ollama API enabled makes the list wait for a timeout.
- H3: `POST /ollama/config/update` with `ENABLE_OLLAMA_API:false`; then confirm after a restart (the setting persists in Open WebUI's DB).
- H4: last call in `solution/openwebui/connect.sh`.

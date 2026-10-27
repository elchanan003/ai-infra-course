agent-request.json is the body of ONE request a coding agent sent through the gateway during prepare-lab.
Key alias: lab-captured   model alias: agent   response/request id: chatcmpl-10ea658400000002f3d3c94b7dd3
Find its row in LiteLLM_SpendLogs (column request_id) for the logged prompt_tokens, e.g.
  docker exec aiinfra-postgres-1 psql -U llm -d litellm -c "select request_id, prompt_tokens, completion_tokens from \"LiteLLM_SpendLogs\" where request_id='chatcmpl-10ea658400000002f3d3c94b7dd3'"
(rows appear 2-5 s after the request; prepare-lab sent it a while ago)

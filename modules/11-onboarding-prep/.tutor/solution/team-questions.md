# Questions for the team

## Stack and architecture
- Who owns the platform repo and which branch deploys to production?
- Which engine and version serve production traffic, and on which GPU types?
- Is serving on raw Deployments, KServe, Ray Serve or llm-d, and where do the engine args live?
- Does the gateway run several replicas with a shared Redis for rate-limit counters?

## Models and artifacts
- Who approves a new model, and what scanning or signing happens before it lands in the registry?
- How long does a cold start take for the largest model, and where do the weights come from?
- How do we roll back a model alias if the new version misbehaves?

## Access, limits and cost
- How are keys and budgets provisioned, in Git or through the admin UI?
- What are the current limits for chat clients versus agent clients, and who chose them?
- What is GPU allocation versus utilisation this month, and who sees the cost report?

## Operations and on-call
- Am I on the on-call rotation, and when would I shadow first?
- Which alerts exist for KV pressure, queue growth, XID errors and 429 ratio, and who owns each?
- Is there a staging cluster where I can safely break things?
- What were the last three incidents and where are the postmortems?

## Security and data
- How is the air gap enforced and audited, and who may bring new images in?
- What happens to prompt and completion logs, and what is the retention period?

# 11 — Quiz: onboarding prep

1. The team serves models with Triton + TensorRT-LLM. What artifact exists here that did not in your vLLM lab, and what does it mean for the air-gap pipeline?
2. Your team uses KServe. Map `InferenceService`, runtime and modelcar onto the pieces of your lab (Deployment, engine args, weights).
3. What does the endpoint picker of the Gateway API Inference Extension look at to choose a replica, and how does that compare with LiteLLM's `simple-shuffle`?
4. Someone proposes a new project on TGI. What do you say about its status and what do you ask?
5. The gateway is Kong AI Gateway or Envoy AI Gateway. Which three module-04/05 questions do you ask to find where limits live and whether counters are shared?
6. What is disaggregated prefill/decode, and which two metrics from module 03 tell you it might help?
7. An unknown dashboard shows only GPU utilisation and request count. List four panels you would ask to add.
8. An alert `KVCacheNearFull` has no runbook and no owner label. What do you do on day 3?
9. Name the three questions whose answers most change your first week, and why.
10. Give two signs that gateway keys and limits are not managed as code, and why that matters for incidents like capstone 1.
11. Your team runs Ray Serve with `serve.llm`. Which of your concepts map to Ray Serve autoscaling, and what do you need to learn that is Ray-specific?
12. What is a good first PR for a new member of an AI-platform team, and why that kind?

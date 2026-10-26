# 02 — Quiz

1. A safetensors file begins with the 8 bytes `00 01 00 00 00 00 00 00`. What is the header length and the absolute offset where tensor data begins? What does `data_offsets` of a tensor refer to?
2. Why is unpickling a checkpoint equivalent to running code? Name the opcodes involved in a minimal exploit, and say what `torch.load(weights_only=True)` changes.
3. A scanner reports "no issues" for a downloaded model. Give three reasons you still do not treat it as safe.
4. Draw the layout of the Hugging Face cache for one repo. Which entries are symlinks, what does `refs/main` contain, and what breaks when the cache is copied with a tool that drops symlinks?
5. What does `HF_HUB_OFFLINE=1` do and what does it not do? Give two other places a "fully offline" system may still try to reach the internet.
6. What four HTTP interactions must a mirror implement for `hf download` to work with `HF_ENDPOINT`, and why does the course set `HF_HUB_DISABLE_XET=1`?
7. You pinned `revision="main"` in a deployment script. What can go wrong six months later, and what do you pin instead? Why is `hf download repo` without `--include` a bad idea for a multi-format repo?
8. Explain the difference between integrity and authenticity for a model transferred across an air gap. Where do the hashes come from and where are they verified?
9. Design S3 credentials for a weights bucket used by a sync job and 20 serving pods: identities, permissions, and what a failing PUT from a serving pod should look like (status/error). How does that differ from a wrong key?
10. Why is an S3 ETag not a reliable sha256 of an object? Where do you keep the checksum instead?
11. Compare tag and digest. After `docker push` to an internal registry, `docker images --digests` shows a different digest than the registry. Why (on this host), and which value do you record and compare against the running container?
12. Compare shipping weights through S3 versus as an OCI artifact (ORAS/ModelKit): two advantages and two drawbacks of each.
13. Compute: a 140 GB model, a 10 Gb/s link at 60% efficiency; 8 nodes start simultaneously from one S3 server with a 25 Gb/s NIC. Time for one node alone, and for all eight at once? What do you change in the design?
14. What is wrong with this "air-gapped serving" setup: `docker run --network bridge -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 vllm/vllm-openai --model meta-llama/Llama-3.1-8B-Instruct --trust-remote-code` (the cache directory is not mounted)? List at least four problems.
15. You must prove a serving stack is offline. Describe the experiment, the evidence you collect, and the control run. Why is the DNS query log, rather than an HTTP sink log, the authoritative counter?

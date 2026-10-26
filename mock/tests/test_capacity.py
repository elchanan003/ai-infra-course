import json, os, subprocess, sys
import pytest
from aimock import capacity as c
from conftest import MODELS, MOCK, Server, write_cfg

GIB = 1024 ** 3
A100 = dict(name="A100-80GB", memory_gib=80.0, count=1, other_process_gib=0.0, mem_bandwidth_gbs=2039.0, tflops=312.0)


def model(n):
    return c.load_model(os.path.join(MODELS, n))


def test_param_counts_plausible():
    for n, lo, hi in [("qwen2.5-0.5b", 0.45e9, 0.55e9), ("qwen2.5-7b", 7.4e9, 7.8e9), ("llama-3.1-8b", 7.9e9, 8.1e9), ("llama-3.1-70b", 70e9, 71e9)]:
        assert lo < model(n)["params"] < hi, n


def test_kv_bytes_per_token_formula():
    m = model("llama-3.1-8b")
    cap = c.compute(c.parse_args("--max-model-len 8192"), m, A100)
    assert cap["kv_bytes_per_token"] == 2 * 32 * 8 * 128 * 2 == 131072
    cap32 = c.compute(c.parse_args("--max-model-len 8192 --kv-cache-dtype fp8"), m, A100)
    assert cap32["kv_bytes_per_token"] == 65536
    assert cap32["kv_cache_size_tokens"] > 1.9 * cap["kv_cache_size_tokens"]


def test_blocks_math():
    m = model("llama-3.1-8b")
    cap = c.compute(c.parse_args("--max-model-len 8192 --block-size 16 --gpu-memory-utilization 0.9"), m, A100)
    budget = 0.9 * 80 * GIB
    assert cap["kv_cache_memory_bytes"] == pytest.approx(budget - cap["weights_bytes_per_gpu"] - cap["activation_bytes"] - cap["nontorch_bytes"], abs=2)
    assert cap["num_gpu_blocks"] == cap["kv_cache_memory_bytes"] // (131072 * 16)
    assert cap["usable_blocks"] == cap["num_gpu_blocks"] - 1
    assert cap["kv_cache_size_tokens"] == cap["num_gpu_blocks"] * 16


def test_tp_splits_weights_and_kv():
    m = model("llama-3.1-70b")
    g = dict(A100, count=2)
    cap = c.compute(c.parse_args("--tensor-parallel-size 2 --max-model-len 8192"), m, g)
    assert cap["weights_bytes_per_gpu"] == pytest.approx(m["params"] * 2 / 2, rel=1e-9)
    assert cap["kv_bytes_per_token_per_gpu"] == cap["kv_bytes_per_token"] // 2


def test_quantization_shrinks_weights():
    m = model("llama-3.1-70b")
    cap = c.compute(c.parse_args("--quantization awq --max-model-len 8192"), m, A100)
    assert cap["weights_bytes_per_gpu"] < 45 * GIB


def test_refuse_tp_not_dividing_heads():
    with pytest.raises(c.StartupError, match=r"Total number of attention heads \(28\) must be divisible by tensor parallel size \(3\)"):
        c.compute(c.parse_args("--tensor-parallel-size 3"), model("qwen2.5-7b"), dict(A100, count=4))


def test_refuse_weights_dont_fit():
    with pytest.raises(c.StartupError, match="CUDA out of memory"):
        c.compute(c.parse_args(""), model("llama-3.1-70b"), A100)


def test_refuse_kv_too_small_uses_real_text():
    gpu = dict(A100, memory_gib=24.0)
    with pytest.raises(c.StartupError) as ei:
        c.compute(c.parse_args("--max-model-len 32768 --gpu-memory-utilization 0.9"), model("llama-2-7b-mha").copy() | {"max_pos": 65536}, gpu)
    msg = ei.value.msg
    assert msg.startswith("To serve at least one request with the model's max seq len (32768), (")
    assert "GiB KV cache is needed, which is larger than the available KV cache memory (" in msg
    assert "the estimated maximum model length is " in msg
    assert "conserving_memory" in msg


def test_refuse_other_process_memory():
    with pytest.raises(c.StartupError, match=r"Free memory on device cuda:0 \(60.0/80.0 GiB\) on startup is less than desired GPU memory utilization \(0.92, 73.6 GiB\)"):
        c.compute(c.parse_args(""), model("qwen2.5-7b"), dict(A100, other_process_gib=20.0))


def test_max_model_len_above_derived():
    with pytest.raises(c.StartupError, match="VLLM_ALLOW_LONG_MAX_MODEL_LEN"):
        c.compute(c.parse_args("--max-model-len 99999"), model("llama-2-7b-mha"), A100)


def test_parse_args_flags():
    a = c.parse_args("--model /m --served-model-name a b --enable-prefix-caching --no-enable-prefix-caching --max-num-seqs=7 --max_model_len 100")
    assert a["served-model-name"] == "a b" and a["enable-prefix-caching"] is False and a["max-num-seqs"] == 7 and a["max-model-len"] == 100
    assert c.parse_args("--model /m")["enable-prefix-caching"] is True


def test_startup_refusal_exit_code(tmp_path):
    cfg = write_cfg(str(tmp_path / "c"), "llama-3.1-70b", "--max-model-len 4096")
    s = Server("vllm", cfg)
    assert s.p.wait(30) == 1
    t = s.logtext()
    assert "CUDA out of memory" in t
    # KV refusal with the real vLLM text
    cfg = write_cfg(str(tmp_path / "c2"), "llama-3.1-70b", "--tensor-parallel-size 2 --max-model-len 131072", gpu="count: 2\n")
    s = Server("vllm", cfg)
    assert s.p.wait(30) == 1
    assert "To serve at least one request with the model's max seq len (131072)" in s.logtext()

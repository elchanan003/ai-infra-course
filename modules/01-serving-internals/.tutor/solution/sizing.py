"""Sizing calculator (task 1.1). All memory results are in GiB (2**30 bytes), never GB."""
GIB = 2 ** 30


def _hd(m):
    return m.get("head_dim") or m["hidden_size"] // m["num_attention_heads"]


def weights_gb(params_b, bytes_per_param):
    return params_b * 1e9 * bytes_per_param / GIB


def kv_bytes_per_token(layers, kv_heads, head_dim, kv_bytes):
    return 2 * layers * kv_heads * head_dim * kv_bytes


def kv_gb(layers, kv_heads, head_dim, kv_bytes, seq_len, n_seqs):
    return kv_bytes_per_token(layers, kv_heads, head_dim, kv_bytes) * seq_len * n_seqs / GIB


def fits(model, gpu_gib, util, tp, seq_len, n_seqs, kv_bytes, overhead_gib=2.0):
    w = weights_gb(model["params_b"], model["bytes_per_param"])
    kv = kv_gb(model["layers"], model["num_key_value_heads"], _hd(model), kv_bytes, seq_len, n_seqs)
    return (w + kv) / tp + overhead_gib <= gpu_gib * util


def min_tp(model, gpu_gib, util, seq_len, n_seqs, kv_bytes, overhead_gib=2.0):
    for tp in (1, 2, 4, 8):
        if model["num_attention_heads"] % tp == 0 and model["num_key_value_heads"] % tp == 0 \
                and fits(model, gpu_gib, util, tp, seq_len, n_seqs, kv_bytes, overhead_gib):
            return tp
    return None

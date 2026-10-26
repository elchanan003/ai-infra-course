"""Sizing calculator (task 1.1). All memory results are in GiB (2**30 bytes), never GB.

`model` is a dict with the keys params_b (billions), bytes_per_param, layers, num_attention_heads,
num_key_value_heads and head_dim. head_dim may be missing (as in some config.json files): then it is
hidden_size / num_attention_heads (hidden_size is then present in the dict).
"""


def weights_gb(params_b, bytes_per_param):
    """Weight memory in GiB."""
    raise NotImplementedError  # TODO


def kv_bytes_per_token(layers, kv_heads, head_dim, kv_bytes):
    """Exact KV-cache bytes for one token (whole model, before any tensor-parallel split)."""
    raise NotImplementedError  # TODO


def kv_gb(layers, kv_heads, head_dim, kv_bytes, seq_len, n_seqs):
    """KV-cache memory in GiB for n_seqs sequences of seq_len tokens."""
    raise NotImplementedError  # TODO


def fits(model, gpu_gib, util, tp, seq_len, n_seqs, kv_bytes, overhead_gib=2.0):
    """True if (weights + KV) / tp + overhead_gib <= gpu_gib * util  (per GPU)."""
    raise NotImplementedError  # TODO


def min_tp(model, gpu_gib, util, seq_len, n_seqs, kv_bytes, overhead_gib=2.0):
    """Smallest TP in (1, 2, 4, 8) that divides BOTH num_attention_heads and num_key_value_heads
    and fits; None if there is none."""
    raise NotImplementedError  # TODO

p = "/tmp/__NONCE__"
open(p, "w").write("__NONCE__")
assert open(p).read() == "__NONCE__"
print("OK __NONCE__")

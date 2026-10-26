import json, os
mib = 0
try:
    with open("/tmp/big", "wb") as f:
        for _ in range(48):
            f.write(b"x" * 1048576); f.flush(); os.fsync(f.fileno()); mib += 1
except OSError:
    pass
print(json.dumps({"mib": mib}))

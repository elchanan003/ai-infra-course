import os
st = open("/proc/self/status").read()
print("uid", os.getuid(), [l for l in st.splitlines() if l.startswith(("CapEff", "NoNewPrivs"))])

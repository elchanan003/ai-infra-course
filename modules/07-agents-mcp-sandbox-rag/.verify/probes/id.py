import json
st = open("/proc/self/status").read()
def f(k): return st.split(k + ":")[1].split("\n")[0].split()
print(json.dumps({"uid": int(f("Uid")[0]), "caps": f("CapEff")[0], "nnp": int(f("NoNewPrivs")[0])}))

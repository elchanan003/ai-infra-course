import json, os, stat
mounts = []
for line in open("/proc/self/mountinfo"):
    a, b = line.split(" - ")
    p = a.split(); q = b.split()
    mounts.append({"root": p[3], "mountpoint": p[4], "fstype": q[0]})
socks = []
for s in ("/var/run/docker.sock", "/run/docker.sock"):
    try:
        if stat.S_ISSOCK(os.stat(s).st_mode): socks.append(s)
    except OSError: pass
print(json.dumps({"mounts": mounts, "sockets": socks}))

import json, os, socket
ifs = sorted(x for x in os.listdir("/sys/class/net") if x != "lo")
try:
    socket.create_connection(("1.1.1.1", 443), timeout=3).close(); conn = True
except OSError:
    conn = False
try:
    socket.gethostbyname("x__NONCE__.probe.invalid"); dns = True
except OSError:
    dns = False
print(json.dumps({"ifs": ifs, "connect": conn, "dns": dns}))

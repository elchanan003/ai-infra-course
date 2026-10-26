import os, socket
print("interfaces:", sorted(os.listdir("/sys/class/net")))
try:
    socket.create_connection(("1.1.1.1", 443), timeout=3).close(); print("connect: reached the internet")
except OSError as e:
    print("connect: failed:", e)

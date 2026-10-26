import os, signal, time
kids = []
for i in range(300):
    try:
        pid = os.fork()
    except OSError as e:
        print("fork failed after", len(kids), "children:", e); break
    if pid == 0:
        time.sleep(5); os._exit(0)
    kids.append(pid)
else:
    print("forked", len(kids), "children without a limit")
for p in kids:
    os.kill(p, signal.SIGKILL)

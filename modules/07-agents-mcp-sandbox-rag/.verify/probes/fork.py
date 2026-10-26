import json, os, signal, time
kids, err = [], None
for _ in range(300):
    try:
        pid = os.fork()
    except OSError as e:
        err = str(e); break
    if pid == 0:
        time.sleep(5); os._exit(0)
    kids.append(pid)
print(json.dumps({"forked": len(kids), "error": err}), flush=True)
for p in kids:
    try: os.kill(p, signal.SIGKILL)
    except OSError: pass
for p in kids:
    try: os.waitpid(p, 0)
    except OSError: pass

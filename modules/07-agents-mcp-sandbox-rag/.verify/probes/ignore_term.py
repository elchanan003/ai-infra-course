import signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
_end = time.time() + 25          # safety net, see loop.py
while time.time() < _end:
    time.sleep(0.2)
print("SURVIVED")

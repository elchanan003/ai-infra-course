import signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
while True:
    time.sleep(0.2)

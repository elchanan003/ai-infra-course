for p in ("/var/tmp/x", "/etc/x", "/tmp/x"):
    try:
        open(p, "w").write("x"); print("write", p, "OK")
    except OSError as e:
        print("write", p, "FAILED:", e)

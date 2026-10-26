import time
_end = time.time() + 25          # safety net so a missing timeout cannot leak a CPU burner
while time.time() < _end:
    pass
print("SURVIVED")

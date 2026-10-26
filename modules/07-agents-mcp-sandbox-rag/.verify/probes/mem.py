keep = []
for i in range(1, 129):
    keep.append(bytearray(b"\x01") * (8 * 1048576))
    print(i * 8, flush=True)

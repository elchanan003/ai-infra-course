keep = []
for i in range(1, 129):
    keep.append(bytearray(b"\x01") * (8 * 1048576))
    print("allocated", i * 8, "MiB", flush=True)

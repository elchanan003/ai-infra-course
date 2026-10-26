"""Fake nvidia-smi: renders from the running mock-dcgm state (http://127.0.0.1:$MOCK_PORT/admin/state)."""
import json, os, sys, time, urllib.request

W = 89
QFIELDS = {  # name -> (header unit, getter(g, v, d) -> (value, unit_suffix))
    "index": ("", lambda g, v, d: g["index"]), "name": ("", lambda g, v, d: g["name"]), "uuid": ("", lambda g, v, d: g["uuid"]),
    "pci.bus_id": ("", lambda g, v, d: g["pci_bus_id"]), "driver_version": ("", lambda g, v, d: d["driver_version"]),
    "serial": ("", lambda g, v, d: g["serial"]),
    "memory.total": ("MiB", lambda g, v, d: g["mem_total"]), "memory.used": ("MiB", lambda g, v, d: v["DCGM_FI_DEV_FB_USED"]),
    "memory.free": ("MiB", lambda g, v, d: v["DCGM_FI_DEV_FB_FREE"]),
    "utilization.gpu": ("%", lambda g, v, d: v["DCGM_FI_DEV_GPU_UTIL"]), "utilization.memory": ("%", lambda g, v, d: v["DCGM_FI_DEV_MEM_COPY_UTIL"]),
    "temperature.gpu": ("", lambda g, v, d: v["DCGM_FI_DEV_GPU_TEMP"]), "temperature.memory": ("", lambda g, v, d: v["DCGM_FI_DEV_MEMORY_TEMP"]),
    "power.draw": ("W", lambda g, v, d: f"{v['DCGM_FI_DEV_POWER_USAGE']:.2f}"), "power.limit": ("W", lambda g, v, d: f"{g['power_limit']:.2f}"),
    "clocks.sm": ("MHz", lambda g, v, d: v["DCGM_FI_DEV_SM_CLOCK"]), "clocks.mem": ("MHz", lambda g, v, d: v["DCGM_FI_DEV_MEM_CLOCK"]),
    "clocks.current.sm": ("MHz", lambda g, v, d: v["DCGM_FI_DEV_SM_CLOCK"]),
    "pstate": ("", lambda g, v, d: "P0" if v["DCGM_FI_DEV_GPU_UTIL"] else "P8"),
    "clocks_throttle_reasons.active": ("", lambda g, v, d: f"0x{v['DCGM_FI_DEV_CLOCK_THROTTLE_REASONS']:016X}"),
    "clocks_event_reasons.active": ("", lambda g, v, d: f"0x{v['DCGM_FI_DEV_CLOCK_THROTTLE_REASONS']:016X}"),
    "ecc.errors.uncorrected.volatile.total": ("", lambda g, v, d: v["DCGM_FI_DEV_ECC_DBE_VOL_TOTAL"]),
    "ecc.errors.corrected.volatile.total": ("", lambda g, v, d: v["DCGM_FI_DEV_ECC_SBE_VOL_TOTAL"]),
    "ecc.mode.current": ("", lambda g, v, d: "Enabled"),
}


def fetch():
    port = os.environ.get("MOCK_PORT", "8000")
    try:
        return json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/admin/state", timeout=3))
    except Exception:
        print("NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver. Make sure that the latest NVIDIA driver is installed and running.\n")
        sys.exit(9)


def lost(g):
    return f"Unable to determine the device handle for GPU{g['pci_bus_id']}: Unknown Error"


def _row(a, b, c, sep="|"):
    return sep + a.ljust(41) + sep + b.ljust(24) + sep + c.ljust(22) + sep


def table(d):
    ts = time.strftime("%a %b %d %H:%M:%S %Y")
    o = [ts + "       ", "+" + "-" * 89 + "+"]
    drv = d["driver_version"]
    o.append("|" + (f" NVIDIA-SMI {drv}".ljust(34) + f"Driver Version: {drv}".ljust(31) + f"CUDA Version: {d['cuda_version']}").ljust(89) + "|")
    o.append("|" + "-" * 41 + "+" + "-" * 24 + "+" + "-" * 22 + "+")
    o.append(_row(" GPU  Name                 Persistence-M", " Bus-Id          Disp.A", " Volatile Uncorr. ECC"))
    o.append(_row(" Fan  Temp   Perf          Pwr:Usage/Cap", "           Memory-Usage", " GPU-Util  Compute M."))
    o.append(_row("", "", "              MIG M. "))
    o.append("|" + "=" * 41 + "+" + "=" * 24 + "+" + "=" * 22 + "|")
    for g in d["gpus"]:
        v = g["values"]
        perf = "P0" if v["DCGM_FI_DEV_GPU_UTIL"] else "P8"
        o.append(_row(f" {g['index']:>3}  {g['name'][:24]:<24}  On ", f" {g['pci_bus_id']:>16} Off ", f"{v['DCGM_FI_DEV_ECC_DBE_VOL_TOTAL']:>21} "))
        o.append(_row(f" N/A  {v['DCGM_FI_DEV_GPU_TEMP']:>3}C    {perf:<2}  {v['DCGM_FI_DEV_POWER_USAGE']:>13.0f}W / {g['power_limit']:>4.0f}W ",
                      f" {v['DCGM_FI_DEV_FB_USED']:>7}MiB / {g['mem_total']:>6}MiB ", f" {v['DCGM_FI_DEV_GPU_UTIL']:>3}%      Default "))
        o.append(_row("", "", "Disabled".rjust(21) + " "))
        o.append("+" + "-" * 41 + "+" + "-" * 24 + "+" + "-" * 22 + "+")
    o += ["", "+" + "-" * 89 + "+", "| Processes:".ljust(90) + "|",
          "|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |",
          "|        ID   ID                                                               Usage      |",
          "|" + "=" * 89 + "|", "|  No running processes found".ljust(90) + "|", "+" + "-" * 89 + "+"]
    return "\n".join(o)


REASON_NAMES = [("Idle", 0x1), ("Applications Clocks Setting", 0x2), ("SW Power Cap", 0x4), ("HW Slowdown", 0x8), ("HW Thermal Slowdown", 0x40),
                ("HW Power Brake Slowdown", 0x80), ("SW Thermal Slowdown", 0x20), ("Sync Boost", 0x10)]


def detail(d, sel):
    o = ["", "==============NVSMI LOG==============", "", f"Timestamp                                 : {time.strftime('%a %b %d %H:%M:%S %Y')}",
         f"Driver Version                            : {d['driver_version']}", f"CUDA Version                              : {d['cuda_version']}", "",
         f"Attached GPUs                             : {len(d['gpus'])}"]
    for g in sel:
        v = g["values"]
        mask = v["DCGM_FI_DEV_CLOCK_THROTTLE_REASONS"]
        o += [f"GPU {g['pci_bus_id']}", f"    Product Name                          : {g['name']}", "    Product Brand                         : NVIDIA",
              f"    Serial Number                         : {g['serial']}", f"    GPU UUID                              : {g['uuid']}",
              f"    Minor Number                          : {g['index']}", "    Persistence Mode                      : Enabled",
              "    FB Memory Usage", f"        Total                             : {g['mem_total']} MiB", "        Reserved                          : 0 MiB",
              f"        Used                              : {v['DCGM_FI_DEV_FB_USED']} MiB", f"        Free                              : {v['DCGM_FI_DEV_FB_FREE']} MiB",
              "    Utilization", f"        GPU                               : {v['DCGM_FI_DEV_GPU_UTIL']} %",
              f"        Memory                            : {v['DCGM_FI_DEV_MEM_COPY_UTIL']} %", "    ECC Mode", "        Current                           : Enabled",
              "    ECC Errors", "        Volatile", "            SRAM Correctable              : 0", "            SRAM Uncorrectable            : 0",
              f"            DRAM Correctable              : {v['DCGM_FI_DEV_ECC_SBE_VOL_TOTAL']}", f"            DRAM Uncorrectable            : {v['DCGM_FI_DEV_ECC_DBE_VOL_TOTAL']}",
              "    Temperature", f"        GPU Current Temp                  : {v['DCGM_FI_DEV_GPU_TEMP']} C", "        GPU T.Limit Temp                  : %d C" % (92 - v['DCGM_FI_DEV_GPU_TEMP']),
              "        GPU Shutdown Temp                 : 92 C", "        GPU Slowdown Temp                 : 89 C", f"        Memory Current Temp               : {v['DCGM_FI_DEV_MEMORY_TEMP']} C",
              "    GPU Power Readings", f"        Instantaneous Power Draw          : {v['DCGM_FI_DEV_POWER_USAGE']:.2f} W", f"        Current Power Limit               : {g['power_limit']:.2f} W",
              "    Clocks", f"        SM                                : {v['DCGM_FI_DEV_SM_CLOCK']} MHz", f"        Memory                            : {v['DCGM_FI_DEV_MEM_CLOCK']} MHz",
              "    Clocks Event Reasons", f"        Clocks Event Reasons Active       : 0x{mask:016X}"]
        for n, b in REASON_NAMES:
            o.append(f"        {n:<34}: {'Active' if mask & b else 'Not Active'}")
        o.append("    Processes                             : None")
    return "\n".join(o)


def main(argv):
    csvq = fmt = None
    sel_ids = None
    mode = "table"
    i = 0
    while i < len(argv):
        a = argv[i]
        nxt = lambda: argv[i + 1]
        if a.startswith("--query-gpu="):
            csvq = a.split("=", 1)[1]
        elif a == "--query-gpu":
            csvq = nxt(); i += 1
        elif a.startswith("--format="):
            fmt = a.split("=", 1)[1]
        elif a == "--format":
            fmt = nxt(); i += 1
        elif a in ("-i", "--id"):
            sel_ids = nxt().split(","); i += 1
        elif a.startswith("--id="):
            sel_ids = a.split("=", 1)[1].split(",")
        elif a in ("-q", "--query"):
            mode = "q"
        elif a == "-L":
            mode = "L"
        elif a.startswith("--query-compute-apps"):
            mode = "apps"
        elif a in ("-h", "--help"):
            print("NVIDIA System Management Interface (mock)\nusage: nvidia-smi [-L] [-q] [-i ID] [--query-gpu=<fields> --format=csv[,noheader][,nounits]]")
            return 0
        elif a in ("-d", "-l", "-lms", "-f", "--filename"):
            i += 1
        i += 1
    d = fetch()
    gpus = d["gpus"]
    if sel_ids:
        gpus = [g for g in gpus if str(g["index"]) in sel_ids or g["uuid"] in sel_ids or g["pci_bus_id"] in sel_ids]
        if not gpus:
            print(f"Unable to determine the device handle for GPU {','.join(sel_ids)}: Not Found")
            return 6
    dead = [g for g in gpus if g["fell_off_bus"]]
    if mode == "L":
        for g in d["gpus"]:
            print(f"GPU {g['index']}: {g['name']} (UUID: {g['uuid']})" if not g["fell_off_bus"] else f"Unable to determine the device handle for GPU{g['pci_bus_id']}: Unknown Error")
        return 0
    if dead and not csvq:
        for g in dead:
            print(lost(g))
        return 255
    if csvq:
        fields = [x.strip() for x in csvq.split(",")]
        opts = [x.strip() for x in (fmt or "csv").split(",")]
        if opts[0] != "csv":
            print("Invalid --format option. Only csv is supported by the mock.")
            return 2
        bad = [x for x in fields if x not in QFIELDS]
        if bad:
            print(f'Field "{bad[0]}" is not a valid field to query.\n')
            return 2
        nounits, noheader = "nounits" in opts, "noheader" in opts
        if not noheader:
            print(", ".join(x + (f" [{QFIELDS[x][0]}]" if QFIELDS[x][0] and not nounits else "") for x in fields))
        for g in gpus:
            if g["fell_off_bus"]:
                print(lost(g))
                continue
            row = []
            for x in fields:
                u, fn = QFIELDS[x]
                val = fn(g, g["values"], d)
                row.append(f"{val} {u}" if u and not nounits else str(val))
            print(", ".join(row))
        return 0
    if mode == "apps":
        if "--format" in " ".join(argv) and "noheader" not in " ".join(argv):
            print("pid, process_name, used_gpu_memory [MiB]")
        return 0
    if mode == "q":
        print(detail(d, gpus))
        return 0
    d2 = dict(d, gpus=gpus)
    print(table(d2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

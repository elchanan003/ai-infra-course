"""mock-dcgm: DCGM exporter-compatible /metrics + shared GPU state for the fake nvidia-smi."""
import hashlib, math, os, time, uuid
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from .common import load_yaml, log

# name, type, help
FIELDS = [
    ("DCGM_FI_DEV_SM_CLOCK", "gauge", "SM clock frequency (in MHz)."),
    ("DCGM_FI_DEV_MEM_CLOCK", "gauge", "Memory clock frequency (in MHz)."),
    ("DCGM_FI_DEV_MEMORY_TEMP", "gauge", "Memory temperature (in C)."),
    ("DCGM_FI_DEV_GPU_TEMP", "gauge", "GPU temperature (in C)."),
    ("DCGM_FI_DEV_POWER_USAGE", "gauge", "Power draw (in W)."),
    ("DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION", "counter", "Total energy consumption since boot (in mJ)."),
    ("DCGM_FI_DEV_PCIE_REPLAY_COUNTER", "counter", "Total number of PCIe retries."),
    ("DCGM_FI_DEV_GPU_UTIL", "gauge", "GPU utilization (in %)."),
    ("DCGM_FI_DEV_MEM_COPY_UTIL", "gauge", "Memory utilization (in %)."),
    ("DCGM_FI_DEV_ENC_UTIL", "gauge", "Encoder utilization (in %)."),
    ("DCGM_FI_DEV_DEC_UTIL", "gauge", "Decoder utilization (in %)."),
    ("DCGM_FI_DEV_XID_ERRORS", "gauge", "Value of the last XID error encountered."),
    ("DCGM_FI_DEV_POWER_VIOLATION", "counter", "Throttling duration due to power constraints (in us)."),
    ("DCGM_FI_DEV_THERMAL_VIOLATION", "counter", "Throttling duration due to thermal constraints (in us)."),
    ("DCGM_FI_DEV_CLOCK_THROTTLE_REASONS", "gauge", "Current clock throttle reasons (bitmask of DCGM_CLOCKS_THROTTLE_REASON_*)"),
    ("DCGM_FI_DEV_FB_FREE", "gauge", "Framebuffer memory free (in MiB)."),
    ("DCGM_FI_DEV_FB_USED", "gauge", "Framebuffer memory used (in MiB)."),
    ("DCGM_FI_DEV_ECC_SBE_VOL_TOTAL", "counter", "Total number of single-bit volatile ECC errors."),
    ("DCGM_FI_DEV_ECC_DBE_VOL_TOTAL", "counter", "Total number of double-bit volatile ECC errors."),
    ("DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS", "counter", "Number of remapped rows for uncorrectable errors"),
    ("DCGM_FI_DEV_CORRECTABLE_REMAPPED_ROWS", "counter", "Number of remapped rows for correctable errors"),
    ("DCGM_FI_DEV_ROW_REMAP_FAILURE", "gauge", "Whether remapping of rows has failed"),
    ("DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL", "counter", "Total number of NVLink bandwidth counters for all lanes."),
    ("DCGM_FI_PROF_GR_ENGINE_ACTIVE", "gauge", "Ratio of time the graphics engine is active."),
    ("DCGM_FI_PROF_PIPE_TENSOR_ACTIVE", "gauge", "Ratio of cycles the tensor (HMMA) pipe is active."),
    ("DCGM_FI_PROF_DRAM_ACTIVE", "gauge", "Ratio of cycles the device memory interface is active sending or receiving data."),
    ("DCGM_FI_PROF_PCIE_TX_BYTES", "counter", "Total number of bytes transmitted through PCIe TX via NVML."),
    ("DCGM_FI_PROF_PCIE_RX_BYTES", "counter", "Total number of bytes received through PCIe RX via NVML."),
]
THROTTLE = dict(idle=0x1, sw_power=0x4, hw_slowdown=0x8, sw_thermal=0x20, hw_thermal=0x40, hw_power_brake=0x80)
XID_TEXT = {79: "GPU has fallen off the bus.", 48: "Double Bit ECC Error", 63: "Row remapping event", 64: "Row remapping failure",
            31: "GPU memory page fault", 43: "GPU stopped processing", 74: "NVLink error", 94: "Contained ECC error", 95: "Uncontained ECC error",
            13: "Graphics Engine Exception", 45: "Preemptive cleanup, due to previous errors"}
FAULT_KEYS = ("xid", "thermal", "ecc", "vram_leak")


def f(v):
    if isinstance(v, float) and v == int(v) and abs(v) < 1e15:
        return str(int(v))
    return repr(round(v, 3)) if isinstance(v, float) else str(v)


class State:
    def __init__(self, cfg_path):
        c = load_yaml(cfg_path, {})
        self.host = c.get("hostname") or os.environ.get("HOSTNAME", "mock-node")
        self.driver = str(c.get("driver_version", "570.124.06"))
        self.cuda = str(c.get("cuda_version", "12.8"))
        gl = c.get("gpus")
        if isinstance(gl, dict) or gl is None:
            d = gl or {}
            gl = [dict(d) for _ in range(int(d.get("count", c.get("count", 1))))]
        self.gpus = []
        for i, g in enumerate(gl):
            mem = int(g.get("memory_mib", 81920))
            model = g.get("model", "NVIDIA A100-SXM4-80GB")
            self.gpus.append(dict(
                index=i, model=model, mem=mem,
                uuid=g.get("uuid") or "GPU-" + str(uuid.UUID(hashlib.md5(f"{self.host}/{i}".encode()).hexdigest())),
                pci=g.get("pci_bus_id") or f"00000000:{0x04 + i * 8:02X}:00.0", power_limit=float(g.get("power_limit_w", 400)),
                base_util=float(g.get("util", 40 + 7 * (i % 3))), base_mem=float(g.get("mem_used_mib", mem * 0.45)),
                pod=g.get("pod"), namespace=g.get("namespace"), container=g.get("container"),
                sm_clock=int(g.get("sm_clock_mhz", 1410)), serial=g.get("serial", f"13200{i:08d}")))
        self.t0 = time.time()
        self.frozen = None
        self.faults = {i: {} for i in range(len(self.gpus))}

    # ---- clock
    def now(self):
        return self.frozen if self.frozen is not None else time.time() - self.t0

    # ---- faults
    def sel(self, gpu):
        if gpu in (None, "all"):
            return list(range(len(self.gpus)))
        if isinstance(gpu, int):
            gpu = [gpu]
        out = [int(x) for x in gpu]
        for x in out:
            if x not in self.faults:
                raise ValueError(f"no such gpu {x}")
        return out

    def set_fault(self, body):
        gl = self.sel(body.get("gpu"))
        keys = [k for k in body if k != "gpu"]
        bad = [k for k in keys if k not in FAULT_KEYS + ("vram_leak_mib_per_min",)]
        if bad or not keys:
            raise ValueError(f"unknown/empty fault keys {bad}; allowed gpu + {list(FAULT_KEYS)}")
        t = self.now()
        for i in gl:
            ff = self.faults[i]
            for k in keys:
                v = body[k]
                if k == "vram_leak_mib_per_min":
                    k = "vram_leak"
                if k == "xid":
                    if v in (0, None, False):
                        ff.pop("xid", None)
                    else:
                        ff["xid"] = int(v)
                        ff["xid_t"] = t
                elif k == "thermal":
                    if v in (0, None, False):
                        ff.pop("thermal", None)
                    else:
                        ff["thermal"] = float(92 if v is True else v)
                        ff["thermal_t"] = t
                elif k == "ecc":
                    if v in (0, None, False):
                        ff.pop("ecc", None)
                    else:
                        if isinstance(v, str):
                            v = {v: 1}
                        ff["ecc"] = dict(sbe=int(v.get("sbe", 0)), dbe=int(v.get("dbe", 0)))
                elif k == "vram_leak":
                    if v in (0, None, False):
                        ff.pop("vram_leak", None)
                    else:
                        ff["vram_leak"] = float(v)
                        ff["vram_leak_t"] = t
        return self.faults_view()

    def clear(self, gpu=None):
        for i in self.sel(gpu):
            self.faults[i] = {}
        return self.faults_view()

    def faults_view(self):
        return {str(i): {k: v for k, v in ff.items() if not k.endswith("_t")} for i, ff in self.faults.items()}

    # ---- derived values
    def values(self, i):
        g, ff, t = self.gpus[i], self.faults[i], self.now()
        util = max(0.0, min(100.0, g["base_util"] + 10 * math.sin(2 * math.pi * t / 90 + i)))
        used = g["base_mem"]
        if "vram_leak" in ff:
            used += ff["vram_leak"] * max(0.0, t - ff["vram_leak_t"]) / 60.0
        used = min(float(g["mem"]), used)
        thermal = "thermal" in ff
        gone = ff.get("xid") == 79
        if gone:
            util = 0.0
        if used >= g["mem"] - 1:
            util = min(util, 100.0)
        temp = ff["thermal"] if thermal else 38 + 0.3 * util
        reasons = 0
        if thermal:
            reasons |= THROTTLE["hw_thermal"] | THROTTLE["hw_slowdown"] | THROTTLE["sw_thermal"]
        elif util < 1:
            reasons |= THROTTLE["idle"]
        power = 62 + (g["power_limit"] - 62) * util / 100 * 0.85
        if thermal:
            power *= 0.7
        sm = g["sm_clock"] * (0.57 if thermal else 1.0)
        act = util / 100 * 0.95
        ecc = ff.get("ecc", {})
        return dict(
            DCGM_FI_DEV_SM_CLOCK=round(sm), DCGM_FI_DEV_MEM_CLOCK=1593, DCGM_FI_DEV_MEMORY_TEMP=round(temp + 6),
            DCGM_FI_DEV_GPU_TEMP=round(temp), DCGM_FI_DEV_POWER_USAGE=round(power, 3),
            DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION=round(power * t * 1000), DCGM_FI_DEV_PCIE_REPLAY_COUNTER=0,
            DCGM_FI_DEV_GPU_UTIL=round(util), DCGM_FI_DEV_MEM_COPY_UTIL=round(util * 0.4), DCGM_FI_DEV_ENC_UTIL=0, DCGM_FI_DEV_DEC_UTIL=0,
            DCGM_FI_DEV_XID_ERRORS=ff.get("xid", 0), DCGM_FI_DEV_POWER_VIOLATION=0,
            DCGM_FI_DEV_THERMAL_VIOLATION=round(max(0.0, t - ff["thermal_t"]) * 1e6) if thermal else 0,
            DCGM_FI_DEV_CLOCK_THROTTLE_REASONS=reasons, DCGM_FI_DEV_FB_FREE=round(g["mem"] - used), DCGM_FI_DEV_FB_USED=round(used),
            DCGM_FI_DEV_ECC_SBE_VOL_TOTAL=ecc.get("sbe", 0), DCGM_FI_DEV_ECC_DBE_VOL_TOTAL=ecc.get("dbe", 0),
            DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS=1 if ecc.get("dbe", 0) else 0, DCGM_FI_DEV_CORRECTABLE_REMAPPED_ROWS=0,
            DCGM_FI_DEV_ROW_REMAP_FAILURE=1 if ff.get("xid") == 64 else 0, DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL=0,
            DCGM_FI_PROF_GR_ENGINE_ACTIVE=round(act, 4), DCGM_FI_PROF_PIPE_TENSOR_ACTIVE=round(act * 0.6, 4),
            DCGM_FI_PROF_DRAM_ACTIVE=round(act * 0.5, 4), DCGM_FI_PROF_PCIE_TX_BYTES=round(util * 1e6 * t),
            DCGM_FI_PROF_PCIE_RX_BYTES=round(util * 2e6 * t),
        )

    def state(self):
        out = []
        for i, g in enumerate(self.gpus):
            ff = self.faults[i]
            out.append(dict(index=i, uuid=g["uuid"], name=g["model"], pci_bus_id=g["pci"], mem_total=g["mem"], power_limit=g["power_limit"],
                            serial=g["serial"], values=self.values(i), faults={k: v for k, v in ff.items() if not k.endswith("_t")},
                            fell_off_bus=ff.get("xid") == 79))
        return dict(hostname=self.host, driver_version=self.driver, cuda_version=self.cuda, time=self.now(), gpus=out)

    def xid_log(self):
        lines = []
        for i, ff in self.faults.items():
            if "xid" in ff:
                g = self.gpus[i]
                x = ff["xid"]
                lines.append(f"[{ff['xid_t']:12.6f}] NVRM: Xid (PCI:{g['pci'][4:].lower()}): {x}, pid=1234, name=python3, {XID_TEXT.get(x, 'Unknown error')}")
        return lines

    def render(self):
        out = []
        for name, typ, help_ in FIELDS:
            out.append(f"# HELP {name} {help_}")
            out.append(f"# TYPE {name} {typ}")
            for i, g in enumerate(self.gpus):
                lab = [("gpu", str(i)), ("UUID", g["uuid"]), ("pci_bus_id", g["pci"]), ("device", f"nvidia{i}"), ("modelName", g["model"]),
                       ("Hostname", self.host), ("DCGM_FI_DRIVER_VERSION", self.driver)]
                for k in ("container", "namespace", "pod"):
                    if g.get(k):
                        lab.append((k, g[k]))
                ls = ",".join(f'{k}="{v}"' for k, v in lab)
                out.append(f"{name}{{{ls}}} {f(self.values(i)[name])}")
        return "\n".join(out) + "\n"


def create_app(config_dir):
    st = State(os.path.join(config_dir, "gpus.yaml"))
    if os.environ.get("MOCK_DCGM_FREEZE"):
        st.frozen = float(os.environ["MOCK_DCGM_FREEZE"])
    f0 = load_yaml(os.path.join(config_dir, "fault.yaml"), {})
    for item in (f0.get("faults") or []):
        st.set_fault(item)
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    log("INFO", f"mock-dcgm: host={st.host} gpus={len(st.gpus)} driver={st.driver}", "dcgm")

    @app.get("/metrics")
    async def metrics():
        return PlainTextResponse(st.render(), media_type="text/plain; version=0.0.4; charset=utf-8")

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    @app.get("/admin/fault")
    async def fget():
        return st.faults_view()

    @app.post("/admin/fault")
    async def fset(request: Request):
        try:
            return st.set_fault(await request.json())
        except (ValueError, TypeError, AttributeError) as e:
            return JSONResponse({"error": str(e)}, status_code=400)

    @app.delete("/admin/fault")
    async def fdel(gpu: str | None = None):
        try:
            return st.clear(None if gpu in (None, "all") else int(gpu))
        except ValueError as e:
            return JSONResponse({"error": str(e)}, status_code=400)

    @app.get("/admin/state")
    async def state():
        return st.state()

    @app.get("/admin/xid-log")
    async def xidlog():
        return PlainTextResponse("\n".join(st.xid_log()) + ("\n" if st.xid_log() else ""))

    @app.post("/admin/clock")
    async def clock(request: Request):
        st.frozen = float((await request.json())["t"])
        return {"frozen_at": st.frozen}

    @app.delete("/admin/clock")
    async def unclock():
        st.t0 = time.time() - (st.frozen or 0)
        st.frozen = None
        return {"frozen_at": None}

    return app

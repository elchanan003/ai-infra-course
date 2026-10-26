import os, re, subprocess, sys
import pytest
from conftest import MOCK, http

NAMES = ["DCGM_FI_DEV_GPU_UTIL", "DCGM_FI_DEV_FB_USED", "DCGM_FI_DEV_FB_FREE", "DCGM_FI_DEV_GPU_TEMP", "DCGM_FI_DEV_POWER_USAGE",
         "DCGM_FI_PROF_GR_ENGINE_ACTIVE", "DCGM_FI_DEV_XID_ERRORS", "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL", "DCGM_FI_DEV_ECC_SBE_VOL_TOTAL",
         "DCGM_FI_DEV_CLOCK_THROTTLE_REASONS", "DCGM_FI_DEV_SM_CLOCK"]


def val(text, name, gpu):
    m = re.search(rf'^{name}\{{gpu="{gpu}",[^}}]*}} (\S+)', text, re.M)
    return float(m.group(1))


def smi(s, *args):
    r = subprocess.run([sys.executable, "-m", "aimock.nvsmi", *args], env=dict(os.environ, MOCK_PORT=str(s.port), PYTHONPATH=MOCK),
                       capture_output=True, text=True, cwd=MOCK)
    return r.returncode, r.stdout


def test_metrics_names_and_labels(dcgm):
    s = dcgm()
    t = s.get("/metrics", raw=True)[1].decode()
    for n in NAMES:
        assert f"# TYPE {n} " in t, n
    line = re.search(r"^DCGM_FI_DEV_GPU_UTIL\{.*$", t, re.M).group(0)
    for lab in ("gpu=", "UUID=", "device=", "modelName=", "Hostname=", "DCGM_FI_DRIVER_VERSION=", "pci_bus_id="):
        assert lab in line
    assert 'Hostname="node-a"' in line and 'modelName="NVIDIA A100-SXM4-80GB"' in line
    assert val(t, "DCGM_FI_DEV_FB_USED", 0) + val(t, "DCGM_FI_DEV_FB_FREE", 0) == 81920
    assert len(re.findall(r"^DCGM_FI_DEV_GPU_UTIL\{", t, re.M)) == 2


def test_deterministic_with_frozen_clock(dcgm):
    a = dcgm().get("/metrics", raw=True)[1]
    b = dcgm().get("/metrics", raw=True)[1]
    # UUIDs derive from hostname/index -> identical across runs
    assert a == b


def test_gpus_yaml_list_form(dcgm):
    s = dcgm("hostname: n1\ngpus:\n  - {model: 'NVIDIA H100 80GB HBM3', memory_mib: 81559, uuid: GPU-aaaa, power_limit_w: 700}\n  - {model: 'NVIDIA H100 80GB HBM3', memory_mib: 81559, pod: p1, namespace: ns, container: c}\n")
    t = s.get("/metrics", raw=True)[1].decode()
    assert 'UUID="GPU-aaaa"' in t and 'pod="p1"' in t and 'modelName="NVIDIA H100 80GB HBM3"' in t


def test_fault_xid_ecc_thermal_leak(dcgm):
    s = dcgm()
    g = lambda n, i: val(s.get("/metrics", raw=True)[1].decode(), n, i)
    assert g("DCGM_FI_DEV_XID_ERRORS", 1) == 0
    assert s.post("/admin/fault", dict(gpu=1, xid=79))[0] == 200
    assert g("DCGM_FI_DEV_XID_ERRORS", 1) == 79 and g("DCGM_FI_DEV_XID_ERRORS", 0) == 0 and g("DCGM_FI_DEV_GPU_UTIL", 1) == 0
    base = g("DCGM_FI_DEV_GPU_TEMP", 1)
    s.post("/admin/fault", dict(gpu=0, thermal=True))
    assert g("DCGM_FI_DEV_GPU_TEMP", 0) == 92 and g("DCGM_FI_DEV_GPU_TEMP", 1) == base
    assert int(g("DCGM_FI_DEV_CLOCK_THROTTLE_REASONS", 0)) & 0x40 and g("DCGM_FI_DEV_SM_CLOCK", 0) < 1000
    s.post("/admin/fault", dict(gpu=0, ecc={"dbe": 2, "sbe": 5}))
    assert g("DCGM_FI_DEV_ECC_DBE_VOL_TOTAL", 0) == 2 and g("DCGM_FI_DEV_ECC_SBE_VOL_TOTAL", 0) == 5
    used0 = g("DCGM_FI_DEV_FB_USED", 1)
    s.post("/admin/fault", dict(gpu=1, vram_leak=600))      # MiB per virtual minute
    s.post("/admin/clock", dict(t=100 + 120))
    assert g("DCGM_FI_DEV_FB_USED", 1) == pytest.approx(used0 + 1200, abs=2)
    assert g("DCGM_FI_DEV_FB_USED", 1) + g("DCGM_FI_DEV_FB_FREE", 1) == 81920
    st = s.get("/admin/fault")[1]
    assert st["0"]["thermal"] == 92 and st["1"]["xid"] == 79
    s.delete("/admin/fault?gpu=0")
    assert g("DCGM_FI_DEV_GPU_TEMP", 0) < 70 and g("DCGM_FI_DEV_XID_ERRORS", 1) == 79
    s.delete("/admin/fault")
    assert g("DCGM_FI_DEV_XID_ERRORS", 1) == 0
    assert s.post("/admin/fault", dict(gpu=9, xid=1))[0] == 400
    assert s.post("/admin/fault", dict(nonsense=1))[0] == 400


def test_nvidia_smi_outputs(dcgm):
    s = dcgm()
    rc, out = smi(s)
    assert rc == 0 and "NVIDIA-SMI 570.124.06" in out and "Driver Version: 570.124.06" in out and "NVIDIA A100-SXM4-80GB" in out and "MiB /  81920MiB" in out.replace("  ", "  ")
    assert all(len(l) == 91 for l in out.splitlines()[2:-1] if l)
    rc, out = smi(s, "--query-gpu=index,name,memory.used,memory.total,temperature.gpu", "--format=csv,noheader,nounits")
    rows = [r.split(", ") for r in out.strip().splitlines()]
    assert rc == 0 and len(rows) == 2 and rows[0][0] == "0" and rows[0][1] == "NVIDIA A100-SXM4-80GB" and rows[0][3] == "81920"
    rc, out = smi(s, "--query-gpu=index,memory.used,utilization.gpu", "--format=csv")
    assert out.splitlines()[0] == "index, memory.used [MiB], utilization.gpu [%]" and re.match(r"0, \d+ MiB, \d+ %", out.splitlines()[1])
    rc, out = smi(s, "-L")
    assert re.match(r"GPU 0: NVIDIA A100-SXM4-80GB \(UUID: GPU-[0-9a-f-]{36}\)", out)
    rc, out = smi(s, "-q", "-i", "1")
    assert "Attached GPUs" in out and "ECC Errors" in out and "Clocks Event Reasons" in out and out.count("Product Name") == 1


def test_nvidia_smi_reflects_faults(dcgm):
    s = dcgm()
    s.post("/admin/fault", dict(gpu=1, thermal=95, ecc={"dbe": 3}))
    rc, out = smi(s, "--query-gpu=index,temperature.gpu,clocks_throttle_reasons.active,ecc.errors.uncorrected.volatile.total", "--format=csv,noheader")
    r = out.strip().splitlines()[1].split(", ")
    assert r[1] == "95" and int(r[2], 16) & 0x40 and r[3] == "3"
    s.post("/admin/fault", dict(gpu=0, xid=79))
    rc, out = smi(s)
    assert rc == 255 and "Unable to determine the device handle for GPU00000000:04:00.0: Unknown Error" in out
    assert "NVRM: Xid (PCI:0000:04:00.0): 79" in s.get("/admin/xid-log")[1]


def test_nvidia_smi_no_server():
    r = subprocess.run([sys.executable, "-m", "aimock.nvsmi"], env=dict(os.environ, MOCK_PORT="1", PYTHONPATH=MOCK), capture_output=True, text=True, cwd=MOCK)
    assert r.returncode == 9 and "couldn't communicate with the NVIDIA driver" in r.stdout

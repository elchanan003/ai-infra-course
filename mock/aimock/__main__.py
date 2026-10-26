import os, sys, traceback


def main():
    if len(sys.argv) < 2:
        print("usage: python -m aimock <vllm|dcgm|hf-mirror>", file=sys.stderr)
        sys.exit(2)
    role = sys.argv[1]
    cfg = os.environ.get("MOCK_CONFIG_DIR", "/config")
    port = int(os.environ.get("MOCK_PORT", "8000"))
    host = os.environ.get("MOCK_HOST", "0.0.0.0")
    import uvicorn
    if role == "vllm":
        from .capacity import StartupError
        from .common import log
        from . import vllm_app
        try:
            a, cap, f0 = vllm_app.startup(cfg)
        except StartupError as e:
            print(f"(EngineCore pid=38) ERROR [core.py:1433] {e}", flush=True)
            print("Traceback (most recent call last):\n  ...", flush=True)
            print(str(e), flush=True)
            sys.exit(1)
        except Exception:
            traceback.print_exc()
            sys.exit(1)
        app = vllm_app.create_app(a, cap, f0, cfg)
    elif role == "dcgm":
        from . import dcgm
        app = dcgm.create_app(cfg)
    elif role == "hf-mirror":
        from . import hfmirror
        app = hfmirror.create_app(os.environ.get("MOCK_DATA_DIR", "/data"))
    else:
        print(f"unknown role {role}", file=sys.stderr)
        sys.exit(2)
    uvicorn.run(app, host=host, port=port, log_level="warning", access_log=False)


main()

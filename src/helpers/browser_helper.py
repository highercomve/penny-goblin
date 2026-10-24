"""Frozen desktop browser entry point; no system Python is used at runtime."""
import runpy
import sys
import os

# GTK's Vulkan renderer and WebKit's DMABUF compositor crash on some
# NVIDIA/Wayland systems. These text/document windows need neither GPU path.
# Keep this local to the browser process; model inference still uses CUDA.
os.environ["GSK_RENDERER"] = "cairo"
os.environ["WEBKIT_DISABLE_DMABUF_RENDERER"] = "1"
os.environ["WEBKIT_DISABLE_COMPOSITING_MODE"] = "1"
# PyInstaller redirects Gio modules to its bundle. We intentionally use the
# system GTK/WebKit stack, including its matching TLS and proxy modules.
os.environ.pop("GIO_MODULE_DIR", None)


def watch_owner():
    # A frozen one-file executable has a bootloader between Python and the
    # application. Watch the actual owner, not just that intermediate process,
    # so an app exit cannot leave an authenticated bank window behind.
    if not getattr(sys, "frozen", False):
        return
    import select
    import signal
    import threading
    parent = os.getppid()
    with open(f"/proc/{parent}/stat", encoding="ascii") as status:
        owner = int(status.read().rsplit(")", 1)[1].split()[1])
    if owner <= 1:
        raise SystemExit(1)
    descriptor = os.pidfd_open(owner)

    def wait():
        select.select([descriptor], [], [])
        os.kill(os.getpid(), signal.SIGTERM)

    threading.Thread(target=wait, daemon=True).start()


watch_owner()

if sys.argv[1:] == ["--check-runtime"]:
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import Gio
    import json
    tls = Gio.TlsBackend.get_default().supports_tls()
    print(json.dumps({"tls": tls}))
    raise SystemExit(0 if tls else 1)

modules = {"--santander": "santander_browser", "--bci": "bci_browser", "--boa": "boa_browser", "--research": "research_browser"}
if len(sys.argv) < 2 or sys.argv[1] not in modules:
    raise SystemExit("Expected --santander, --bci, --boa or --research")
module = modules[sys.argv.pop(1)]
runpy.run_module(module, run_name="__main__")

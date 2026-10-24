"""An isolated, ephemeral Santander login window. Only the movements response exits."""
import ctypes
import json
import os
import signal
import sys
from urllib.parse import urlsplit

TARGET = "https://mibanco.santander.cl/UI.Web.HB/Private_new/frame/#/private/Saldos_TC/main/bill"
LOGIN = "https://mibanco.santander.cl/"
ENDPOINT = "/perdsk/tarjetasDeCredito/consultaUltimosMovimientos"
MAX_RESPONSE = 2 * 1024 * 1024


def bank_url(url):
    try:
        p = urlsplit(url)
        return (p.scheme == "https" and not p.username and not p.password
                and p.port in (None, 443)
                and (p.hostname == "santander.cl" or (p.hostname or "").endswith(".santander.cl")))
    except ValueError:
        return False



# This is the only script injected into the isolated bank page. It never reads
# request bodies, request headers, login fields, storage, cookies or unrelated responses.
CAPTURE_SCRIPT = r"""(() => {
  const target = value => {
    try {
      const u = new URL(value, location.href);
      return !u.username && !u.password && u.origin === __MOVEMENTS_ORIGIN__ &&
        u.pathname === __MOVEMENTS_PATH__;
    } catch { return false; }
  };
  let sequence = 0;
  const started = () => {
    const id = ++sequence;
    try { window.webkit.messageHandlers.penny_santander.postMessage('{"state":"loading"}'); } catch {}
    return id;
  };
  const failed = id => {
    try { if (id === sequence) window.webkit.messageHandlers.penny_santander.postMessage('{"state":"failed"}'); } catch {}
  };
  const emit = (value, id) => {
    if (id !== sequence) return;
    try {
      const text = typeof value === 'string' ? value : JSON.stringify(value);
      if (text.length <= 2 * 1024 * 1024)
        window.webkit.messageHandlers.penny_santander.postMessage(text);
    } catch {}
  };
  const nativeFetch = window.fetch;
  window.fetch = function(...args) {
    const pending = nativeFetch.apply(this, args);
    if (target(args[0] instanceof Request ? args[0].url : args[0])) {
      const id = started();
      pending.then(response => {
        if (response.ok && target(response.url)) {
          const size = Number(response.headers.get('Content-Length'));
          if (!Number.isFinite(size) || size <= 2 * 1024 * 1024)
            (async () => {
              const reader = response.clone().body?.getReader();
              if (!reader) return;
              let bytes = 0, text = '';
              const decoder = new TextDecoder();
              while (true) {
                const part = await reader.read();
                if (part.done) { emit(text + decoder.decode(), id); return; }
                bytes += part.value.byteLength;
                if (bytes > 2 * 1024 * 1024) { reader.cancel().catch(() => {}); failed(id); return; }
                text += decoder.decode(part.value, {stream:true});
              }
            })().catch(() => failed(id));
        } else failed(id);
      }).catch(() => failed(id));
    }
    return pending;
  };
  const targets = new WeakMap();
  const nativeOpen = XMLHttpRequest.prototype.open;
  const nativeSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(...args) {
    const result = nativeOpen.apply(this, args);
    targets.set(this, target(args[1]));
    return result;
  };
  XMLHttpRequest.prototype.send = function(...args) {
    if (targets.get(this)) {
      const id = started();
      this.addEventListener('loadend', () => {
      if (this.status >= 200 && this.status < 300 && target(this.responseURL)) {
        if (this.responseType === 'json') emit(this.response, id);
        else if (!this.responseType || this.responseType === 'text') emit(this.responseText, id);
      } else failed(id);
      }, {once:true});
    }
    return nativeSend.apply(this, args);
  };
})();"""


def run(fixture=None):
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("WebKit", "6.0")
    from gi.repository import Gtk, GLib, WebKit

    Gtk.init()
    loop = GLib.MainLoop()
    session = WebKit.NetworkSession.new_ephemeral()
    manager = WebKit.UserContentManager()
    manager.register_script_message_handler("penny_santander", None)
    view = WebKit.WebView(network_session=session, user_content_manager=manager)
    # These document browsers do not need GPU compositing. On NVIDIA/Wayland
    # the threaded compositor can crash before the login page is displayed.
    settings = view.get_settings()
    settings.set_hardware_acceleration_policy(WebKit.HardwareAccelerationPolicy.NEVER)
    # Do not let bank fingerprinting trigger desktop camera/microphone portals.
    # Login and statement capture do not need media devices.
    settings.set_enable_webrtc(False)
    settings.set_enable_media_stream(False)
    from bank_chrome import BankChrome
    window = Gtk.Window(title="Penny Goblin — Santander")
    window.set_default_size(1100, 800)
    chrome = BankChrome(window, view)
    output = None
    captured = None
    routed = False

    def finish(value):
        nonlocal output
        if output is None:
            output = value
            loop.quit()

    def policy(_view, decision, kind):
        if kind in (WebKit.PolicyDecisionType.NAVIGATION_ACTION, WebKit.PolicyDecisionType.NEW_WINDOW_ACTION):
            action = decision.get_navigation_action()
            url = action.get_request().get_uri()
            allowed = bank_url(url)
            if fixture:
                p, expected = urlsplit(url), urlsplit(fixture)
                allowed = p.scheme == "http" and p.netloc == expected.netloc
            if url == "about:blank" and kind != WebKit.PolicyDecisionType.NEW_WINDOW_ACTION:
                return False
            if not allowed or kind == WebKit.PolicyDecisionType.NEW_WINDOW_ACTION:
                decision.ignore()
                if action.is_user_gesture() or kind == WebKit.PolicyDecisionType.NEW_WINDOW_ACTION:
                    chrome.update(chrome.stage, "External navigation blocked", "Use the Santander page in this window to continue.")
                return True
        return False

    def received(_manager, message):
        nonlocal captured
        try:
            raw = message.to_string()
            if len(raw.encode("utf-8")) > MAX_RESPONSE:
                raise ValueError()
            value = json.loads(raw)
            if value in ({"state": "loading"}, {"state": "failed"}):
                captured = None
                loading = value["state"] == "loading"
                chrome.update(2, "Reading card movements…" if loading else "Couldn’t read movements",
                              "Keep this window open." if loading else "Open the selected card’s movements again to retry.", busy=loading, error=not loading)
                return
            if (not isinstance(value, dict) or value.get("METADATA", {}).get("STATUS") != "0"
                    or value.get("DATA", {}).get("Informacion", {}).get("Codigo") != "00"
                    or not isinstance(value.get("DATA", {}).get("MatrizMovimientos"), list)):
                raise ValueError()
            captured = value
            count = len(value["DATA"]["MatrizMovimientos"])
            chrome.update(3, "Ready to review", f"{count} bank movements captured. Check the selected card before continuing. Nothing has been saved yet.", ready=True)
            if fixture:  # Synthetic browser acceptance only; real banking always waits for the user.
                chrome.primary.emit("clicked")
        except (ValueError, TypeError, AttributeError, RecursionError):
            captured = None
            chrome.update(2, "Couldn’t read movements", "Santander returned an unexpected response. Try opening card movements again.", error=True)

    def primary_action(*_):
        if captured is not None and chrome.action == "review":
            finish({"response": captured})
        else:
            view.load_uri(fixture or (LOGIN if chrome.action == "retry" else TARGET))

    chrome.primary.connect("clicked", primary_action)
    chrome.back.connect("clicked", lambda *_: view.load_uri(fixture or LOGIN))
    manager.connect("script-message-received::penny_santander", received)
    origin = ("http://" + urlsplit(fixture).netloc) if fixture else "https://api-dsk.santander.cl"
    script = CAPTURE_SCRIPT.replace("__MOVEMENTS_ORIGIN__", json.dumps(origin)).replace("__MOVEMENTS_PATH__", json.dumps(ENDPOINT))
    manager.add_script(WebKit.UserScript.new(script, WebKit.UserContentInjectedFrames.ALL_FRAMES,
                       WebKit.UserScriptInjectionTime.START, None, None))

    def changed(_view, _property):
        nonlocal routed
        # The private SPA route proves navigation after login, without reading
        # login fields or inspecting account/session details.
        url = view.get_uri() or ""
        parts = urlsplit(url)
        if (not fixture and not routed and bank_url(url) and parts.hostname == "mibanco.santander.cl"
                and parts.path == "/UI.Web.HB/Private_new/frame/"
                and parts.fragment.startswith("/private/") and url != TARGET):
            routed = True
            GLib.idle_add(lambda: (view.load_uri(TARGET), False)[1])
        if parts.fragment.startswith("/private/") and captured is None:
            chrome.update(2, "Choose your card", "Open its current movements. You’ll review new charges in Penny Goblin before saving.")

    def loading(_view, event):
        nonlocal captured
        if event == WebKit.LoadEvent.STARTED:
            captured = None
            chrome.update(chrome.stage if chrome.stage < 3 else 2, "Loading Santander…", "Your sign-in stays in this private bank window.", busy=True)
        elif event == WebKit.LoadEvent.FINISHED and captured is None and chrome.action != "retry":
            if (urlsplit(view.get_uri() or "").fragment or "").startswith("/private/"):
                chrome.update(2, "Choose your card", "Open its current movements. You’ll review new charges before saving.")
            else:
                chrome.update(1, "Sign in to Santander", "Use your RUT and password on the bank’s page.")

    view.connect("load-changed", loading)
    view.connect("notify::uri", changed)
    view.connect("notify::estimated-load-progress", lambda *_: chrome.page_progress(view))
    view.connect("notify::is-loading", lambda *_: chrome.page_progress(view))

    def load_failed(_view, _event, _uri, error):
        if not error.matches(WebKit.network_error_quark(), WebKit.NetworkError.CANCELLED):
            chrome.update(chrome.stage, "Couldn’t load Santander", error.message, error=True)
        return True

    view.connect("decide-policy", policy)
    view.connect("create", lambda *_: None)
    view.connect("permission-request", lambda _, request: (request.deny(), True)[1])
    view.connect("load-failed", load_failed)
    view.connect("load-failed-with-tls-errors", lambda *_: (chrome.update(chrome.stage, "Connection couldn’t be verified", "Santander’s certificate could not be verified. Close this window and try later.", error=True), True)[1])
    view.connect("web-process-terminated", lambda *_: finish({"error": "SantanderBrowserUnavailable"}))
    session.connect("download-started", lambda _, download: download.cancel())
    window.connect("close-request", lambda *_: (finish({"error": "Cancelled"}), True)[1])
    timer = GLib.timeout_add_seconds(15 * 60, lambda: (finish({"error": "SantanderLoginTimedOut"}), False)[1])
    window.present()
    view.load_uri(fixture or LOGIN)
    try:
        loop.run()
    finally:
        if output is not None and output.get("error") != "SantanderLoginTimedOut":
            GLib.source_remove(timer)
        view.stop_loading()
        window.destroy()
    return output or {"error": "Cancelled"}


if __name__ == "__main__":
    # A killed app must not leave a banking session running.
    parent = os.getppid()
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0 or parent == 1 or os.getppid() != parent:
        raise SystemExit(1)
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)
    # WebKit and GTK messages must never corrupt the private response pipe.
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    fixture = None
    if len(sys.argv) == 3 and sys.argv[1] == "--fixture-url":
        fixture = sys.argv[2]
        p = urlsplit(fixture)
        if p.scheme != "http" or p.hostname != "127.0.0.1" or p.username or p.password:
            raise SystemExit(1)
    elif len(sys.argv) != 1:
        raise SystemExit(1)
    try:
        result = run(fixture)
    except Exception:
        result = {"error": "SantanderBrowserUnavailable"}
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")), file=protocol, flush=True)

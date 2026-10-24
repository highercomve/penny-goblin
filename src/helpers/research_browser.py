"""Desktop research browser feasibility prototype; not connected to the ledger.

Run under scripts/headless.sh. stdin/stdout carry one JSON object per line.
Distributed with a bundled Python/PyGObject runtime; uses system GTK4/WebKitGTK 6. No app IPC bridge is
installed. This is browser isolation, not a general network sandbox.
"""
import argparse
import ctypes
import signal
import json
import os
import sys
import threading
from urllib.parse import urlencode, urlsplit

# Keep native libraries and their children off the JSON protocol stream.
PROTOCOL = sys.stdout
if __name__ == "__main__":
    # The browser belongs to its model/app worker, including abnormal exits.
    parent = os.getppid()
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "Cannot watch research parent")
    if parent == 1 or os.getppid() != parent:
        os._exit(1)
    PROTOCOL = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("WebKit", "6.0")
from gi.repository import Gio, GLib, Gtk, WebKit

MAX_INPUT = 4096
# Fixed application-owned projection. The model cannot supply JavaScript.
PROJECTION = r"""JSON.stringify((() => {
  const visible = el => !!el.getClientRects().length &&
    getComputedStyle(el).visibility !== 'hidden';
  const links = [];
  for (const el of document.querySelectorAll('a[href]')) {
    if (links.length >= 80) break;
    if (!visible(el)) continue;
    const text = (el.innerText || el.getAttribute('aria-label') || '').trim();
    if (text && el.href.length <= 2048 && /^https?:/.test(el.href))
      links.push({text: text.slice(0, 240), url: el.href});
  }
  return {url: location.href, title: document.title.slice(0, 300),
    text: (document.body?.innerText || '').slice(0, 16000), links,
    pending_search: location.hostname.endsWith('google.com') && location.pathname === '/search' &&
      !(document.querySelector('#search, #rso')?.innerText || '').trim(),
    challenge: !!document.querySelector('iframe[src*="recaptcha"], .g-recaptcha, #captcha-form, #challenge-running, #challenge-stage') || /just a moment|verify you are human|verifying you are human|unusual traffic|checking your browser/i.test(document.title + ' ' + (document.body?.innerText || '').slice(0, 1500)),
    consent: location.hostname === 'consent.google.com'};
})())"""


class Browser:
    def __init__(self, fixture_url=None):
        Gtk.init()
        self.loop = GLib.MainLoop()
        self.fixture_url = fixture_url
        self.session = WebKit.NetworkSession.new_ephemeral()
        self.proxy = None
        if not fixture_url:
            from research_network import Proxy
            self.proxy = Proxy()
            proxy = WebKit.NetworkProxySettings.new(f"http://127.0.0.1:{self.proxy.server_address[1]}", [])
            self.session.set_proxy_settings(WebKit.NetworkProxyMode.CUSTOM, proxy)
        self.view = WebKit.WebView(network_session=self.session)
        settings = self.view.get_settings()
        # Text research needs no GPU compositor; keep it independent of the
        # desktop's NVIDIA/Wayland graphics path (and the model's CUDA backend).
        settings.set_hardware_acceleration_policy(WebKit.HardwareAccelerationPolicy.NEVER)
        settings.set_enable_html5_database(False)
        settings.set_enable_webrtc(False)
        settings.set_enable_media_stream(False)
        settings.set_enable_dns_prefetching(False)
        settings.set_allow_file_access_from_file_urls(False)
        settings.set_allow_universal_access_from_file_urls(False)
        self.view.connect("load-changed", self.loaded)
        self.view.connect("load-failed", self.failed)
        self.view.connect("load-failed-with-tls-errors", self.tls_failed)
        self.view.connect("permission-request", lambda _, request: (request.deny(), True)[1])
        self.view.connect("decide-policy", self.policy)
        self.view.connect("create", lambda *_: None)
        self.view.connect("script-dialog", self.script_dialog)
        self.view.connect("web-process-terminated", self.terminated)
        self.session.connect("download-started", lambda _, download: download.cancel())
        self.window = Gtk.Window(title="Penny Goblin research prototype")
        self.window.set_default_size(1024, 768)
        self.window.set_child(self.view)
        self.window.present()
        self.request = None
        self.done = threading.Event()
        self.done.set()
        self.accepted = threading.Event()
        self.timer = None
        self.cancel = None
        self.generation = 0
        self.page = None
        self.page_id = 0
        self.read_attempts = 0
        self.load_started = False

    def allowed(self, url):
        try:
            parts = urlsplit(url)
            if parts.username or parts.password:
                return False
            if self.fixture_url and parts.scheme == "http":
                fixture = urlsplit(self.fixture_url)
                return parts.netloc == fixture.netloc
            return parts.scheme == "https" and bool(parts.hostname)
        except ValueError:
            return False

    def policy(self, _, decision, kind):
        if kind in (WebKit.PolicyDecisionType.NAVIGATION_ACTION, WebKit.PolicyDecisionType.NEW_WINDOW_ACTION):
            url = decision.get_navigation_action().get_request().get_uri()
            # WebKit/Google create empty child frames while loading pages.
            if url == "about:blank" and kind != WebKit.PolicyDecisionType.NEW_WINDOW_ACTION:
                return False
            if kind == WebKit.PolicyDecisionType.NEW_WINDOW_ACTION or not self.allowed(url):
                decision.ignore()
                self.finish(error="NavigationDenied")
                return True
        if kind == WebKit.PolicyDecisionType.RESPONSE and not decision.is_mime_type_supported():
            decision.ignore()
            self.finish(error="UnsupportedContent")
            return True
        return False

    def script_dialog(self, _, dialog):
        # Never let page alert/confirm dialogs stall a research job.
        if dialog.get_dialog_type() in (WebKit.ScriptDialogType.CONFIRM, WebKit.ScriptDialogType.BEFORE_UNLOAD_CONFIRM):
            dialog.confirm_set_confirmed(False)
        return True

    def finish(self, result=None, error=None):
        if self.request is None:
            return
        reply = {"id": self.request.get("id"), "ok": error is None}
        reply["error" if error else "result"] = error or result
        self.request = None
        if self.timer is not None:
            GLib.source_remove(self.timer)
            self.timer = None
        if self.cancel:
            self.cancel.cancel()
            self.cancel = None
        print(json.dumps(reply, ensure_ascii=False), flush=True, file=PROTOCOL)
        self.done.set()

    def timeout(self):
        self.timer = None
        self.finish(error="PageTimeout")
        self.view.stop_loading()
        return False

    def loaded(self, _, event):
        if self.request is None:
            return
        if event == WebKit.LoadEvent.STARTED:
            self.load_started = True
        elif event == WebKit.LoadEvent.FINISHED and self.load_started:
            self.load_started = False
            self.read_current(self.generation)

    def read_current(self, generation):
        if self.request is not None and generation == self.generation:
            self.view.evaluate_javascript(PROJECTION, -1, "penny-research", None,
                                          self.cancel, self.extracted, generation)
        return False

    def extracted(self, view, result, generation):
        if self.request is None or generation != self.generation:
            return
        try:
            page = json.loads(view.evaluate_javascript_finish(result).to_string())
            if not self.allowed(page["url"]):
                raise ValueError("NavigationDenied")
            # Search sites can populate their DOM after the load event. Never
            # report an empty browser shell as usable research evidence.
            self.read_attempts += 1
            pending = not page["text"].strip() or page["pending_search"]
            if pending and not page["challenge"] and not page["consent"] and self.read_attempts < 60:
                GLib.timeout_add(250, self.read_current, generation)
                return
            self.page_id += 1
            page["page_id"] = self.page_id
            blocked = page.pop("challenge") or urlsplit(page["url"]).path.startswith("/sorry")
            page["state"] = "blocked" if blocked else "consent_required" if page.pop("consent") else "ready" if page["text"].strip() else "unreadable"
            if page.pop("pending_search") and page["state"] == "ready":
                page["state"] = "unreadable"
            page.pop("consent", None)
            # Links are resolved by index against this retained snapshot only.
            self.page = page
            self.finish(result=page)
        except (GLib.Error, ValueError, TypeError, KeyError):
            self.finish(error="PageReadFailed")

    def failed(self, _view, _event, _uri, error):
        # Starting navigation cancels the previous load. That cancellation is
        # not a failure of the new tool request.
        if error.matches(WebKit.network_error_quark(), WebKit.NetworkError.CANCELLED):
            return True
        self.finish(error="PageLoadFailed")
        return True

    def tls_failed(self, *_):
        self.finish(error="TlsRejected")
        return True

    def terminated(self, *_):
        self.page = None
        self.finish(error="BrowserTerminated")

    def dispatch(self, request):
        self.generation += 1
        self.read_attempts = 0
        self.request = request
        try:
            action = request.get("tool")
            if action == "read_page":
                if not self.page or request.get("page_id") != self.page["page_id"]:
                    raise ValueError("StalePage")
                self.finish(result=self.page)
                return False
            if action == "search":
                query = request.get("query")
                if not isinstance(query, str) or not query.strip() or len(query) > 240:
                    raise ValueError("InvalidQuery")
                url = "https://www.google.com/search?" + urlencode({"q": query, "hl": "es"})
            elif action == "follow_link":
                if not self.page or request.get("page_id") != self.page["page_id"]:
                    raise ValueError("StalePage")
                index = request.get("link")
                if type(index) is not int or not 0 <= index < len(self.page["links"]):
                    raise ValueError("InvalidLink")
                url = self.page["links"][index]["url"]
            elif action == "fixture" and self.fixture_url:
                url = self.fixture_url
            else:
                raise ValueError("UnknownTool")
            if not self.allowed(url):
                raise ValueError("NavigationDenied")
            self.page = None
            self.load_started = False
            self.cancel = Gio.Cancellable()
            self.timer = GLib.timeout_add_seconds(25, self.timeout)
            self.view.load_uri(url)
        except (ValueError, TypeError, KeyError) as error:
            self.finish(error=str(error))
        return False

    def receive(self, request):
        try:
            if request.get("tool") == "cancel":
                active = self.request is not None
                self.generation += 1
                if active:
                    self.finish(error="Cancelled")
                    self.view.stop_loading()
                print(json.dumps({"id": request.get("id"), "ok": True,
                                  "result": {"cancelled": active}}), flush=True, file=PROTOCOL)
            elif self.request is not None:
                print(json.dumps({"id": request.get("id"), "ok": False,
                                  "error": "BrowserBusy"}), flush=True, file=PROTOCOL)
            else:
                self.done.clear()
                self.dispatch(request)
        finally:
            self.accepted.set()
        return False

    def input(self):
        while True:
            line = sys.stdin.buffer.readline(MAX_INPUT + 1)
            if not line:
                self.done.wait()
                GLib.idle_add(self.loop.quit)
                return
            if len(line) > MAX_INPUT:
                # Close the protocol rather than interpreting trailing chunks.
                print(json.dumps({"id": None, "ok": False, "error": "RequestTooLarge"}), flush=True, file=PROTOCOL)
                GLib.idle_add(self.loop.quit)
                return
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise ValueError()
            except (ValueError, UnicodeDecodeError, RecursionError):
                print(json.dumps({"id": None, "ok": False, "error": "InvalidRequest"}), flush=True, file=PROTOCOL)
                continue
            self.accepted.clear()
            GLib.idle_add(self.receive, request)
            self.accepted.wait()

    def run(self):
        threading.Thread(target=self.input, daemon=True).start()
        try:
            self.loop.run()
        finally:
            if self.cancel:
                self.cancel.cancel()
            self.view.stop_loading()
            self.window.destroy()
            if self.proxy:
                self.proxy.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-url", help="Local test server URL; never supplied by the model")
    args = parser.parse_args()
    if args.fixture_url:
        parsed = urlsplit(args.fixture_url)
        if parsed.scheme != "http" or parsed.hostname != "127.0.0.1":
            parser.error("fixture URL must use http://127.0.0.1")
    Browser(args.fixture_url).run()

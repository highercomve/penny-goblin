"""Insights month range, whole-year selection and category medians in the real WebKit UI.

Run with Oriel scripts/headless.sh; no real ledger/model/network is used.
"""
import functools
import http.server
import json
from pathlib import Path
import threading
import unittest
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("WebKit", "6.0")
from gi.repository import Gtk, GLib, WebKit

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = r"""
window.setInterval = () => 0;
window.qaCalls = [];
const row = (n, date, amount, category, payee) => ({id: String(n).repeat(64).slice(0, 64), revision: 1, date, amount, currency: 'CLP',
  payee, account: '1234', category, notes: '', reference: '', location: '', evidence_count: 0});
window.qaFixture = {platform: 'linux', vision_available: false, tray_running: false, statements: [],
 settings: JSON.stringify({salary: 10000, cards_config: {'1234': 'Household'}, fixed_expenses_items: [{name: 'Rent', amount: 500, keywords: ['RENT']}]}),
 expenses: [
  row(1, '2025-11-04', 700, 'Food', 'Old market'),
  row(2, '2026-01-10', 1000, 'Food', 'Market'), row(3, '2026-01-12', 300, 'Taxi', 'Cab'),
  row(4, '2026-02-03', 3000, 'Food', 'Market'),
  row(5, '2026-03-08', 2000, 'Food', 'Market'), row(6, '2026-03-09', 900, 'Taxi', 'Cab')]};
window.oriel = {listen(){}, invoke: async (cmd, args = {}) => {
 qaCalls.push({cmd, args});
 if (cmd === 'snapshot') return qaFixture;
 if (cmd === 'export_report') return true;
 if (cmd === 'save_budget') {
  if (args.expected !== qaFixture.settings) throw Error('SettingsConflict');
  qaFixture.settings = JSON.stringify(args.settings); return 0;
 }
 if (cmd === 'qa_scenario' || cmd === 'take_quick_action') return null;
 throw Error(cmd);
}};
window.addEventListener('load', async () => {
 const until = async (fn) => { for (let i = 0; i < 150; i++) { if (fn()) return; await new Promise(r => setTimeout(r, 20)); } throw Error('UI wait timed out'); };
 const check = (ok, message) => { if (!ok) throw Error(message); };
 const choose = (id, value) => { $(id).value = value; $(id).dispatchEvent(new Event('change', {bubbles: true})); };
 const chart = () => [...$('category-chart').querySelectorAll('.report-row')].map(r => r.textContent);
 try {
  await until(() => snapshot);
  showView('insights');
  check($('insights-from').value === '2026-03' && $('insights-to').value === '2026-03', 'Insights did not start on the latest month');
  check($('insights-period').textContent === 'March 2026', `Unexpected label ${$('insights-period').textContent}`);
  check(chart()[0].includes('Food') && !chart()[0].includes('median'), 'Single month shows a median');

  choose('insights-year', '2026');
  check($('insights-from').value === '2026-01' && $('insights-to').value === '2026-03', 'Whole year did not cover its months');
  check($('insights-period').textContent.includes('3 months'), 'Range label lacks month count');
  check($('month').value === '2026-03', 'Insights changed the Home month');
  // Food: 1000, 3000, 2000 -> median 2000. Taxi: 300, 0, 900 -> median 300.
  let rows = chart();
  check(rows[0].includes('Food') && rows[0].includes('6.000') && rows[0].includes('median $2.000'), `Food total row: ${rows[0]}`);
  choose('category-measure', 'median');
  rows = chart();
  check(rows[0].includes('Food') && rows[0].includes('$2.000') && rows[0].includes('total $6.000'), `Food median row: ${rows[0]}`);
  check(rows[1].includes('Taxi') && rows[1].includes('$300'), `Taxi median row: ${rows[1]}`);

  $('chart-fixed').click();
  check(chart().some(r => r.includes('Rent') && r.includes('$500') && r.includes('Planned a month')), 'Median plans one month of rent');
  choose('category-measure', 'total');
  check(chart().some(r => r.includes('Rent') && r.includes('$1.500')), 'Range total plans rent for each month');
  $('chart-fixed').click();

  choose('insights-from', '2025-11');
  check($('insights-year').value === '', 'Year chip kept after the range changed');
  check($('insights-period').textContent.includes('5 months'), 'Calendar months not counted');
  choose('insights-from', '2026-03'); choose('insights-to', '2026-01');
  check($('insights-from').value === '2026-01' && $('insights-to').value === '2026-01', 'Through before From was not corrected');

  // A median joins the monthly budget; Home then tracks it for the month.
  choose('insights-year', '2026'); choose('category-measure', 'median');
  check($('category-hint').textContent.includes('Long-press'), 'Median mode lacks the long-press hint');
  // A tap still opens the category's payments; a long press offers the budget.
  $('category-chart').querySelector('.report-row').click();
  check(currentView === 'payments' && drilldown?.name === 'Food', 'Tap did not open Food payments');
  check($('rows').querySelectorAll('.payment').length === 3, 'Drill-down lost payments outside the Home month');
  history.back(); await until(() => currentView === 'insights');
  $('category-chart').querySelector('.report-row').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true}));
  await until(() => $('ask-dialog').open);
  check($('ask-message').textContent.includes('Food') && $('ask-message').textContent.includes('$2.000'), $('ask-message').textContent);
  check($('ask-ok').textContent === 'Add to budget', 'Unexpected budget action');
  $('ask-ok').click();
  await until(() => JSON.parse(qaFixture.settings).category_budgets?.Food === 2000 && JSON.parse(snapshot.settings).category_budgets);
  check(JSON.parse(qaFixture.settings).fixed_expenses_items.length === 1, 'Budget save lost fixed expenses');
  check(chart()[0].includes('budget $2.000'), 'Insights row lacks its budget');
  // March: Food spent 2000 of 2000; forecast = 10000 - 500 planned - 2900 variable.
  const budgetRow = $('category-budgets').querySelector('.report-row');
  check(budgetRow && budgetRow.textContent.includes('Food') && budgetRow.textContent.includes('$0 left'), 'Home budget row missing');
  check($('budget-forecast').textContent.includes('6.600'), `Forecast ${$('budget-forecast').textContent}`);
  check($('budget-parts').textContent.includes('Budgets left'), 'Budget parts lack the reserve');
  choose('month', '2026-02');
  // February: Taxi nothing, Food 3000 of 2000 -> 1000 over.
  check($('category-budgets').textContent.includes('$1.000 over'), $('category-budgets').textContent);
  choose('month', '2026-03');
  check($('budget-hint').textContent.includes('Long-press'), 'Home lacks the remove hint');
  // The confirm dialog's own history entry is popped asynchronously after it closes.
  await until(() => history.state?.penny !== 'dialog');
  const origin = currentView;
  $('category-budgets').querySelector('.report-row').click();
  check(currentView === 'payments' && drilldown?.name === 'Food' && drilldown.ids.size === 1, 'Budget tap did not open its month payments');
  history.back(); await until(() => currentView === origin);
  $('category-budgets').querySelector('.report-row').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true}));
  await until(() => $('ask-dialog').open);
  check($('ask-ok').textContent === 'Remove budget', 'Unexpected remove action');
  $('ask-ok').click();
  await until(() => !$('category-budgets').children.length);
  check(!JSON.parse(qaFixture.settings).category_budgets.Food, 'Budget not removed');
  choose('category-measure', 'total');

  choose('insights-year', '2025');
  $('export-report').click();
  await until(() => qaCalls.some(x => x.cmd === 'export_report'));
  const html = qaCalls.find(x => x.cmd === 'export_report').args.html;
  check(html.includes('November 2025') && html.includes('Old market') && !html.includes('Cab'), 'Export ignored the Insights range');
  window.webkit.messageHandlers.qa.postMessage(JSON.stringify({ok: true}));
 } catch (error) { window.webkit.messageHandlers.qa.postMessage(JSON.stringify({ok: false, error: String(error), stack: error.stack})); }
});
"""


class QuietFiles(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_): pass


class InsightsUiTest(unittest.TestCase):
    def test_range_desktop(self):
        self.run_range(False)

    def test_range_phone(self):
        self.run_range(True)

    def run_range(self, mobile):
        Gtk.init()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietFiles, directory=str(ROOT / "frontend")))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        loop = GLib.MainLoop()
        result = {}
        manager = WebKit.UserContentManager()
        manager.register_script_message_handler("qa", None)
        def received(_manager, value):
            result.update(json.loads(value.to_string()))
            loop.quit()
        manager.connect("script-message-received::qa", received)
        script = BRIDGE.replace("platform: 'linux'", "platform: 'android'") if mobile else BRIDGE
        manager.add_script(WebKit.UserScript.new(script, WebKit.UserContentInjectedFrames.TOP_FRAME, WebKit.UserScriptInjectionTime.START, None, None))
        view = WebKit.WebView(network_session=WebKit.NetworkSession.new_ephemeral(), user_content_manager=manager)
        window = Gtk.Window()
        window.set_default_size(393 if mobile else 1180, 820)
        window.set_child(view)
        window.present()
        view.load_uri(f"http://127.0.0.1:{server.server_port}/")
        timeout = GLib.timeout_add_seconds(20, lambda: (loop.quit(), False)[1])
        try:
            loop.run()
            self.assertTrue(result.get("ok"), result or "WebKit UI timed out")
        finally:
            GLib.source_remove(timeout)
            window.destroy()
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__": unittest.main()

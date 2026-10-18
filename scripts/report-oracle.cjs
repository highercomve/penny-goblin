// Read-only oracle for the compiled reporting port; files contain private data.
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.join(__dirname, '..', 'frontend');
const reports = vm.runInNewContext(fs.readFileSync(path.join(root, 'merchants.js'), 'utf8') + fs.readFileSync(path.join(root, 'reports.js'), 'utf8') + '; PennyReports');
const settings = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const iso = date => {if(!date.includes('/')) return date; const [day,month,shortYear]=date.split('/');const year=shortYear.length===2 ? String((+shortYear<=68?2000:1900)+Number(shortYear)) : shortYear;return `${year}-${month}-${day}`;};
const rows = settings.transactions.map(r => ({...r, payee:r.desc, account:r.card, date:iso(r.date)}));
const months = [...new Set(rows.map(r => r.date.slice(0,7)))].map(month => {
 const t = reports.monthly(rows.filter(r => r.date.startsWith(month)), settings);
 return {month,actual:String(t.actual),variable:String(t.variable),fixed:String(t.fixed),special:String(t.special),forecast:String(t.legacyForecast),remaining:String(t.actualRemaining)};
});
const merchants = rows.map(r => ({payee:r.payee, brand:reports.merchant(r.payee,settings),exact:reports.merchant(r.payee,settings,false)}));
fs.writeFileSync(process.argv[3], JSON.stringify({months,merchants}), {mode:0o600});

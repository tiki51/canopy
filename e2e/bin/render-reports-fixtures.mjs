// Renders e2e/fixtures/reports-option-{a,b,c}.png, the three design mockups
// @designer posts in the reports seed's Feature build run (site captures).
// Run from e2e/: node bin/render-reports-fixtures.mjs
import { chromium } from "@playwright/test";

const css = `
body{margin:0;font:13px -apple-system,Segoe UI,Helvetica,Arial,sans-serif;background:#eef0f3;color:#1f2933}
.label{display:flex;justify-content:space-between;align-items:center;padding:10px 16px;background:#fff;border-bottom:1px solid #dde2e8;font-size:12px;color:#5b6b7b}
.label b{color:#1f2933;font-size:13px}
.app{margin:14px 16px;background:#fff;border:1px solid #dde2e8;border-radius:8px;overflow:hidden}
.top{display:flex;align-items:center;gap:10px;padding:12px 16px;border-bottom:1px solid #e6eaef}
.top h1{font-size:15px;margin:0;flex:1}
.crumb{color:#8593a3;font-size:12px}
.bar{display:flex;align-items:center;gap:8px;padding:8px 16px;border-bottom:1px solid #eef1f4;background:#fafbfc}
.chip{border:1px solid #d5dbe2;border-radius:6px;padding:3px 8px;font-size:12px;color:#3d4c5c;background:#fff}
.sp{flex:1}
.btn{border:1px solid #c9d1da;border-radius:6px;padding:4px 10px;font-size:12px;background:#fff;color:#1f2933}
.pri{background:#2f6fed;border-color:#2f6fed;color:#fff}
.hl{outline:2px dashed #2f6fed;outline-offset:3px}
table{border-collapse:collapse;width:100%}
th,td{padding:7px 16px;text-align:left;border-bottom:1px solid #eef1f4;font-variant-numeric:tabular-nums}
th{font-size:11px;text-transform:uppercase;letter-spacing:.04em;color:#6b7a8a;font-weight:600}
td.n{text-align:right}th.n{text-align:right}
.menu{position:absolute;right:16px;top:34px;width:210px;background:#fff;border:1px solid #d5dbe2;border-radius:8px;box-shadow:0 8px 24px rgba(15,23,42,.12);padding:4px;z-index:2}
.menu div{padding:6px 10px;border-radius:5px;font-size:12px}
.menu div.on{background:#eef3fe;color:#1d4fc4}
.menu small{display:block;color:#8593a3;font-size:11px}
.rel{position:relative}
.note{margin:0 16px 14px;font-size:12px;color:#5b6b7b}
.modal{position:absolute;inset:0;background:rgba(15,23,42,.28);display:flex;align-items:center;justify-content:center}
.dlg{width:300px;background:#fff;border-radius:10px;box-shadow:0 12px 32px rgba(15,23,42,.2);padding:14px 16px}
.dlg h2{font-size:14px;margin:0 0 8px}.dlg label{display:flex;gap:6px;align-items:center;font-size:12px;padding:2px 0}
.dlg .row{display:flex;justify-content:flex-end;gap:6px;margin-top:10px}
`;

const rows = [
  ["Week 38", "North America", "1,284", "912", "71%"],
  ["Week 38", "Europe", "1,046", "701", "67%"],
  ["Week 38", "Asia Pacific", "688", "433", "63%"],
  ["Week 37", "North America", "1,197", "850", "71%"],
  ["Week 37", "Europe", "983", "649", "66%"],
];
const table = `<table><tr><th>Week</th><th>Region</th><th class="n">Signups</th><th class="n">Activated</th><th class="n">Rate</th></tr>
${rows.map((r) => `<tr><td>${r[0]}</td><td>${r[1]}</td><td class="n">${r[2]}</td><td class="n">${r[3]}</td><td class="n">${r[4]}</td></tr>`).join("")}</table>`;

const header = (extra = "") =>
  `<div class="top"><span class="crumb">Reports /</span><h1>Weekly signups</h1>${extra}</div>`;
const toolbar = (extra = "") =>
  `<div class="bar"><span class="chip">Last 4 weeks ▾</span><span class="chip">All regions ▾</span><span class="sp"></span>${extra}</div>`;

const options = {
  a: {
    title: "Option A · Export button in the page header",
    note: "One click, exports exactly what the table shows.",
    body: `${header('<span class="btn pri hl">Export CSV</span>')}${toolbar()}${table}`,
  },
  b: {
    title: "Option B · Export menu in the table toolbar",
    note: "Lives with the filters it respects; room for more formats later.",
    body: `${header()}<div class="rel">${toolbar('<span class="btn hl">Export ▾</span>')}<div class="menu"><div class="on">CSV, current view<small>Filters and sort as shown</small></div><div>CSV, all rows<small>Ignores the filters</small></div></div>${table}</div>`,
  },
  c: {
    title: "Option C · Export dialog with a column picker",
    note: "Most control, one extra step for everyone.",
    body: `<div class="rel">${header('<span class="btn hl">Export…</span>')}${toolbar()}${table}<div class="modal"><div class="dlg"><h2>Export Weekly signups</h2><label>☑ Week</label><label>☑ Region</label><label>☑ Signups</label><label>☑ Activated</label><label>☐ Rate</label><div class="row"><span class="btn">Cancel</span><span class="btn pri">Download CSV</span></div></div></div></div>`,
  },
};

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 640, height: 352 }, deviceScaleFactor: 2 });
for (const [key, o] of Object.entries(options)) {
  await page.setContent(
    `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style></head><body><div class="label"><b>${o.title}</b><span>Reports · CSV export</span></div><div class="app">${o.body}</div><p class="note">${o.note}</p></body></html>`,
  );
  const path = `fixtures/reports-option-${key}.png`;
  await page.screenshot({ path, fullPage: true });
  console.log("wrote", path);
}
await browser.close();

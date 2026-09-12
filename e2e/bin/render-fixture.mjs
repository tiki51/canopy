// Renders e2e/fixtures/retry-log.png, the screenshot Priya attaches in the Acme seed.
// Run from e2e/: node bin/render-fixture.mjs fixtures/retry-log.png
import { chromium } from "@playwright/test";
const html = `<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;font:13px -apple-system,Segoe UI,Helvetica,Arial,sans-serif;background:#f4f5f7;color:#1f2933}
.top{background:#1b2a41;color:#fff;padding:10px 18px;display:flex;justify-content:space-between;align-items:center}
.top b{font-size:14px}.top span{opacity:.75;font-size:12px}
.wrap{padding:16px 18px}h1{font-size:16px;margin:0 0 4px}.sub{color:#5b6b7b;margin:0 0 12px;font-size:12px}
table{border-collapse:collapse;width:100%;background:#fff;border:1px solid #d9dee4;border-radius:6px;overflow:hidden}
th,td{padding:7px 10px;text-align:left;border-bottom:1px solid #e6eaef;font-variant-numeric:tabular-nums}
th{background:#eef1f4;font-weight:600;font-size:12px;color:#3d4c5c}
.bad{background:#fff1f0}.tag{display:inline-block;padding:1px 6px;border-radius:9px;font-size:11px}
.fail{background:#fde2e1;color:#a4262c}.ok{background:#dff5e3;color:#1e6b34}.dup{background:#fff0c2;color:#7a5a00}
.note{margin-top:10px;padding:8px 10px;background:#fff7d6;border:1px solid #f1d27a;border-radius:6px;font-size:12px}
</style></head><body>
<div class="top"><b>Acme Billing · Admin</b><span>retry log · inv_88213 · support ticket #4821</span></div>
<div class="wrap"><h1>Charge attempts for invoice inv_88213</h1><p class="sub">Customer: Northwind Traders · Amount: $1,240.00 · Filter: last 24h</p>
<table><tr><th>Time</th><th>Source</th><th>Gateway call</th><th>Result</th><th>Charge id</th></tr>
<tr><td>09:14:02</td><td>checkout</td><td>charge</td><td><span class="tag fail">failed · timeout</span></td><td>—</td></tr>
<tr><td>09:15:00</td><td>retry_worker</td><td>charge</td><td><span class="tag ok">succeeded</span></td><td>ch_9f3a…</td></tr>
<tr class="bad"><td>09:15:03</td><td>webhook payment_failed</td><td>charge</td><td><span class="tag dup">succeeded · DUPLICATE</span></td><td>ch_9f3b…</td></tr>
<tr><td>09:15:04</td><td>webhook payment_succeeded</td><td>mark_paid</td><td><span class="tag ok">ok</span></td><td>—</td></tr>
</table>
<div class="note">Two successful charges three seconds apart. Both callers saw status = open before either mark_paid ran.</div></div>
</body></html>`;
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 760, height: 330 }, deviceScaleFactor: 2 });
await page.setContent(html);
await page.screenshot({ path: process.argv[2] });
await browser.close();
console.log("wrote", process.argv[2]);

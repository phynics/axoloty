// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { chromium } from 'playwright';

const baseUrl = process.argv[2];
if (!baseUrl) {
  console.error('Usage: node docs-smoke-check.mjs <base-url>');
  process.exit(1);
}

const base = baseUrl.endsWith('/') ? baseUrl : baseUrl + '/';
const notFoundRegex = /page you['’]re looking for can['’]t be found/i;

const browser = await chromium.launch();
let failed = false;

async function checkRoute(name, url, expectRedirect) {
  const page = await browser.newPage();
  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {});
    await page.waitForFunction(
      () => document.body?.textContent && document.body.textContent.length > 50,
      { timeout: 10000 }
    ).catch(() => {});

    const body = (await page.textContent('body')) ?? '';
    const finalUrl = page.url();

    if (notFoundRegex.test(body)) {
      console.error(`FAIL: ${name} (${url}) rendered the Not Found view.`);
      failed = true;
      return;
    }
    if (expectRedirect && !finalUrl.includes('documentation/axoloty/')) {
      console.error(`FAIL: ${name} (${url}) did not redirect to documentation. Final URL: ${finalUrl}`);
      failed = true;
      return;
    }
    if (body.trim().length === 0) {
      console.error(`FAIL: ${name} (${url}) rendered an empty page.`);
      failed = true;
      return;
    }
    console.log(`OK: ${name} (${url}) -> ${finalUrl}`);
  } catch (err) {
    console.error(`FAIL: ${name} (${url}) errored: ${err.message}`);
    failed = true;
  } finally {
    await page.close();
  }
}

await checkRoute('root', base, true);
await checkRoute('canonical', base + 'documentation/axoloty/', false);

await browser.close();
process.exit(failed ? 1 : 0);

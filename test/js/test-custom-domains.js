'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const scriptPath = path.resolve(
  __dirname,
  '../../web/js/vx-custom-domains.js'
);
const customDomains = require(scriptPath);
const browserSource = fs.readFileSync(scriptPath, 'utf8');

assert.deepEqual(
  Object.keys(customDomains).sort(),
  [
    'isValidDomain',
    'normalizeDomain',
    'serializeDomains',
    'validateDomains',
  ]
);

assert.equal(customDomains.normalizeDomain('  Example.COM...  '), 'example.com');
assert.equal(customDomains.normalizeDomain(''), '');
assert.equal(customDomains.normalizeDomain(null), '');
assert.equal(customDomains.isValidDomain('castlesoncommand.com.au'), true);
assert.equal(customDomains.isValidDomain('www.castlesoncommand.com.au'), true);
assert.equal(customDomains.isValidDomain('xn--bcher-kva.example'), true);

for (const invalid of [
  'localhost',
  'https://example.com',
  'example.com/path',
  'example.com:443',
  '192.0.2.10',
  '*.example.com',
  '_service.example.com',
  '.example.com',
  'example..com',
  '-edge.example.com',
  'edge-.example.com',
  'café.example',
  `${'a'.repeat(64)}.example.com`,
  `${'a'.repeat(250)}.com`,
]) {
  assert.equal(
    customDomains.isValidDomain(invalid),
    false,
    `invalid domain was accepted: ${invalid}`
  );
}

assert.equal(
  customDomains.serializeDomains([
    ' Example.COM. ',
    '',
    'WWW.EXAMPLE.COM...',
  ]),
  'example.com\nwww.example.com'
);
assert.deepEqual(
  customDomains.validateDomains([''], '', 199),
  { valid: true, index: -1, reason: '', values: [''] }
);
assert.deepEqual(
  customDomains.validateDomains(['example.com', ''], '', 199),
  {
    valid: false,
    index: 1,
    reason: 'empty',
    values: ['example.com', ''],
  }
);
assert.deepEqual(
  customDomains.validateDomains(['example.com', 'EXAMPLE.COM.'], '', 199),
  {
    valid: false,
    index: 1,
    reason: 'duplicate',
    values: ['example.com', 'example.com'],
  }
);
assert.deepEqual(
  customDomains.validateDomains(
    ['primary.example.com'],
    'PRIMARY.EXAMPLE.COM.',
    199
  ),
  {
    valid: false,
    index: 0,
    reason: 'primary',
    values: ['primary.example.com'],
  }
);
assert.deepEqual(
  customDomains.validateDomains(['https://example.com'], '', 199),
  {
    valid: false,
    index: 0,
    reason: 'invalid',
    values: ['https://example.com'],
  }
);

const tooMany = Array.from(
  { length: 200 },
  (_, index) => `site-${index}.example.com`
);
const limitResult = customDomains.validateDomains(tooMany, '', 199);
assert.equal(limitResult.valid, false);
assert.equal(limitResult.index, 199);
assert.equal(limitResult.reason, 'limit');
assert.deepEqual(limitResult.values, tooMany);

async function runBrowserBehavior() {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.setContent(`
      <!doctype html>
      <html>
        <body>
          <form id="web-form">
            <div data-vx-custom-domains
                 data-primary-domain="s-0123456789.managed.example"
                 data-max-domains="199"
                 data-invalid-message="invalid domain"
                 data-duplicate-message="duplicate domain"
                 data-empty-message="empty domain"
                 data-primary-message="primary domain"
                 data-limit-message="too many domains">
              <div data-vx-custom-domain-rows>
                <div data-vx-custom-domain-row>
                  <input type="text"
                         data-vx-custom-domain-input
                         value="example.com">
                  <button type="button"
                          data-vx-custom-domain-remove>remove</button>
                  <button type="button"
                          data-vx-custom-domain-add>add</button>
                </div>
              </div>
              <div data-vx-custom-domain-error></div>
              <textarea name="v_aliases">example.com</textarea>
            </div>
          </form>
          <script>${browserSource}</script>
        </body>
      </html>
    `);

    const rows = page.locator('[data-vx-custom-domain-row]');
    const inputs = page.locator('[data-vx-custom-domain-input]');
    const canonical = page.locator('textarea[name="v_aliases"]');
    const firstAdd = page.locator('[data-vx-custom-domain-add]').first();
    const firstRemove = page.locator('[data-vx-custom-domain-remove]').first();

    assert.equal(await rows.count(), 1);
    assert.equal(await canonical.inputValue(), 'example.com');
    assert.equal(await firstAdd.isVisible(), true);
    assert.equal(await firstRemove.isVisible(), true);

    await firstAdd.click();
    assert.equal(await rows.count(), 2);
    assert.equal(
      await inputs.nth(1).evaluate(
        (element) => element.ownerDocument.activeElement === element
      ),
      true
    );
    assert.equal(await firstAdd.isVisible(), false);
    assert.equal(
      await page.locator('[data-vx-custom-domain-add]').nth(1).isVisible(),
      true
    );
    assert.equal(await firstRemove.isVisible(), true);

    await inputs.nth(1).fill(' API.Example.COM... ');
    assert.equal(
      await canonical.inputValue(),
      'example.com\napi.example.com'
    );
    await inputs.nth(1).blur();
    assert.equal(await inputs.nth(1).inputValue(), 'api.example.com');

    await inputs.nth(1).fill('EXAMPLE.COM.');
    assert.equal(await inputs.nth(1).getAttribute('aria-invalid'), 'true');
    assert.equal(
      await page.locator('[data-vx-custom-domain-error]').textContent(),
      'duplicate domain'
    );
    assert.equal(
      await page.locator('[data-vx-custom-domain-error]').evaluate(
        (element) => element.classList.contains('is-visible')
      ),
      true
    );
    assert.equal(
      await page.locator('#web-form').evaluate((form) => form.dispatchEvent(
        new Event('submit', { bubbles: true, cancelable: true })
      )),
      false,
      'duplicate domains did not prevent submission'
    );

    await inputs.nth(1).fill('second.example.com');
    assert.equal(await inputs.nth(1).getAttribute('aria-invalid'), null);
    assert.equal(
      await page.locator('#web-form').evaluate((form) => form.dispatchEvent(
        new Event('submit', { bubbles: true, cancelable: true })
      )),
      true,
      'valid domains prevented submission'
    );
    assert.equal(
      await canonical.inputValue(),
      'example.com\nsecond.example.com'
    );

    await page.locator('[data-vx-custom-domain-remove]').nth(1).click();
    assert.equal(await rows.count(), 1);
    assert.equal(await canonical.inputValue(), 'example.com');
    assert.equal(await firstRemove.isVisible(), true);
    assert.equal(await firstAdd.isVisible(), true);

    await firstRemove.click();
    assert.equal(await rows.count(), 1);
    assert.equal(await inputs.first().inputValue(), '');
    assert.equal(await canonical.inputValue(), '');
    assert.equal(await firstRemove.isVisible(), false);
    assert.equal(await firstAdd.isVisible(), true);

    await inputs.first().fill('https://example.com');
    assert.equal(await inputs.first().getAttribute('aria-invalid'), 'true');
    assert.equal(
      await page.locator('#web-form').evaluate((form) => form.dispatchEvent(
        new Event('submit', { bubbles: true, cancelable: true })
      )),
      false,
      'invalid domains did not prevent submission'
    );
  } finally {
    await browser.close();
  }
}

runBrowserBehavior()
  .then(() => {
    console.log('Custom-domain JavaScript tests passed.');
  })
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });

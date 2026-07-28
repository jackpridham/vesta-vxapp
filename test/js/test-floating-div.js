const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function loadWatcher() {
  const values = new Map();
  const shown = new Set();
  let ajaxOptions;
  const jquery = (selector) => ({
    fadeIn() { return this; },
    fadeOut() { return this; },
    focus() { return this; },
    hide() { return this; },
    html() { return this; },
    on() { return this; },
    prop() { return 0; },
    scrollTop() { return this; },
    serializeArray() { return []; },
    show() { shown.add(selector); return this; },
    val(value) {
      if (arguments.length === 0) return values.get(selector);
      values.set(selector, value);
      return this;
    },
    css() { return this; },
  });
  jquery.ajax = (options) => {
    ajaxOptions = options;
  };

  const context = {
    Array,
    console: { log() {} },
    document: { addEventListener() {} },
    GLOBAL: { TOKEN: 'test-token' },
    JSON,
    Number,
    setInterval() { return 42; },
    clearInterval() {},
    $: jquery,
  };
  vm.createContext(context);
  vm.runInContext(
    fs.readFileSync(path.resolve(__dirname, '../../web/js/floating-div.js'), 'utf8'),
    context
  );
  return {
    context,
    getAjaxOptions: () => ajaxOptions,
    shown,
    values,
  };
}

{
  const harness = loadWatcher();
  harness.context.startWatchingSpawnedAjaxProcess('owner', 'hash', '#page-output');
  harness.context.run_ajax_call_for_spawned_ajax_process('owner', 'hash', '#page-output');
  harness.getAjaxOptions().success('<html>login</html>');

  assert.equal(
    harness.values.get('#page-output'),
    'Unable to read spawned process output.'
  );
  assert.equal(harness.context.myvesta_interval_id, null);
  assert.equal(harness.shown.has('#close-floating-div-button'), true);
}

{
  const harness = loadWatcher();
  harness.context.startWatchingSpawnedAjaxProcess('owner', 'hash', '#page-output');
  harness.context.run_ajax_call_for_spawned_ajax_process('owner', 'hash', '#page-output');
  harness.getAjaxOptions().success(JSON.stringify({
    code: 1,
    exit_code: 9,
    output: 'operation failed',
  }));

  assert.equal(harness.values.get('#page-output'), 'operation failed');
  assert.equal(harness.values.has('#confirm-div-content-textarea-variable'), false);
  assert.equal(harness.context.myvesta_interval_id, null);
}

console.log('floating-div watcher tests passed');

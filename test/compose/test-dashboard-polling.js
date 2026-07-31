'use strict';

const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(
  require('path').join(__dirname, '../../web/js/pages/list_docker.js'),
  'utf8'
);

function nodeStub() {
  return {
    length: 0,
    abort() {},
    attr() { return this; },
    data() { return ''; },
    each() { return this; },
    empty() { return this; },
    find() { return this; },
    hide() { return this; },
    on() { return this; },
    text() { return this; },
    toggle() { return this; },
    append() { return this; },
    closest() { return this; },
  };
}

function jqueryStub(value) {
  if (typeof value === 'function') {
    value();
  }
  return nodeStub();
}
jqueryStub.each = function(collection, callback) {
  Object.keys(collection || {}).forEach((key) => callback(key, collection[key]));
};

const context = {
  Date,
  Number,
  console,
  document: { createTextNode: () => ({}) },
  window: {
    DOCKER_LIST: {
      dockerAvailable: false,
      containers: [],
      pollIntervalMs: 60000,
    },
    setInterval() {},
  },
  jQuery: jqueryStub,
};
vm.runInNewContext(source, context, { filename: 'list_docker.js' });

const polling = context.window.VX_DOCKER_POLLING_TEST;
assert(polling, 'polling test contract was not exported');
assert.strictEqual(polling.formatCpu(1.234), '1.2%');
assert.strictEqual(polling.formatCapacityMiB(512), '512.0 MiB');
assert.strictEqual(polling.formatCapacityMiB(2048), '2.0 GiB');
assert.strictEqual(polling.formatNetwork(1.234), '1.23 MiB/s');
assert.match(
  polling.formatTimestamp(new Date(Date.now() - 5000).toISOString()),
  /\(5s ago\)$/
);

assert.match(source, /safePostJson\(config\.statsUrl/);
assert.match(source, /safePostJson\(config\.healthUrl/);
assert.match(source, /\$\.when\(statsRequest, healthRequest\)/);
assert.match(source, /generation !== pollGeneration/);
assert.match(source, /beforeunload pagehide/);
assert.match(source, /request\.abort\(\)/);
assert.match(source, /timeout: config\.requestTimeoutMs \|\| 10000/);
assert.match(source, /metric \|\| emptyMetric\(\)/);
assert.match(source, /health \|\| unavailableHealth\(\)/);

console.log('Compose dashboard polling tests passed.');

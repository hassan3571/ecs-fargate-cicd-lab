const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');

let server;
let baseUrl;

before(() => new Promise((resolve) => {
  const app = createApp({
    APP_ENV: 'test',
    APP_VERSION: 'abc123',
    APP_MESSAGE: 'hello test',
    API_SECRET: 'super-secret-value',
  });
  server = app.listen(0, () => {
    baseUrl = `http://127.0.0.1:${server.address().port}`;
    resolve();
  });
}));

after(() => new Promise((resolve) => server.close(resolve)));

test('GET /api/health returns ok', async () => {
  const res = await fetch(`${baseUrl}/api/health`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { status: 'ok' });
});

test('GET /api/info returns version and configuration', async () => {
  const res = await fetch(`${baseUrl}/api/info`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.environment, 'test');
  assert.equal(body.version, 'abc123');
  assert.equal(body.message, 'hello test');
  assert.equal(body.secretConfigured, true);
});

test('GET /api/info never exposes the secret value', async () => {
  const text = await (await fetch(`${baseUrl}/api/info`)).text();
  assert.ok(!text.includes('super-secret-value'));
});

test('unknown routes return 404', async () => {
  const res = await fetch(`${baseUrl}/api/does-not-exist`);
  assert.equal(res.status, 404);
});

test('X-Powered-By header is disabled', async () => {
  const res = await fetch(`${baseUrl}/api/health`);
  assert.equal(res.headers.get('x-powered-by'), null);
});

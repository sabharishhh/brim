import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import worker, { FeedbackInbox, readReport } from './worker.mjs';

const report = () => ({ id: randomUUID(), kind: 'bug', title: 'A problem', body: '## Bug report\n\nWhat happened.' });
const request = value => new Request('https://feedback.example/v1/feedback', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'Idempotency-Key': value.id, 'CF-Connecting-IP': '192.0.2.1' },
  body: JSON.stringify(value),
});
const internal = value => new Request('https://internal/report', { method: 'POST', body: JSON.stringify(value) });
const issue = value => ({ number: 42, html_url: 'https://github.com/sabharishhh/brim/issues/42', body: value.body });

function context(storage = new Map()) {
  let sequence = Promise.resolve();
  return {
    values: storage,
    storage: {
      async get(key) { return storage.get(key); },
      async put(key, value) { storage.set(key, value); },
      async delete(key) { storage.delete(key); },
    },
    blockConcurrencyWhile(action) {
      const result = sequence.then(action);
      sequence = result.catch(() => {});
      return result;
    },
  };
}

function environment(fetcher) {
  const objects = new Map();
  const env = {
    GITHUB_TOKEN: 'server-only-test-token',
    REPORT_LIMITER: { async limit() { return { success: true }; } },
    REPORTS: {
      idFromName(name) { return name; },
      get(name) {
        if (!objects.has(name)) objects.set(name, new FeedbackInbox(context(), env, fetcher));
        return objects.get(name);
      },
    },
  };
  return env;
}

test('validates the report type and matching idempotency key', async () => {
  const value = report();
  assert.deepEqual(await readReport(request(value)), value);
  const bad = request(value);
  bad.headers.set('Idempotency-Key', randomUUID());
  await assert.rejects(readReport(bad));
  await assert.rejects(readReport(request({ ...value, kind: 'unrecognized' })));
  await assert.rejects(readReport(request({ ...value, title: ' ' })));
});

test('rejects a streamed payload beyond the size cap', async () => {
  const value = report();
  await assert.rejects(readReport(request({ ...value, body: 'x'.repeat(48_001) })));
});

test('fails closed if deployment credentials or bindings are missing', async () => {
  assert.equal((await worker.fetch(request(report()), {})).status, 503);
});

test('honors the per-address rate limit before calling GitHub', async () => {
  const env = environment(() => assert.fail('GitHub must not be called'));
  env.REPORT_LIMITER.limit = async () => ({ success: false });
  const response = await worker.fetch(request(report()), env);
  assert.equal(response.status, 429);
  assert.equal(response.headers.get('Retry-After'), '60');
});

test('concurrent retries create one issue and return the same receipt', async () => {
  let posts = 0;
  const env = environment(async (url, options) => {
    assert.equal(url, 'https://api.github.com/repos/sabharishhh/brim/issues');
    assert.equal(options.headers.Authorization, 'Bearer server-only-test-token');
    assert.equal(options.redirect, 'error');
    posts++;
    const value = JSON.parse(options.body);
    return Response.json(issue(value), { status: 201 });
  });
  const value = report();
  const results = await Promise.all([worker.fetch(request(value), env), worker.fetch(request(value), env)]);
  assert.equal(posts, 1);
  assert.deepEqual(await results[0].json(), await results[1].json());
});

test('a changed payload cannot reuse another reports id', async () => {
  let posts = 0;
  const env = environment(async (_, options) => {
    posts++;
    return Response.json(issue(JSON.parse(options.body)), { status: 201 });
  });
  const value = report();
  assert.equal((await worker.fetch(request(value), env)).status, 201);
  assert.equal((await worker.fetch(request({ ...value, body: 'Different text' }), env)).status, 409);
  assert.equal(posts, 1);
});

test('a lost GitHub response recovers the issue after object restart without posting again', async () => {
  const ctx = context();
  let posts = 0;
  let savedIssue;
  const fetcher = async (_, options) => {
    if (options.method === 'POST') {
      posts++;
      savedIssue = issue(JSON.parse(options.body));
      throw new Error('Response lost after GitHub created the issue');
    }
    return Response.json([savedIssue]);
  };
  const env = environment(fetcher);
  const value = report();
  assert.equal((await new FeedbackInbox(ctx, env, fetcher).fetch(internal(value))).status, 503);
  const restarted = new FeedbackInbox(context(ctx.values), env, fetcher);
  const response = await restarted.fetch(internal(value));
  assert.equal(response.status, 200);
  assert.equal((await response.json()).number, 42);
  assert.equal(posts, 1);
  assert.equal(JSON.stringify(ctx.values.get('report')).includes(value.body), false);
});

test('an unconfirmed request is never blindly posted a second time', async () => {
  let posts = 0;
  const env = environment(async (_, options) => {
    if (options.method === 'POST') { posts++; throw new Error('Timeout'); }
    return Response.json([]);
  });
  const value = report();
  assert.equal((await worker.fetch(request(value), env)).status, 503);
  assert.equal((await worker.fetch(request(value), env)).status, 503);
  assert.equal(posts, 1);
});

test('a global daily cap bounds anonymous issue creation', async () => {
  const budget = new FeedbackInbox(context(), {}, () => assert.fail('Budget does not call GitHub'));
  const admit = () => budget.fetch(new Request('https://internal/budget', { method: 'POST' }));
  for (let count = 0; count < 100; count++) assert.equal((await admit()).status, 200);
  assert.equal((await admit()).status, 429);
});

test('a receipt for a different repository is never returned as success', async () => {
  const env = environment(async () => Response.json({ number: 42, html_url: 'https://github.com/other/repo/issues/42' },
    { status: 201 }));
  assert.equal((await worker.fetch(request(report()), env)).status, 503);
});

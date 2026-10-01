const repository = 'sabharishhh/brim';
const api = `https://api.github.com/repos/${repository}/issues`;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const maximumBytes = 48_000;
const segmenter = new Intl.Segmenter('en', { granularity: 'grapheme' });
const characterCount = text => Array.from(segmenter.segment(text)).length;

function reply(status, value) {
  return Response.json(value, {
    status,
    headers: { 'Cache-Control': 'no-store', ...(status === 429 ? { 'Retry-After': '60' } : {}) },
  });
}

export async function readReport(request) {
  if (request.headers.get('Content-Type')?.split(';')[0].trim() !== 'application/json') {
    throw new Error('content-type');
  }
  const reader = request.body?.getReader();
  if (!reader) throw new Error('empty');
  const chunks = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maximumBytes) {
      await reader.cancel();
      throw new Error('size');
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  const report = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  if (!report || !uuid.test(report.id) ||
      request.headers.get('Idempotency-Key')?.toLowerCase() !== report.id.toLowerCase() ||
      !['bug', 'feature', 'general'].includes(report.kind) ||
      typeof report.title !== 'string' || !report.title.trim() || characterCount(report.title) > 120 ||
      typeof report.body !== 'string' || !report.body.trim() || characterCount(report.body) > 14_000) {
    throw new Error('invalid');
  }
  return { id: report.id.toLowerCase(), kind: report.kind, title: report.title.trim(), body: report.body };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== '/v1/feedback') return reply(404, { error: 'Not found' });
    if (request.method !== 'POST') return reply(405, { error: 'POST required' });
    // A release can ship the browser flow before the service is deployed.
    if (!env.GITHUB_TOKEN || !env.REPORTS || !env.REPORT_LIMITER) {
      return reply(503, { error: 'Reporting is not configured' });
    }
    let report;
    try { report = await readReport(request); }
    catch { return reply(400, { error: 'Invalid report' }); }
    const ip = request.headers.get('CF-Connecting-IP');
    if (!ip) return reply(400, { error: 'Client address unavailable' });
    const { success } = await env.REPORT_LIMITER.limit({ key: ip });
    if (!success) return reply(429, { error: 'Please wait before sending another report' });
    const inbox = env.REPORTS.get(env.REPORTS.idFromName(`report:${report.id}`));
    return inbox.fetch(new Request('https://internal/report', {
      method: 'POST', body: JSON.stringify(report),
    }));
  },
};

/// A Durable Object serializes each report's attempts. Store the intent before
/// contacting GitHub: a lost response must not cause a second issue on retry.
export class FeedbackInbox {
  constructor(ctx, env, fetcher = fetch) {
    this.ctx = ctx;
    this.env = env;
    // Workerd requires the native fetch function to keep its global receiver.
    this.fetcher = fetcher.bind(globalThis);
  }

  fetch(request) {
    return this.ctx.blockConcurrencyWhile(async () => {
      if (new URL(request.url).pathname === '/budget') return this.admit();
      const report = await request.json();
      const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(report)));
      const hash = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
      const stored = await this.ctx.storage.get('report');
      if (stored) {
        if (stored.hash !== hash) return reply(409, { error: 'This report ID belongs to different text' });
        if (stored.receipt) return reply(200, stored.receipt);
        // GitHub's creation endpoint has no idempotency key. After an ambiguous
        // failure, look for our marker and never blindly POST a second time.
        return this.recover(report, hash);
      }
      const budget = this.env.REPORTS.get(this.env.REPORTS.idFromName('global-budget'));
      const admission = await budget.fetch(new Request('https://internal/budget', { method: 'POST' }));
      if (admission.status !== 200) return admission;
      await this.ctx.storage.put('report', { hash });
      const marker = `<!-- brim-feedback:${report.id} -->`;
      let response;
      try {
        response = await this.github(api, {
          method: 'POST', body: JSON.stringify({ title: report.title, body: `${report.body}\n\n${marker}` }),
        });
      } catch { return reply(503, { error: 'Submission not yet confirmed; retry the same report' }); }
      if (response.status === 201) {
        try {
          const receipt = this.receipt(report, await response.json());
          await this.ctx.storage.put('report', { hash, receipt });
          return reply(201, receipt);
        } catch { return reply(503, { error: 'Submission not yet confirmed' }); }
      }
      // A validation/auth rejection is definitive. Retrying after fixing the
      // service may create this report. 5xx and timeouts stay ambiguous.
      if ([400, 401, 403, 404, 410, 422].includes(response.status)) {
        await this.ctx.storage.delete('report');
      }
      return reply(response.status === 429 ? 429 : 503, { error: 'GitHub did not confirm the report' });
    });
  }

  async admit() {
    // A shared cap also bounds abuse across addresses and Cloudflare regions.
    const day = Math.floor(Date.now() / 86_400_000);
    const budget = await this.ctx.storage.get('budget');
    const count = budget?.day === day ? budget.count : 0;
    if (count >= 100) return reply(429, { error: 'Daily reporting limit reached' });
    await this.ctx.storage.put('budget', { day, count: count + 1 });
    return reply(200, { accepted: true });
  }

  async recover(report, hash) {
    try {
      // Three pages cover more than two days at the global cap. If absent,
      // leave it unconfirmed rather than risking a duplicate or lying.
      for (let page = 1; page <= 3; page++) {
        const response = await this.github(`${api}?state=all&sort=created&direction=desc&per_page=100&page=${page}`);
        if (!response.ok) break;
        const issues = await response.json();
        if (!Array.isArray(issues)) break;
        const found = issues.find(issue => !issue.pull_request &&
          issue.body?.includes(`<!-- brim-feedback:${report.id} -->`));
        if (found) {
          const receipt = this.receipt(report, found);
          await this.ctx.storage.put('report', { hash, receipt });
          return reply(200, receipt);
        }
        if (issues.length < 100) break;
      }
    } catch { /* Keep the unconfirmed intent for a later, safe retry. */ }
    return reply(503, { error: 'Submission not yet confirmed; retry the same report' });
  }

  receipt(report, issue) {
    if (!Number.isSafeInteger(issue.number) || issue.number <= 0 ||
        issue.html_url !== `https://github.com/${repository}/issues/${issue.number}`) {
      throw new Error('Invalid GitHub receipt');
    }
    return { id: report.id, number: issue.number, url: issue.html_url };
  }

  github(url, options = {}) {
    return this.fetcher(url, {
      ...options, redirect: 'manual', signal: AbortSignal.timeout(5_000),
      headers: {
        Authorization: `Bearer ${this.env.GITHUB_TOKEN}`,
        Accept: 'application/vnd.github+json',
        'Content-Type': 'application/json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Brim-Feedback',
      },
    });
  }
}

# Feedback relay

A small Cloudflare Worker that turns reports sent from Brim's Settings into
issues on `sabharishhh/brim`. It holds the GitHub token, so the app never
does.

Brim's builds send to `https://brim-feedback.brim-app.workers.dev/v1/feedback`.
A build with `BRIM_FEEDBACK_ENDPOINT` left empty skips the relay and opens a
prefilled GitHub issue in the browser instead, which needs the person's own
GitHub account. Long reports can be copied into the issue, and screenshots
attached there.

Each report includes Brim's version and build, the macOS version and the
processor type. Logs, file paths and the list of installed apps are never
sent.

## Deploying

1. Install Cloudflare's Wrangler CLI and sign in to your Cloudflare account.
2. Create a fine-grained GitHub token for this repository with read and write
   access to Issues only. From this directory, run
   `npx wrangler secret put GITHUB_TOKEN --config wrangler.jsonc` and paste
   the token when asked. Never put the token in a file, a commit or a build
   setting, and rotate it before it expires.
3. Run `wrangler deploy`. This also creates the Durable Object and the rate
   limiter. A custom domain is optional.
4. Build Brim with `BRIM_FEEDBACK_ENDPOINT=https://YOUR-HOST/v1/feedback`
   and check the key in the built app's `Contents/Info.plist`. A malformed
   endpoint fails visibly and keeps the draft.
5. Send a test report before publishing a release, and check the issue it
   created.

Tests need no dependencies:

```sh
node --test Services/FeedbackRelay/worker.test.mjs
```

## Request format

`POST /v1/feedback` with a JSON body of `{id, kind, title, body}` and an
`Idempotency-Key` header set to the report's UUID. `kind` is `bug`,
`feature` or `general`. A new issue returns 201, a repeat returns 200, both
with `{id, number, url}`. Brim accepts the reply only if the UUID matches and
the URL is an HTTPS issue on its own repository. Too many requests return 429
with `Retry-After`.

## Limits

Payloads are capped at 48 KB, titles at 120 characters and bodies at 14,000
characters. The rate limiter allows three requests per address per minute at
each Cloudflare location, and a Durable Object allows 100 new reports a day
(UTC) across the service. Raise both before a wider release.

## Duplicates and lost replies

GitHub has no idempotency key for creating issues. The relay stores a hash of
each report before posting and handles one attempt at a time. If a reply is
lost, it looks for the report's marker in recent issues. If it cannot find
one, the report stays unconfirmed and is not posted again, so an ambiguous
failure never creates a duplicate. The maintainer may have to check such a
report by hand.

## Privacy

The rate limiter sees IP addresses. The relay does not log report text, and
the Durable Objects keep only hashes and receipts. The report itself becomes
a public issue, so this is not a channel for anything sensitive. Rotating or
removing the token stops direct sending; builds without the endpoint keep
using the browser flow.

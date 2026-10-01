# Feedback delivery

Brim's Debug and Release builds use the deployed relay at
`https://brim-feedback.brim-app.workers.dev/v1/feedback`.
The GitHub credential remains a Cloudflare secret named `GITHUB_TOKEN`.

A build with an empty `BRIM_FEEDBACK_ENDPOINT` uses GitHub's issue draft URLs. The
user composes in Brim, then creates the issue on GitHub. This needs
the user's GitHub account. Opening a draft never records a sent report.
Long reports can be copied and pasted instead of exceeding URL limits;
screenshots can be attached in GitHub's editor.

For submission entirely inside Brim, this optional Cloudflare Worker keeps
the GitHub credential on the server. There is no credential in the app.
Reports become public issues in `sabharishhh/brim`. Deploying the service
and configuring a release endpoint are required when hosting a separate
installation of the service.

## Activate direct sending

1. Use an existing Cloudflare account and install its official Wrangler CLI.
2. Create a fine-grained GitHub token restricted to this repository, with
   Issues read/write permission. Store it using the exact command
   `npx wrangler secret put GITHUB_TOKEN --config wrangler.jsonc`
   from this directory. Paste the token only when prompted for its value.
   `GITHUB_TOKEN` is the secret name; never use the token itself as a name.
   Do not put the token in a file,
   commit, build setting or application bundle. Rotate it before expiry.
3. Run `wrangler deploy` from this directory. The configuration creates the
   Durable Object and rate limiter. Set a custom domain if desired.
4. Build Brim with
   `BRIM_FEEDBACK_ENDPOINT=https://YOUR-HOST/v1/feedback`.
   Inspect the built bundle's `Contents/Info.plist` to confirm the key.
   Leave the build setting empty to use the browser flow. A malformed configured endpoint
   fails visibly and leaves the draft intact.
5. Test a submission with the maintainer's approval before publishing a
   release. Check the returned issue number and public issue contents.

Run the server logic tests without dependencies:

```sh
node --test Support/FeedbackRelay/worker.test.mjs
```

The endpoint accepts POST JSON `{id, kind, title, body}` and an
`Idempotency-Key` header equal to the report UUID. `kind` is `bug`,
`feature` or `general`. Success is HTTP 201, or 200 for a repeat, with
`{id, number, url}`. Brim accepts only a matching UUID and an HTTPS issue
URL for its own repository. Rate limits return 429 with Retry-After.

The service caps payloads at 48 KB, titles at 120 characters and bodies at
14,000 characters. Cloudflare's limiter allows three requests per address
per minute at each location. A Durable Object caps new attempts at 100
per UTC day across the service. Tune both limits before deploying for a
larger audience. IP addresses are used by the rate limiter; report text is
not logged by this code. Cloudflare still processes normal network data.

GitHub does not offer an idempotency key for creating issues. The service
saves a report hash before making the request and serializes attempts in a
Durable Object. A lost reply is recovered by locating the report's marker
in recent issues. If it cannot be found, the request remains unconfirmed
and is never blindly posted again. This favors avoiding duplicate issues
over guaranteed delivery after an ambiguous failure. The maintainer may
need to resolve an unconfirmed attempt manually.

Keep the Worker token scoped to Issues. Durable Objects retain hashes and
receipts for retry safety; no report body is persisted in those objects.
The public issue itself contains the report. Do not use this channel for
sensitive material. Disabling or rotating the server token stops direct
posting; a release without the endpoint continues to offer GitHub drafts.

## Sources

- [GitHub issue URL parameters](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-an-issue)
- [GitHub issue creation API](https://docs.github.com/en/rest/issues/issues#create-an-issue)
- [Keeping GitHub credentials secure](https://docs.github.com/en/rest/authentication/keeping-your-api-credentials-secure)
- [Cloudflare rate limiting](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
- [Durable Object concurrency](https://developers.cloudflare.com/durable-objects/api/state/)
- [Apple progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)

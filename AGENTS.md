# Public Repository Safety

These instructions apply to the entire repository. This is a public repository: treat every commit,
branch, tag, pull request, issue, Actions input, log, summary, cache, and artifact as public and
potentially permanent. Deleting a later commit does not remove data from Git history or GitHub caches.

## Non-negotiable rules

- Never commit, paste into a tool call, print, or upload real authentication material. This includes
  Zhihu cookies (`z_c0`, `d_c0`, `_xsrf`, and other session cookies), authorization headers, tokens,
  passwords, QR-login payloads, Keychain exports, and authenticated WebKit storage.
- Never commit Apple or device signing material: Apple Account credentials, app-specific passwords,
  two-factor codes, private keys, signing certificates with private keys, provisioning profiles,
  pairing records, Team IDs, device UDIDs, or Keychain exports.
- Never commit GitHub credentials, Actions secrets, cloud credentials, `.env` files, or credentials for
  any future recommendation service.
- Never commit personal account data or raw authenticated API output. This includes profile exports,
  personalized feed responses, searches, reading history, notifications, favorites, drafts, comments,
  analytics events, screenshots, packet captures, and unredacted diagnostic logs.
- Do not place sensitive files inside the repository merely because `.gitignore` covers them. Keep them
  outside the repository and use the system Keychain, interactive login, or local environment variables.
- Do not ask a user to send credentials through chat, an issue, or a pull request. Use an interactive
  provider-owned authentication flow when authentication is required.

Credential field names, endpoint paths, signing algorithms, and clearly synthetic test values are
allowed. A test value must be short, obviously invalid, and unrelated to a real account (for example,
`device-cookie` or `login-cookie`).

## Application data handling

- Store login credentials only in the existing Keychain-backed account store. Do not move them to
  `UserDefaults`, SwiftData, source files, fixtures, or plaintext files.
- Build diagnostics from an allowlist. Safe fields are coarse endpoint templates, query key names (not
  values), status codes, timings, byte counts, item counts, and synthetic identifiers. Never log full
  URLs, query values, headers, bodies, cookies, content text, search terms, or account identifiers.
- Use `Logger` privacy annotations conservatively. Marking a value public is acceptable only after the
  value has been structurally reduced to an allowlisted form.
- Unit tests must use synthetic fixtures. Do not record a live session and then redact it by hand.
- Any new export, debug screen, A/B inspector, or recommendation instrumentation must default to local
  storage, avoid credentials and personal identifiers, and require an explicit review before sharing.
- Preserve the separation between retrieval and ranking without copying raw authenticated responses
  into the repository. Checked-in recommendation samples must be minimal, synthetic DTO fixtures.

## GitHub Actions and distribution

- Keep workflow permissions at the minimum required. Build and test jobs use `contents: read` and must
  not receive repository secrets.
- Never use `pull_request_target` to build or execute pull-request code. Never expose secrets to code
  from forks or other untrusted refs.
- Pin third-party actions to an immutable full commit SHA and set checkout `persist-credentials: false`.
- PR and unsigned-IPA builds must remain unsigned. Do not add Apple certificates, provisioning profiles,
  Apple Account credentials, or signing secrets to CI merely to make an installable build.
- Treat `workflow_dispatch` inputs and their values as public. Do not enter a private Bundle ID, Team ID,
  device identifier, token, or account detail.
- Upload artifacts from explicit allowlisted paths only. Inspect newly added artifact contents, keep
  retention short, and never upload repository-wide directories, home directories, Keychains, WebKit
  data, raw API captures, or environment dumps.
- Do not print environment variables, GitHub contexts, request headers, or shell traces around commands
  that may handle credentials.

## Required change procedure

Before every commit or push:

1. Inspect `git status --short` and preserve unrelated user changes.
2. Stage explicit paths; do not use broad staging when sensitive local files may exist.
3. Run `./scripts/check-public-safety.sh` against the Git index.
4. Inspect `git diff --cached --name-only` and the complete `git diff --cached`.
5. Run relevant tests and `git diff --check`.

Enable the repository hook in each clone with:

```bash
git config core.hooksPath .githooks
```

Do not bypass the hook or weaken the scanner to make a failure disappear. If a false positive is
confirmed, add the narrowest possible documented exception without printing the matched value.

## Suspected exposure

If sensitive data may have reached Git, GitHub, an Actions log, or an artifact:

1. Stop pushing and do not quote the value in a public discussion.
2. Revoke or rotate the credential first; deletion and history rewriting are not revocation.
3. Record only the credential type and affected location, never the value.
4. Remove it from the working tree, all affected history, Actions artifacts/caches, and releases with
   coordinated maintainer approval.
5. Re-run the safety scan and verify the remote state before resuming work.

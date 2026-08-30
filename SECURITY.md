# Security and Privacy Policy

This client handles account sessions and personalized content. A public issue or pull request is not a
safe place for credentials or private account data.

## Reporting a vulnerability or exposure

Use GitHub private vulnerability reporting for this repository when it is available. If it is not
available, open only a fully redacted issue asking the maintainer to establish a private contact method.
Do not include the secret, an authenticated response, a pairing record, or an unredacted screenshot.

If a credential was exposed, revoke or rotate it immediately before waiting for a code fix. Logging out
all affected Zhihu sessions, revoking an affected GitHub token, or revoking an affected Apple signing
credential may be necessary. Removing a file or closing an Actions run does not invalidate a credential.

A useful private report contains:

- the affected component and version or commit;
- the credential/data category, but never the credential value;
- where it appeared (path, commit, log, artifact, or release);
- minimal reproduction steps using synthetic data;
- the exposure window and whether rotation has completed.

## Information that must stay private

- Zhihu cookies, tokens, authorization headers, QR-login payloads, and Keychain contents;
- Apple Account credentials, signing private keys, provisioning profiles, pairing files, Team IDs, and
  device UDIDs;
- GitHub, cloud, or future recommendation-service credentials;
- raw personalized API responses, searches, history, notifications, favorites, drafts, and feedback;
- packet captures, WebKit data, database files, and unredacted application or Actions logs.

Endpoint names and obviously fake fixtures are safe to discuss. When in doubt, redact first and share
the minimum information needed to reproduce the problem.

## Contributor checklist

Before pushing, enable the repository hook once per clone:

```bash
git config core.hooksPath .githooks
```

Then stage only intended files and run:

```bash
./scripts/check-public-safety.sh
git diff --cached --name-only
git diff --cached
```

The automated check catches high-confidence credential formats and forbidden local-data files. It is a
backstop, not proof that content is safe: reviewers must still look for personal data, authenticated API
responses, identifiers, and sensitive values in logs and screenshots.

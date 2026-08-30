## Summary

<!-- Describe the user-visible outcome and the smallest rationale needed to review it. -->

## Verification

<!-- List the exact tests/builds/checks that passed. -->

## Public repository safety

- [ ] I used only synthetic test fixtures; no live account response or personalized feed data is included.
- [ ] This change contains no cookies, tokens, credentials, private keys, pairing/provisioning files,
      device identifiers, or personal account data.
- [ ] New logging uses an allowlist and excludes full URLs, query values, headers, bodies, content,
      search terms, and account identifiers.
- [ ] Workflow changes use least privilege, immutable action SHAs, no `pull_request_target`, and no
      secrets for pull-request code.
- [ ] I inspected every new artifact path and confirmed that no credential or private user data is
      uploaded.
- [ ] `./scripts/check-public-safety.sh` and `git diff --check` pass.

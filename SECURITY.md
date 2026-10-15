# Security Policy

## Supported versions

Only the latest release receives security fixes. Please update before reporting.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through GitHub's **[Report a vulnerability](https://github.com/ixxxxoooo/jietu/security/advisories/new)** form (repository *Security* tab → *Report a vulnerability*). Include:

- the Lucent version and macOS version,
- a description of the issue and its impact,
- steps or a proof of concept to reproduce it.

You can expect an acknowledgement within 7 days. We will keep you informed while we investigate, and credit you in the release notes if you wish once a fix ships.

## Scope and privacy model

Lucent works entirely on your Mac: screenshots, recordings, OCR and history are processed and stored locally, and the app does not upload data. Things we consider in scope:

- reading or writing files outside the folders the user configured (save folder, history directory),
- leaking captured content to other processes or the network,
- abuse of the Screen Recording, Microphone or Accessibility permissions,
- flaws in the release pipeline (signing, DMG contents, workflow secrets).

## Known characteristics

- Releases are signed with a self-signed certificate (no Apple Developer ID, not notarized). macOS Gatekeeper therefore asks you to remove the quarantine flag before the first launch; this is documented in the README. Verify the DMG against the `SHA256SUMS.txt` published with each release.

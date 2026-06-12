# Releasing

How to cut a release of Agentic Sandbox Sentry, and how users verify what they
downloaded. The process is automated by
[.github/workflows/release.yml](../.github/workflows/release.yml).

## Cutting a release (maintainers)

1. Update `CHANGELOG.md` with a new `## vX.Y.Z - YYYY-MM-DD` section at the top.
2. Bump `SENTRY_VERSION` in `sentryctl`.
3. Commit, push, and confirm the test workflow is green on `main`.
4. Tag and push the tag:

```bash
git tag v0.1.4
git push origin v0.1.4
```

The release workflow then:

- runs the full test suite (a failing suite aborts the release),
- builds a source tarball with `git archive` (reproducible from the tag),
- writes `SHA256SUMS` with the tarball checksum,
- attaches **signed build provenance** via GitHub artifact attestation,
- extracts your `CHANGELOG.md` section as the release notes,
- publishes the GitHub Release with the tarball and checksums attached.

## Verifying a download (users)

Download the tarball and `SHA256SUMS` from the release page, then:

```bash
# 1. Checksum: confirms the file is exactly what CI built
shasum -a 256 -c SHA256SUMS        # macOS
sha256sum -c SHA256SUMS            # Linux

# 2. Provenance: confirms it was built by this repo's release workflow
#    on GitHub-hosted infrastructure (requires the GitHub CLI)
gh attestation verify agentic-sandbox-sentry-vX.Y.Z.tar.gz \
  --repo Hellotravisss/agentic-sandbox-sentry
```

If either check fails, do not run the code — re-download from the official
releases page, and if it still fails, report it per [SECURITY.md](../SECURITY.md).

Cloning the repository at a tag is an equally valid installation path:

```bash
git clone --branch vX.Y.Z https://github.com/Hellotravisss/agentic-sandbox-sentry.git
```

## Why provenance instead of GPG

GitHub artifact attestations bind the artifact to the exact workflow run, commit,
and repository that produced it, verified against GitHub's Sigstore instance. That
gives users a stronger guarantee than a maintainer-held GPG key (which can be
copied or lost) without any key management. A GPG signature can be added later if
distribution channels require it.

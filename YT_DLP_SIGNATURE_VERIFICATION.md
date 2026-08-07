# Verifying yt-dlp downloads

## What yt-dlp publishes per release

Every release at [yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp/releases) ships, alongside the executables themselves:

| Asset | What it is |
|-------|-----------|
| `SHA2-256SUMS` | Plain-text file, one line per release asset: `<64 hex chars><sp><sp><filename>`. |
| `SHA2-256SUMS.sig` | Detached OpenPGP signature over `SHA2-256SUMS` (binary `.sig`). |
| `SHA2-512SUMS` | Same as above but SHA-512. |
| `SHA2-512SUMS.sig` | Detached OpenPGP signature over `SHA2-512SUMS`. |

Example `SHA2-256SUMS` for release `2026.03.17`:

```
3bda0968a01cde70d26720653003b28553c71be14dcb2e5f4c24e9921fdad745  yt-dlp
3db811b366b2da47337d2fcfdfe5bbd9a258dad3f350c54974f005df115a1545  yt-dlp.exe
e80c47b3ce712acee51d5e3d4eace2d181b44d38f1942c3a32e3c7ff53cd9ed5  yt-dlp_macos
c2b0189f581fe4a2ddd41954f1bcb7d327db04b07ed0dea97e4f1b3e09b5dd8e  yt-dlp_linux
…
```

The signing key is Simon Sawicki's GPG key (`Simon Sawicki (yt-dlp signing key) <contact@grub4k.xyz>`, fingerprint `AC0CBBE6848D6A8734 64AF4E57CF65 933B5A 7581`, RSA 4096). The ASCII-armored public key lives at `https://github.com/yt-dlp/yt-dlp/raw/master/public.key` and was added in upstream commit [`12647e03`](https://github.com/yt-dlp/yt-dlp/commit/12647e03d417feaa9ea6a458bea5ebd747494a53). The canonical CLI verification flow is:

```bash
gpg --import < public.key
gpg --verify SHA2-256SUMS.sig SHA2-256SUMS
sha256sum -c SHA2-256SUMS --ignore-missing
```

The first line establishes trust in the key (you have to decide to trust it — typically by cross-checking the fingerprint against multiple sources). The second proves `SHA2-256SUMS` was signed by yt-dlp's release key. The third checks every binary you have on disk against the (now-trusted) sums file.

## Two threat models, two layers

| Layer | What it proves | Defeated by |
|-------|----------------|-------------|
| HTTPS to `github.com` + `SHA2-256SUMS` check | The bytes you got are byte-identical to what GitHub serves *right now*, and the binary matches what the sums file lists. | A compromised GitHub release upload (e.g. attacker with push access to the release, or a malicious CI run) — they can swap both the binary and `SHA2-256SUMS` consistently and you won't notice. |
| OpenPGP signature on `SHA2-256SUMS` | The sums file was produced by the holder of yt-dlp's signing key. | Compromise of the signing key itself. |

For ClipGrab's threat model — "we trust GitHub" is the same assumption pip/PyPI installs make implicitly today — the first layer alone is a meaningful improvement over the current "download whatever GitHub gives us, no checks at all" baseline. The second layer is strictly stronger.

## What's implementable with Qt + C++ stdlib alone

| Step | Qt-only? | How |
|------|----------|-----|
| HTTPS download with cert validation | ✅ | `QNetworkAccessManager` uses the system TLS backend (Secure Transport / SChannel / OpenSSL). Reject TLS errors instead of swallowing them. |
| Compute SHA-256 of a downloaded file | ✅ | `QCryptographicHash(QCryptographicHash::Sha256)` + `addData(QIODevice*)`. |
| Parse `SHA2-256SUMS` | ✅ | Split on `\n`, find the line ending in our filename, take the leading 64 hex chars. |
| Compare hash to expected | ✅ | `actual.compare(expected, Qt::CaseInsensitive) == 0`. |
| Verify the detached OpenPGP `.sig` | ❌ | Qt has no OpenPGP support, and neither does the C++ standard library. The TLS backends Qt wraps don't expose generic public-key verification at the Qt API level. |

For the OpenPGP step we'd need to either:

1. **Bundle GPG** (`gpg.exe` / `gpg` binary, ~5 MB) and shell out — works but adds another moving part to the bundle.
2. **Link an OpenPGP library**:
   - [Sequoia-PGP](https://sequoia-pgp.org/) — Rust, has a stable C ABI (`sequoia-openpgp-ffi`).
   - [RNP](https://github.com/rnpgp/rnp) — C++ library used by Thunderbird.
   - [GPGME](https://gnupg.org/software/gpgme/) — wraps a `gpg` install, so doesn't actually remove the binary dependency.
3. **Hand-roll RFC 4880 packet parsing + RSA verification** — possible, ~2 KLOC, not worth the maintenance.
4. **Verify in CI instead of at runtime**: have the GitHub Actions pipeline run `gpg --verify` once when bumping pinned hashes; ship just the verified SHA in our code. Same approach we use for ffmpeg / deno.

## What this branch actually implements

`clipgrab.cpp::startYoutubeDlDownload` now:

1. Picks the per-OS asset (`yt-dlp_macos` / `yt-dlp.exe` / `yt-dlp`).
2. Fetches `SHA2-256SUMS` from `https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS`.
3. Parses out the expected SHA-256 for our asset (`sha256FromSumsFile`).
4. Fetches the binary into `<AppDataLocation>/<asset>.partial`.
5. Computes SHA-256 with `QCryptographicHash` and compares case-insensitively to the expected value.
6. On match: renames `.partial` → final, `chmod 0755` on macOS/Linux, defensively calls `removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)` on macOS.
7. On mismatch or any network error: deletes the partial, surfaces an `errorHandler` message, and quits the helper-downloader flow. The most likely benign cause of mismatch is "GitHub published a new release between the two requests" — the user just retries.

This is the Qt-only layer. If/when we want the OpenPGP layer too, the natural integration point is right after step 3: download `SHA2-256SUMS.sig`, verify the signature against the pinned `public.key`, and only then proceed to step 4. The library plumbing is the only blocker.

## A note on supply chain

This work doesn't change the trust model meaningfully on its own — pre-change we already trusted `github.com` to deliver `yt-dlp` correctly, and now we still trust it to deliver both `SHA2-256SUMS` and the binary. What it does buy us is:

- Detection of CDN corruption / mid-flight modification (your local cache, a misbehaving proxy, etc.).
- A natural seam for adding OpenPGP verification later — the SHA already comes from `SHA2-256SUMS`, so once we can verify that file, the whole chain is anchored to the signing key with no further code changes.
- A clean failure mode: a tampered or stale binary fails verification, gets deleted, and the user is told to retry rather than silently running a wrong binary.

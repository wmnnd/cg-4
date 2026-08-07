# ClipGrab code review — bugs, security, runtime exceptions

Scope: whole codebase (`video`, `clipgrab`, `youtube_dl`, `mainwindow`,
`download_list_model`, `converter_*`, `message_dialog`). Every finding below was
verified against the current source on `claude/remove-webengine`. Line numbers
are from that branch.

Provenance note: the large majority of the serious findings are **pre-existing**
— they live in code inherited from the original app / the Qt6 port, not in the
WebEngine-removal or yt-dlp-download work. That's called out per finding.

Severity legend: 🔴 critical · 🟠 high · 🟡 medium · ⚪ low / latent.

---

## Security

### 🔴 S1 — Update server can write arbitrary settings, delete files, open arbitrary URLs, and force-quit
`clipgrab.cpp:469-483` (pre-existing)

`parseUpdateInfo()` processes `<command>` elements from the update XML with no
allowlist:

```cpp
else if ((command.attribute("type") == "open"))
    QDesktopServices::openUrl(QUrl(command.attribute("uri")));      // :471
else if ((command.attribute("type") == "set"))
    QSettings().setValue(command.attribute("key"),
                         command.attribute("value"));               // :475
else if ((command.attribute("type") == "unset"))
    QSettings().remove(command.attribute("key"));                  // :478
else if (command.attribute("type") == "die")
    QApplication::quit();                                          // :482
```

Anyone who controls the update endpoint (or can MITM it — see S3 re: no cert
pinning) gets, silently and with no user interaction on the next update check:

- **Full traffic interception.** Set `UseProxy=true` + `ProxyHost`/`ProxyPort`
  to attacker infrastructure. `activateProxySettings()` (`clipgrab.cpp:750`)
  routes *all* app network traffic through it on next launch.
- **Arbitrary file deletion (user perms).** Set key `updateFile` to any path;
  the constructor (`clipgrab.cpp:228-238`) reads that setting on the next launch
  and calls `updateFile.remove()` on it.
- **Suppress future updates.** Set `DisableUpdateNotifications=true` /
  `disableYoutubeDlDownload=true` to freeze the app on a known-vulnerable
  version.
- **Arbitrary URL/scheme launch.** `open` with `file:///…`, a UNC path, or any
  OS-registered scheme.
- **Remote DoS.** `die` quits the app on command.

Fix: allowlist the settable keys, validate `open` to `http(s)` only, drop or
gate `die`, and treat the update channel as untrusted input.

### 🔴 S2 — ffmpeg argument injection via video metadata
`converter_ffmpeg.cpp:156-158, 204` (pre-existing)

The conversion command is built as one string and run via
`QProcess::startCommand()`:

```cpp
ffmpegCall = ffmpegCall + " -metadata title=\""  + metaTitle  + "\"";
ffmpegCall = ffmpegCall + " -metadata author=\"" + metaArtist + "\"";
ffmpegCall = ffmpegCall + " -metadata artist=\"" + metaArtist + "\"";
...
ffmpeg->startCommand(ffmpegCall);                                  // :204
```

`metaArtist` originates from the remote video's `artist`/`uploader` field
(`video.cpp:201-203`), flows through the metadata dialog
(`mainwindow.cpp` "Use metadata" path) into `setMetaArtist()`, and reaches the
command **unescaped**. `startCommand()` runs `QProcess::splitCommand()`, which
does its own double-quote parsing, so a `"` in the value terminates the quote
early and the following tokens become new ffmpeg arguments.

Attack: publish a video whose uploader name is
`x" -f mp4 y" -metadata a="`. A victim with "Use metadata" enabled who picks an
audio-only format and confirms the dialog gets attacker-controlled ffmpeg
options injected — enough to add inputs/outputs, i.e. **read a local file into
the output or write a second attacker-named output file** (potential code
execution by clobbering a startup script).

Scope correction worth recording: `startCommand()` does **not** invoke a shell,
so `` ` ``, `$()`, `;`, `|` are passed literally to ffmpeg and are *not*
breakouts — only an unbalanced `"` is exploitable. `metaTitle` happens to be
scrubbed today only as a side effect of the `getSafeFilename()` bug (I3); do not
rely on that.

Fix: use `QProcess::start(program, QStringList)` with a real argument vector
(applies to the filename concatenations at `:46,48,52,198` too).

### 🟠 S3 — Self-update verified only by SHA-1 from the same untrusted channel, then executed
`clipgrab.cpp:541-563` (pre-existing)

```cpp
QCryptographicHash fileHash(QCryptographicHash::Sha1);            // :541
...
if (hashResult != updateSha1) { …reject… }                       // :546
...
QDesktopServices::openUrl(QUrl::fromLocalFile(updateFile->fileName())); // :563
```

The downloaded installer/binary is renamed to keep its `.exe`/`.dmg`/`.tar`
extension and handed to the OS to execute/mount. Integrity rests entirely on
(a) HTTPS to the XML host and (b) a **SHA-1** value supplied by that same XML.
SHA-1 is collision-broken; there is no code-signature check. The update `uri`
(`clipgrab.cpp:340,509`) is never scheme/host-validated, so the binary can be
pulled over plain **HTTP** from any host. Combined with S1 (attacker can set the
update URL) or any XML-channel compromise, this is a code-execution path. Fix:
require HTTPS, verify a real code signature (or at minimum SHA-256), pin the host.

### 🟡 S4 — yt-dlp download trust chain is settings-overridable and unsigned
`youtube_dl.cpp` `YoutubeDlDownloader` ctor + `start()` (introduced this PR)

`baseUrl` comes from `QSettings("youtubeDlBaseUrl", …github…)` with no scheme
check, and both `SHA2-256SUMS` and the artifact are fetched from it. The SHA-256
check is **sound** (see V1) but only proves the artifact matches the sums file
*from the same server*; `SHA2-256SUMS.sig` is not verified. Anyone who can set
that one QSetting (e.g. via S1) points the whole flow at their server with a
matching sums file and gets persistent code execution at next `find()`. Lower
severity than S1/S2 because it requires the settings write first. Fix: pin
`https://`, lock the override, verify the GPG signature (tracked in
`YT_DLP_SIGNATURE_VERIFICATION.md`).

### ⚪ S5 — Proxy password leaks onto the yt-dlp process argv
`youtube_dl.cpp:118-135` (pre-existing)

`--proxy http://user:pass@host` is passed as an argv element, readable by any
local user via `ps` / `/proc/<pid>/cmdline`. Not injectable, but the secret is
exposed. Fix: pass credentials via environment or `--netrc`.

---

## Crashes / runtime exceptions

### 🟠 C1 — `originalFormat.split(".").at(1)` out-of-range
`converter_ffmpeg.cpp:48` (pre-existing)

```cpp
ffmpegCall.append(" … -f " + originalFormat.split(".").at(1) + " …");
```
If `originalFormat` has no `.`, `split(".")` returns one element and `.at(1)`
throws/`Q_ASSERT` → crash. Reached from the `concatenate()` DASH-muxing path.

### 🟡 C2 — `targetConverter` null dereference on download-finished
`video.cpp:583` (pre-existing)

`download()` (`video.cpp:86`) checks state + `selectedQuality` but never
`targetConverter != nullptr`; `handleProcessFinished` then calls
`targetConverter->startConversion(...)`. `targetConverter` is null until
`setConverter()` runs. Any caller that reaches `download()` without
`setConverter()` first crashes. The normal UI path always calls `setConverter`
before enqueue, so it's latent — but `getTargetFormatName()` (`:542`) *does*
null-guard, showing the inconsistency. Add the guard in `download()`.

### 🟡 C3 — `getSelectedQualityName()` / negative `setQuality` index
`video.cpp:462-466, 522-526` (pre-existing)

`setQuality()` guards only `index >= qualities.size()`, not `index < 0`, and
`getSelectedQualityName()` guards only `== -1`. `setQuality(-2)` succeeds, then
`getSelectedQualityName()` runs `qualities.at(-2)` → crash. (`download()` is
incidentally safe because it guards `selectedQuality <= -1`.) Reachable from
`mainwindow.cpp` passing an empty combo's `currentIndex() == -1` into a path that
later hits `qualities.at(-1)`. Fix the bound to `index < 0 || index >= size`.

### ⚪ C4 — unmatched `endRemoveRows()`
`download_list_model.cpp:33-43` (pre-existing)

`downloadAboutToBeRemoved` can `return` early (lines 35, 37) without calling
`beginRemoveRows`, but `downloadRemoved` unconditionally calls `endRemoveRows()`
(line 42). If those two ever fire out of lockstep, `endRemoveRows` pops an empty
change stack in `QAbstractItemModel` → UB/crash. Latent: the only emit site
today guarantees membership. Landmine for any future removal path.

### ⚪ C5 — `availableUpdates.last()` unguarded in public slots
`clipgrab.cpp:491, 545, 664` (pre-existing)

`startUpdateDownload` / `updateDownloadFinished` / `skipUpdate` are public slots
that call `availableUpdates.last()` with no `isEmpty()` check. Safe only by the
current connect ordering; `last()` on an empty list is UB.

### ⚪ C6 — `.last()` on a possibly-empty split
`mainwindow.cpp:289` (pre-existing) — `target == "/"` yields an empty
`split("/", SkipEmptyParts)`, and `.last()` is UB. Save-dialog edge case.

---

## Logic bugs

### 🟡 L1 — `vcodecPreferences.empty();` is a no-op (WebM preference silently broken)
`video.cpp:214` (pre-existing)

```cpp
if (QSettings().value("UseWebM", false).toBool()) {
    acceptedExts << "webm" << "opus";
    vcodecPreferences.empty();          // no-op — result discarded; meant clear()
}
```
`QList::empty()` is a `const` query (STL alias for `isEmpty()`). The list keeps
`{"avc1","av01"}`, so with WebM enabled the sort still *deprioritizes* VP9/WebM —
the opposite of intent. Change to `vcodecPreferences.clear();`.

### 🟡 L2 — ffmpeg/Merger progress regex has wrong alternation precedence
`video.cpp:411` (pre-existing)

```cpp
re.setPattern("^\\[ffmpeg|Merger\\] Merging formats into \"([^\"]+)\"");
```
`|` splits the whole pattern into `^\[ffmpeg` OR
`Merger\] Merging formats into "(…)"`. A real `[ffmpeg] Merging formats into "X"`
line matches only the capture-less first alternative, so `captured(1)` is null
and `finalDownloadFilename` is never set from ffmpeg output. Intended
`^\\[(ffmpeg|Merger)\\]`.

### 🟡 L3 — 64-bit `filesize` truncated to 32-bit
`video.cpp:361, 380` (pre-existing)

`quality.videoFileSize`/`audioFileSize` are `qint64` but assigned from
`QJsonValue::toInt()` (returns `int`). A `filesize > 2^31` (~2.1 GB, routine for
4K) truncates or goes negative, corrupting `downloadSize` and the progress
percentage. Use `.toInteger()`.

### 🟡 L4 — codec-rank stored in `bool`
`video.cpp:292-293` (pre-existing) — `bool vcodecAPreferencePos` holds a rank
(`vcodecPreferences.length()`, then a loop index), collapsing ranks to 0/1 so
`av01` and "no preferred codec" become indistinguishable and the intended
`avc1 < av01 < others` ordering breaks. Should be `int`. (Projection stays
consistent, so no `std::sort` UB — just wrong order.)

### 🟡 L5 — `getSafeFilename()` mutates the `title` member in place
`video.cpp:475` (pre-existing)

```cpp
return title.replace(QRegularExpression("…"), "");
```
`QString::replace` mutates `*this` and returns a reference, so calling
`getSafeFilename()` permanently strips characters from the `title` member — a
surprising side effect (and the only reason `metaTitle` dodges S2). Use a local
copy: `return QString(title).replace(…);`.

### ⚪ L6 — `[=]` lambdas capture `this`, alias current-video members
`clipgrab.cpp:258, 822` (pre-existing) — the `stateChanged` lambdas read
`this->currentVideo` / `this->currentSearch` at emit time, so a late signal from
a superseded (already `deleteLater`'d) object emits with the *new* pointer. Use
an explicit value capture of the specific object.

### ⚪ L7 — `humanizeBytes` returns "" for ≤1 byte
`clipgrab.cpp:796` — `if (bytes > factor)` should be `>=`; 0–1 bytes render as an
empty string.

### ⚪ L8 — `isKnownVideoUrl` regex typos
`clipgrab.cpp:743,746` — `(player.)` requires the literal text and unescaped `.`
in `youtu.be`; `vimeo.com/video/N` won't match and `youtuXbe/…` would.

### ⚪ L9 — stale download state on restart
`video.cpp:630` — `removeTempFiles()` never clears `downloadFilenames` /
`downloadSizeEstimates` / `finalDownloadFilename`, so cancel → `restart()`
carries stale state into the next run.

---

## Resource leaks (all pre-existing)

- **R1 `clipgrab.cpp:302`** — `parseUpdateInfo` never `deleteLater()`s the reply
  or the `new QNetworkAccessManager`; every update check leaks both. Same for
  `updateNAM` at `:508` and the update dialog/Ui at `:375-377` on non-rejected
  paths.
- **R2 `clipgrab.cpp:664`** — with `RemoveFinishedDownloads`,
  `downloads.removeAll(video)` drops the pointer without `deleteLater()`.
- **R3 `video.cpp`** — `video` has no destructor: `playlistVideos` entries
  (`:169`), the final `youtubeDl` QProcess, and `targetConverter` (`:479`) leak
  per instance; adds up for large playlists.
- **R4 `clipgrab.cpp:677-680`** — `cancelAllDownloads` adds a context-less
  `connect(...)` each call that is never disconnected → `allDownloadsCanceled`
  fires multiple times after repeated cancels.

---

## Verified safe (checked, no action needed)

- **V1 — yt-dlp SHA-256 verification is sound.** Case-insensitive compare,
  lowercase `toHex()`, empty-expected-hash rejected *before* compare, 64-hex
  parse guard, extraction only after match. No "empty hash compares equal"
  bypass. (`youtube_dl.cpp`)
- **V2 — `YoutubeDlDownloader` lifetime is correct.** `new QFile(partial, this)`
  is `delete`d on exactly one path each; `~QObject` de-registers it from the
  parent, so the later `deleteLater()` doesn't double-free. SSL-teardown path is
  safe (children auto-destroyed); worst case a `.partial` is left on disk.
- **V3 — no argument injection in the yt-dlp/tar path.** Proxy/PATH/paths are
  separate argv/env entries, never shell-interpreted; `zipPath`/`tmpDir` are
  fixed AppData paths that never start with `-`.
- **V4 — zip extraction can't escape `installPath`.** `entryList(NoDotAndDotDot)`
  yields bare basenames; `QDirIterator` uses `NoSymLinks`; `wipePath` unlinks
  symlinks rather than following them.
- **V5 — search-thumbnail handling is safe.** `thumbnailRequests.take(reply)`
  returns null after `clear()`, and `searchResults->row(target)` compares
  addresses without dereferencing, so stale replies can't use-after-free.

---

## Suggested priority

1. **S1** (control-server command allowlist) and **S2** (ffmpeg argv vector) —
   both remotely reachable, both give an attacker meaningful local impact. These
   are the two that matter most.
2. **S3** (SHA-256 + real signature for self-update; require HTTPS).
3. **C1 / C2 / C3** — easy crashers, one-line guards each.
4. **L1 / L2 / L3** — behaviour bugs with user-visible effects (WebM prefs,
   progress display, filename detection).
5. Leaks and the remaining ⚪ items — cleanup as convenient.

None of these block the WebEngine/yt-dlp PR (they're overwhelmingly pre-existing
and orthogonal), but S1/S2/S3 are worth their own follow-up before the next
release regardless of this branch.

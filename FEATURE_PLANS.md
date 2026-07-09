# Feature Implementation Plans — ClipGrab 4.x

**Base for all three plans: `claude/remove-webengine` @ `015ce96` (v4.0.0-beta1).**
All `file:line` references below are valid at that commit. The plans are ordered
by dependency: Plan 2 builds on Plan 1's data model, Plan 3 reads Plan 2's
language selection. Implement in order; each plan is separately shippable.

> **Private document** — listed in `packaging/export-source.sh` `PRIVATE_PATHS`;
> keep it out of any public tree.

---

## Shared context: how the pipeline works today

One fetch, one selection, one download:

1. **Fetch** — `video::fetchInfo()` runs `yt-dlp -J --no-playlist <url>`;
   `video::handleInfoJson()` (video.cpp:150) parses the JSON once and builds
   `QList<videoQuality> qualities` (video.h:34 — struct with `name`,
   `videoFormat`/`audioFormat` (yt-dlp format_ids), `containerName`,
   `videoFileSize`/`audioFileSize`, `resolution`).
2. **UI** — `mainwindow.cpp:350` fills `downloadComboQuality` 1:1 from
   `qualities` (userData = `resolution` int, used by the
   `rememberedVideoQuality` setting at mainwindow.cpp:357/903).
3. **Selection** — `startDownload()` (mainwindow.cpp:317) calls
   `setQuality(comboIndex)` (index into `qualities`) and
   `setConverter(converter, mode)`; `audioOnly` :=
   `converter->isAudioOnly(mode)` (video.cpp:478).
4. **Download** — `video::download()` (video.cpp:86) builds
   `-f <videoFormat>` (muxed), `-f <audioFormat>` (audioOnly), or
   `-f <video>+<audio>` (video.cpp:107-111), downloads to a temp template
   (`cg-youtube-dl-%(id)s-%(format_id)s.%(ext)s`), then hands the merged file
   to the converter (`converter_copy` "Original", or `converter_ffmpeg` modes
   0-5: MPEG4, WMV, OGG Theora, MP3, OGG Vorbis, Original-audio; audio-only =
   modes 3-5, converter_ffmpeg.cpp:254).

### What `handleInfoJson` throws away (the problem Plans 1+2 fix)

- **Input ext filter** (video.cpp:210): only `{mp4, m4a}` formats are kept
  (`+ webm/opus` when the `UseWebM` setting is on). *Consequence discovered on
  the prior attempt branch (see below): YouTube ships per-language dub audio
  almost exclusively as opus/webm — itag 140 (m4a) exists only for the original
  language — so the dubs are usually discarded right here.*
- **AI-dub erase** (video.cpp:227-259): collects languages whose `format_note`
  contains "original" into `languagePreferences`, then **erases** every audio
  format in any other language (and video formats with a differing non-empty
  language). This is what Plan 2 replaces with a picker.
- **Early dedup** (video.cpp:321-333): after sorting (height ▸ fps ▸ ext ▸
  vcodec-preference `{avc1, av01}` ▸ acodec ▸ format string), `std::unique`
  keeps exactly one video format per `(height, fps)` — all codec/container
  alternatives are gone before the user ever picks anything.
- **Audio pairing** (video.cpp:378): each surviving video format gets ONE
  audio format via the proportional index
  `(n-1) * i / videoFormats.size()` (best audio with best video, worse audio
  further down). audioOnly downloads reuse *that* pairing — there is no
  "best audio for an audio target" logic.

### Known defects to fix in passing (Plan 1 absorbs all of these)

| Where | Defect |
|---|---|
| video.cpp:214 | `vcodecPreferences.empty();` — `.empty()` is a const query; the intended `.clear()` never happens, so `UseWebM` does **not** actually neutralize the mp4-codec preference. |
| video.cpp:360/379 (quality build loop) | `filesize` read with `.toInt()` — overflows >2 GiB; use `.toDouble()` → `qint64` (JSON numbers are doubles anyway). |
| video.h:49 | `videoQuality::operator<` is a stubbed TODO returning `false` — delete it with the refactor. |
| video.cpp:378 | The proportional audio pairing (see above) — replaced by the resolver. |

### Prior art: branch `claude/audio-language-and-subtitles` (unmerged)

An earlier attempt at features 2+3 exists (8 commits, head `5e5e4e9`, based on
an older main). **Do not merge it** — Plan 1's data model supersedes its
approach — but mine it for the hard-won extractor knowledge:

- **Salvage (knowledge):**
  - Accept *all* audio exts during parsing or language detection sees only the
    original track (commit `9441ab7`).
  - Language must fall back to `audio_track.language` when the top-level
    `language` field is empty (commit `600fb44`).
  - Language codes need normalizing (`en-US` vs `en`) before deduping.
  - Storyboard formats (`vcodec == "none" && acodec == "none"`) must be
    excluded or they surface as a bogus "Default" language (commit `e74c4e6`).
  - Original-language detection: `format_note` containing `"original"`
    (yt-dlp also exposes `language_preference == 10` for the default track —
    use as fallback signal).
- **Salvage (code, adaptable):** the `subtitle {name, language}` struct and
  the `subtitles`-object JSON parsing shape; the Homebrew-PATH fix it carried
  is already on the base branch.
- **Discard:** its `audioQuality` parallel list (Plan 1 keeps one unified
  format list instead); its per-download *subtitle picker* UI and
  `--embed-subs` pipeline (Plan 3 uses a settings toggle + sidecar files);
  its `supportsSubtitleEmbedding()` converter API.

### Cross-cutting rules for the implementer

- New user-visible strings: wrap in `tr()`; expect an `lupdate` pass later —
  do not hand-edit `.ts` files.
- New settings keys are listed per plan; all read via `QSettings` with the
  documented defaults so absent keys behave identically to today.
- Non-YouTube portals must keep working: many yield only muxed formats with
  empty `language` — every new code path needs the "no language info, no
  separate audio" degenerate case to reproduce today's behavior.
- `video.cpp` is shared by the playlist/search path (`--flat-playlist`
  entries are `_type: url` stubs, video.cpp:195 — they never reach the format
  parsing until fetched individually). No changes needed there, but don't
  break the early-return.

---

## Plan 1 — Late format resolution (keep everything, resolve at download time)

### Goal

Parse and keep **all** usable formats (every codec, container, language, and
resolution). The UI keeps showing deduplicated quality *levels* exactly as
today. The actual yt-dlp format string is computed only when the user hits
download, by a resolver that knows the chosen quality level, the target
format (audio-only or not, container), the chosen audio language (Plan 2),
and a new "preferred MP4 codec" setting.

### Data model (video.h)

Replace the early-collapsed lists with retained raw data + a derived view:

```cpp
// One yt-dlp format entry, kept verbatim-ish from the -J JSON.
struct mediaFormat
{
    QString formatId;        // "137"
    QString ext;             // "mp4", "webm", "m4a", "opus"
    QString vcodec;          // "avc1.640028", "av01...", "none"
    QString acodec;          // "mp4a.40.2", "opus", "none"
    int     height = 0;      // 0 for audio-only
    int     fps = 0;
    double  tbr = 0;         // total bitrate, for audio ranking
    qint64  filesize = 0;    // filesize, else filesize_approx, else 0
    QString language;        // normalized (see Plan 2), may be empty
    bool    isOriginalLanguage = false;
    QString formatNote;

    bool isAudioOnly() const { return vcodec == "none"; }
    bool isVideo()     const { return vcodec != "none"; }
};
```

`video` members: `QList<mediaFormat> mediaFormats;` (replaces nothing visible —
`qualities` stays but becomes derived). Keep `videoQuality` as the **UI view
row**: `{name, resolution, fps}` is all it still needs (drop
`videoFormat/audioFormat/...` fields from it once nothing reads them; the
selected download's sizes come from the resolver).

### Parsing changes (`handleInfoJson`)

1. Keep the storyboard exclusion (`vcodec==none && acodec==none` → skip) and
   drop everything else that filters: **no ext filter, no language erase, no
   `std::unique`**. Every format becomes a `mediaFormat` (with the
   language-normalization + `audio_track` fallback from Plan 2's rules — put
   the helper in place now even if the picker lands later).
2. Build the UI view: collect distinct `(height, fps≥59?)` levels from video
   formats, sorted descending; reuse the existing naming code verbatim
   (video.cpp:335-355: `"1080p"`, `"…60"`, `"(HD)/(4K)/(8K)"`, `"unknown"`).
   Do **not** append `" WebM"` to names anymore — container is now a
   download-time decision, not a quality-row identity.
3. Compute `filesize` as `filesize` → fallback `filesize_approx` → 0, via
   `.toDouble()`.
4. Delete the `UseWebM` input filtering (video.cpp:210-215) — the setting
   moves into the resolver (below). This also obsoletes the `.empty()` bug.

### The resolver

```cpp
struct resolvedSelection
{
    QString formatString;   // ready-made yt-dlp -f value, may contain "/" fallbacks
    qint64  videoSize = 0;  // for downloadSize estimate
    qint64  audioSize = 0;
    QString container;      // expected merged ext: "mp4"/"webm"/"m4a"/"opus"/…
};

resolvedSelection video::resolveSelection() const;
// inputs (all already members by download() time):
//   selectedQuality (level index), audioOnly, targetConverterMode,
//   preferredLanguage (Plan 2), QSettings: UseWebM, preferredMp4Codec
```

Selection rules, in order:

**A. Audio-only target** (`audioOnly == true`) — the user's headline case:
   1. Candidates: all `mediaFormat::isAudioOnly()` entries.
   2. Filter by language: exact preferred → original → any (drop the filter at
      each step if it empties the pool).
   3. Rank by `tbr` descending. Map the chosen quality level to an audio
      tier: level 0 (top row) → best tbr; last level → lowest tbr; in between
      proportional (this preserves the spirit of "high quality ⇒ best audio"
      while making a low pick actually cheaper). Document this in a comment —
      audio streams have no resolution, the mapping is a deliberate
      interpretation.
   4. Container preference: for MP3/OGG/Original-audio conversion anything
      works, but prefer `m4a` when the eventual container is mp4-family and
      `opus/webm` when `UseWebM` — one `std::stable_sort` tie-break.
   5. Emit `formatString = "<id>/bestaudio"` (the `/bestaudio` suffix is the
      safety net if the chosen id 403s — yt-dlp retries alternatives
      natively). **No video is downloaded at all** — today a muxed-only pick
      downloads the full video for an MP3 target.

**B. Video target:**
   1. Candidates: video formats at the selected `(height, fps)` level.
   2. Container: unless `UseWebM`, prefer `mp4`; with `UseWebM` allow webm to
      win ties (rank, don't erase — if the level exists only as webm, use it).
   3. Codec: new setting `preferredMp4Codec` ∈ `{"h264", "av1"}` (default
      `"h264"`, matching today's hardcoded `{avc1, av01}` order). Rank
      `vcodec` prefix `avc1` vs `av01` accordingly; unknown codecs last.
      (Applies to mp4 candidates; webm/vp9 unaffected.)
   4. Pick audio to pair (skip if the winner is muxed, `acodec != "none"`):
      same language logic as A.2, rank by `tbr` desc, take the best that is
      container-compatible (mp4 video ⇒ `{m4a, mp4, aac}` audio; webm video ⇒
      `{webm, opus, ogg}` — keep the existing compat table from
      video.cpp:364-369). NOTE this deliberately upgrades the old proportional
      pairing: every quality level now gets the best compatible audio; size
      diffs are trivial next to video.
   5. `formatString = "<vid>+<aid>/<vid>/best"` (paired, then bare video if
      the audio id vanishes, then yt-dlp's own best as last resort).
   6. Set `videoSize/audioSize` from the chosen entries (downloadSize estimate
      at video.cpp:91 keeps working).

**C. Degenerate portals** (no separate audio, one muxed format, no language):
   rules above naturally collapse — candidates lists just have one entry; the
   resolver must never *fail* when `mediaFormats` is non-empty. Add
   `Q_ASSERT`-free guards: empty candidate pool at any hard step ⇒ relax that
   step (language → any, level → nearest level ≤ requested, container → any).

### Call-site changes

- `video::download()` (video.cpp:86): replace the three `-f` branches
  (video.cpp:105-111) with one `resolveSelection()` call;
  `downloadSize = r.videoSize + r.audioSize`.
- `converter_copy::startConversion` receives `originalExtension` — currently
  from `qualities.at(selectedQuality).containerName` (video.cpp:560 region,
  `getSafeFilename`/conversion start). Thread `resolvedSelection::container`
  through instead (store the last resolution result as a member,
  `resolvedSelection currentSelection;`, set in `download()`).
- `mainwindow.cpp:350-370` — unchanged mechanics (fills from
  `getQualities()`, which now returns the derived view). The
  `rememberedVideoQuality` resolution matching (mainwindow.cpp:357) keeps
  working because userData is still the resolution int.
- `setQuality(int)` semantics change from "row in qualities==formats" to
  "row in quality levels" — same signature, update the bounds check.

### New setting

- Key `preferredMp4Codec`, values `"h264"` (default) | `"av1"`.
- UI: Settings → the group that holds `settingsUseWebM` (mainwindow.ui:807) —
  a small combo `settingsPreferredCodec` with two entries; store on
  `currentIndexChanged` like the neighboring toggles. Tooltip: "Used when a
  quality is available in more than one MP4 codec. AV1 files are smaller;
  H.264 plays everywhere."

### Verification checklist (Plan 1)

- [ ] YouTube video with av01+avc1 at same resolution: default downloads
      avc1; setting flipped to AV1 downloads av01 (`yt-dlp -J` fixture +
      inspect chosen `-f` in the QProcess args via qDebug).
- [ ] MP3 target from a video whose chosen level is muxed-only on a generic
      portal: no separate audio exists → falls back to muxed download (old
      behavior), while on YouTube it downloads a pure audio stream (new).
- [ ] `UseWebM` on: webm wins ties, mp4-codec setting ignored for webm.
- [ ] Non-YouTube muxed-only portal (e.g. a direct-file/generic extractor):
      identical behavior to 4.0.0-beta1.
- [ ] >2 GiB format: size estimate no longer negative.
- [ ] Playlist/search flows unaffected (stub entries).

---

## Plan 2 — Audio language picker

### Goal

Replace the destructive AI-dub filter with data: keep all languages (done in
Plan 1), show a picker next to the quality combo, honor it in the resolver,
and default to the original language so the out-of-box behavior still avoids
AI dubs.

### Extraction rules (finalize the helper stubbed in Plan 1)

In `handleInfoJson`, for every format:

1. `language` := top-level `language` field; if empty, `audio_track.language`
   (nested object — present on YouTube dub tracks).
2. Normalize: trim, lowercase the primary subtag for comparison but preserve
   the original tag for yt-dlp/`--sub-langs` use; treat `en-US`/`en-GB` as
   distinct picker entries only when both exist, else collapse to `en`.
   Helper: `static QString video::normalizeLanguage(QString)`.
3. `isOriginalLanguage` := `format_note` contains `"original"`
   (case-insensitive); fallback: `language_preference` JSON field `== 10`.
4. Storyboards already excluded (Plan 1).

New accessors on `video`:

```cpp
QStringList availableAudioLanguages() const; // display order: original first,
                                             // then alphabetical by display name
QString originalAudioLanguage() const;       // "" when unknown
void setPreferredLanguage(const QString& code);   // stored member, used by resolver
```

### UI (mainwindow.ui, download tab `gridLayout_4`)

Current row 4: `label_2 "Format:"(c0) | downloadComboFormat(c1) |
label_3 "Quality:"(c2) | downloadComboQuality(c3) | downloadStart(c4)`.

- Move `downloadStart` to column 6.
- Insert `labelLanguage` ("Audio:") at column 4 and `downloadComboLanguage`
  at column 5 (same sizePolicy/max-width 210 as the other combos, `enabled`
  false by default like its neighbors).
- **Visibility rule:** hide `labelLanguage` + combo when
  `availableAudioLanguages().size() < 2` (the overwhelmingly common case, and
  every non-YouTube portal) — the row then looks exactly like today.
  Hide, don't just disable, to avoid dead chrome.

Population (in the `handleCurrentVideoStateChanged` block that fills the
quality combo, mainwindow.cpp:344-370):

- Item text: `QLocale(code).nativeLanguageName()` fallback to the raw code;
  append `" (original)"` (tr()) on the original entry. Item data: the
  unnormalized language tag (what yt-dlp expects back).
- Default selection: `rememberedAudioLanguage` setting if it matches an
  available language, else the original, else index 0.
- Persist on change: `rememberedAudioLanguage` = item data (mirror the
  quality persistence at mainwindow.cpp:903; guard with the same
  `updatingComboQuality`-style reentrancy flag — add
  `updatingComboLanguage`).

`startDownload()` (mainwindow.cpp:317): before `setQuality(...)`, call
`video->setPreferredLanguage(ui.downloadComboLanguage->currentData().toString())`
(empty string when hidden ⇒ resolver falls back to original — identical to
today's behavior).

### Resolver integration (Plan 1's step A.2 / B.4)

Preference cascade per candidate pool: exact tag match → same primary subtag
(`de` matches `de-DE`) → `isOriginalLanguage` → language-empty formats → any.
Delete the erase block video.cpp:227-259 (it's already gone if Plan 1 landed
first; this plan is where its *behavior* is re-provided by defaulting to
original).

### Settings

- `rememberedAudioLanguage` (string tag, no UI — implicit like
  `rememberedVideoQuality`).

### Verification checklist (Plan 2)

- [ ] YouTube video with dubs (e.g. any MrBeast video): picker appears,
      original preselected + labeled, choosing German downloads the de track
      (verify `-f` ids + play the file).
- [ ] Same video, `UseWebM` off: dubs still listed (they're opus — proves the
      ext filter removal took).
- [ ] Video without dubs / non-YouTube portal: picker hidden, zero behavior
      change.
- [ ] Remembered language re-applies on the next dub-carrying video; a video
      lacking the remembered language falls back to original.
- [ ] Audio-only target + language pick: pure audio stream in that language.

---

## Plan 3 — Subtitle downloads

### yt-dlp capability analysis (verified against current docs)

| Option | Behavior | Use |
|---|---|---|
| `--write-subs` | Download subtitles as **sidecar files** next to the output (naming follows `-o`: `<output-base>.<lang>.<ext>`) | ✅ core |
| `--sub-langs EXPR` | Comma list; supports `all`, regex-ish wildcards (`en.*`), and `-` exclusions (`all,-live_chat`) | ✅ core |
| `--sub-format PREF` | Preference among formats *the site offers* (no conversion), e.g. `srt/vtt/best` | not needed if converting |
| `--convert-subs FMT` | Post-processor converting to `srt`/`vtt`/`ass`/`lrc`; needs ffmpeg — satisfied: bundled ffmpeg dir is prepended to PATH for yt-dlp (youtube_dl.cpp:115-131), system ffmpeg on Linux | ✅ `srt` |
| `--write-auto-subs` | Include auto-generated (ASR + auto-translate) captions | optional, off |
| `--embed-subs` | Mux subs into the container during merge (mp4→mov_text, mkv→srt/ass, webm→vtt) | ❌ rejected, see below |
| `-J` fields | `subtitles` (manual, keyed by lang) vs `automatic_captions` (hundreds for YouTube) | availability check |

**Recommendation: sidecar `.srt` files, never embed, never burn.**
Burning (re-encode with hardsubs) is out per your call — yt-dlp doesn't do it
anyway. Embedding is what the old attempt branch did, and it's the reason it
had to restrict formats: it only works when yt-dlp's merge container supports
soft subs *and* ClipGrab's own converter doesn't touch the file afterwards
(only "Original"; mov_text in mp4 is also the least-supported subtitle codec).
Sidecar files sidestep the whole matrix — they work for **every video target
format including MPEG4/WMV/OGG** because they're independent files that we
move next to the final output ourselves, and every player picks up
`Movie.<lang>.srt` beside `Movie.mp4`. So instead of "subtitles only for
mp4/original", the constraint becomes just: **no subtitles for audio-only
targets** (senseless) — a strictly better trade than the one you anticipated.

### Settings UI (single toggle + one choice, as requested)

Settings tab, `groupBox_2` region (mainwindow.ui:1067) or the downloads
group — implementer's judgment on best visual fit:

- `settingsDownloadSubtitles` (QCheckBox): **"Download subtitles when
  available"** — default off. Key: `downloadSubtitles` (bool).
- `settingsSubtitleScope` (QComboBox, enabled only when the checkbox is on):
  - "Only the selected audio language" (default) — key value `"selected"`
  - "All languages" — key value `"all"`
  Key: `subtitleScope` (string).
- Deliberately **no** auto-caption option in v1 (`automatic_captions` on
  YouTube = ASR + machine translations into ~150 languages; with `all` that's
  a file explosion and low quality). Leave a `// future:` note keyed to
  `--write-auto-subs`.

### Pipeline wiring

**In `video::download()`** (video.cpp:86), when `downloadSubtitles` is on
**and** `!audioOnly`:

```
--write-subs --convert-subs srt --sub-langs <EXPR>
```

`EXPR`:
- scope `"all"` → `all,-live_chat` (live_chat is a JSON pseudo-subtitle on
  YouTube VODs; excluding it is standard practice).
- scope `"selected"` → take the Plan 2 language tag (fallback: original,
  fallback: system UI language's primary subtag), emit `"<primary>.*"` so
  `de` matches `de-DE`/`de-orig` variants. If the fetch JSON's `subtitles`
  object was empty, skip the flags entirely (cheap no-op guard; yt-dlp would
  only warn, but skipping keeps logs clean).

**Tracking the files** — two additions to `handleDownloadInfo`
(video.cpp:389):

1. New pattern `^\[info\] Writing video subtitles to: (.+)` → append to a new
   `QStringList subtitleFilenames;` member.
2. Guard the existing progress accounting: the `Destination:` pattern
   (video.cpp:394) will also match each subtitle download; entries whose path
   is in `subtitleFilenames` (or ends `.srt/.vtt/.ass/.lrc`) must **not** be
   added to `downloadFilenames`/`downloadSizeEstimates`, or the progress bar
   and size estimate get polluted (subs are ~50 KB; the estimate math at
   video.cpp:437-470 would jitter).

**Moving them into place** — in `handleConversionFinished` (video.cpp:597):
the converter yields `finalFilename` (possibly renamed `Title-1.mp4` by the
collision logic, converter_copy.cpp:36-46). For each tracked subtitle file:

- target = `<finalFilename minus extension>.<lang>.srt`, where `<lang>` is
  recovered from the source name (regex `\.([A-Za-z0-9_-]+)\.srt$`).
- `QFile::rename` from temp; on cross-device failure fall back to
  copy+remove. Overwrite-if-exists (consistent with the sub belonging to the
  just-written video).

**Cleanup** — `removeTempFiles()` (video.cpp:630) and `cancel()` must delete
`subtitleFilenames` leftovers; clear the list in `restart()` alongside
`downloadFilenames`.

### Non-YouTube / edge behavior

- Portals without subtitles: `subtitles` object empty → flags skipped → zero
  change.
- Sub-only failures must not fail the download: yt-dlp already treats
  subtitle errors as warnings (no exit-code change), and our `ERROR:` regex
  (video.cpp:471) only reacts to hard errors — verify with a fixture, note in
  tests.
- Filenames with dots: the lang-recovery regex anchors on the trailing
  `.<lang>.srt` pair, so `My.Cool.Video.en.srt` parses correctly.

### Verification checklist (Plan 3)

- [ ] YouTube video with manual subs, scope=selected, language=de → exactly
      `Title.de.srt` (or `de-*` variants) beside the output; plays with
      auto-detected subs in VLC/IINA.
- [ ] scope=all → one `.srt` per manual language, no `live_chat.json`, no
      auto-captions.
- [ ] MP3 target with subtitles enabled → no sub flags passed.
- [ ] WMV target (converter_ffmpeg re-encode) → subs still arrive (sidecars
      independent of conversion).
- [ ] Collision rename (`Title-1.mp4`) → sidecar follows (`Title-1.de.srt`).
- [ ] Cancel mid-download → no stray `.srt`/`.part` in temp.
- [ ] Progress bar steady on a large video with 10+ sub languages.

---

## Suggested delivery order & sizing

| Step | Scope | Rough size |
|---|---|---|
| 1 | Plan 1 refactor + codec setting (no UI language work) | ~400 LOC touched, highest risk — land alone, soak on beta |
| 2 | Plan 2 picker (data model already there) | ~150 LOC |
| 3 | Plan 3 subtitles | ~150 LOC |

Each step ends green on the existing CI matrix and is independently
releasable as a beta increment (`4.0.0-beta2` …).

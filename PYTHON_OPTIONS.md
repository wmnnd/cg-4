# Python on macOS and Windows: bundling options

## The status quo

`youtube_dl.cpp` spawns Python and runs the bundled `yt-dlp` script:

```cpp
process->setProgram(pythonPath);                  // python3 / python.exe
process->setArguments({"<path>/yt-dlp", ...args});
```

So today ClipGrab ships:

| OS      | What's bundled              | Source                                | Approx. on-disk |
|---------|------------------------------|---------------------------------------|-----------------|
| Windows | Python 3.13 embeddable zip  | python.org `python-3.13.12-embed-amd64.zip` | ~25 MB |
| macOS   | Python 3.13 install_only tree | astral-sh/python-build-standalone `cpython-3.13.13+20260510-aarch64-apple-darwin-install_only.tar.gz` | ~60 MB |
| Linux   | (nothing — uses system python3) | n/a                                | 0 |

`yt-dlp` itself is downloaded at runtime from `https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp`. That's the standalone `.py`-style script — it needs an external Python interpreter to run.

## What options exist

### 1. yt-dlp's official PyInstaller binaries — **recommended**

yt-dlp publishes self-contained PyInstaller bundles in every release:

| File                  | Platform / arch                | Approx. size | Source                                                                 |
|-----------------------|--------------------------------|--------------|------------------------------------------------------------------------|
| `yt-dlp_macos`        | macOS, universal2 (arm64+x86_64) | ~45 MB     | [`yt-dlp_macos`](https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos) |
| `yt-dlp.exe`          | Windows x86_64                 | ~18 MB       | [`yt-dlp.exe`](https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe)     |
| `yt-dlp_x86.exe`      | Windows x86                    | ~17 MB       | (release page)                                                          |
| `yt-dlp_linux`        | Linux x86_64                   | ~25 MB       | (release page)                                                          |

Each binary has Python + the stdlib + `yt-dlp`'s own code + its third-party deps (`mutagen`, `certifi`, `brotli`, `requests`, …) baked in via PyInstaller, and runs as a single executable: `./yt-dlp_macos --version`. No interpreter on PATH required.

**Implication for ClipGrab**:
- Drop Python bundling from the dep-prep script and from the staging step.
- Change `ClipGrab::downloadYoutubeDl` to fetch the per-OS binary instead of the script (URL pattern is symmetric, just different filename).
- Change `YoutubeDl::instance()` to set `program = ytDlpPath` and `arguments = {…cli args}` (no more `python3 <script>` indirection). The deno / ffmpeg PATH-augmentation already in place stays the same.

**Net size impact** (vs the current bundle):

| Bundle | Today | With official binary | Delta |
|--------|-------|---------------------|-------|
| macOS  | ~60 MB Python framework + a yt-dlp script downloaded at runtime | `yt-dlp_macos` (~45 MB) downloaded at runtime, no Python framework | **−60 MB shipped, −45 MB downloaded → app stays ~15 MB smaller, no first-run Python download** |
| Windows | ~25 MB Python embeddable + a yt-dlp script downloaded at runtime | `yt-dlp.exe` (~18 MB) downloaded at runtime, no Python embeddable | **−25 MB shipped, −18 MB downloaded → app stays ~7 MB smaller** |
| Linux  | 0 (system python3) | `yt-dlp_linux` (~25 MB) | +25 MB downloaded at runtime, **or** keep relying on system python3 / system yt-dlp |

The "Linux" line is the one tradeoff: we currently rely on the user's system python3 and ship nothing. Switching to the binary on Linux too would mean a +25 MB first-run download but removes the system-python dependency. Could be either / configurable.

**Caveats**:
- macOS support floor: yt-dlp's universal2 build requires macOS 10.15+. Older Macs need the deprecated `yt-dlp_macos_legacy` (discontinued in August 2025, see [yt-dlp#13856](https://github.com/yt-dlp/yt-dlp/issues/13856)) — but the existing CMake bundle is already arm64-only, so this is not a regression.
- yt-dlp now requires Python 3.10+; if the user's system Python is too old on Linux, the script-based approach silently breaks. The binary doesn't have that issue.

### 2. python-build-standalone `install_only_stripped`

Same source we use today, but the `_stripped` variant of `install_only` (debug symbols removed). [Their own size table](https://github.com/astral-sh/python-build-standalone/releases) shows the macOS arm64 difference is **~0.1 MB** between the two — most of the bundle weight is the stdlib `.py` / `.so` files, not symbols.

Worth doing as a one-character config change (URL suffix `+install_only_stripped` instead of `+install_only`), but it doesn't move the needle alone.

### 3. Apple system Python

`/usr/bin/python3` exists on macOS but is an Xcode stub that pops up a "command line tools" installer on first use. Not viable for shipping.

### 4. Homebrew / MacPorts Python

Reliable but requires the user to install brew first. Not bundleable.

### 5. Embedded interpreter (link libpython, use Py_Initialize)

ClipGrab would have to ship libpython + the stdlib anyway, and would gain nothing over option 1 — yt-dlp still needs a full CPython runtime. Don't.

### 6. MicroPython / RustPython / other Python implementations

Won't run yt-dlp. yt-dlp depends on a long list of stdlib modules (`urllib`, `http`, `ssl`, `email`, `xml`, `asyncio`, `multiprocessing`, `sqlite3`, …) and on third-party C-extension wheels (`brotli`, `mutagen`, `certifi`, `pycryptodome` for some extractors). Only mainline CPython works.

### 7. Build our own custom CPython

Strip stdlib modules at the configure step, link statically, etc. Achievable but huge maintenance burden — we'd be tracking upstream Python security patches by hand. Astral already does this with python-build-standalone; using their builds is the same thing without the maintenance.

### 8. Nuitka-compiled yt-dlp

Compile yt-dlp to native code with Nuitka. Possible but bespoke — yt-dlp itself is built with PyInstaller upstream; using Nuitka means we'd be the only ones doing it, with all the maintenance that implies. [Comparisons](https://coderslegacy.com/nuitka-vs-pyinstaller/) show Nuitka bundles usually end up larger than PyInstaller ones for the same code anyway.

## Recommendation

Switch to option 1 — use yt-dlp's own PyInstaller binaries. Concrete changes:

1. **`cmake/PrepareDependencies.cmake`**: remove the macOS Python framework download and the Windows Python embeddable download. Optionally keep a Linux yt-dlp binary download.
2. **`ClipGrab::downloadYoutubeDl` in `clipgrab.cpp`**: change the URL to the per-OS binary, and the target filename (`yt-dlp_macos`, `yt-dlp.exe`, `yt-dlp_linux`). `chmod +x` after download on macOS/Linux.
3. **`YoutubeDl::find` / `instance` in `youtube_dl.cpp`**: drop the `program = python3` + `arguments = [script, ...]` rewrite. Just spawn the binary directly. The macOS PATH augmentation for deno can stay (still needed for the JS-runtime side of things).
4. **CI workflow `.github/workflows/ci.yml`**: drop the macOS Python framework splice and the Windows Python embed copy from the Stage steps.
5. **Macro bundle dir layout doesn't need to change** — yt-dlp still gets fetched at runtime to the same `AppDataLocation/yt-dlp` path; only the URL and the spawn invocation differ.

This eliminates the largest non-Qt component of the bundle and simplifies the dep-prep script. It also means yt-dlp's own self-update (`yt-dlp -U`) and the periodic auto-rebuilds work transparently — we're using exactly what yt-dlp ships.

## Quick numbers

Current macOS arm64 release bundle is ~211 MB compressed (~800 MB unzipped on the user's machine). The Python framework is on the order of 25–30% of that. Removing it gets the .dmg from ~211 MB to roughly ~155 MB compressed without changing anything Qt-side, and the unzipped .app drops by another ~80–100 MB.

Combined with the QtWebEngine removal on the `claude/remove-webengine` branch (~150 MB Chromium core gone), the practical floor for the macOS bundle should sit around 60–80 MB compressed — basically Qt frameworks + ffmpeg + deno.

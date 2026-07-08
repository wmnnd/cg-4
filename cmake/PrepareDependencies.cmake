# Downloads and stages the bundled runtime dependencies for ClipGrab.
#
# Usage:
#   cmake -P cmake/PrepareDependencies.cmake [-DEXTERNAL_DIR=<path>]
#
# On Windows: fetches a static ffmpeg build (BtbN) and the deno JS runtime.
# On macOS:   fetches static ffmpeg (Martin Riedl) and the deno JS runtime
#             for BOTH arm64 and x86_64 and lipo-merges each pair into a
#             universal binary, matching the universal2 app build.
# On Linux:   no-op. ClipGrab on Linux uses system ffmpeg.
#
# Python is no longer downloaded here: yt-dlp's own PyInstaller binaries
# (yt-dlp_macos, yt-dlp.exe) are fetched at app runtime instead, which
# already bundle CPython + the stdlib subset they need.
#
# Each archive is fetched into <EXTERNAL_DIR>/cache/, verified against a
# pinned SHA256, and extracted into a platform-specific subdirectory of
# <EXTERNAL_DIR>. The CI workflow then copies the extracted files next to the
# built clipgrab binary.

cmake_minimum_required(VERSION 3.20)

# ---------------------------------------------------------------------------
# Pinned versions and checksums.
#
# To bump a version:
#   1. Update the URL and version variables.
#   2. Set the corresponding _SHA256 to "" and run this script once.
#   3. The script prints the computed SHA256 — paste it back as the pinned
#      value so subsequent builds are verified.
# ---------------------------------------------------------------------------

# BtbN's "latest" tag is rebuilt nightly. When the upstream zip changes the
# SHA below will no longer match and this script will fail — at that point
# clear the SHA, rerun once, and re-pin to the new value.
set(FFMPEG_WIN_URL
    "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip")
# TODO: pin once verified. First run will print the computed value.
set(FFMPEG_WIN_SHA256 "")

# Martin Riedl publishes per-arch macOS builds with a stable redirect URL
# for the latest release. evermeet.cx is Intel-only so we don't use it.
# Both arches are fetched and lipo-merged into one universal ffmpeg.
set(FFMPEG_MAC_ARM64_URL
    "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip")
# TODO: pin once verified. First run will print the computed value.
set(FFMPEG_MAC_ARM64_SHA256 "")
set(FFMPEG_MAC_X86_64_URL
    "https://ffmpeg.martin-riedl.de/redirect/latest/macos/x86_64/release/ffmpeg.zip")
# TODO: pin once verified. First run will print the computed value.
set(FFMPEG_MAC_X86_64_SHA256 "")

# yt-dlp's YouTube extractor invokes a JS runtime (deno preferred, node
# fallback) for signature deciphering. Without one in PATH, per-language
# combined HLS formats disappear from the picker, so we ship deno alongside
# the app on Windows and macOS. Linux relies on whatever the user has.
set(DENO_VERSION "2.7.13")
set(DENO_BASE_URL
    "https://github.com/denoland/deno/releases/download/v${DENO_VERSION}")
set(DENO_WIN_URL    "${DENO_BASE_URL}/deno-x86_64-pc-windows-msvc.zip")
# TODO: pin once verified. First run will print the computed value.
set(DENO_WIN_SHA256 "")
set(DENO_MAC_ARM64_URL    "${DENO_BASE_URL}/deno-aarch64-apple-darwin.zip")
set(DENO_MAC_ARM64_SHA256 "e2e63288d11e3f36855b60d77585844cbc5146600cbc7224e2d9276a35378089")
set(DENO_MAC_X86_64_URL   "${DENO_BASE_URL}/deno-x86_64-apple-darwin.zip")
# TODO: pin once verified. First run will print the computed value.
set(DENO_MAC_X86_64_SHA256 "")

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------

if(NOT DEFINED EXTERNAL_DIR)
    set(EXTERNAL_DIR "${CMAKE_CURRENT_LIST_DIR}/../external")
endif()
get_filename_component(EXTERNAL_DIR "${EXTERNAL_DIR}" ABSOLUTE)

set(CACHE_DIR "${EXTERNAL_DIR}/cache")
file(MAKE_DIRECTORY "${CACHE_DIR}")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function(fetch_archive)
    cmake_parse_arguments(ARG "" "NAME;URL;SHA256;DESTINATION" "" ${ARGN})

    set(cached "${CACHE_DIR}/${ARG_NAME}")

    # If the cached file's hash no longer matches what's pinned, refetch.
    if(EXISTS "${cached}" AND ARG_SHA256)
        file(SHA256 "${cached}" existing_hash)
        if(NOT existing_hash STREQUAL ARG_SHA256)
            message(STATUS "Cached ${ARG_NAME} hash mismatch, redownloading")
            file(REMOVE "${cached}")
        endif()
    endif()

    if(NOT EXISTS "${cached}")
        message(STATUS "Downloading ${ARG_URL}")
        if(ARG_SHA256)
            file(DOWNLOAD "${ARG_URL}" "${cached}"
                EXPECTED_HASH SHA256=${ARG_SHA256}
                SHOW_PROGRESS
                STATUS dl_status
                TLS_VERIFY ON)
        else()
            file(DOWNLOAD "${ARG_URL}" "${cached}"
                SHOW_PROGRESS
                STATUS dl_status
                TLS_VERIFY ON)
        endif()
        list(GET dl_status 0 dl_code)
        list(GET dl_status 1 dl_msg)
        if(NOT dl_code EQUAL 0)
            file(REMOVE "${cached}")
            message(FATAL_ERROR "Failed to download ${ARG_URL}: ${dl_msg}")
        endif()
    endif()

    if(NOT ARG_SHA256)
        file(SHA256 "${cached}" computed)
        message(WARNING
            "No SHA256 pinned for ${ARG_NAME}.\n"
            "Computed: ${computed}\n"
            "Paste this into PrepareDependencies.cmake to enable verification.")
    endif()

    file(REMOVE_RECURSE "${ARG_DESTINATION}")
    file(MAKE_DIRECTORY "${ARG_DESTINATION}")
    message(STATUS "Extracting ${ARG_NAME} -> ${ARG_DESTINATION}")
    file(ARCHIVE_EXTRACT
        INPUT "${cached}"
        DESTINATION "${ARG_DESTINATION}")
endfunction()

# lipo-merge per-arch Mach-O binaries into one universal binary at OUTPUT,
# then verify both slices actually made it in. macOS-host only.
function(make_universal)
    cmake_parse_arguments(ARG "" "OUTPUT" "INPUTS" ${ARGN})

    get_filename_component(out_dir "${ARG_OUTPUT}" DIRECTORY)
    file(REMOVE_RECURSE "${out_dir}")
    file(MAKE_DIRECTORY "${out_dir}")

    execute_process(
        COMMAND lipo -create ${ARG_INPUTS} -output "${ARG_OUTPUT}"
        RESULT_VARIABLE lipo_result
        ERROR_VARIABLE lipo_error)
    if(NOT lipo_result EQUAL 0)
        message(FATAL_ERROR "lipo -create failed for ${ARG_OUTPUT}: ${lipo_error}")
    endif()

    execute_process(
        COMMAND lipo -archs "${ARG_OUTPUT}"
        OUTPUT_VARIABLE archs
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT (archs MATCHES "arm64" AND archs MATCHES "x86_64"))
        message(FATAL_ERROR
            "${ARG_OUTPUT} is not universal (archs: ${archs})")
    endif()

    file(CHMOD "${ARG_OUTPUT}" PERMISSIONS
        OWNER_READ OWNER_WRITE OWNER_EXECUTE
        GROUP_READ GROUP_EXECUTE
        WORLD_READ WORLD_EXECUTE)
    message(STATUS "Staged universal binary at ${ARG_OUTPUT} (${archs})")
endfunction()

# ---------------------------------------------------------------------------
# Platform dispatch
# ---------------------------------------------------------------------------

if(CMAKE_HOST_WIN32)
    message(STATUS "Preparing Windows dependencies in ${EXTERNAL_DIR}")

    fetch_archive(
        NAME    "ffmpeg-win64-gpl.zip"
        URL     "${FFMPEG_WIN_URL}"
        SHA256  "${FFMPEG_WIN_SHA256}"
        DESTINATION "${EXTERNAL_DIR}/ffmpeg-extracted")

    # BtbN's archive has a versioned top-level directory; locate the ffmpeg
    # binary inside and stage it at a predictable path for the CI workflow.
    file(GLOB_RECURSE found_ffmpeg
        "${EXTERNAL_DIR}/ffmpeg-extracted/*/bin/ffmpeg.exe")
    if(NOT found_ffmpeg)
        message(FATAL_ERROR
            "Could not locate ffmpeg.exe under ${EXTERNAL_DIR}/ffmpeg-extracted")
    endif()
    list(GET found_ffmpeg 0 ffmpeg_exe)
    file(REMOVE_RECURSE "${EXTERNAL_DIR}/ffmpeg-bin")
    file(MAKE_DIRECTORY "${EXTERNAL_DIR}/ffmpeg-bin")
    file(COPY "${ffmpeg_exe}" DESTINATION "${EXTERNAL_DIR}/ffmpeg-bin/")
    message(STATUS "Staged ffmpeg.exe at ${EXTERNAL_DIR}/ffmpeg-bin/ffmpeg.exe")

    fetch_archive(
        NAME    "deno-${DENO_VERSION}-win64.zip"
        URL     "${DENO_WIN_URL}"
        SHA256  "${DENO_WIN_SHA256}"
        DESTINATION "${EXTERNAL_DIR}/deno-bin")
    message(STATUS "Staged deno ${DENO_VERSION} at ${EXTERNAL_DIR}/deno-bin/deno.exe")

elseif(CMAKE_HOST_APPLE)
    # The app ships as a universal2 bundle, so the bundled tools must be
    # universal too: fetch each upstream's arm64 and x86_64 builds and
    # lipo-merge them. (The arch list is hardcoded rather than probed since
    # CMAKE_HOST_SYSTEM_PROCESSOR is empty in `cmake -P` script mode anyway.)
    message(STATUS "Preparing macOS (universal2) dependencies in ${EXTERNAL_DIR}")

    # --- ffmpeg: per-arch zips, each containing one `ffmpeg` at the root ---
    fetch_archive(
        NAME    "ffmpeg-macos-arm64.zip"
        URL     "${FFMPEG_MAC_ARM64_URL}"
        SHA256  "${FFMPEG_MAC_ARM64_SHA256}"
        DESTINATION "${EXTERNAL_DIR}/ffmpeg-extracted-arm64")
    fetch_archive(
        NAME    "ffmpeg-macos-x86_64.zip"
        URL     "${FFMPEG_MAC_X86_64_URL}"
        SHA256  "${FFMPEG_MAC_X86_64_SHA256}"
        DESTINATION "${EXTERNAL_DIR}/ffmpeg-extracted-x86_64")

    set(ffmpeg_slices "")
    foreach(arch arm64 x86_64)
        file(GLOB_RECURSE found_ffmpeg "${EXTERNAL_DIR}/ffmpeg-extracted-${arch}/ffmpeg")
        if(NOT found_ffmpeg)
            message(FATAL_ERROR
                "Could not locate ffmpeg binary under ${EXTERNAL_DIR}/ffmpeg-extracted-${arch}")
        endif()
        list(GET found_ffmpeg 0 ffmpeg_exe)
        list(APPEND ffmpeg_slices "${ffmpeg_exe}")
    endforeach()
    make_universal(
        OUTPUT "${EXTERNAL_DIR}/ffmpeg-bin/ffmpeg"
        INPUTS ${ffmpeg_slices})

    # --- deno: per-arch zips, each containing one `deno` at the root -------
    fetch_archive(
        NAME    "deno-${DENO_VERSION}-macos-arm64.zip"
        URL     "${DENO_MAC_ARM64_URL}"
        SHA256  "${DENO_MAC_ARM64_SHA256}"
        DESTINATION "${EXTERNAL_DIR}/deno-extracted-arm64")
    fetch_archive(
        NAME    "deno-${DENO_VERSION}-macos-x86_64.zip"
        URL     "${DENO_MAC_X86_64_URL}"
        SHA256  "${DENO_MAC_X86_64_SHA256}"
        DESTINATION "${EXTERNAL_DIR}/deno-extracted-x86_64")

    set(deno_slices "")
    foreach(arch arm64 x86_64)
        file(GLOB found_deno "${EXTERNAL_DIR}/deno-extracted-${arch}/deno")
        if(NOT found_deno)
            message(FATAL_ERROR
                "Could not locate deno binary in ${EXTERNAL_DIR}/deno-extracted-${arch}")
        endif()
        list(GET found_deno 0 deno_bin)
        list(APPEND deno_slices "${deno_bin}")
    endforeach()
    make_universal(
        OUTPUT "${EXTERNAL_DIR}/deno-bin/deno"
        INPUTS ${deno_slices})

elseif(CMAKE_HOST_UNIX)
    message(STATUS "Linux build: no bundled runtime dependencies "
                   "(system ffmpeg and python3 are used)")
else()
    message(FATAL_ERROR "Unsupported host platform")
endif()

message(STATUS "Dependencies prepared at: ${EXTERNAL_DIR}")

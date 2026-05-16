# Downloads and stages the bundled runtime dependencies for ClipGrab.
#
# Usage:
#   cmake -P cmake/PrepareDependencies.cmake [-DEXTERNAL_DIR=<path>]
#
# On Windows: fetches a static ffmpeg build (BtbN) and the embeddable Python
# distribution from python.org.
# On macOS:   fetches a static ffmpeg build (evermeet.cx). Python framework
#             bundling is not implemented yet; the app falls back to system
#             python3.
# On Linux:   no-op. ClipGrab on Linux uses system ffmpeg and system python3.
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
set(FFMPEG_WIN_SHA256
    "853e0cc1a6d48598851b88a6a3cd6f0bf43b84c260476d864244f212ce04b1f0")

set(FFMPEG_MAC_VERSION "8.1.1")
set(FFMPEG_MAC_URL
    "https://evermeet.cx/ffmpeg/ffmpeg-${FFMPEG_MAC_VERSION}.zip")
# TODO: pin once verified. First run will print the computed value.
set(FFMPEG_MAC_SHA256 "")

set(PYTHON_VERSION "3.13.12")
set(PYTHON_WIN_URL
    "https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-embed-amd64.zip")
set(PYTHON_WIN_SHA256
    "76f238f606250c87c6beac75dccd35ee99070a13490555936abb6cb64ecce3d0")

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
set(DENO_MAC_ARM_URL    "${DENO_BASE_URL}/deno-aarch64-apple-darwin.zip")
set(DENO_MAC_ARM_SHA256 "e2e63288d11e3f36855b60d77585844cbc5146600cbc7224e2d9276a35378089")
set(DENO_MAC_X86_URL    "${DENO_BASE_URL}/deno-x86_64-apple-darwin.zip")
# TODO: pin once verified.
set(DENO_MAC_X86_SHA256 "")

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
        NAME    "python-${PYTHON_VERSION}-embed-amd64.zip"
        URL     "${PYTHON_WIN_URL}"
        SHA256  "${PYTHON_WIN_SHA256}"
        DESTINATION "${EXTERNAL_DIR}/python")
    message(STATUS "Staged Python ${PYTHON_VERSION} at ${EXTERNAL_DIR}/python")

    fetch_archive(
        NAME    "deno-${DENO_VERSION}-win64.zip"
        URL     "${DENO_WIN_URL}"
        SHA256  "${DENO_WIN_SHA256}"
        DESTINATION "${EXTERNAL_DIR}/deno-bin")
    message(STATUS "Staged deno ${DENO_VERSION} at ${EXTERNAL_DIR}/deno-bin/deno.exe")

elseif(CMAKE_HOST_APPLE)
    message(STATUS "Preparing macOS dependencies in ${EXTERNAL_DIR}")

    fetch_archive(
        NAME    "ffmpeg-${FFMPEG_MAC_VERSION}-macos.zip"
        URL     "${FFMPEG_MAC_URL}"
        SHA256  "${FFMPEG_MAC_SHA256}"
        DESTINATION "${EXTERNAL_DIR}/ffmpeg-extracted")

    # evermeet.cx ships a single executable in the zip. Stage it the same
    # way as on Windows.
    file(GLOB_RECURSE found_ffmpeg "${EXTERNAL_DIR}/ffmpeg-extracted/ffmpeg")
    if(NOT found_ffmpeg)
        message(FATAL_ERROR
            "Could not locate ffmpeg binary under ${EXTERNAL_DIR}/ffmpeg-extracted")
    endif()
    list(GET found_ffmpeg 0 ffmpeg_exe)
    file(REMOVE_RECURSE "${EXTERNAL_DIR}/ffmpeg-bin")
    file(MAKE_DIRECTORY "${EXTERNAL_DIR}/ffmpeg-bin")
    file(COPY "${ffmpeg_exe}"
        DESTINATION "${EXTERNAL_DIR}/ffmpeg-bin/"
        FILE_PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
                         GROUP_READ GROUP_EXECUTE
                         WORLD_READ WORLD_EXECUTE)
    message(STATUS "Staged ffmpeg at ${EXTERNAL_DIR}/ffmpeg-bin/ffmpeg")

    # Pick the deno binary that matches the host architecture. macos-latest
    # GHA runners are Apple Silicon; the x86_64 fallback covers Intel macs.
    if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
        set(deno_url    "${DENO_MAC_ARM_URL}")
        set(deno_sha256 "${DENO_MAC_ARM_SHA256}")
        set(deno_arch   "aarch64")
    else()
        set(deno_url    "${DENO_MAC_X86_URL}")
        set(deno_sha256 "${DENO_MAC_X86_SHA256}")
        set(deno_arch   "x86_64")
    endif()
    fetch_archive(
        NAME    "deno-${DENO_VERSION}-macos-${deno_arch}.zip"
        URL     "${deno_url}"
        SHA256  "${deno_sha256}"
        DESTINATION "${EXTERNAL_DIR}/deno-extracted")
    file(GLOB found_deno "${EXTERNAL_DIR}/deno-extracted/deno")
    if(NOT found_deno)
        message(FATAL_ERROR "Could not locate deno binary in extracted archive")
    endif()
    list(GET found_deno 0 deno_bin)
    file(REMOVE_RECURSE "${EXTERNAL_DIR}/deno-bin")
    file(MAKE_DIRECTORY "${EXTERNAL_DIR}/deno-bin")
    file(COPY "${deno_bin}"
        DESTINATION "${EXTERNAL_DIR}/deno-bin/"
        FILE_PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
                         GROUP_READ GROUP_EXECUTE
                         WORLD_READ WORLD_EXECUTE)
    message(STATUS "Staged deno (${deno_arch}) at ${EXTERNAL_DIR}/deno-bin/deno")

    # TODO: bundle Python on macOS via astral-sh/python-build-standalone.
    # The app already falls back to system python3, so this is non-blocking
    # for the PoC.

elseif(CMAKE_HOST_UNIX)
    message(STATUS "Linux build: no bundled runtime dependencies "
                   "(system ffmpeg and python3 are used)")
else()
    message(FATAL_ERROR "Unsupported host platform")
endif()

message(STATUS "Dependencies prepared at: ${EXTERNAL_DIR}")

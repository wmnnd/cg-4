# 3.16 is the minimum Qt 6 supports (and documents) for its CMake API.
cmake_minimum_required(VERSION 3.16)

# The single place the version is defined. Everything else derives from it:
# the CLIPGRAB_VERSION compile definition (app UI + update check), the
# Info.plist version keys, the CI artifact/volume names, and the numeric
# project() version below. Pre-release suffixes like -beta1 are supported
# here; project(VERSION) only accepts plain x.y.z, so the numeric prefix is
# extracted for it automatically.
set(CLIPGRAB_VERSION 4.0.0-beta1)

string(REGEX MATCH "^[0-9]+\\.[0-9]+(\\.[0-9]+)?" CLIPGRAB_VERSION_NUMERIC "${CLIPGRAB_VERSION}")
if(NOT CLIPGRAB_VERSION_NUMERIC)
    message(FATAL_ERROR "CLIPGRAB_VERSION must start with x.y[.z], got: ${CLIPGRAB_VERSION}")
endif()
project(clipgrab VERSION ${CLIPGRAB_VERSION_NUMERIC} LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# These three are exactly what qt_standard_project_setup() would turn on. We
# set them by hand rather than call that helper because it requires Qt 6.3+
# and the Linux CI builds against distro Qt 6.2 — this form works everywhere.
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

find_package(Qt6 REQUIRED COMPONENTS
    Core
    Gui
    Widgets
    Network
    Xml
    LinguistTools
)

set(CLIPGRAB_SOURCES
    clipgrab.cpp
    converter.cpp
    converter_copy.cpp
    converter_ffmpeg.cpp
    download_list_model.cpp
    helper_downloader.cpp
    loading_spinner.cpp
    main.cpp
    mainwindow.cpp
    message_dialog.cpp
    notifications.cpp
    video.cpp
    youtube_dl.cpp
)

set(CLIPGRAB_HEADERS
    clipgrab.h
    converter.h
    converter_copy.h
    converter_ffmpeg.h
    download_list_model.h
    helper_downloader.h
    loading_spinner.h
    mac_colorspace.h
    mainwindow.h
    message_dialog.h
    notifications.h
    video.h
    youtube_dl.h
)

set(CLIPGRAB_FORMS
    helper_downloader.ui
    mainwindow.ui
    message_dialog.ui
    metadata-dialog.ui
    update_message.ui
)

set(CLIPGRAB_TS_FILES
    clipgrab_bg.ts
    clipgrab_bn.ts
    clipgrab_ca.ts
    clipgrab_cs.ts
    clipgrab_de.ts
    clipgrab_el.ts
    clipgrab_es.ts
    clipgrab_eu.ts
    clipgrab_fa.ts
    clipgrab_fi.ts
    clipgrab_fr.ts
    clipgrab_hr.ts
    clipgrab_hu.ts
    clipgrab_id.ts
    clipgrab_it.ts
    clipgrab_ja.ts
    clipgrab_ko.ts
    clipgrab_lt.ts
    clipgrab_mk.ts
    clipgrab_nl.ts
    clipgrab_no.ts
    clipgrab_pa.ts
    clipgrab_pl.ts
    clipgrab_pt.ts
    clipgrab_ro.ts
    clipgrab_ru.ts
    clipgrab_si.ts
    clipgrab_sr.ts
    clipgrab_strings.ts
    clipgrab_sv.ts
    clipgrab_sw.ts
    clipgrab_tr.ts
    clipgrab_vi.ts
    clipgrab_zh.ts
)

if(WIN32)
    set(CLIPGRAB_PLATFORM_SOURCES windows_icon.rc)
elseif(APPLE)
    # mac_colorspace.mm is Objective-C++ (AppKit) — only built on macOS.
    set(CLIPGRAB_PLATFORM_SOURCES clipgrab.icns mac_colorspace.mm)
    set_source_files_properties(clipgrab.icns PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
endif()

qt_add_executable(clipgrab
    ${CLIPGRAB_SOURCES}
    ${CLIPGRAB_HEADERS}
    ${CLIPGRAB_FORMS}
    resources.qrc
    ${CLIPGRAB_PLATFORM_SOURCES}
)

target_compile_definitions(clipgrab PRIVATE
    CLIPGRAB_VERSION="${CLIPGRAB_VERSION}"
)

target_include_directories(clipgrab PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}
)

target_link_libraries(clipgrab PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Widgets
    Qt6::Network
    Qt6::Xml
)

# GUI app: build against the Windows GUI subsystem so no console window opens.
# (Ignored on other platforms.)
set_target_properties(clipgrab PROPERTIES WIN32_EXECUTABLE TRUE)

if(APPLE)
    # ClipGrab.plist is a template: CMake substitutes the
    # ${MACOSX_BUNDLE_*} placeholders below from these target properties
    # when it generates the bundle's Info.plist, so the version lands there
    # from the one CLIPGRAB_VERSION definition above.
    set_target_properties(clipgrab PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ClipGrab.plist"
        MACOSX_BUNDLE_BUNDLE_NAME "ClipGrab"
        MACOSX_BUNDLE_ICON_FILE "clipgrab.icns"
        MACOSX_BUNDLE_BUNDLE_VERSION "${CLIPGRAB_VERSION}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${CLIPGRAB_VERSION}"
        OUTPUT_NAME "ClipGrab"
    )
    target_link_libraries(clipgrab PRIVATE "-framework AppKit" "-framework Foundation")
endif()

qt_add_translations(clipgrab TS_FILES ${CLIPGRAB_TS_FILES})

# Convenience target so configured trees can also fetch deps via:
#   cmake --build build --target prepare-dependencies
# Standalone equivalent (no configure step needed):
#   cmake -P cmake/PrepareDependencies.cmake
# Guarded because that script is a private packaging file: it's absent from
# the scrubbed open-source tree, and a plain source build never needs it.
if(EXISTS "${CMAKE_SOURCE_DIR}/cmake/PrepareDependencies.cmake")
    add_custom_target(prepare-dependencies
        COMMAND ${CMAKE_COMMAND}
            -DEXTERNAL_DIR=${CMAKE_SOURCE_DIR}/external
            -P ${CMAKE_SOURCE_DIR}/cmake/PrepareDependencies.cmake
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "Fetching ffmpeg / deno runtime dependencies"
        VERBATIM
    )
endif()

install(TARGETS clipgrab
    BUNDLE DESTINATION .
    RUNTIME DESTINATION bin
)

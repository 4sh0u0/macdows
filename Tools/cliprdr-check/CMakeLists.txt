cmake_minimum_required(VERSION 3.15)
project(cliprdr-check C)

# An offline check, not a client (adr/0026 lane L3): cliprdr-check.c loads the built-in cliprdr
# channel of a FreeRDP install prefix, attaches the App's clipboard bridge to it -- the bridge's own
# source file, App/CRBridge/crclip_bridge.c, compiled in here unchanged with the CRDPQueue sources
# it posts to -- and feeds it server PDUs made by FreeRDP's own server-side cliprdr encoder, whose
# two vendored source files are compiled in as well. Scripts/test-cliprdr.sh is its one caller
# (Tier 2 runs it after Bootstrap). Not part of the Xcode project. The pkg-config and rpath steps
# are Tools/rail-handshake-check/CMakeLists.txt's, for the same reason: the wrapper passes the
# prefix's PHYSICAL path, so the rpath, the build directory and the binary's loaded-from-prefix
# guard all name the one config-hash directory being judged.
#
# CLIPRDR_CHECK_SANITIZER=thread|address builds the whole binary (this tool, the bridge, the
# CRDPQueue sources, the two upstream encoder files) with that sanitizer; the prefix's libraries
# stay as they were built.

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

if(NOT DEFINED FREERDP_PREFIX)
  message(FATAL_ERROR
    "FREERDP_PREFIX is not set. Pass -DFREERDP_PREFIX=<path to a FreeRDP install prefix>; "
    "Scripts/test-cliprdr.sh sets this automatically.")
endif()
if(NOT EXISTS "${FREERDP_PREFIX}/lib/pkgconfig")
  message(FATAL_ERROR
    "${FREERDP_PREFIX}/lib/pkgconfig does not exist -- did Scripts/build-freerdp.sh "
    "run and install successfully for this prefix?")
endif()

get_filename_component(CC_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
if(NOT DEFINED FREERDP_SOURCE)
  set(FREERDP_SOURCE "${CC_REPO_ROOT}/ThirdParty/FreeRDP")
endif()
set(CC_CLIPRDR_SOURCE "${FREERDP_SOURCE}/channels/cliprdr")
if(NOT EXISTS "${CC_CLIPRDR_SOURCE}/server/cliprdr_main.c" OR NOT EXISTS "${CC_CLIPRDR_SOURCE}/cliprdr_common.c")
  message(FATAL_ERROR
    "${CC_CLIPRDR_SOURCE} does not hold the vendored cliprdr sources -- is the ThirdParty/FreeRDP "
    "submodule checked out?")
endif()

# Captured before pkg_check_modules(FREERDP ...) defines its own FREERDP_PREFIX from the .pc file.
set(CC_FREERDP_PREFIX "${FREERDP_PREFIX}")
set(ENV{PKG_CONFIG_PATH} "${CC_FREERDP_PREFIX}/lib/pkgconfig")

find_package(PkgConfig REQUIRED)
pkg_check_modules(FREERDP REQUIRED freerdp3)
pkg_check_modules(FREERDP_CLIENT REQUIRED freerdp-client3)
pkg_check_modules(WINPR REQUIRED winpr3)

set(CC_UPSTREAM_SOURCES
  "${CC_CLIPRDR_SOURCE}/server/cliprdr_main.c"
  "${CC_CLIPRDR_SOURCE}/cliprdr_common.c"
)

add_executable(cliprdr-check
  cliprdr-check.c
  "${CC_REPO_ROOT}/App/CRBridge/crclip_bridge.c"
  "${CC_REPO_ROOT}/Packages/MacdowsCore/Sources/CRDPQueue/crdpq_control.c"
  "${CC_REPO_ROOT}/Packages/MacdowsCore/Sources/CRDPQueue/crdpq_outbound.c"
  "${CC_REPO_ROOT}/Packages/MacdowsCore/Sources/CRDPQueue/crdpq_clip.c"
  ${CC_UPSTREAM_SOURCES}
)

target_include_directories(cliprdr-check PRIVATE
  "${CC_REPO_ROOT}/App/CRBridge"
  "${CC_REPO_ROOT}/Packages/MacdowsCore/Sources/CRDPQueue/include"
  "${CC_CLIPRDR_SOURCE}"
  ${FREERDP_CLIENT_INCLUDE_DIRS}
  ${FREERDP_INCLUDE_DIRS}
  ${WINPR_INCLUDE_DIRS}
)

target_compile_options(cliprdr-check PRIVATE
  ${FREERDP_CLIENT_CFLAGS_OTHER}
  ${FREERDP_CFLAGS_OTHER}
  ${WINPR_CFLAGS_OTHER}
)
# Warnings are this repository's business for its own files, not for the two upstream files.
set_source_files_properties(cliprdr-check.c "${CC_REPO_ROOT}/App/CRBridge/crclip_bridge.c"
  PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra")
set_source_files_properties(${CC_UPSTREAM_SOURCES} PROPERTIES COMPILE_OPTIONS "-w")

if(DEFINED CLIPRDR_CHECK_SANITIZER AND NOT CLIPRDR_CHECK_SANITIZER STREQUAL "")
  if(NOT CLIPRDR_CHECK_SANITIZER MATCHES "^(thread|address)$")
    message(FATAL_ERROR "CLIPRDR_CHECK_SANITIZER must be thread or address")
  endif()
  target_compile_options(cliprdr-check PRIVATE -fsanitize=${CLIPRDR_CHECK_SANITIZER} -fno-omit-frame-pointer)
  target_link_options(cliprdr-check PRIVATE -fsanitize=${CLIPRDR_CHECK_SANITIZER})
endif()

target_link_directories(cliprdr-check PRIVATE
  ${FREERDP_CLIENT_LIBRARY_DIRS}
  ${FREERDP_LIBRARY_DIRS}
  ${WINPR_LIBRARY_DIRS}
)

target_link_libraries(cliprdr-check PRIVATE
  ${FREERDP_CLIENT_LIBRARIES}
  ${FREERDP_LIBRARIES}
  ${WINPR_LIBRARIES}
)

# rpath: rail-handshake-check's derivation and guard, unchanged (see that file).
get_filename_component(CC_BUILD_ROOT "${CC_FREERDP_PREFIX}/../../.." ABSOLUTE)
set(CC_FFMPEG_LIB_DIR "${CC_BUILD_ROOT}/deps/ffmpeg-prefix/lib")
set(CC_RPATH "${CC_FREERDP_PREFIX}/lib")
if(IS_DIRECTORY "${CC_BUILD_ROOT}/freerdp" AND IS_DIRECTORY "${CC_FFMPEG_LIB_DIR}")
  list(APPEND CC_RPATH "${CC_FFMPEG_LIB_DIR}")
else()
  message(STATUS
    "cliprdr-check: ${CC_BUILD_ROOT} does not look like this repo's build root with an ffmpeg "
    "prefix at deps/ffmpeg-prefix/lib, so nothing was added to the rpath for it.")
endif()

set_target_properties(cliprdr-check PROPERTIES
  INSTALL_RPATH "${CC_RPATH}"
  BUILD_WITH_INSTALL_RPATH TRUE
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
)

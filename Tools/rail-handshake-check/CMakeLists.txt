cmake_minimum_required(VERSION 3.15)
project(rail-handshake-check C)

# An offline check, not a client: rail-handshake-check.c loads the built-in RAIL channel of a
# FreeRDP install prefix and drives its default handshake answer with no connection at all.
# Scripts/test-rail-handshake.sh is its one caller (Tier 2 runs it after Bootstrap). Not part of
# the Xcode project. The pkg-config and rpath steps follow Tools/rail-probe/CMakeLists.txt, with
# one deliberate difference in what FREERDP_PREFIX is. rail-probe keeps the caller's LEXICAL
# spelling and argues against resolving it first (in a worktree, walking up from the resolved
# path names the main checkout's .build). The wrapper here passes the prefix's PHYSICAL path on
# purpose: this check judges one config-hash directory, and `current` is a moving link, so the
# rpath, the build directory and the binary's loaded-from-prefix guard must all name that
# directory. The ffmpeg found three levels up from the physical path is the one that prefix was
# built against (the same physical build root) -- in a worktree whose .build/freerdp and
# .build/deps link into the main checkout, that is the main checkout's, which is where both
# libraries really are.

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

if(NOT DEFINED FREERDP_PREFIX)
  message(FATAL_ERROR
    "FREERDP_PREFIX is not set. Pass -DFREERDP_PREFIX=<path to a FreeRDP install prefix>; "
    "Scripts/test-rail-handshake.sh sets this automatically.")
endif()
if(NOT EXISTS "${FREERDP_PREFIX}/lib/pkgconfig")
  message(FATAL_ERROR
    "${FREERDP_PREFIX}/lib/pkgconfig does not exist -- did Scripts/build-freerdp.sh "
    "run and install successfully for this prefix?")
endif()

# Captured before pkg_check_modules(FREERDP ...) defines its own FREERDP_PREFIX from the .pc file.
set(RHC_FREERDP_PREFIX "${FREERDP_PREFIX}")
set(ENV{PKG_CONFIG_PATH} "${RHC_FREERDP_PREFIX}/lib/pkgconfig")

find_package(PkgConfig REQUIRED)
pkg_check_modules(FREERDP REQUIRED freerdp3)
pkg_check_modules(FREERDP_CLIENT REQUIRED freerdp-client3)
pkg_check_modules(WINPR REQUIRED winpr3)

add_executable(rail-handshake-check rail-handshake-check.c)

target_include_directories(rail-handshake-check PRIVATE
  ${FREERDP_CLIENT_INCLUDE_DIRS}
  ${FREERDP_INCLUDE_DIRS}
  ${WINPR_INCLUDE_DIRS}
)

target_compile_options(rail-handshake-check PRIVATE
  ${FREERDP_CLIENT_CFLAGS_OTHER}
  ${FREERDP_CFLAGS_OTHER}
  ${WINPR_CFLAGS_OTHER}
  -Wall
  -Wextra
)

target_link_directories(rail-handshake-check PRIVATE
  ${FREERDP_CLIENT_LIBRARY_DIRS}
  ${FREERDP_LIBRARY_DIRS}
  ${WINPR_LIBRARY_DIRS}
)

target_link_libraries(rail-handshake-check PRIVATE
  ${FREERDP_CLIENT_LIBRARIES}
  ${FREERDP_LIBRARIES}
  ${WINPR_LIBRARIES}
)

# rpath: the prefix's own lib dir, plus the self-built ffmpeg that libfreerdp3 loads through
# @rpath, found three levels up and across from the prefix (freerdp/<hash>/prefix next to
# deps/ffmpeg-prefix under one build root, Scripts/lib.sh) -- rail-probe's derivation and guard,
# applied to the physical path the wrapper passes (see the top of this file for why), so the
# rpath names the config-hash directory the check is about, never the moving `current` link.
get_filename_component(RHC_BUILD_ROOT "${RHC_FREERDP_PREFIX}/../../.." ABSOLUTE)
set(RHC_FFMPEG_LIB_DIR "${RHC_BUILD_ROOT}/deps/ffmpeg-prefix/lib")
set(RHC_RPATH "${RHC_FREERDP_PREFIX}/lib")
if(IS_DIRECTORY "${RHC_BUILD_ROOT}/freerdp" AND IS_DIRECTORY "${RHC_FFMPEG_LIB_DIR}")
  list(APPEND RHC_RPATH "${RHC_FFMPEG_LIB_DIR}")
else()
  message(STATUS
    "rail-handshake-check: ${RHC_BUILD_ROOT} does not look like this repo's build root with an "
    "ffmpeg prefix at deps/ffmpeg-prefix/lib, so nothing was added to the rpath for it. "
    "Harmless for a FreeRDP built without ffmpeg -- but if the binary aborts in dyld on "
    "@rpath/libavcodec, this is the line that decided it could not help.")
endif()

set_target_properties(rail-handshake-check PROPERTIES
  INSTALL_RPATH "${RHC_RPATH}"
  BUILD_WITH_INSTALL_RPATH TRUE
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
)

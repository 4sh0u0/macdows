cmake_minimum_required(VERSION 3.15)
project(rail-probe C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

if(NOT DEFINED FREERDP_PREFIX)
  message(FATAL_ERROR
    "FREERDP_PREFIX is not set. Pass -DFREERDP_PREFIX=<path to a FreeRDP install prefix>, "
    "e.g. the repo root's .build/freerdp/current/prefix produced by Scripts/build-freerdp.sh. "
    "Scripts/probe.sh sets this automatically.")
endif()
if(NOT EXISTS "${FREERDP_PREFIX}/lib/pkgconfig")
  message(FATAL_ERROR
    "${FREERDP_PREFIX}/lib/pkgconfig does not exist — did Scripts/build-freerdp.sh "
    "run and install successfully for this prefix?")
endif()

# The caller's FREERDP_PREFIX, captured before pkg_check_modules can shadow it.
# pkg_check_modules(FREERDP ...) defines FREERDP_PREFIX itself -- the .pc file's own
# `prefix=` variable, which freerdp3.pc spells relative to the file
# (`${pcfiledir}/../..`) -- so from that call onwards the -D the caller passed is gone.
# With the vendored freerdp3.pc the two spellings collapse to the same directory, so nothing
# below has noticed yet -- this is defensive, not corrective. They stop being interchangeable
# the moment a .pc spells `prefix=` with a different depth or as an unrelated absolute path --
# a Homebrew prefix reached as /opt/homebrew/opt/freerdp has its own Cellar path in there --
# and the ffmpeg lib dir at the bottom of this file is derived by walking *up* from the
# prefix, i.e. it would then be derived from the wrong place. That is the same foreign-prefix
# case the IS_DIRECTORY guard down there exists for. Anything here that treats the prefix as a
# location therefore reads this variable, not the one pkg-config leaves behind.
set(RAILPROBE_FREERDP_PREFIX "${FREERDP_PREFIX}")

# Point pkg-config at the vendored prefix instead of relying on a caller-set
# PKG_CONFIG_PATH environment variable (that's what the original lab prototype did).
set(ENV{PKG_CONFIG_PATH} "${RAILPROBE_FREERDP_PREFIX}/lib/pkgconfig")

find_package(PkgConfig REQUIRED)
pkg_check_modules(FREERDP REQUIRED freerdp3)
pkg_check_modules(FREERDP_CLIENT REQUIRED freerdp-client3)
pkg_check_modules(WINPR REQUIRED winpr3)

add_executable(rail-probe rail-probe.c)

target_include_directories(rail-probe PRIVATE
  ${FREERDP_CLIENT_INCLUDE_DIRS}
  ${FREERDP_INCLUDE_DIRS}
  ${WINPR_INCLUDE_DIRS}
)

target_compile_options(rail-probe PRIVATE
  ${FREERDP_CLIENT_CFLAGS_OTHER}
  ${FREERDP_CFLAGS_OTHER}
  ${WINPR_CFLAGS_OTHER}
  -Wall
  -Wextra
)

target_link_directories(rail-probe PRIVATE
  ${FREERDP_CLIENT_LIBRARY_DIRS}
  ${FREERDP_LIBRARY_DIRS}
  ${WINPR_LIBRARY_DIRS}
)

target_link_libraries(rail-probe PRIVATE
  ${FREERDP_CLIENT_LIBRARIES}
  ${FREERDP_LIBRARIES}
  ${WINPR_LIBRARIES}
  pthread
)

# W8 gave the vendored libfreerdp3 three `@rpath/libav*.dylib` load commands -- libavcodec,
# libavutil, libswresample, from the self-built LGPL ffmpeg that Scripts/build-ffmpeg.sh
# installs -- so the FreeRDP prefix alone stopped being a complete runtime search path: dyld
# aborts before main() is entered with "Library not loaded: @rpath/libavcodec...", which
# means Scripts/probe.sh builds a binary it cannot then exec. App/project.yml answers the
# same breakage for the XcodeGen tool targets by putting
# $(SRCROOT)/../.build/deps/ffmpeg-prefix/lib on LD_RUNPATH_SEARCH_PATHS (see the comment
# there on bridge-smoke's copy for the project's canonical explanation); this is that entry
# for the one tool target built outside XcodeGen.
#
# Derived, not hardcoded: Scripts/lib.sh keeps both prefixes under one build root
# (CRDP_BUILD_DIR) as siblings -- freerdp/<config-hash>/prefix and deps/ffmpeg-prefix -- so
# whichever FreeRDP prefix probe.sh hands us, the ffmpeg it was linked against is three
# levels up and across. Lexical, not filesystem (ABSOLUTE): the derivation is a statement
# about the layout Scripts/lib.sh builds, so it collapses `..` textually and keeps the
# caller's own spelling of the build root -- the same string Scripts/lib.sh derives
# CRDP_FFMPEG_PREFIX from. REALPATH would collapse the `..` textually too and land on the
# identical string here; the variant that would differ is resolving the prefix *first* and
# then walking up, which in a git worktree follows .build/freerdp into the main checkout and
# names a prefix in a tree the caller never mentioned. Symlinks along the way are dyld's
# business at load time, not ours.
get_filename_component(RAILPROBE_BUILD_ROOT "${RAILPROBE_FREERDP_PREFIX}/../../.." ABSOLUTE)
set(RAILPROBE_FFMPEG_LIB_DIR "${RAILPROBE_BUILD_ROOT}/deps/ffmpeg-prefix/lib")

# rpath into the caller's FreeRDP prefix so the built binary runs without DYLD_LIBRARY_PATH
# gymnastics, regardless of which config-hash directory it was built against; plus the ffmpeg
# lib dir above, appended only when the layout it was derived from is really there.
#
# The guard checks the assumption as well as the conclusion. `deps/ffmpeg-prefix/lib` exists
# is the conclusion; `freerdp/` alongside it is the assumption -- that the directory three
# levels up is the build root this prefix came out of, and not some unrelated parent that
# happens to own a directory of the right name. So a FreeRDP prefix from somewhere else
# (Homebrew, a system install) and a future change to build-freerdp.sh's depth land in the
# same diagnosable branch: nothing nonexistent or unrelated is baked into LC_RPATH, and the
# configure log names the directory that was looked for. Such prefixes usually carry no
# @rpath ffmpeg references at all, so the miss is normally harmless -- and when it is not,
# the log line is the first thing the dyld abort sends the reader to.
set(RAILPROBE_RPATH "${RAILPROBE_FREERDP_PREFIX}/lib")
if(IS_DIRECTORY "${RAILPROBE_BUILD_ROOT}/freerdp" AND IS_DIRECTORY "${RAILPROBE_FFMPEG_LIB_DIR}")
  list(APPEND RAILPROBE_RPATH "${RAILPROBE_FFMPEG_LIB_DIR}")
else()
  message(STATUS
    "rail-probe: ${RAILPROBE_BUILD_ROOT} does not look like this repo's build root with an "
    "ffmpeg prefix at deps/ffmpeg-prefix/lib, so nothing was added to the rpath for it. "
    "Harmless for a FreeRDP built without ffmpeg -- but if this binary aborts in dyld on "
    "@rpath/libavcodec, this is the line that decided it could not help.")
endif()

set_target_properties(rail-probe PROPERTIES
  INSTALL_RPATH "${RAILPROBE_RPATH}"
  BUILD_WITH_INSTALL_RPATH TRUE
)

set_target_properties(rail-probe PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")

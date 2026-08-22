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

# Point pkg-config at the vendored prefix instead of relying on a caller-set
# PKG_CONFIG_PATH environment variable (that's what the original lab prototype did).
set(ENV{PKG_CONFIG_PATH} "${FREERDP_PREFIX}/lib/pkgconfig")

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

# rpath into FREERDP_PREFIX so the built binary runs without DYLD_LIBRARY_PATH gymnastics,
# regardless of which config-hash directory it was built against.
set_target_properties(rail-probe PROPERTIES
  INSTALL_RPATH "${FREERDP_PREFIX}/lib"
  BUILD_WITH_INSTALL_RPATH TRUE
)

set_target_properties(rail-probe PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")

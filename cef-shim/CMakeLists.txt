# cef-shim/CMakeLists.txt — builds the Chromium (CEF) shim outside SwiftPM.
#
#   cmake -B build -DCEF_ROOT=/path/to/cef_binary_<ver>_macosarm64_minimal \
#         -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
#   cmake --build build --config Release
#
# Produces:
#   libpeekr_cef.dylib  — the shim the Swift app dlopen()s (implements peekr_cef.h)
#   peekr_helper        — the CEF subprocess executable (wrap into *Helper.app)
#
# On macOS the Chromium Embedded Framework is loaded at RUNTIME (cef_load_library),
# not linked here — only the static libcef_dll_wrapper + system frameworks link.
# NOT compiled by `swift build`.

cmake_minimum_required(VERSION 3.21)
project(peekr_cef CXX)

if(NOT DEFINED CEF_ROOT)
  message(FATAL_ERROR "Set -DCEF_ROOT=/path/to/cef_binary_<ver>_macosarm64[_minimal]")
endif()

set(CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)

# Build the static C++ convenience wrapper from the SDK.
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

# --- The shim Swift dlopen()s ------------------------------------------------
add_library(peekr_cef SHARED src/peekr_cef.mm)
SET_LIBRARY_TARGET_PROPERTIES(peekr_cef)
add_dependencies(peekr_cef libcef_dll_wrapper)
target_include_directories(peekr_cef PRIVATE "${CEF_ROOT}" "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(peekr_cef libcef_dll_wrapper ${CEF_STANDARD_LIBS})

# --- The mandatory helper subprocess -----------------------------------------
add_executable(peekr_helper src/peekr_helper.mm)
SET_EXECUTABLE_TARGET_PROPERTIES(peekr_helper)
add_dependencies(peekr_helper libcef_dll_wrapper)
target_include_directories(peekr_helper PRIVATE "${CEF_ROOT}")
target_link_libraries(peekr_helper libcef_dll_wrapper ${CEF_STANDARD_LIBS})

# --- Runtime smoke harness (build/runtime test only, not shipped) ------------
add_executable(peekr_smoke src/peekr_smoke.mm)
SET_EXECUTABLE_TARGET_PROPERTIES(peekr_smoke)
add_dependencies(peekr_smoke peekr_cef)
target_include_directories(peekr_smoke PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(peekr_smoke peekr_cef ${CEF_STANDARD_LIBS})

PRINT_CEF_CONFIG()

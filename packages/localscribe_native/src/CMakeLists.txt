cmake_minimum_required(VERSION 3.14)
project(localscribe_native LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# whisper.cpp and its bundled ggml are linked statically into our one .so.
set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE            OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP            OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL        OFF CACHE BOOL "" FORCE)

if (ANDROID_ABI STREQUAL "arm64-v8a")
    # FP16 vector arithmetic (ARMv8.2, ~2018+ phones). The Dart side checks
    # /proc/cpuinfo for "asimdhp" before using this library.
    set(GGML_CPU_ARM_ARCH "armv8.2-a+fp16" CACHE STRING "" FORCE)
endif()

set(WHISPER_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/whisper.cpp)
add_subdirectory(${WHISPER_DIR} ${CMAKE_CURRENT_BINARY_DIR}/whisper.cpp EXCLUDE_FROM_ALL)

add_library(localscribe_native SHARED localscribe_native.cpp)

target_link_libraries(localscribe_native PRIVATE whisper mediandk log)
target_compile_options(localscribe_native PRIVATE -O3 -fvisibility=hidden)
target_link_options(localscribe_native PRIVATE
    -Wl,--exclude-libs,ALL
    -Wl,--gc-sections
    -Wl,-z,max-page-size=16384)

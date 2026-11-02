cmake_minimum_required(VERSION 3.14)
project(localscribe_llm LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# llama.cpp and its bundled ggml are linked statically into our one .so. It
# is a separate library from localscribe_native (whisper.cpp) so the two
# ggml copies never meet; each keeps its symbols hidden.
set(BUILD_SHARED_LIBS     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS     OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES  OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER    OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP       OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL         OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE           OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP           OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL       OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE        ON  CACHE BOOL "" FORCE)

if (ANDROID_ABI STREQUAL "arm64-v8a")
    # Same baseline as whisper: ARMv8.2 with FP16 (~2018+; no dot-product,
    # which e.g. the Snapdragon 845 lacks). The Dart side checks
    # /proc/cpuinfo before using this library.
    set(GGML_CPU_ARM_ARCH "armv8.2-a+fp16" CACHE STRING "" FORCE)
endif()

set(LLAMA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/llama.cpp)
add_subdirectory(${LLAMA_DIR} ${CMAKE_CURRENT_BINARY_DIR}/llama.cpp EXCLUDE_FROM_ALL)

add_library(localscribe_llm SHARED localscribe_llm.cpp)

target_link_libraries(localscribe_llm PRIVATE llama log)
target_compile_options(localscribe_llm PRIVATE -O3 -fvisibility=hidden)
target_link_options(localscribe_llm PRIVATE
    -Wl,--exclude-libs,ALL
    -Wl,--gc-sections
    -Wl,-z,max-page-size=16384)

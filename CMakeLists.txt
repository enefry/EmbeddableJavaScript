cmake_minimum_required(VERSION 3.20)

project(ejs LANGUAGES C)

find_package(Threads REQUIRED)

if(APPLE)
  enable_language(OBJC)
endif()

set(EJS_ENGINE "stub" CACHE STRING "JavaScript engine backend: stub or quickjs-ng")
set_property(CACHE EJS_ENGINE PROPERTY STRINGS "stub" "quickjs-ng")

set(EJS_RUNTIME_LOOP "stub" CACHE STRING "Runtime event loop backend: stub or libuv")
set_property(CACHE EJS_RUNTIME_LOOP PROPERTY STRINGS "stub" "libuv")

set(EJS_ALLOWED_ENGINES "stub" "quickjs-ng")
set(EJS_ALLOWED_RUNTIME_LOOPS "stub" "libuv")

if(NOT EJS_ENGINE IN_LIST EJS_ALLOWED_ENGINES)
  message(FATAL_ERROR
    "Invalid EJS_ENGINE='${EJS_ENGINE}'. Allowed values: stub, quickjs-ng. "
    "Pass -DEJS_ENGINE=<allowed> or clear the build cache directory.")
endif()

if(NOT EJS_RUNTIME_LOOP IN_LIST EJS_ALLOWED_RUNTIME_LOOPS)
  message(FATAL_ERROR
    "Invalid EJS_RUNTIME_LOOP='${EJS_RUNTIME_LOOP}'. Allowed values: stub, libuv. "
    "Pass -DEJS_RUNTIME_LOOP=<allowed> or clear the build cache directory.")
endif()

set(EJS_QUICKJS_NG_SOURCE_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/quickjs-ng"
    CACHE PATH
    "Path to a quickjs-ng source checkout")

set(EJS_LIBUV_SOURCE_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libuv"
    CACHE PATH
    "Path to a libuv source checkout")

option(ENABLE_COVERAGE "Enable code coverage instrumentation" OFF)
if(ENABLE_COVERAGE)
  if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    add_compile_options(-fprofile-arcs -ftest-coverage)
    add_link_options(--coverage)
  endif()
endif()

include(CTest)

add_subdirectory(core)
add_subdirectory(platform)
add_subdirectory(modules/wintertc)
add_subdirectory(modules/fs)
add_subdirectory(modules/system)
add_subdirectory(modules/fswatch)
add_subdirectory(modules/worker)
add_subdirectory(modules/path)
add_subdirectory(modules/buffer)
add_subdirectory(modules/kv)
add_subdirectory(modules/sqlite)
add_subdirectory(modules/net)
add_subdirectory(modules/xhr)
add_subdirectory(modules/ws)
add_subdirectory(modules/package)
add_subdirectory(modules/stdlib/hashing)
add_subdirectory(modules/stdlib/uuid)
add_subdirectory(modules/stdlib/ipaddr)
if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
add_subdirectory(sample)
add_subdirectory(tools)

add_custom_target(ejs_platform_boundary_check
  COMMAND ${CMAKE_COMMAND}
          -DROOT_DIR=${CMAKE_CURRENT_SOURCE_DIR}
          -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/check_platform_boundary.cmake
  COMMENT "Checking root platform remains WinterTC-agnostic"
  VERBATIM
)

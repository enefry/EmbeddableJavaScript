add_library(ejs_core STATIC
  src/ejs_abi.c
  src/ejs_error.c
  src/ejs_native_api.c
  src/ejs_runtime_loop.c
  src/ejs_runtime.c
  
  include/ejs_native_api.h
  include/ejs_runtime.h
  src/ejs_abi.h
  src/ejs_engine.h
  src/ejs_error.h
  src/ejs_runtime_internal.h
)

source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
  src/ejs_abi.c
  src/ejs_error.c
  src/ejs_native_api.c
  src/ejs_runtime_loop.c
  src/ejs_runtime.c
  src/ejs_runtime_loop_libuv.c
  src/ejs_runtime_loop_stub.c
  src/ejs_engine_quickjs_ng.c
  src/ejs_engine_stub.c
  
  include/ejs_native_api.h
  include/ejs_runtime.h
  src/ejs_abi.h
  src/ejs_engine.h
  src/ejs_error.h
  src/ejs_runtime_internal.h
)

target_include_directories(ejs_core
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

option(EJS_TEST "Enable test error injection and debugging code" OFF)
if(EJS_TEST)
  target_compile_definitions(ejs_core PRIVATE EJS_TEST=1)
endif()

target_link_libraries(ejs_core PUBLIC Threads::Threads)

if(EJS_RUNTIME_LOOP STREQUAL "libuv")
  if(NOT EXISTS "${EJS_LIBUV_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
      "EJS_RUNTIME_LOOP=libuv requires EJS_LIBUV_SOURCE_DIR to point to a libuv checkout. "
      "Expected: ${EJS_LIBUV_SOURCE_DIR}/CMakeLists.txt")
  endif()

  set(LIBUV_BUILD_SHARED OFF CACHE BOOL "Build libuv shared library" FORCE)
  set(LIBUV_BUILD_TESTS OFF CACHE BOOL "Build libuv tests" FORCE)
  set(LIBUV_BUILD_BENCH OFF CACHE BOOL "Build libuv benchmarks" FORCE)

  add_subdirectory("${EJS_LIBUV_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/libuv" EXCLUDE_FROM_ALL)

  if(NOT TARGET uv_a)
    message(FATAL_ERROR "libuv was found, but CMake target 'uv_a' was not created")
  endif()

  target_sources(ejs_core PRIVATE src/ejs_runtime_loop_libuv.c)
  target_compile_definitions(ejs_core PRIVATE EJS_RUNTIME_LOOP_LIBUV=1)
  target_link_libraries(ejs_core PRIVATE uv_a)
else()
  target_sources(ejs_core PRIVATE src/ejs_runtime_loop_stub.c)
  target_compile_definitions(ejs_core PRIVATE EJS_RUNTIME_LOOP_STUB=1)
endif()

if(EJS_ENGINE STREQUAL "quickjs-ng")
  if(NOT EXISTS "${EJS_QUICKJS_NG_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
      "EJS_ENGINE=quickjs-ng requires EJS_QUICKJS_NG_SOURCE_DIR to point to a quickjs-ng checkout. "
      "Expected: ${EJS_QUICKJS_NG_SOURCE_DIR}/CMakeLists.txt")
  endif()

  add_library(ejs_quickjs_ng_engine STATIC
    "${EJS_QUICKJS_NG_SOURCE_DIR}/dtoa.c"
    "${EJS_QUICKJS_NG_SOURCE_DIR}/libregexp.c"
    "${EJS_QUICKJS_NG_SOURCE_DIR}/libunicode.c"
    "${EJS_QUICKJS_NG_SOURCE_DIR}/quickjs.c"
  )

  target_compile_definitions(ejs_quickjs_ng_engine PRIVATE _GNU_SOURCE)
  if(TVOS)
    target_compile_definitions(ejs_quickjs_ng_engine PRIVATE _TVOS)
  endif()
  if(WATCHOS)
    target_compile_definitions(ejs_quickjs_ng_engine PRIVATE _WATCHOS)
  endif()

  target_include_directories(ejs_quickjs_ng_engine PUBLIC
    "${EJS_QUICKJS_NG_SOURCE_DIR}"
  )

  target_link_libraries(ejs_quickjs_ng_engine PUBLIC Threads::Threads ${CMAKE_DL_LIBS})

  find_library(EJS_M_LIBRARIES m)
  if(EJS_M_LIBRARIES)
    target_link_libraries(ejs_quickjs_ng_engine PUBLIC ${EJS_M_LIBRARIES})
  endif()

  target_sources(ejs_core PRIVATE src/ejs_engine_quickjs_ng.c)
  target_compile_definitions(ejs_core PRIVATE EJS_ENGINE_QUICKJS_NG=1)
  target_link_libraries(ejs_core PRIVATE ejs_quickjs_ng_engine)
else()
  target_sources(ejs_core PRIVATE src/ejs_engine_stub.c)
  target_compile_definitions(ejs_core PRIVATE EJS_ENGINE_STUB=1)
endif()

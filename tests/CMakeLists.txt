add_executable(ejs_core_test
  core/ejs_core_test.c
  core/support/ejs_fake_host.c
  core/support/ejs_fake_host.h
)

add_executable(ejs_regression_smoke
  core/ejs_regression_smoke.c
)

source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
  core/ejs_core_test.c
  core/support/ejs_fake_host.c
  core/support/ejs_fake_host.h
)

source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
  core/ejs_regression_smoke.c
)

target_include_directories(ejs_core_test PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../core/include
  ${CMAKE_CURRENT_SOURCE_DIR}/../core/src
  ${CMAKE_CURRENT_SOURCE_DIR}/core/support
)

target_include_directories(ejs_regression_smoke PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../core/include
  ${CMAKE_CURRENT_SOURCE_DIR}/../core/src
)

target_link_libraries(ejs_core_test PRIVATE ejs_core)
target_link_libraries(ejs_regression_smoke PRIVATE ejs_core)

if(EJS_TEST)
  target_compile_definitions(ejs_core_test PRIVATE EJS_TEST=1)
  target_compile_definitions(ejs_regression_smoke PRIVATE EJS_TEST=1)
endif()

if(EJS_RUNTIME_LOOP STREQUAL "libuv")
  target_compile_definitions(ejs_core_test PRIVATE EJS_RUNTIME_LOOP_LIBUV=1)
  target_link_libraries(ejs_core_test PRIVATE uv_a)
  target_compile_definitions(ejs_regression_smoke PRIVATE EJS_RUNTIME_LOOP_LIBUV=1)
  target_link_libraries(ejs_regression_smoke PRIVATE uv_a)
endif()

if(EJS_ENGINE STREQUAL "quickjs-ng")
  target_compile_definitions(ejs_core_test PRIVATE EJS_ENGINE_QUICKJS_NG=1)
  target_compile_definitions(ejs_regression_smoke PRIVATE EJS_ENGINE_QUICKJS_NG=1)
else()
  target_compile_definitions(ejs_core_test PRIVATE EJS_ENGINE_STUB=1)
  target_compile_definitions(ejs_regression_smoke PRIVATE EJS_ENGINE_STUB=1)
endif()

function(ejs_register_test target labels timeout)
  if(TARGET ${target})
    add_test(NAME ${target} COMMAND ${target})
    set_tests_properties(${target} PROPERTIES
      LABELS "${labels}"
      TIMEOUT ${timeout}
    )
  endif()
endfunction()

add_test(NAME ejs_platform_boundary_test
  COMMAND ${CMAKE_COMMAND}
          -DROOT_DIR=${CMAKE_SOURCE_DIR}
          -P ${CMAKE_SOURCE_DIR}/cmake/check_platform_boundary.cmake
)
set_tests_properties(ejs_platform_boundary_test PROPERTIES
  LABELS "boundary;lint"
  TIMEOUT 10
)

add_test(NAME ejs_platform_boundary_negative_test
  COMMAND ${CMAKE_COMMAND}
          -DROOT_DIR=${CMAKE_SOURCE_DIR}/tests/fixtures/platform_boundary_violation
          -P ${CMAKE_SOURCE_DIR}/cmake/check_platform_boundary.cmake
)
set_tests_properties(ejs_platform_boundary_negative_test PROPERTIES
  LABELS "boundary;lint"
  TIMEOUT 10
  WILL_FAIL TRUE
)

ejs_register_test(ejs_regression_smoke "smoke;core" 20)
ejs_register_test(ejs_core_test "core" 120)

find_program(EJS_NODE_EXECUTABLE node)
if(EJS_NODE_EXECUTABLE)
  add_test(NAME ejs_phase1_modules_js_test
    COMMAND ${EJS_NODE_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/js/phase1_modules_js_test.js
  )
  set_tests_properties(ejs_phase1_modules_js_test PROPERTIES
    LABELS "js;phase1"
    TIMEOUT 20
  )

  add_test(NAME ejs_worker_js_test
    COMMAND ${EJS_NODE_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/js/worker_js_test.js
  )
  set_tests_properties(ejs_worker_js_test PROPERTIES
    LABELS "js;worker"
    TIMEOUT 20
  )

  add_test(NAME ejs_network_js_test
    COMMAND ${EJS_NODE_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/js/network_js_test.js
  )
  set_tests_properties(ejs_network_js_test PROPERTIES
    LABELS "js;network"
    TIMEOUT 20
  )

  add_test(NAME ejs_ejspkg_converter_test
    COMMAND ${EJS_NODE_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/ejspkg/converter_test.js
  )
  set_tests_properties(ejs_ejspkg_converter_test PROPERTIES
    LABELS "js;ejspkg;tools"
    TIMEOUT 20
  )

  add_test(NAME ejs_ejspkg_cheerio_conversion_test
    COMMAND ${EJS_NODE_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/ejspkg/cheerio_conversion_test.js
  )
  set_tests_properties(ejs_ejspkg_cheerio_conversion_test PROPERTIES
    LABELS "js;ejspkg;tools;cheerio"
    SKIP_RETURN_CODE 77
    TIMEOUT 30
  )
endif()

if(APPLE AND TARGET ejs_apple_platform)
  add_executable(ejs_apple_platform_test
    apple/ejs_apple_platform_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    apple/ejs_apple_platform_test.m
  )

  target_link_libraries(ejs_apple_platform_test PRIVATE ejs_apple_platform)
  target_compile_options(ejs_apple_platform_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_apple_platform_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_apple_platform_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_apple_platform_test "apple;platform" 60)
endif()

if(APPLE AND TARGET ejs_wintertc_apple)
  add_executable(ejs_wintertc_apple_test
    wintertc/apple/ejs_wintertc_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    wintertc/apple/ejs_wintertc_apple_test.m
  )

  target_link_libraries(ejs_wintertc_apple_test PRIVATE ejs_wintertc_apple)
  target_compile_options(ejs_wintertc_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_wintertc_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_wintertc_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_wintertc_apple_test "apple;wintertc" 60)
endif()

if(APPLE AND TARGET ejs_fs_apple)
  add_executable(ejs_fs_apple_test
    fs/apple/ejs_fs_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    fs/apple/ejs_fs_apple_test.m
  )

  target_link_libraries(ejs_fs_apple_test PRIVATE ejs_fs_apple)
  target_compile_options(ejs_fs_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_fs_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_fs_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_fs_apple_test "apple;fs" 60)
endif()

if(APPLE AND TARGET ejs_system_apple)
  add_executable(ejs_system_apple_test
    system/apple/ejs_system_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    system/apple/ejs_system_apple_test.m
  )

  target_link_libraries(ejs_system_apple_test PRIVATE ejs_system_apple)
  target_compile_options(ejs_system_apple_test PRIVATE -fobjc-arc)
  set_target_properties(ejs_system_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_system_apple_test "apple;system" 60)
endif()

if(APPLE AND TARGET ejs_fswatch_apple)
  add_executable(ejs_fswatch_apple_test
    fswatch/apple/ejs_fswatch_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    fswatch/apple/ejs_fswatch_apple_test.m
  )

  target_link_libraries(ejs_fswatch_apple_test PRIVATE ejs_fswatch_apple)
  target_compile_options(ejs_fswatch_apple_test PRIVATE -fobjc-arc)
  set_target_properties(ejs_fswatch_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_fswatch_apple_test "apple;fswatch" 60)
endif()

if(APPLE AND TARGET ejs_path_apple)
  add_executable(ejs_path_apple_test
    path/apple/ejs_path_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    path/apple/ejs_path_apple_test.m
  )

  target_link_libraries(ejs_path_apple_test PRIVATE ejs_path_apple)
  target_compile_options(ejs_path_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_path_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_path_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_path_apple_test "apple;path" 60)
endif()

if(APPLE AND TARGET ejs_buffer_apple)
  add_executable(ejs_buffer_apple_test
    buffer/apple/ejs_buffer_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    buffer/apple/ejs_buffer_apple_test.m
  )

  target_link_libraries(ejs_buffer_apple_test PRIVATE ejs_buffer_apple)
  target_compile_options(ejs_buffer_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_buffer_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_buffer_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_buffer_apple_test "apple;buffer" 60)
endif()

if(APPLE AND TARGET ejs_package_apple)
  add_executable(ejs_package_apple_test
    package/apple/ejs_package_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    package/apple/ejs_package_apple_test.m
  )

  target_link_libraries(ejs_package_apple_test PRIVATE ejs_package_apple)
  target_compile_options(ejs_package_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_package_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_package_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_package_apple_test "apple;package;ejspkg" 60)

  add_executable(ejs_package_cheerio_apple_test
    package/apple/ejs_package_cheerio_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    package/apple/ejs_package_cheerio_apple_test.m
  )

  target_link_libraries(ejs_package_cheerio_apple_test PRIVATE ejs_package_apple)
  target_compile_options(ejs_package_cheerio_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_package_cheerio_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_package_cheerio_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_package_cheerio_apple_test "apple;package;ejspkg;cheerio" 60)
  set_tests_properties(ejs_package_cheerio_apple_test PROPERTIES
    SKIP_RETURN_CODE 77
  )
endif()

if(APPLE AND TARGET ejs_kv_apple)
  add_executable(ejs_kv_apple_test
    kv/apple/ejs_kv_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    kv/apple/ejs_kv_apple_test.m
  )

  target_link_libraries(ejs_kv_apple_test PRIVATE ejs_kv_apple)
  target_compile_options(ejs_kv_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_kv_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_kv_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_kv_apple_test "apple;kv" 60)
endif()

if(APPLE AND TARGET ejs_sqlite_apple)
  add_executable(ejs_sqlite_apple_test
    sqlite/apple/ejs_sqlite_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    sqlite/apple/ejs_sqlite_apple_test.m
  )

  target_link_libraries(ejs_sqlite_apple_test PRIVATE ejs_sqlite_apple)
  target_compile_options(ejs_sqlite_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_sqlite_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_sqlite_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_sqlite_apple_test "apple;sqlite" 60)
endif()

if(APPLE AND TARGET ejs_worker_apple)
  add_executable(ejs_worker_apple_test
    worker/apple/ejs_worker_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    worker/apple/ejs_worker_apple_test.m
  )

  target_link_libraries(ejs_worker_apple_test PRIVATE ejs_worker_apple)
  target_compile_options(ejs_worker_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_worker_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_worker_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_worker_apple_test "apple;worker" 60)
endif()

if(APPLE AND TARGET ejs_net_apple)
  add_executable(ejs_net_apple_test
    net/apple/ejs_net_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    net/apple/ejs_net_apple_test.m
  )

  target_link_libraries(ejs_net_apple_test PRIVATE ejs_net_apple)
  target_compile_options(ejs_net_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_net_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_net_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_net_apple_test "apple;net" 60)
endif()

if(APPLE AND TARGET ejs_xhr_apple)
  add_executable(ejs_xhr_apple_test
    xhr/apple/ejs_xhr_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    xhr/apple/ejs_xhr_apple_test.m
  )

  target_link_libraries(ejs_xhr_apple_test PRIVATE ejs_xhr_apple)
  target_compile_options(ejs_xhr_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_xhr_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_xhr_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_xhr_apple_test "apple;xhr" 60)
endif()

if(APPLE AND TARGET ejs_ws_apple)
  add_executable(ejs_ws_apple_test
    ws/apple/ejs_ws_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    ws/apple/ejs_ws_apple_test.m
  )

  target_link_libraries(ejs_ws_apple_test PRIVATE ejs_ws_apple)
  target_compile_options(ejs_ws_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_ws_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_ws_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_ws_apple_test "apple;ws" 60)
endif()

if(APPLE AND TARGET ejs_hashing_apple AND TARGET ejs_uuid_apple AND TARGET ejs_ipaddr_apple)
  add_executable(ejs_stdlib_apple_test
    stdlib/apple/ejs_stdlib_apple_test.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    stdlib/apple/ejs_stdlib_apple_test.m
  )

  target_link_libraries(ejs_stdlib_apple_test PRIVATE
    ejs_hashing_apple
    ejs_uuid_apple
    ejs_ipaddr_apple
  )
  target_compile_options(ejs_stdlib_apple_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_stdlib_apple_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_stdlib_apple_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_stdlib_apple_test "apple;stdlib" 60)
endif()

if(APPLE
    AND TARGET ejs_wintertc_apple
    AND TARGET ejs_fs_apple
    AND TARGET ejs_system_apple
    AND TARGET ejs_fswatch_apple
    AND TARGET ejs_path_apple
    AND TARGET ejs_buffer_apple
    AND TARGET ejs_kv_apple
    AND TARGET ejs_sqlite_apple
    AND TARGET ejs_hashing_apple
    AND TARGET ejs_uuid_apple
    AND TARGET ejs_worker_apple)
  add_executable(ejs_apple_cli_test
    apple/ejs_apple_cli_test.m
    ../tools/apple/EJSAppleCLISupport.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    apple/ejs_apple_cli_test.m
  )
  source_group(TREE ${CMAKE_SOURCE_DIR} PREFIX "Source" FILES
    ${CMAKE_SOURCE_DIR}/tools/apple/EJSAppleCLISupport.m
  )

  target_link_libraries(ejs_apple_cli_test PRIVATE
    ejs_wintertc_apple
    ejs_fs_apple
    ejs_system_apple
    ejs_fswatch_apple
    ejs_path_apple
    ejs_buffer_apple
    ejs_kv_apple
    ejs_sqlite_apple
    ejs_hashing_apple
    ejs_uuid_apple
    ejs_worker_apple
    ejs_net_apple
    ejs_ws_apple
    ejs_xhr_apple
    ejs_ipaddr_apple
  )
  target_compile_options(ejs_apple_cli_test PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_apple_cli_test PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_apple_cli_test PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  ejs_register_test(ejs_apple_cli_test "apple;cli" 60)
endif()

if(ANDROID AND TARGET ejs_android_platform)
  enable_language(CXX)

  add_executable(ejs_android_platform_test
    android/ejs_android_platform_test.cpp
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    android/ejs_android_platform_test.cpp
  )

  target_link_libraries(ejs_android_platform_test PRIVATE ejs_android_platform)
  set_target_properties(ejs_android_platform_test PROPERTIES
    BUILD_RPATH "@loader_path/../../platform/android/Debug;@loader_path/../platform/android;@loader_path/../../platform/android"
    INSTALL_RPATH "@loader_path/../../platform/android/Debug;@loader_path/../platform/android;@loader_path/../../platform/android"
    BUILD_WITH_INSTALL_RPATH ON
    XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@loader_path/../../platform/android/Debug @loader_path/../platform/android @loader_path/../../platform/android"
  )
  if(EJS_TEST)
    target_compile_definitions(ejs_android_platform_test PRIVATE EJS_TEST=1)
  endif()
  ejs_register_test(ejs_android_platform_test "android;platform" 60)
endif()

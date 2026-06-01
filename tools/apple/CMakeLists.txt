add_library(ejs_apple_cli_support STATIC
  EJSAppleCLISupport.h
  EJSAppleCLISupport.m
)

source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
  EJSAppleCLISupport.h
  EJSAppleCLISupport.m
  ejs_apple_cli_main.m
)

target_link_libraries(ejs_apple_cli_support PUBLIC
  ejs_wintertc_apple
  ejs_fs_apple
  ejs_system_apple
  ejs_net_apple
  ejs_ws_apple
  ejs_xhr_apple
  ejs_ipaddr_apple
  ejs_fswatch_apple
  ejs_path_apple
  ejs_buffer_apple
  ejs_sqlite_apple
  ejs_kv_apple
  ejs_hashing_apple
  ejs_uuid_apple
  ejs_worker_apple
)
target_compile_options(ejs_apple_cli_support PRIVATE -fobjc-arc)
if(EJS_TEST)
  target_compile_definitions(ejs_apple_cli_support PRIVATE EJS_TEST=1)
endif()
set_target_properties(ejs_apple_cli_support PROPERTIES
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
)

add_executable(ejs_apple_cli ejs_apple_cli_main.m)
target_link_libraries(ejs_apple_cli PRIVATE ejs_apple_cli_support)
target_compile_options(ejs_apple_cli PRIVATE -fobjc-arc)
set_target_properties(ejs_apple_cli PROPERTIES
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
)

if(BUILD_TESTING)
  add_test(NAME ejs_apple_cli_help_test
    COMMAND ejs_apple_cli --help
  )
  set_tests_properties(ejs_apple_cli_help_test PROPERTIES
    LABELS "apple;cli"
    TIMEOUT 10
  )

  add_test(NAME ejs_apple_cli_missing_script_test
    COMMAND ejs_apple_cli
  )
  set_tests_properties(ejs_apple_cli_missing_script_test PROPERTIES
    LABELS "apple;cli"
    TIMEOUT 10
    WILL_FAIL TRUE
  )
endif()

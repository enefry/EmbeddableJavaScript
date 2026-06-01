add_executable(ejs_sample ejs_sample.c)

target_include_directories(ejs_sample PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/../core/include
)

target_link_libraries(ejs_sample PRIVATE ejs_core)

if(EJS_RUNTIME_LOOP STREQUAL "libuv")
  target_link_libraries(ejs_sample PRIVATE uv_a)
endif()

if(APPLE AND TARGET ejs_wintertc_apple)
  add_executable(ejs_apple_sample ejs_apple_sample.m)

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    ejs_apple_sample.m
  )

  target_link_libraries(ejs_apple_sample PRIVATE ejs_wintertc_apple)
  target_compile_options(ejs_apple_sample PRIVATE -fobjc-arc)
  set_target_properties(ejs_apple_sample PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
endif()

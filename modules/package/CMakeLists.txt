if(APPLE AND TARGET ejs_apple_platform)
  find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)

  add_library(ejs_package_apple STATIC
    platform/apple/include/EJSPackageApple.h
    platform/apple/src/EJSPackageApple.m
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    platform/apple/include/EJSPackageApple.h
    platform/apple/src/EJSPackageApple.m
  )

  target_include_directories(ejs_package_apple
    PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/platform/apple/include
  )

  target_link_libraries(ejs_package_apple
    PUBLIC
      ejs_apple_platform
      ${FOUNDATION_FRAMEWORK}
  )

  target_compile_options(ejs_package_apple PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_package_apple PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_package_apple PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
endif()

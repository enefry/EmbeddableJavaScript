find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)

add_library(ejs_apple_platform STATIC
  include/EJSApplePlatform.h
  include/EJSContextConfiguration.h
  include/EJSContext.h
  include/EJSProvider.h
  include/EJSRuntime.h
  include/EJSRuntimeConfiguration.h
  src/EJSApplePlatform.m
)

source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
  include/EJSApplePlatform.h
  include/EJSContextConfiguration.h
  include/EJSContext.h
  include/EJSProvider.h
  include/EJSRuntime.h
  include/EJSRuntimeConfiguration.h
  src/EJSApplePlatform.m
)

target_include_directories(ejs_apple_platform
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
  PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../core/include
)

target_link_libraries(ejs_apple_platform
  PUBLIC
    ejs_core
    ${FOUNDATION_FRAMEWORK}
)

target_compile_options(ejs_apple_platform PRIVATE -fobjc-arc)

if(EJS_TEST)
  target_compile_definitions(ejs_apple_platform PRIVATE EJS_TEST=1)
endif()

set_target_properties(ejs_apple_platform PROPERTIES
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
)

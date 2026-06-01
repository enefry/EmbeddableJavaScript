set(EJS_FSWATCH_JS_FILES
  js/fswatch.js
)

if(APPLE AND TARGET ejs_apple_platform)
  find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
  find_program(EJS_XXD_EXECUTABLE xxd REQUIRED)

  set(EJS_FSWATCH_GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
  set(EJS_FSWATCH_BUNDLE_HEADER ${EJS_FSWATCH_GENERATED_DIR}/ejs_fswatch_js_bundle.h)
  string(JOIN "|" EJS_FSWATCH_JS_JOINED ${EJS_FSWATCH_JS_FILES})
  set(EJS_FSWATCH_JS_ABSOLUTE_FILES "")
  foreach(js_file IN LISTS EJS_FSWATCH_JS_FILES)
    list(APPEND EJS_FSWATCH_JS_ABSOLUTE_FILES ${CMAKE_CURRENT_SOURCE_DIR}/${js_file})
  endforeach()

  add_custom_command(
    OUTPUT ${EJS_FSWATCH_BUNDLE_HEADER}
    COMMAND ${CMAKE_COMMAND}
            -DOUT=${EJS_FSWATCH_BUNDLE_HEADER}
            -DINPUT_DIR=${CMAKE_CURRENT_SOURCE_DIR}
            -DINPUTS=${EJS_FSWATCH_JS_JOINED}
            -DXXD=${EJS_XXD_EXECUTABLE}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_fswatch_bundle.cmake
    DEPENDS
      ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_fswatch_bundle.cmake
      ${EJS_FSWATCH_JS_ABSOLUTE_FILES}
    VERBATIM
  )

  add_library(ejs_fswatch_apple STATIC
    platform/apple/include/EJSFSWatchApple.h
    platform/apple/src/EJSFSWatchApple.m
    ${EJS_FSWATCH_BUNDLE_HEADER}
  )

  target_include_directories(ejs_fswatch_apple
    PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/platform/apple/include
    PRIVATE
      ${EJS_FSWATCH_GENERATED_DIR}
  )

  target_link_libraries(ejs_fswatch_apple
    PUBLIC
      ejs_apple_platform
      ${FOUNDATION_FRAMEWORK}
  )

  target_compile_options(ejs_fswatch_apple PRIVATE -fobjc-arc)
  set_target_properties(ejs_fswatch_apple PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
endif()

if(ANDROID)
  set(EJS_FSWATCH_ANDROID_JAVA_SOURCES
    platform/android/java/com/ejs/modules/fswatch/EJSFSWatch.java
    platform/android/java/com/ejs/modules/fswatch/EJSFSWatchProvider.java
  )
  set(EJS_FSWATCH_ANDROID_JAVA_ABSOLUTE_SOURCES "")
  foreach(java_source IN LISTS EJS_FSWATCH_ANDROID_JAVA_SOURCES)
    list(APPEND EJS_FSWATCH_ANDROID_JAVA_ABSOLUTE_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/${java_source})
  endforeach()
  set(EJS_FSWATCH_ANDROID_RESOURCE_DIR ${CMAKE_CURRENT_BINARY_DIR}/android-resources/ejs/modules/fswatch)
  add_custom_command(
    OUTPUT ${EJS_FSWATCH_ANDROID_RESOURCE_DIR}/fswatch.js
    COMMAND ${CMAKE_COMMAND} -E make_directory ${EJS_FSWATCH_ANDROID_RESOURCE_DIR}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${CMAKE_CURRENT_SOURCE_DIR}/js/fswatch.js
            ${EJS_FSWATCH_ANDROID_RESOURCE_DIR}/fswatch.js
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/js/fswatch.js
    VERBATIM
  )
  add_custom_target(ejs_fswatch_android_sources
    DEPENDS
      ${EJS_FSWATCH_ANDROID_JAVA_ABSOLUTE_SOURCES}
      ${EJS_FSWATCH_ANDROID_RESOURCE_DIR}/fswatch.js
  )
  set_target_properties(ejs_fswatch_android_sources PROPERTIES
    EJS_ANDROID_JAVA_SOURCES "${EJS_FSWATCH_ANDROID_JAVA_ABSOLUTE_SOURCES}"
    EJS_ANDROID_RESOURCE_DIR "${CMAKE_CURRENT_BINARY_DIR}/android-resources"
    EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}"
    EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java"
    EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_BINARY_DIR}/android-resources"
  )
  if(TARGET ejs_android_modules_java AND TARGET ejs_android_modules_metadata)
    add_dependencies(ejs_android_modules_java ejs_fswatch_android_sources)
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCES "${EJS_FSWATCH_ANDROID_JAVA_ABSOLUTE_SOURCES}")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_BINARY_DIR}/android-resources")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCES "${EJS_FSWATCH_ANDROID_JAVA_ABSOLUTE_SOURCES}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_BINARY_DIR}/android-resources")
  endif()
endif()

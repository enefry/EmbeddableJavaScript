set(EJS_WINTERTC_JS_FILES
  js/timers.js
  js/events.js
  js/url.js
  js/encoding.js
  js/blob.js
  js/streams.js
  js/fetch.js
  js/crypto.js
  js/performance.js
  js/console.js
  js/bootstrap.js
)

if(APPLE AND TARGET ejs_apple_platform)
  find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
  find_library(SECURITY_FRAMEWORK Security REQUIRED)
  find_program(EJS_XXD_EXECUTABLE xxd REQUIRED)

  set(EJS_WINTERTC_GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
  set(EJS_WINTERTC_BUNDLE_HEADER ${EJS_WINTERTC_GENERATED_DIR}/ejs_wintertc_js_bundle.h)
  string(JOIN "|" EJS_WINTERTC_JS_JOINED ${EJS_WINTERTC_JS_FILES})
  set(EJS_WINTERTC_JS_ABSOLUTE_FILES "")
  foreach(js_file IN LISTS EJS_WINTERTC_JS_FILES)
    list(APPEND EJS_WINTERTC_JS_ABSOLUTE_FILES ${CMAKE_CURRENT_SOURCE_DIR}/${js_file})
  endforeach()

  add_custom_command(
    OUTPUT ${EJS_WINTERTC_BUNDLE_HEADER}
    COMMAND ${CMAKE_COMMAND}
            -DOUT=${EJS_WINTERTC_BUNDLE_HEADER}
            -DINPUT_DIR=${CMAKE_CURRENT_SOURCE_DIR}
            -DINPUTS=${EJS_WINTERTC_JS_JOINED}
            -DXXD=${EJS_XXD_EXECUTABLE}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_wintertc_bundle.cmake
    DEPENDS
      ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_wintertc_bundle.cmake
      ${EJS_WINTERTC_JS_ABSOLUTE_FILES}
    VERBATIM
  )

  add_library(ejs_wintertc_apple STATIC
    platform/apple/include/EJSWinterTCApple.h
    platform/apple/src/EJSWinterTCApple.m
    ${EJS_WINTERTC_BUNDLE_HEADER}
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    platform/apple/include/EJSWinterTCApple.h
    platform/apple/src/EJSWinterTCApple.m
    ${EJS_WINTERTC_JS_FILES}
  )

  target_include_directories(ejs_wintertc_apple
    PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/platform/apple/include
    PRIVATE
      ${EJS_WINTERTC_GENERATED_DIR}
  )

  target_link_libraries(ejs_wintertc_apple
    PUBLIC
      ejs_apple_platform
      ${FOUNDATION_FRAMEWORK}
      ${SECURITY_FRAMEWORK}
  )

  target_compile_options(ejs_wintertc_apple PRIVATE -fobjc-arc)

  if(EJS_TEST)
    target_compile_definitions(ejs_wintertc_apple PRIVATE EJS_TEST=1)
  endif()

  set_target_properties(ejs_wintertc_apple PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
endif()

if(ANDROID AND TARGET ejs_android_platform)
  add_custom_target(ejs_wintertc_android_java
    SOURCES
      platform/android/java/com/ejs/wintertc/EJSWinterTCAndroid.java
      platform/android/java/com/ejs/wintertc/EJSWinterTCScripts.java
      ${EJS_WINTERTC_JS_FILES}
  )
  set(EJS_WINTERTC_ANDROID_JAVA_ABSOLUTE_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/wintertc/EJSWinterTCAndroid.java
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/wintertc/EJSWinterTCScripts.java
  )
  set_target_properties(ejs_wintertc_android_java PROPERTIES
    EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}"
    EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java"
    EJS_ANDROID_JAVA_SOURCES "${EJS_WINTERTC_ANDROID_JAVA_ABSOLUTE_SOURCES}"
    EJS_ANDROID_REQUIRED_MANIFEST_PERMISSIONS "android.permission.INTERNET"
  )
  if(TARGET ejs_android_modules_java AND TARGET ejs_android_modules_metadata)
    add_dependencies(ejs_android_modules_java ejs_wintertc_android_java)
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCES "${EJS_WINTERTC_ANDROID_JAVA_ABSOLUTE_SOURCES}")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_REQUIRED_MANIFEST_PERMISSIONS "android.permission.INTERNET")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCES "${EJS_WINTERTC_ANDROID_JAVA_ABSOLUTE_SOURCES}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_REQUIRED_MANIFEST_PERMISSIONS "android.permission.INTERNET")
  endif()
endif()

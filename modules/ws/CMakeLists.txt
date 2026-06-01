set(EJS_WS_JS_FILES
  js/ws.js
)

if(APPLE AND TARGET ejs_apple_platform)
  find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
  find_program(EJS_XXD_EXECUTABLE xxd REQUIRED)

  set(EJS_WS_GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
  set(EJS_WS_BUNDLE_HEADER ${EJS_WS_GENERATED_DIR}/ejs_ws_js_bundle.h)
  string(JOIN "|" EJS_WS_JS_JOINED ${EJS_WS_JS_FILES})
  set(EJS_WS_JS_ABSOLUTE_FILES "")
  foreach(js_file IN LISTS EJS_WS_JS_FILES)
    list(APPEND EJS_WS_JS_ABSOLUTE_FILES ${CMAKE_CURRENT_SOURCE_DIR}/${js_file})
  endforeach()

  add_custom_command(
    OUTPUT ${EJS_WS_BUNDLE_HEADER}
    COMMAND ${CMAKE_COMMAND}
            -DOUT=${EJS_WS_BUNDLE_HEADER}
            -DINPUT_DIR=${CMAKE_CURRENT_SOURCE_DIR}
            -DINPUTS=${EJS_WS_JS_JOINED}
            -DXXD=${EJS_XXD_EXECUTABLE}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_ws_bundle.cmake
    DEPENDS
      ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_ws_bundle.cmake
      ${EJS_WS_JS_ABSOLUTE_FILES}
    VERBATIM
  )

  add_library(ejs_ws_apple STATIC
    platform/apple/include/EJSWebSocketApple.h
    platform/apple/src/EJSWebSocketApple.m
    ${EJS_WS_BUNDLE_HEADER}
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    platform/apple/include/EJSWebSocketApple.h
    platform/apple/src/EJSWebSocketApple.m
    ${EJS_WS_JS_FILES}
  )

  target_include_directories(ejs_ws_apple
    PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/platform/apple/include
    PRIVATE
      ${EJS_WS_GENERATED_DIR}
  )

  target_link_libraries(ejs_ws_apple
    PUBLIC
      ejs_apple_platform
      ${FOUNDATION_FRAMEWORK}
  )

  target_compile_options(ejs_ws_apple PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_ws_apple PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_ws_apple PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
endif()

if(ANDROID)
  set(EJS_WS_ANDROID_JAVA_SOURCES
    platform/android/java/com/ejs/modules/ws/EJSWebSocket.java
    platform/android/java/com/ejs/modules/ws/EJSWebSocketProvider.java
  )
  set(EJS_WS_ANDROID_JAVA_ABSOLUTE_SOURCES "")
  foreach(java_source IN LISTS EJS_WS_ANDROID_JAVA_SOURCES)
    list(APPEND EJS_WS_ANDROID_JAVA_ABSOLUTE_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/${java_source})
  endforeach()
  set(EJS_WS_ANDROID_RESOURCE_DIR ${CMAKE_CURRENT_BINARY_DIR}/android-resources/ejs/modules/ws)
  add_custom_command(
    OUTPUT ${EJS_WS_ANDROID_RESOURCE_DIR}/ws.js
    COMMAND ${CMAKE_COMMAND} -E make_directory ${EJS_WS_ANDROID_RESOURCE_DIR}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${CMAKE_CURRENT_SOURCE_DIR}/js/ws.js
            ${EJS_WS_ANDROID_RESOURCE_DIR}/ws.js
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/js/ws.js
    VERBATIM
  )
  add_custom_target(ejs_ws_android_sources
    DEPENDS
      ${EJS_WS_ANDROID_JAVA_ABSOLUTE_SOURCES}
      ${EJS_WS_ANDROID_RESOURCE_DIR}/ws.js
  )
  set_target_properties(ejs_ws_android_sources PROPERTIES
    EJS_ANDROID_JAVA_SOURCES "${EJS_WS_ANDROID_JAVA_ABSOLUTE_SOURCES}"
    EJS_ANDROID_RESOURCE_DIR "${CMAKE_CURRENT_BINARY_DIR}/android-resources"
    EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}"
    EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java"
    EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_BINARY_DIR}/android-resources"
    EJS_ANDROID_REQUIRED_MANIFEST_PERMISSIONS "android.permission.INTERNET"
  )
  if(TARGET ejs_android_modules_java AND TARGET ejs_android_modules_metadata)
    add_dependencies(ejs_android_modules_java ejs_ws_android_sources)
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCES "${EJS_WS_ANDROID_JAVA_ABSOLUTE_SOURCES}")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_BINARY_DIR}/android-resources")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_REQUIRED_MANIFEST_PERMISSIONS "android.permission.INTERNET")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCES "${EJS_WS_ANDROID_JAVA_ABSOLUTE_SOURCES}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_BINARY_DIR}/android-resources")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_REQUIRED_MANIFEST_PERMISSIONS "android.permission.INTERNET")
  endif()
endif()

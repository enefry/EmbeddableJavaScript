set(EJS_IPADDR_JS_FILES
  js/ipaddr.js
)

if(APPLE AND TARGET ejs_apple_platform)
  find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
  find_program(EJS_XXD_EXECUTABLE xxd REQUIRED)

  set(EJS_IPADDR_GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
  set(EJS_IPADDR_BUNDLE_HEADER ${EJS_IPADDR_GENERATED_DIR}/ejs_ipaddr_js_bundle.h)
  string(JOIN "|" EJS_IPADDR_JS_JOINED ${EJS_IPADDR_JS_FILES})
  set(EJS_IPADDR_JS_ABSOLUTE_FILES "")
  foreach(js_file IN LISTS EJS_IPADDR_JS_FILES)
    list(APPEND EJS_IPADDR_JS_ABSOLUTE_FILES ${CMAKE_CURRENT_SOURCE_DIR}/${js_file})
  endforeach()

  add_custom_command(
    OUTPUT ${EJS_IPADDR_BUNDLE_HEADER}
    COMMAND ${CMAKE_COMMAND}
            -DOUT=${EJS_IPADDR_BUNDLE_HEADER}
            -DINPUT_DIR=${CMAKE_CURRENT_SOURCE_DIR}
            -DINPUTS=${EJS_IPADDR_JS_JOINED}
            -DXXD=${EJS_XXD_EXECUTABLE}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_ipaddr_bundle.cmake
    DEPENDS
      ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_ipaddr_bundle.cmake
      ${EJS_IPADDR_JS_ABSOLUTE_FILES}
    VERBATIM
  )

  add_library(ejs_ipaddr_apple STATIC
    platform/apple/include/EJSIPAddrApple.h
    platform/apple/src/EJSIPAddrApple.m
    ${EJS_IPADDR_BUNDLE_HEADER}
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    platform/apple/include/EJSIPAddrApple.h
    platform/apple/src/EJSIPAddrApple.m
    ${EJS_IPADDR_JS_FILES}
  )

  target_include_directories(ejs_ipaddr_apple
    PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/platform/apple/include
    PRIVATE
      ${EJS_IPADDR_GENERATED_DIR}
  )

  target_link_libraries(ejs_ipaddr_apple
    PUBLIC
      ejs_apple_platform
      ${FOUNDATION_FRAMEWORK}
  )

  target_compile_options(ejs_ipaddr_apple PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_ipaddr_apple PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_ipaddr_apple PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
endif()

if(ANDROID AND TARGET ejs_android_platform)
  set(EJS_IPADDR_ANDROID_GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated/android/java/com/ejs/modules/stdlib/ipaddr)
  set(EJS_IPADDR_ANDROID_BUNDLE_JAVA ${EJS_IPADDR_ANDROID_GENERATED_DIR}/EJSIPAddrBundle.java)
  string(JOIN "|" EJS_IPADDR_ANDROID_JS_JOINED ${EJS_IPADDR_JS_FILES})
  set(EJS_IPADDR_ANDROID_JS_ABSOLUTE_FILES "")
  foreach(js_file IN LISTS EJS_IPADDR_JS_FILES)
    list(APPEND EJS_IPADDR_ANDROID_JS_ABSOLUTE_FILES ${CMAKE_CURRENT_SOURCE_DIR}/${js_file})
  endforeach()

  add_custom_command(
    OUTPUT ${EJS_IPADDR_ANDROID_BUNDLE_JAVA}
    COMMAND ${CMAKE_COMMAND}
            -DOUT=${EJS_IPADDR_ANDROID_BUNDLE_JAVA}
            -DINPUT_DIR=${CMAKE_CURRENT_SOURCE_DIR}
            -DINPUTS=${EJS_IPADDR_ANDROID_JS_JOINED}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_ipaddr_android_bundle.cmake
    DEPENDS
      ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_ipaddr_android_bundle.cmake
      ${EJS_IPADDR_ANDROID_JS_ABSOLUTE_FILES}
    VERBATIM
  )

  add_custom_target(ejs_ipaddr_android_java
    DEPENDS
      ${EJS_IPADDR_ANDROID_BUNDLE_JAVA}
      ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/stdlib/ipaddr/EJSIPAddr.java
  )

  add_library(ejs_ipaddr_android_java_metadata INTERFACE)
  add_dependencies(ejs_ipaddr_android_java_metadata ejs_ipaddr_android_java)
  set_target_properties(ejs_ipaddr_android_java_metadata PROPERTIES
    INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java;${CMAKE_CURRENT_BINARY_DIR}/generated/android/java"
    INTERFACE_EJS_ANDROID_JAVA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/stdlib/ipaddr/EJSIPAddr.java;${EJS_IPADDR_ANDROID_BUNDLE_JAVA}"
  )
  if(TARGET ejs_android_modules_java AND TARGET ejs_android_modules_metadata)
    add_dependencies(ejs_android_modules_java ejs_ipaddr_android_java)
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java;${CMAKE_CURRENT_BINARY_DIR}/generated/android/java")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/stdlib/ipaddr/EJSIPAddr.java;${EJS_IPADDR_ANDROID_BUNDLE_JAVA}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java;${CMAKE_CURRENT_BINARY_DIR}/generated/android/java")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/stdlib/ipaddr/EJSIPAddr.java;${EJS_IPADDR_ANDROID_BUNDLE_JAVA}")
  endif()
endif()

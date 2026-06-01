set(EJS_KV_JS_FILES
  js/kv.js
  js/storage.js
)

if(APPLE AND TARGET ejs_apple_platform)
  find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
  find_library(SQLITE3_LIBRARY sqlite3 REQUIRED)
  find_program(EJS_XXD_EXECUTABLE xxd REQUIRED)

  set(EJS_KV_GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
  set(EJS_KV_BUNDLE_HEADER ${EJS_KV_GENERATED_DIR}/ejs_kv_js_bundle.h)
  string(JOIN "|" EJS_KV_JS_JOINED ${EJS_KV_JS_FILES})
  set(EJS_KV_JS_ABSOLUTE_FILES "")
  foreach(js_file IN LISTS EJS_KV_JS_FILES)
    list(APPEND EJS_KV_JS_ABSOLUTE_FILES ${CMAKE_CURRENT_SOURCE_DIR}/${js_file})
  endforeach()

  add_custom_command(
    OUTPUT ${EJS_KV_BUNDLE_HEADER}
    COMMAND ${CMAKE_COMMAND}
            -DOUT=${EJS_KV_BUNDLE_HEADER}
            -DINPUT_DIR=${CMAKE_CURRENT_SOURCE_DIR}
            -DINPUTS=${EJS_KV_JS_JOINED}
            -DXXD=${EJS_XXD_EXECUTABLE}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_kv_bundle.cmake
    DEPENDS
      ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_kv_bundle.cmake
      ${EJS_KV_JS_ABSOLUTE_FILES}
    VERBATIM
  )

  add_library(ejs_kv_apple STATIC
    platform/apple/include/EJSKeyValueStoreApple.h
    platform/apple/src/EJSKeyValueStoreApple.m
    ${EJS_KV_BUNDLE_HEADER}
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    platform/apple/include/EJSKeyValueStoreApple.h
    platform/apple/src/EJSKeyValueStoreApple.m
    ${EJS_KV_JS_FILES}
  )

  target_include_directories(ejs_kv_apple
    PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/platform/apple/include
    PRIVATE
      ${EJS_KV_GENERATED_DIR}
  )

  target_link_libraries(ejs_kv_apple
    PUBLIC
      ejs_apple_platform
      ${FOUNDATION_FRAMEWORK}
      ${SQLITE3_LIBRARY}
  )

  target_compile_options(ejs_kv_apple PRIVATE -fobjc-arc)

  if(EJS_TEST)
    target_compile_definitions(ejs_kv_apple PRIVATE EJS_TEST=1)
  endif()

  set_target_properties(ejs_kv_apple PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
endif()

if(ANDROID AND TARGET ejs_android_platform)
  add_library(ejs_kv_android INTERFACE)

  target_sources(ejs_kv_android INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/kv/EJSKeyValueStore.java
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources/com/ejs/modules/kv/kv.js
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources/com/ejs/modules/kv/storage.js
  )

  target_link_libraries(ejs_kv_android INTERFACE ejs_android_platform)

  target_include_directories(ejs_kv_android INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources
  )

  set_target_properties(ejs_kv_android PROPERTIES
    INTERFACE_EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}"
    INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java"
    INTERFACE_EJS_ANDROID_JAVA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/kv/EJSKeyValueStore.java"
    INTERFACE_EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources"
  )
  if(TARGET ejs_android_modules_java AND TARGET ejs_android_modules_metadata)
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/kv/EJSKeyValueStore.java")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/kv/EJSKeyValueStore.java")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources")
  endif()
endif()

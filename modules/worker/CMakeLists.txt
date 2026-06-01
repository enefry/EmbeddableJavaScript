set(EJS_WORKER_JS_FILES
  js/worker_parent.js
  js/worker_child.js
)

if(APPLE AND TARGET ejs_apple_platform)
  find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
  find_program(EJS_XXD_EXECUTABLE xxd REQUIRED)

  set(EJS_WORKER_GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
  set(EJS_WORKER_BUNDLE_HEADER ${EJS_WORKER_GENERATED_DIR}/ejs_worker_js_bundle.h)
  string(JOIN "|" EJS_WORKER_JS_JOINED ${EJS_WORKER_JS_FILES})
  set(EJS_WORKER_JS_ABSOLUTE_FILES "")
  foreach(js_file IN LISTS EJS_WORKER_JS_FILES)
    list(APPEND EJS_WORKER_JS_ABSOLUTE_FILES ${CMAKE_CURRENT_SOURCE_DIR}/${js_file})
  endforeach()

  add_custom_command(
    OUTPUT ${EJS_WORKER_BUNDLE_HEADER}
    COMMAND ${CMAKE_COMMAND}
            -DOUT=${EJS_WORKER_BUNDLE_HEADER}
            -DINPUT_DIR=${CMAKE_CURRENT_SOURCE_DIR}
            -DINPUTS=${EJS_WORKER_JS_JOINED}
            -DXXD=${EJS_XXD_EXECUTABLE}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_worker_bundle.cmake
    DEPENDS
      ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_worker_bundle.cmake
      ${EJS_WORKER_JS_ABSOLUTE_FILES}
    VERBATIM
  )

  add_library(ejs_worker_apple STATIC
    platform/apple/include/EJSWorkerApple.h
    platform/apple/src/EJSWorkerApple.m
    ${EJS_WORKER_BUNDLE_HEADER}
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    platform/apple/include/EJSWorkerApple.h
    platform/apple/src/EJSWorkerApple.m
    ${EJS_WORKER_JS_FILES}
  )

  target_include_directories(ejs_worker_apple
    PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/platform/apple/include
    PRIVATE
      ${EJS_WORKER_GENERATED_DIR}
  )

  target_link_libraries(ejs_worker_apple
    PUBLIC
      ejs_apple_platform
      ${FOUNDATION_FRAMEWORK}
  )

  target_compile_options(ejs_worker_apple PRIVATE -fobjc-arc)
  if(EJS_TEST)
    target_compile_definitions(ejs_worker_apple PRIVATE EJS_TEST=1)
  endif()
  set_target_properties(ejs_worker_apple PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
endif()

if(ANDROID AND TARGET ejs_android_platform)
  add_custom_target(ejs_worker_android_java
    SOURCES
      platform/android/java/com/ejs/worker/EJSWorkerAndroid.java
      platform/android/java/com/ejs/worker/EJSWorkerScripts.java
      ${EJS_WORKER_JS_FILES}
  )
  set(EJS_WORKER_ANDROID_JAVA_ABSOLUTE_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/worker/EJSWorkerAndroid.java
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/worker/EJSWorkerScripts.java
  )
  set_target_properties(ejs_worker_android_java PROPERTIES
    EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}"
    EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java"
    EJS_ANDROID_JAVA_SOURCES "${EJS_WORKER_ANDROID_JAVA_ABSOLUTE_SOURCES}"
  )
  if(TARGET ejs_android_modules_java AND TARGET ejs_android_modules_metadata)
    add_dependencies(ejs_android_modules_java ejs_worker_android_java)
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCES "${EJS_WORKER_ANDROID_JAVA_ABSOLUTE_SOURCES}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCES "${EJS_WORKER_ANDROID_JAVA_ABSOLUTE_SOURCES}")
  endif()
endif()

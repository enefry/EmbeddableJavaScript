set(EJS_FS_JS_FILES
  js/fs.js
)

if(APPLE AND TARGET ejs_apple_platform)
  find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
  find_program(EJS_XXD_EXECUTABLE xxd REQUIRED)

  set(EJS_FS_GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
  set(EJS_FS_BUNDLE_HEADER ${EJS_FS_GENERATED_DIR}/ejs_fs_js_bundle.h)
  string(JOIN "|" EJS_FS_JS_JOINED ${EJS_FS_JS_FILES})
  set(EJS_FS_JS_ABSOLUTE_FILES "")
  foreach(js_file IN LISTS EJS_FS_JS_FILES)
    list(APPEND EJS_FS_JS_ABSOLUTE_FILES ${CMAKE_CURRENT_SOURCE_DIR}/${js_file})
  endforeach()

  add_custom_command(
    OUTPUT ${EJS_FS_BUNDLE_HEADER}
    COMMAND ${CMAKE_COMMAND}
            -DOUT=${EJS_FS_BUNDLE_HEADER}
            -DINPUT_DIR=${CMAKE_CURRENT_SOURCE_DIR}
            -DINPUTS=${EJS_FS_JS_JOINED}
            -DXXD=${EJS_XXD_EXECUTABLE}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_fs_bundle.cmake
    DEPENDS
      ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_fs_bundle.cmake
      ${EJS_FS_JS_ABSOLUTE_FILES}
    VERBATIM
  )

  add_library(ejs_fs_apple STATIC
    platform/apple/include/EJSFileSystemApple.h
    platform/apple/src/EJSFileSystemApple.m
    ${EJS_FS_BUNDLE_HEADER}
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    platform/apple/include/EJSFileSystemApple.h
    platform/apple/src/EJSFileSystemApple.m
    ${EJS_FS_JS_FILES}
  )

  target_include_directories(ejs_fs_apple
    PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/platform/apple/include
    PRIVATE
      ${EJS_FS_GENERATED_DIR}
  )

  target_link_libraries(ejs_fs_apple
    PUBLIC
      ejs_apple_platform
      ${FOUNDATION_FRAMEWORK}
  )

  target_compile_options(ejs_fs_apple PRIVATE -fobjc-arc)

  if(EJS_TEST)
    target_compile_definitions(ejs_fs_apple PRIVATE EJS_TEST=1)
  endif()

  set_target_properties(ejs_fs_apple PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
endif()

if(ANDROID AND TARGET ejs_android_platform)
  add_library(ejs_fs_android INTERFACE)

  target_sources(ejs_fs_android INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/fs/EJSFileSystem.java
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources/com/ejs/modules/fs/fs.js
  )

  target_link_libraries(ejs_fs_android INTERFACE ejs_android_platform)

  target_include_directories(ejs_fs_android INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources
  )

  set_target_properties(ejs_fs_android PROPERTIES
    INTERFACE_EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}"
    INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java"
    INTERFACE_EJS_ANDROID_JAVA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/fs/EJSFileSystem.java"
    INTERFACE_EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources"
  )
  if(TARGET ejs_android_modules_java AND TARGET ejs_android_modules_metadata)
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/fs/EJSFileSystem.java")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/fs/EJSFileSystem.java")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources")
  endif()
endif()

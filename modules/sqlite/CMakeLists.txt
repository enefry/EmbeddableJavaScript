set(EJS_SQLITE_JS_FILES
  js/sqlite.js
)

if(APPLE AND TARGET ejs_apple_platform)
  find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
  find_library(SQLITE3_LIBRARY sqlite3 REQUIRED)
  find_program(EJS_XXD_EXECUTABLE xxd REQUIRED)

  set(EJS_SQLITE_GENERATED_DIR ${CMAKE_CURRENT_BINARY_DIR}/generated)
  set(EJS_SQLITE_BUNDLE_HEADER ${EJS_SQLITE_GENERATED_DIR}/ejs_sqlite_js_bundle.h)
  string(JOIN "|" EJS_SQLITE_JS_JOINED ${EJS_SQLITE_JS_FILES})
  set(EJS_SQLITE_JS_ABSOLUTE_FILES "")
  foreach(js_file IN LISTS EJS_SQLITE_JS_FILES)
    list(APPEND EJS_SQLITE_JS_ABSOLUTE_FILES ${CMAKE_CURRENT_SOURCE_DIR}/${js_file})
  endforeach()

  add_custom_command(
    OUTPUT ${EJS_SQLITE_BUNDLE_HEADER}
    COMMAND ${CMAKE_COMMAND}
            -DOUT=${EJS_SQLITE_BUNDLE_HEADER}
            -DINPUT_DIR=${CMAKE_CURRENT_SOURCE_DIR}
            -DINPUTS=${EJS_SQLITE_JS_JOINED}
            -DXXD=${EJS_XXD_EXECUTABLE}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_sqlite_bundle.cmake
    DEPENDS
      ${CMAKE_CURRENT_SOURCE_DIR}/cmake/generate_sqlite_bundle.cmake
      ${EJS_SQLITE_JS_ABSOLUTE_FILES}
    VERBATIM
  )

  add_library(ejs_sqlite_apple STATIC
    platform/apple/include/EJSSQLiteApple.h
    platform/apple/src/EJSSQLiteApple.m
    ${EJS_SQLITE_BUNDLE_HEADER}
  )

  source_group(TREE ${CMAKE_CURRENT_SOURCE_DIR} PREFIX "Source" FILES
    platform/apple/include/EJSSQLiteApple.h
    platform/apple/src/EJSSQLiteApple.m
    ${EJS_SQLITE_JS_FILES}
  )

  target_include_directories(ejs_sqlite_apple
    PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/platform/apple/include
    PRIVATE
      ${EJS_SQLITE_GENERATED_DIR}
  )

  target_link_libraries(ejs_sqlite_apple
    PUBLIC
      ejs_apple_platform
      ${FOUNDATION_FRAMEWORK}
      ${SQLITE3_LIBRARY}
  )

  target_compile_options(ejs_sqlite_apple PRIVATE -fobjc-arc)

  if(EJS_TEST)
    target_compile_definitions(ejs_sqlite_apple PRIVATE EJS_TEST=1)
  endif()

  set_target_properties(ejs_sqlite_apple PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
endif()

if(ANDROID AND TARGET ejs_android_platform)
  add_library(ejs_sqlite_android INTERFACE)

  target_sources(ejs_sqlite_android INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/sqlite/EJSSQLite.java
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources/com/ejs/modules/sqlite/sqlite.js
  )

  target_link_libraries(ejs_sqlite_android INTERFACE ejs_android_platform)

  target_include_directories(ejs_sqlite_android INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java
    ${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources
  )

  set_target_properties(ejs_sqlite_android PROPERTIES
    INTERFACE_EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}"
    INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java"
    INTERFACE_EJS_ANDROID_JAVA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/sqlite/EJSSQLite.java"
    INTERFACE_EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources"
  )
  if(TARGET ejs_android_modules_java AND TARGET ejs_android_modules_metadata)
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_JAVA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/sqlite/EJSSQLite.java")
    set_property(TARGET ejs_android_modules_java APPEND PROPERTY EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_MODULE_PATHS "${CMAKE_CURRENT_SOURCE_DIR}")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCE_ROOTS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_JAVA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/java/com/ejs/modules/sqlite/EJSSQLite.java")
    set_property(TARGET ejs_android_modules_metadata APPEND PROPERTY INTERFACE_EJS_ANDROID_RESOURCE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/platform/android/resources")
  endif()
endif()

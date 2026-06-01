if(NOT DEFINED ROOT_DIR)
  message(FATAL_ERROR "ROOT_DIR is required")
endif()

set(platform_dir "${ROOT_DIR}/platform")
if(NOT EXISTS "${platform_dir}")
  message(FATAL_ERROR "platform directory does not exist: ${platform_dir}")
endif()

set(forbidden_source_tokens
  "modules/"
  "modules\\"
  "tests/"
  "tests\\"
  "EJSWinterTC"
  "EJSNet"
  "EJSNetwork"
  "XMLHttpRequest"
  "WebSocket"
  "ejs_wintertc"
  "ejs_net"
  "ejs_xhr"
  "ejs_ws"
  "installWinterTC"
  "WinterTC/platform"
  "modules/wintertc/platform"
  "wintertc."
)

set(forbidden_platform_target_tokens
  "modules/"
  "modules\\"
  "tests/"
  "tests\\"
  "EJSWinterTC"
  "EJSNet"
  "EJSNetwork"
  "XMLHttpRequest"
  "WebSocket"
  "ejs_wintertc"
  "ejs_net"
  "ejs_xhr"
  "ejs_ws"
  "installWinterTC"
  "wintertc."
  "ejs_fs_apple"
  "ejs_path_apple"
  "ejs_buffer_apple"
  "ejs_kv_apple"
  "ejs_sqlite_apple"
  "ejs_net_apple"
  "ejs_xhr_apple"
  "ejs_ws_apple"
  "ejs_apple_cli_support"
)

file(GLOB_RECURSE platform_candidates "${platform_dir}/*")
set(platform_files "")
foreach(candidate IN LISTS platform_candidates)
  if(IS_DIRECTORY "${candidate}")
    continue()
  endif()

  get_filename_component(filename "${candidate}" NAME)
  get_filename_component(extension "${candidate}" EXT)
  if(filename STREQUAL "CMakeLists.txt" OR
     extension MATCHES "^\\.(c|cc|cpp|h|m|mm)$")
    list(APPEND platform_files "${candidate}")
  endif()
endforeach()

set(violations "")
foreach(platform_file IN LISTS platform_files)
  file(READ "${platform_file}" contents)
  foreach(token IN LISTS forbidden_source_tokens)
    string(FIND "${contents}" "${token}" token_index)
    if(NOT token_index EQUAL -1)
      file(RELATIVE_PATH relative_file "${ROOT_DIR}" "${platform_file}")
      list(APPEND violations "${relative_file}: forbidden token '${token}'")
    endif()
  endforeach()
endforeach()

set(cmake_scope_files "")
foreach(candidate
    "${ROOT_DIR}/CMakeLists.txt"
    "${ROOT_DIR}/platform/CMakeLists.txt")
  if(EXISTS "${candidate}")
    list(APPEND cmake_scope_files "${candidate}")
  endif()
endforeach()

file(GLOB_RECURSE cmake_scope_candidates
  "${ROOT_DIR}/cmake/*.cmake"
  "${ROOT_DIR}/platform/*.cmake"
)
list(APPEND cmake_scope_files ${cmake_scope_candidates})
list(REMOVE_DUPLICATES cmake_scope_files)

foreach(cmake_file IN LISTS cmake_scope_files)
  file(READ "${cmake_file}" contents)
  string(REGEX MATCHALL
    "target_[A-Za-z_]+[ \t\r\n]*\\([ \t\r\n]*ejs_apple_platform[ \t\r\n]*[^\\)]*\\)"
    platform_target_calls
    "${contents}")

  foreach(target_call IN LISTS platform_target_calls)
    foreach(token IN LISTS forbidden_platform_target_tokens)
      string(FIND "${target_call}" "${token}" token_index)
      if(NOT token_index EQUAL -1)
        file(RELATIVE_PATH relative_file "${ROOT_DIR}" "${cmake_file}")
        list(APPEND violations
          "${relative_file}: ejs_apple_platform target call contains forbidden token '${token}'")
      endif()
    endforeach()
  endforeach()
endforeach()

if(violations)
  list(REMOVE_DUPLICATES violations)
  list(JOIN violations "\n  " violation_text)
  message(FATAL_ERROR "Root platform must remain WinterTC-agnostic:\n  ${violation_text}")
endif()

message(STATUS "Root platform boundary check passed")

if(NOT DEFINED PERMISSIONS_FILE)
  message(FATAL_ERROR "PERMISSIONS_FILE is required")
endif()

if(NOT DEFINED OUT)
  message(FATAL_ERROR "OUT is required")
endif()

set(permissions "")
if(EXISTS "${PERMISSIONS_FILE}")
  file(STRINGS "${PERMISSIONS_FILE}" permission_lines)
  foreach(permission IN LISTS permission_lines)
    string(STRIP "${permission}" permission)
    if(NOT permission STREQUAL "")
      list(APPEND permissions "${permission}")
    endif()
  endforeach()
endif()

list(REMOVE_DUPLICATES permissions)

set(content "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\">\n")
foreach(permission IN LISTS permissions)
  string(APPEND content "  <uses-permission android:name=\"${permission}\" />\n")
endforeach()
string(APPEND content "</manifest>\n")

file(WRITE "${OUT}" "${content}")

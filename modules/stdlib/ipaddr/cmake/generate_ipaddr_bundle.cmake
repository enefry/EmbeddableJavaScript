if(NOT DEFINED OUT OR OUT STREQUAL "")
  message(FATAL_ERROR "OUT is required")
endif()

if(NOT DEFINED INPUT_DIR OR INPUT_DIR STREQUAL "")
  message(FATAL_ERROR "INPUT_DIR is required")
endif()

if(NOT DEFINED INPUTS OR INPUTS STREQUAL "")
  message(FATAL_ERROR "INPUTS is required")
endif()

if(NOT DEFINED XXD OR XXD STREQUAL "")
  message(FATAL_ERROR "XXD is required")
endif()

get_filename_component(out_dir "${OUT}" DIRECTORY)
file(MAKE_DIRECTORY "${out_dir}")
string(REPLACE "|" ";" js_files "${INPUTS}")

file(WRITE "${OUT}"
  "#ifndef EJS_IPADDR_JS_BUNDLE_H\n#define EJS_IPADDR_JS_BUNDLE_H\n\n#include <stddef.h>\n\n"
  "typedef struct {\n    const char *name;\n    const unsigned char *code;\n    size_t len;\n} EJSIPAddrBundledScript;\n\n"
)

set(script_entries "")
foreach(js_file IN LISTS js_files)
  get_filename_component(js_name "${js_file}" NAME_WE)
  string(MAKE_C_IDENTIFIER "${js_name}" js_identifier)
  set(symbol "ejs_ipaddr_js_${js_identifier}")

  execute_process(
    COMMAND "${XXD}" -i -n "${symbol}" "${INPUT_DIR}/${js_file}"
    RESULT_VARIABLE xxd_result
    OUTPUT_VARIABLE xxd_output
    ERROR_VARIABLE xxd_error
  )

  if(NOT xxd_result EQUAL 0)
    message(FATAL_ERROR "xxd failed for ${js_file}: ${xxd_error}")
  endif()

  string(REPLACE "unsigned char ${symbol}[]" "static const unsigned char ${symbol}[]" xxd_output "${xxd_output}")
  string(REPLACE "unsigned int ${symbol}_len" "static const size_t ${symbol}_len" xxd_output "${xxd_output}")
  string(REPLACE "\n};\nstatic const size_t ${symbol}_len" ",\n  0x00\n};\nstatic const size_t ${symbol}_len" xxd_output "${xxd_output}")
  file(APPEND "${OUT}" "${xxd_output}\n")
  string(APPEND script_entries "    { \"${js_file}\", ${symbol}, ${symbol}_len },\n")
endforeach()

file(APPEND "${OUT}"
  "static const EJSIPAddrBundledScript ejs_ipaddr_scripts[] = {\n"
  "${script_entries}"
  "};\n"
  "static const size_t ejs_ipaddr_scripts_count = sizeof(ejs_ipaddr_scripts) / sizeof(ejs_ipaddr_scripts[0]);\n\n"
  "#endif /* EJS_IPADDR_JS_BUNDLE_H */\n"
)

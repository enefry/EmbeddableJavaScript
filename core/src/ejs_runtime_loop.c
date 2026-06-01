/**
 * ejs_runtime_loop.c — 事件循环后端的公共辅助函数
 *
 * 本文件包含所有事件循环后端共享的辅助函数。
 * 当前仅包含 ejs_runtime_loop_backend_name，用于返回当前编译链接的
 * 事件循环后端名称标识。
 *
 * 后端选择通过编译宏控制：
 *   - EJS_RUNTIME_LOOP_LIBUV：使用 libuv 后端（ejs_runtime_loop_libuv.c）
 *   - EJS_RUNTIME_LOOP_STUB：使用 stub 后端（ejs_runtime_loop_stub.c）
 *
 * 这两个宏在 CMakeLists.txt 中通过 target_compile_definitions 定义，
 * 且互斥——不会同时定义两个宏。
 */

#include "ejs_runtime_loop.h"

/**
 * ejs_runtime_loop_backend_name — 获取当前事件循环后端的名称
 *
 * 返回一个静态字符串标识符，用于诊断日志和测试断言：
 *   - libuv 后端返回 "libuv"
 *   - stub 后端返回 "stub"
 *   - 其他情况返回 "unknown"（表示编译配置有误）
 *
 * @return 后端名称的静态字符串（无需释放）
 */
const char * ejs_runtime_loop_backend_name(void) {
#if defined(EJS_RUNTIME_LOOP_LIBUV)
    return "libuv";

#elif defined(EJS_RUNTIME_LOOP_STUB)
    return "stub";

#else
    return "unknown";

#endif
}

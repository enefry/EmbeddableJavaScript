/**
 * ejs_error.h — EJS 错误系统的内部接口
 *
 * 本头文件定义了 EJSCoreError 结构体的创建、销毁和访问函数。
 * EJSCoreError 是 EJS 运行时统一的错误信息容器，用于封装：
 *   - 运行时内部错误（如内存不足、无效参数）
 *   - JS 引擎异常（如语法错误、运行时异常）
 *   - 宿主原生层错误（如网络失败、文件系统错误）
 *
 * 错误对象的创建采用"全拷贝"策略：所有字符串字段（message、stack、
 * platform_domain）都在创建时通过 strdup 复制到堆上，确保错误对象
 * 的生命周期独立于产生错误的上下文。调用方通过 ejs_error_destroy
 * 统一释放。
 *
 * 设计原则：
 *   - 零依赖：仅依赖 ejs_runtime.h 中的公共类型
 *   - 线程安全：EJSCoreError 本身是只读的，创建和销毁由调用方同步保证
 *   - 可扩展：通过 platform_domain + platform_code 支持任意后端子系统
 */

#ifndef EJS_ERROR_H
#define EJS_ERROR_H

#include "ejs_runtime.h"

/**
 * ejs_error_create — 创建一个新的错误对象
 *
 * 所有字符串参数都会被复制到堆上，调用方可安全释放原始字符串。
 * 若某字段不需要，可传入 NULL（message/stack/platform_domain）
 * 或 0（platform_code）。
 *
 * @param code           错误分类码，对应 EJSCoreErrorCode 枚举
 * @param message        人类可读的错误描述，会被 strdup 复制
 * @param stack          JS 堆栈跟踪字符串，会被 strdup 复制
 * @param platform_domain 平台错误域（如 "libuv"），会被 strdup 复制
 * @param platform_code  平台特定错误码（如 UV_ECONNREFUSED）
 * @return 新创建的错误对象；内存不足时返回 NULL
 */
EJSCoreError * ejs_error_create(EJSCoreErrorCode code,
                            const char   *message,
                            const char   *stack,
                            const char   *platform_domain,
                            int          platform_code);

/**
 * ejs_error_from_host_error — 从宿主错误结构体创建 EJSCoreError
 *
 * 将 EJSCoreHostError 转换为内部 EJSCoreError 表示。若 host_error 为 NULL，
 * 则创建一个描述为 "host operation failed without error details" 的
 * 内部错误。
 *
 * @param host_error 宿主错误结构体指针，可为 NULL
 * @return 新创建的错误对象；内存不足时返回 NULL
 */
EJSCoreError * ejs_error_from_host_error(const EJSCoreHostError *host_error);

/**
 * ejs_result_ok — 构造一个成功的 EJSCoreResult
 *
 * @return status 为 EJS_STATUS_OK、error 为 NULL 的结果
 */
EJSCoreResult ejs_result_ok(void);

/**
 * ejs_result_error — 构造一个失败的 EJSCoreResult
 *
 * @param error 错误对象；EJSCoreResult 将接管其所有权
 * @return status 为 EJS_STATUS_ERROR、error 指向传入对象的结果
 */
EJSCoreResult ejs_result_error(EJSCoreError *error);

#endif /* ifndef EJS_ERROR_H */

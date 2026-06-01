/**
 * ejs_error.c — EJS 错误系统的实现
 *
 * 本文件实现了 EJSCoreError 结构体的完整生命周期管理，包括：
 *   - 创建：ejs_error_create、从宿主错误转换：ejs_error_from_host_error
 *   - 访问器：ejs_error_code、message、stack、platform_domain、platform_code
 *   - 销毁：ejs_error_destroy
 *   - 辅助：ejs_result_ok、ejs_result_error
 *
 * 内存管理策略：
 *   EJSCoreError 结构体通过 calloc 分配，所有字符串字段通过内部辅助函数
 *   ejs_strdup_or_null 复制到堆上。这确保了错误对象可以在任意上下文中
 *   安全传递，不受原始字符串生命周期的限制。
 *
 * 线程安全：
 *   EJSCoreError 创建后即为只读，可被多线程安全访问。创建和销毁必须由
 *   调用方保证同步（通常在同一线程或已同步的上下文中进行）。
 */

#include "ejs_error.h"
#include "ejs_util.h"

#include <stdlib.h>

/**
 * EJSCoreError — 错误信息的内部表示
 *
 * 所有字符串字段均通过堆分配复制，确保独立于产生错误的上下文。
 * code 字段存储 EJSCoreErrorCode 的整数值，允许直接作为 int 传递。
 */
struct EJSCoreError {
    int code;                /* 错误分类码，对应 EJSCoreErrorCode 枚举的整数值 */
    char *message;           /* 人类可读的错误描述，堆分配，可为 NULL */
    char *stack;             /* JS 堆栈跟踪字符串，堆分配，可为 NULL */
    char *platform_domain;   /* 平台错误域标识（如 "libuv"），堆分配，可为 NULL */
    int platform_code;       /* 平台特定错误码（如 UV_ECONNREFUSED） */
};

/**
 * ejs_error_create — 创建一个新的错误对象
 *
 * 使用 calloc 分配 EJSCoreError 结构体，并将所有字符串参数通过
 * ejs_strdup_or_null 复制到堆上。即使某些 strdup 失败（返回 NULL），
 * 仍然返回一个有效的 EJSCoreError（只是对应字段为 NULL），避免在
 * 错误路径中再出现错误处理的复杂度爆炸。
 *
 * @param code           错误分类码
 * @param message        错误描述，会被 strdup
 * @param stack          堆栈跟踪，会被 strdup
 * @param platform_domain 平台错误域，会被 strdup
 * @param platform_code  平台错误码
 * @return 新创建的错误对象；若 calloc 失败则返回 NULL
 */
EJSCoreError * ejs_error_create(EJSCoreErrorCode code,
                            const char   *message,
                            const char   *stack,
                            const char   *platform_domain,
                            int          platform_code) {
    EJSCoreError *error = (EJSCoreError *)calloc(1u, sizeof(EJSCoreError));

    if (error == NULL) {
        return NULL;
    }

    error->code = (int)code;
    error->message = ejs_strdup_or_null(message);
    error->stack = ejs_strdup_or_null(stack);
    error->platform_domain = ejs_strdup_or_null(platform_domain);
    error->platform_code = platform_code;

    return error;
}

/**
 * ejs_error_from_host_error — 从宿主错误结构体创建 EJSCoreError
 *
 * 如果 host_error 为 NULL，创建一个描述为
 * "host operation failed without error details" 的 EJS_ERROR_INTERNAL 错误，
 * 防止在宿主未提供错误信息时出现空指针问题。
 */
EJSCoreError * ejs_error_from_host_error(const EJSCoreHostError *host_error) {
    if (host_error == NULL) {
        return ejs_error_create(EJS_ERROR_INTERNAL,
                                "host operation failed without error details",
                                NULL,
                                NULL,
                                0);
    }

    return ejs_error_create(host_error->code,
                            host_error->message,
                            NULL,
                            host_error->platform_domain,
                            host_error->platform_code);
}

/**
 * ejs_result_ok — 构造成功的 EJSCoreResult
 *
 * 这是一个便捷的工厂函数，避免调用方手动初始化结构体字段。
 */
EJSCoreResult ejs_result_ok(void) {
    EJSCoreResult result;

    result.status = EJS_STATUS_OK;
    result.error = NULL;
    return result;
}

/**
 * ejs_result_error — 构造失败的 EJSCoreResult
 *
 * EJSCoreResult 将接管 error 的所有权，调用方不应再单独销毁 error。
 */
EJSCoreResult ejs_result_error(EJSCoreError *error) {
    EJSCoreResult result;

    result.status = EJS_STATUS_ERROR;
    result.error = error;
    return result;
}

/**
 * ejs_error_code — 获取错误的分类码
 *
 * @return 若 error 为 NULL 则返回 EJS_ERROR_NONE，否则返回 error->code
 */
int ejs_error_code(const EJSCoreError *error) {
    return error == NULL ? (int)EJS_ERROR_NONE : error->code;
}

/**
 * ejs_error_message — 获取错误的消息文本
 *
 * @return 若 error 为 NULL 则返回 NULL，否则返回 error->message
 */
const char * ejs_error_message(const EJSCoreError *error) {
    return error == NULL ? NULL : error->message;
}

/**
 * ejs_error_stack — 获取错误的 JS 堆栈跟踪
 *
 * @return 若 error 为 NULL 或无堆栈信息则返回 NULL
 */
const char * ejs_error_stack(const EJSCoreError *error) {
    return error == NULL ? NULL : error->stack;
}

/**
 * ejs_error_platform_domain — 获取平台错误域
 *
 * @return 若 error 为 NULL 则返回 NULL
 */
const char * ejs_error_platform_domain(const EJSCoreError *error) {
    return error == NULL ? NULL : error->platform_domain;
}

/**
 * ejs_error_platform_code — 获取平台特定错误码
 *
 * @return 若 error 为 NULL 则返回 0
 */
int ejs_error_platform_code(const EJSCoreError *error) {
    return error == NULL ? 0 : error->platform_code;
}

/**
 * ejs_error_destroy — 销毁错误对象
 *
 * 释放 EJSCoreError 结构体及其所有堆分配的字符串字段。
 * 传入 NULL 是安全的（无操作）。销毁后 error 指针不可再使用。
 */
void ejs_error_destroy(EJSCoreError *error) {
    if (error == NULL) {
        return;
    }

    free(error->message);
    free(error->stack);
    free(error->platform_domain);
    free(error);
}

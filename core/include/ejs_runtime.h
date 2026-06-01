/**
 * ejs_runtime.h — EJS 运行时公共 ABI 定义
 *
 * 本头文件定义了 EJS 运行时的最小公共接口，是宿主应用与 JS 运行时内核
 * 交互的唯一入口。设计原则为"极简微内核"：仅暴露运行时/上下文的创建销毁、
 * 脚本求值、微任务驱动、中断请求和错误访问，不包含任何具体 API 语义
 * （如 fetch、crypto、fs 等）。
 *
 * 所有高层 API 均通过 ejs_native_api.h 中定义的万能异步通道
 * （EJSCoreHostInvokeAPI.invoke / __ejs_native__.invoke）由 WinterTC 模块
 * 在 JS 侧实现，与 core 完全解耦。
 *
 * ABI 兼容性约定：
 *   - 所有公共结构体以 abi_version + struct_size 开头，支持向前兼容扩展
 *   - 宿主必须正确设置这两个字段，运行时在入口处进行校验
 *   - reserved 字段供未来扩展使用，当前必须置零
 */

#ifndef EJS_RUNTIME_H
#define EJS_RUNTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "ejs_native_api.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * EJS_RUNTIME_ABI_VERSION — 运行时 ABI 版本号
 *
 * 当本头文件中的结构体布局发生不兼容变更时递增。宿主传入的
 * EJSCoreRuntimeConfig/EJSCoreEvalOptions 等结构体的 abi_version 必须与此值匹配，
 * 否则运行时将拒绝创建。
 */
#define EJS_RUNTIME_ABI_VERSION 1u

/**
 * EJSCoreRuntime — JS 运行时实例（不透明句柄）
 *
 * 代表一个独立的 JS 运行时，内含引擎运行时（如 QuickJS JSRuntime）、
 * 事件循环（libuv loop）和宿主 API 注册表。一个运行时可创建多个上下文。
 * 运行时不是线程安全的——所有对同一 EJSCoreRuntime 的操作必须在同一线程
 * （owner-thread）上执行。
 */
typedef struct EJSCoreRuntime   EJSCoreRuntime;

/**
 * EJSCoreContext — JS 执行上下文（不透明句柄）
 *
 * 代表一个独立的 JS 执行环境，内含引擎上下文（如 QuickJS JSContext）、
 * 挂起的异步操作链表和定时器列表。每个上下文有独立的全局对象和模块作用域。
 * 上下文从属于某个 EJSCoreRuntime，共享运行时的事件循环。
 *
 * 生命周期契约：
 *   - context handle 仅在所属 runtime 有效期间可用。
 *   - 一旦 runtime 销毁流程开始（调用 ejs_runtime_destroy 或
 *     ejs_runtime_destroy_with_completion），该 runtime 下所有 context handle
 *     都应视为失效，宿主不得再调用 ejs_context_destroy 或其它 context API。
 */
typedef struct EJSCoreContext   EJSCoreContext;

/**
 * EJSCoreError — 错误信息容器（不透明句柄）
 *
 * 封装 JS 异常或运行时错误的详细信息，包括错误码、消息文本、
 * JS 堆栈跟踪、以及平台相关的错误域和错误码。
 * 调用方负责通过 ejs_error_destroy 释放。
 */
typedef struct EJSCoreError     EJSCoreError;

/**
 * EJSCoreStatus — 函数调用的状态码
 *
 * EJS_STATUS_OK 表示操作成功，EJS_STATUS_ERROR 表示操作失败，
 * 详细错误信息通过 EJSCoreResult.error 获取。
 */
typedef enum {
    EJS_STATUS_OK    = 0,
    EJS_STATUS_ERROR = 1
} EJSCoreStatus;

/**
 * EJSCoreEvalKind — 脚本求值类型
 *
 * EJS_EVAL_KIND_SCRIPT：普通脚本，在全局作用域中执行
 * EJS_EVAL_KIND_MODULE：ES 模块，支持 import/export 语法
 */
typedef enum {
    EJS_EVAL_KIND_SCRIPT = 0,
    EJS_EVAL_KIND_MODULE = 1
} EJSCoreEvalKind;

/**
 * EJSCoreRuntimeConfig — 运行时创建配置
 *
 * 宿主在调用 ejs_runtime_create 前必须正确初始化此结构体：
 *   - abi_version 必须等于 EJS_RUNTIME_ABI_VERSION
 *   - struct_size 必须等于 sizeof(EJSCoreRuntimeConfig)
 *   - flags 和 reserved 当前必须置零，供未来扩展
 *   - runtime_name/runtime_version 仅供诊断日志使用，可为 NULL；运行时只浅拷贝
 *     指针，调用方必须保证字符串在 EJSCoreRuntime 生命周期内保持有效
 *   - memory_limit_bytes 设置 JS 堆内存上限（0 表示不限制）
 *   - max_stack_size 设置 JS 调用栈上限（0 表示使用引擎默认值）
 */
typedef struct {
    uint32_t abi_version;     /* ABI 版本号，必须为 EJS_RUNTIME_ABI_VERSION */
    size_t struct_size;       /* 结构体大小，必须为 sizeof(EJSCoreRuntimeConfig) */
    uint64_t flags;           /* 行为标志位，当前保留，必须为 0 */
    void *reserved[4];        /* 保留字段，必须为 NULL */

    const char *runtime_name; /* 运行时名称标识，仅供诊断，可为 NULL；调用方保留所有权 */
    const char *runtime_version;/* 运行时版本号，仅供诊断，可为 NULL；调用方保留所有权 */
    uint64_t memory_limit_bytes;/* JS 堆内存上限（字节），0 表示不限制 */
    uint32_t max_stack_size;  /* JS 调用栈上限（字节），0 表示引擎默认 */
} EJSCoreRuntimeConfig;

/**
 * EJS_RUNTIME_CONFIG_DEFAULT_VALUE / ejs_runtime_config_default_value
 *
 * EJSCoreRuntimeConfig 的快捷默认初始化。默认值只填充 ABI 版本和结构体大小，
 * 其余字段保持 0/NULL，等价于使用 memset 后手动设置 abi_version 和 struct_size。
 */
#define EJS_RUNTIME_CONFIG_DEFAULT_VALUE \
    { EJS_RUNTIME_ABI_VERSION, sizeof(EJSCoreRuntimeConfig), 0u, { NULL, NULL, NULL, NULL }, NULL, NULL, 0u, 0u }

static inline EJSCoreRuntimeConfig ejs_runtime_config_default_value(void) {
    EJSCoreRuntimeConfig config = EJS_RUNTIME_CONFIG_DEFAULT_VALUE;

    return config;
}

/**
 * EJSCoreEvalOptions — 脚本/模块求值选项
 *
 * 用于 ejs_eval_module 的扩展参数。kind 必须为 EJS_EVAL_KIND_MODULE。
 * specifier 和 source_url 影响模块解析和堆栈跟踪中的文件名显示。
 */
typedef struct {
    uint32_t abi_version;     /* ABI 版本号，必须为 EJS_RUNTIME_ABI_VERSION */
    size_t struct_size;       /* 结构体大小，必须为 sizeof(EJSCoreEvalOptions) */
    uint64_t flags;           /* 行为标志位，当前保留，必须为 0 */
    void *reserved[4];        /* 保留字段，必须为 NULL */

    const char *specifier;    /* 模块标识符（如 "math"），影响 import 解析，可为 NULL */
    const char *source_url;   /* 源文件 URL（如 "file:///app.js"），影响堆栈跟踪，可为 NULL */
    EJSCoreEvalKind kind;         /* 求值类型，必须为 EJS_EVAL_KIND_MODULE */
} EJSCoreEvalOptions;

/**
 * EJSCoreModuleSource — 已审核模块源码表条目
 *
 * 用于 ejs_context_register_module_sources。调用方在 runtime 外部完成包读取、
 * hash 校验、approval 校验和权限审核后，把 bounded 的内存源码表注册到 context。
 * runtime loader 只从这张表同步解析 import，不做文件 I/O、网络 I/O 或 provider 调用。
 *
 * specifier 是 loader 的规范化键，通常应使用 `ejs-pkg://.../modules/foo.js`。
 * source_url 影响 import.meta.url 和诊断；为 NULL 时使用 specifier。
 * source/source_len 在调用期间有效即可，runtime 会深拷贝。
 */
typedef struct {
    const char *specifier;    /* 规范化模块 specifier，不可为 NULL/空字符串 */
    const char *source_url;   /* 诊断/source URL，可为 NULL；建议与 specifier 一致 */
    const char *source;       /* UTF-8 JavaScript module source，不可为 NULL */
    size_t source_len;        /* source 字节长度 */
} EJSCoreModuleSource;

/**
 * EJSCoreResult — 函数调用的返回结果
 *
 * 通过 status 判断操作是否成功；若失败，error 包含详细错误信息，
 * 调用方负责通过 ejs_error_destroy 释放 error。
 */
typedef struct {
    EJSCoreStatus status;         /* 操作状态：OK 或 ERROR */
    EJSCoreError *error;          /* 错误详情，status 为 OK 时为 NULL */
} EJSCoreResult;

/**
 * EJSCoreRuntimeStopCompletion — runtime 停止/销毁完成回调
 *
 * 当 ejs_runtime_destroy_with_completion 完成异步优雅销毁流程后调用。
 * user_data 由调用方持有，runtime 只在 completion 调用时原样传回，不会释放。
 * 调用方必须保证 user_data 至少在 completion 返回前有效。
 */
typedef void (*EJSCoreRuntimeStopCompletion)(void *user_data);

/**
 * ejs_runtime_create — 创建一个新的 JS 运行时实例
 *
 * 根据 config 配置创建运行时，内含引擎运行时和事件循环。
 * 创建后需调用 ejs_context_create 创建执行上下文。
 *
 * @param config 运行时配置，不可为 NULL，abi_version 和 struct_size 必须正确
 * @return 运行时实例指针；失败时返回 NULL（配置无效或内存不足）
 */
EJSCoreRuntime * ejs_runtime_create(const EJSCoreRuntimeConfig *config);

/**
 * ejs_runtime_destroy_with_completion — 异步且非阻塞地销毁运行时实例
 *
 * 该函数会标记运行时为不可用，并优先尝试把销毁任务转交给 owner 线程异步完成。
 * 后台线程会依次优雅清空并释放所有当前积压在事件/任务队列中的 JS 任务与完成回调，
 * 原子性销毁所有 Context 并释放底层的 QuickJS-ng 上下文，
 * 关闭并清理所有定时器和 I/O 句柄，最终释放 EJSCoreRuntime 自身的全部物理内存，
 * 并在行将退出前触发宿主的 completion 回调。
 *
 * 正常情况下该接口会尽快返回；在极端资源不足场景下，内部可能降级为同步销毁路径。
 *
 * @param runtime 运行时实例，不可为 NULL
 * @param completion 销毁完成后的回调，可为 NULL
 * @param user_data 传递给 completion 的用户数据；runtime 不拥有、不释放
 */
void ejs_runtime_destroy_with_completion(EJSCoreRuntime               *runtime,
                                         EJSCoreRuntimeStopCompletion completion,
                                         void                     *user_data);

/**
 * ejs_runtime_destroy — 同步阻塞地销毁运行时实例
 *
 * 非 owner 线程调用时，本接口会阻塞等待，直到销毁完成后返回。
 * owner 线程调用时，本接口仅触发异步销毁流程并尽快返回；返回时不保证资源
 * 已全部释放。
 *
 * 若调用方需要明确的“销毁完成”时机，请使用
 * ejs_runtime_destroy_with_completion。
 *
 * 生命周期与并发契约：
 *   - runtime destroy 会使该 runtime 下全部 context handle 失效。
 *   - runtime destroy 启动后，宿主不得再调用任何 context API，包括
 *     ejs_context_destroy。
 *   - 同一 runtime 的 destroy 操作必须由宿主串行化；并发或重复 destroy 仅用于
 *     内部容错路径，不能作为公开 ABI 语义依赖。
 *
 * 销毁后 runtime 指针不可再使用。传入 NULL 是安全的（无操作）。
 *
 * @param runtime 待销毁的运行时指针，可为 NULL
 */
void ejs_runtime_destroy(EJSCoreRuntime *runtime);

/**
 * ejs_context_create — 在运行时中创建一个新的 JS 执行上下文
 *
 * 上下文拥有独立的全局对象和模块作用域。创建后 JS 引擎会自动注入
 * __ejs_native__.invoke 等内核原语到全局对象上。
 *
 * @param runtime 所属的运行时实例，不可为 NULL
 * @return 上下文实例指针；失败时返回 NULL
 */
EJSCoreContext * ejs_context_create(EJSCoreRuntime *runtime);

/**
 * ejs_context_destroy — 销毁执行上下文
 *
 * 销毁上下文时将自动取消并释放所有挂起的异步操作（invoke_list），
 * 停止并销毁所有活跃的定时器。销毁后 context 指针不可再使用。
 * 调用方必须保证所属 runtime 仍处于有效状态；runtime destroy 启动后禁止再对
 * 该 runtime 的 context handle 调用本接口。
 * 传入 NULL 是安全的（无操作）。
 *
 * @param context 待销毁的上下文指针，可为 NULL
 */
void ejs_context_destroy(EJSCoreContext *context);

/**
 * ejs_context_register_host — 为上下文注册宿主 API
 *
 * 注册后，JS 侧通过 __ejs_native__.invoke 发起的调用将转发到
 * host_api->invoke_api.invoke 回调。同时，操作的取消和释放将通过
 * host_api->operations.cancel/release 回调通知宿主。
 * 每个上下文只能注册一个宿主 API，重复注册会覆盖之前的。
 * 若未注册宿主 API，JS 侧调用 __ejs_native__.invoke 将抛出 InternalError。
 *
 * 生命周期说明：
 *   - runtime 在注册时会深拷贝 EJSCoreHostAPI 结构体，调用方无需保证传入结构体长久有效。
 *   - 宿主传入的 EJSCoreUserData 会在核心中依据 double-callback 规则进行引用计数托管。
 *     当内部引用计数归零时，会自动触发关联托管 user_data 的 release 析构。
 *   - 每个异步 invoke 会强引用它发起时的 Host record 快照，因此重新注册 Host
 *     或注销 Host 后，未完成的 pending 异步操作仍能正常运转，并在最终全部结束时安全释放旧 Host 资源。
 *   - 传入非 NULL 但 ABI/结构体校验失败的 host_api 会被视为注销请求：当前
 *     已注册 Host 会被清空并释放。
 *
 * @param context  上下文实例，不可为 NULL
 * @param host_api 指向 EJSCoreHostAPI 结构体的指针，注册后可立即释放其栈/堆内存；传 NULL 表示注销
 */
void ejs_context_register_host(EJSCoreContext *context, const EJSCoreHostAPI *host_api);

/**
 * ejs_eval_script — 在上下文中执行一段 JS 脚本
 *
 * 以全局作用域模式（JS_EVAL_TYPE_GLOBAL）执行 source 中的 JS 代码。
 * 执行是同步的——函数返回时脚本已执行完毕。若脚本抛出异常，
 * 返回的 EJSCoreResult.status 为 EJS_STATUS_ERROR，error 包含异常详情。
 *
 * @param context    执行上下文，不可为 NULL
 * @param filename   源文件名，用于堆栈跟踪和错误报告，可为 NULL（默认 "<eval>"）
 * @param source     JS 源代码字符串
 * @param source_len 源代码字节长度
 * @return 执行结果；成功时 status 为 OK，失败时 error 需由调用方释放
 */
EJSCoreResult ejs_eval_script(EJSCoreContext *context,
                          const char *filename,
                          const char *source,
                          size_t     source_len);

/**
 * ejs_eval_module — 在上下文中执行一段 ES 模块
 *
 * 以 ES 模块模式（JS_EVAL_TYPE_MODULE）执行 source 中的 JS 代码，
 * 支持 import/export 语法。options->kind 必须为 EJS_EVAL_KIND_MODULE。
 *
 * @param context    执行上下文，不可为 NULL
 * @param options    模块求值选项，不可为 NULL，kind 必须为 EJS_EVAL_KIND_MODULE
 * @param source     JS 模块源代码字符串
 * @param source_len 源代码字节长度
 * @return 执行结果；成功时 status 为 OK，失败时 error 需由调用方释放
 */
EJSCoreResult ejs_eval_module(EJSCoreContext           *context,
                          const EJSCoreEvalOptions *options,
                          const char           *source,
                          size_t               source_len);

/**
 * ejs_context_register_module_sources — 注册 context-scoped ES 模块源码表
 *
 * 该接口只接收已审核、已校验、已在内存中的源码表。它不会读取文件、扫描目录、
 * 解析 npm、访问网络或调用 host provider。重复注册相同 specifier 会替换源码表条目；
 * 已经被 JS 引擎链接进模块缓存的模块不会被 retroactively invalidated。
 *
 * @param context      目标执行上下文
 * @param sources      模块源码数组；source_count 为 0 时可为 NULL
 * @param source_count 模块源码数量
 * @return 注册结果
 */
EJSCoreResult ejs_context_register_module_sources(EJSCoreContext             *context,
                                                  const EJSCoreModuleSource *sources,
                                                  size_t                     source_count);

/**
 * ejs_request_interrupt — 请求中断运行时
 *
 * 设置运行时的中断标志，引擎将在下一次检查点中断 JS 执行。
 * 注意：当前 quickjs-ng 后端尚未实现实际的中断回调（函数为空操作），
 * 此接口为预留的未来功能。
 *
 * @param runtime 运行时实例，可为 NULL（无操作）
 */
void ejs_request_interrupt(EJSCoreRuntime *runtime);

/**
 * ejs_error_code — 获取错误的分类码
 *
 * @param error 错误对象，可为 NULL（返回 EJS_ERROR_NONE）
 * @return EJSCoreErrorCode 枚举值，如 EJS_ERROR_INVALID_ARGUMENT、EJS_ERROR_NETWORK 等
 */
int ejs_error_code(const EJSCoreError *error);

/**
 * ejs_error_message — 获取错误的消息文本
 *
 * 返回的字符串在 ejs_error_destroy 前有效，不可为调用方修改或释放。
 *
 * @param error 错误对象，可为 NULL（返回 NULL）
 * @return 错误消息字符串，如 "JavaScript evaluation failed"
 */
const char * ejs_error_message(const EJSCoreError *error);

/**
 * ejs_error_stack — 获取错误的 JS 堆栈跟踪
 *
 * 返回的字符串在 ejs_error_destroy 前有效。仅当错误源自 JS 异常时
 * 才有堆栈信息；运行时内部错误（如无效参数）通常无堆栈。
 *
 * @param error 错误对象，可为 NULL（返回 NULL）
 * @return JS 堆栈跟踪字符串，若无堆栈则返回 NULL
 */
const char * ejs_error_stack(const EJSCoreError *error);

/**
 * ejs_error_platform_domain — 获取平台相关的错误域标识
 *
 * 标识产生错误的平台子系统，如 "libuv"、"net"、"ssl" 等。
 * 仅当错误源自宿主原生层时才有值。
 *
 * @param error 错误对象，可为 NULL（返回 NULL）
 * @return 平台错误域字符串
 */
const char * ejs_error_platform_domain(const EJSCoreError *error);

/**
 * ejs_error_platform_code — 获取平台相关的错误码
 *
 * 对应 platform_domain 子系统的具体错误码，如 libuv 的 UV_ECONNREFUSED、
 * OpenSSL 的 ERR_PACK 等。仅当错误源自宿主原生层时才有意义。
 *
 * @param error 错误对象，可为 NULL（返回 0）
 * @return 平台错误码
 */
int ejs_error_platform_code(const EJSCoreError *error);

/**
 * ejs_error_destroy — 销毁错误对象
 *
 * 释放错误对象及其关联的所有字符串（message、stack、platform_domain）。
 * 销毁后 error 指针不可再使用。传入 NULL 是安全的（无操作）。
 *
 * @param error 待销毁的错误对象，可为 NULL
 */
void ejs_error_destroy(EJSCoreError *error);

#ifdef __cplusplus
}
#endif

#endif /* ifndef EJS_RUNTIME_H */

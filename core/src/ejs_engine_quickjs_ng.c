/**
 * ejs_engine_quickjs_ng.c — QuickJS-ng 引擎后端的完整实现
 *
 * 本文件实现了 ejs_engine.h 中定义的所有引擎后端接口函数，
 * 基于 QuickJS-ng 引擎提供 JS 脚本/模块执行、微任务驱动、中断请求、
 * 内核绑定注册等能力。
 *
 * 核心架构：
 *   EJSEngineRuntime — 包装 QuickJS 的 JSRuntime，管理引擎级别的资源
 *     ├── JSRuntime *runtime          — QuickJS 运行时实例
 *     ├── interrupt_requested         — 中断标志（原子变量），由 ejs_engine_request_interrupt 设置
 *     └── test_active_context         — 测试用：当前活跃的 JSContext 指针（仅 EJS_TEST）
 *
 *   EJSEngineContext — 包装 QuickJS 的 JSContext，管理上下文级别的资源
 *     ├── EJSEngineRuntime *runtime   — 反向引用所属引擎运行时
 *     ├── JSContext *context          — QuickJS 上下文实例
 *     ├── EJSTimerState *timer_list   — 单链表，挂载所有活跃的 JS 定时器状态
 *     ├── uint64_t next_timer_id      — 下一个定时器的自增 ID
 *     └── EJSInvokeState *invoke_list — 双链表，挂载所有挂起的异步调用状态
 *
 *   EJSInvokeState — 一次 __ejs_native__.invoke 调用的完整生命周期状态
 *     ├── ctx                         — JSContext 原子指针（销毁时置 NULL）
 *     ├── runtime                     — 所属的 EJSCoreRuntime
 *     ├── resolve_func / reject_func  — Promise 的 resolve/reject 函数引用
 *     ├── ref_count                   — 原子引用计数（链表引用 + 宿主引用 + 任务队列引用）
 *     ├── completed                   — 原子标志，防止重复完成
 *     ├── op                          — 关联的 EJSCoreHostOperation 异步操作
 *     └── prev / next                 — 双链表节点，用于 EJSEngineContext.invoke_list
 *
 *   EJSTimerState — 一个 JS 定时器（setTimeout/setInterval）的引擎侧状态
 *     ├── ctx                         — 关联的 JSContext
 *     ├── callback                    — JS 回调函数引用
 *     ├── timer                       — 底层运行时定时器实例
 *     ├── timer_id                    — 定时器的唯一标识
 *     ├── repeat                      — 是否为重复定时器（interval）
 *     └── next                        — 单链表后继指针
 *
 * 线程安全：
 *   - interrupt_requested、completed、ref_count、ctx 均为原子变量
 *   - invoke 回调（ejs_invoke_completion_callback）可能从宿主工作线程调用，
 *     通过 ejs_runtime_loop_post 将完成回调投递到 owner 线程执行
 *   - 所有 JS 操作（JS_Call、JS_FreeValue 等）仅在 owner 线程上执行
 *
 * 测试错误注入机制（仅 EJS_TEST 构建）：
 *   ejs_test_inject_engine_error 全局变量用于测试中模拟各种失败路径，
 *   每个错误注入点对应一个整数值（如 1=JS_NewRuntime 失败，2=calloc 失败等）。
 *   生产构建不会编译该变量或任何错误注入分支。
 */

#include "ejs_engine.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef EJS_TEST
/**
 * ejs_test_inject_engine_error — 错误注入开关（仅测试使用）
 *
 * 测试框架通过设置此变量为特定整数值，在代码中的对应注入点模拟内存分配失败、
 * 引擎初始化失败等异常路径，以验证错误处理的健壮性。
 *
 * 错误注入点编号说明：
 *   1  — EJSEngineRuntime 分配失败
 *   2  — JS_NewRuntime 失败
 *   3  — EJSEngineContext 分配失败
 *   4  — JS_NewContext 失败
 *   5  — EJSTimerState 分配失败
 *   8  — EJSInvokeState 分配失败
 *   9  — JS_NewPromiseCapability 失败
 *   10 — module_id 转换失败模拟
 *   11 — JS_ExecutePendingJob 返回 -1 模拟
 *   12 — runtime loop 不可用模拟
 *   13/14 — timer init/start 失败模拟
 *   15 — EJSInvokeCompletionTask 分配失败
 *   16 — completion result_data 分配失败
 *   17 — core bindings 注册失败
 *   29 — 异步 invoke payload 字符串转换失败模拟
 *   30 — 同步 invoke payload 字符串转换失败模拟
 *   31 — 同步 invoke 返回 ArrayBuffer 复制失败模拟
 *
 * 注意：该符号以及所有读取它的分支都必须被 #ifdef EJS_TEST 包住。
 * 它是白盒测试入口，不属于 engine ABI；生产构建中暴露它会把测试控制面
 * 带入发布产物，并让非测试代码能够触发不真实的失败路径。
 */
int ejs_test_inject_engine_error = 0;
#endif

#include "ejs_native_api.h"
#include "ejs_runtime_internal.h"
#include "ejs_runtime_loop.h"
#include "ejs_util.h"
#include "quickjs.h"

/**
 * EJSTimerState — JS 定时器的引擎侧状态
 *
 * 每个 setTimeout/setInterval 调用都会创建一个 EJSTimerState 实例，
 * 挂载在 EJSEngineContext 的 timer_list 单链表中。
 * 当定时器触发时，通过 JS_Call 调用保存的 callback；
 * 非重复定时器触发后自动从链表中移除并销毁。
 */
typedef struct EJSTimerState {
    JSContext *ctx;            /* 关联的 QuickJS 上下文 */
    JSValue callback;          /* JS 回调函数引用（JS_DupValue 增加引用计数） */
    EJSRuntimeTimer *timer;    /* 底层运行时定时器实例（libuv timer 或 stub） */
    uint64_t timer_id;         /* 定时器的唯一自增 ID，由 next_timer_id 分配 */
    bool repeat;               /* true 表示 setInterval（重复触发），false 表示 setTimeout */
    bool firing;               /* 当前是否正在 JS_Call 该 callback */
    bool pending_destroy;      /* firing 期间 clear 自身时延迟释放 JS 引用 */
    struct EJSTimerState *next; /* 单链表后继指针 */
} EJSTimerState;

/**
 * EJSInvokeState — 前向声明
 *
 * 完整定义在下方，表示一次异步 invoke 调用的生命周期状态。
 */
typedef struct EJSInvokeState EJSInvokeState;
typedef struct EJSPromiseRejectionState EJSPromiseRejectionState;
typedef struct EJSModuleSourceRecord EJSModuleSourceRecord;

/**
 * struct EJSEngineRuntime — QuickJS-ng 引擎运行时的内部表示
 *
 * 包装 QuickJS 的 JSRuntime，并添加中断控制等 EJS 特有功能。
 */
struct EJSEngineRuntime {
    JSRuntime *runtime;              /* QuickJS 运行时实例，管理 GC、内存分配等 */
    _Atomic(bool) interrupt_requested; /* 中断请求标志，由 ejs_engine_request_interrupt 原子设置 */
    struct EJSEngineContext *pending_rejection_contexts; /* 等待 checkpoint 派发 unhandled rejection 的 context 链表 */
#ifdef EJS_TEST
    /*
     * 测试辅助：记录当前活跃的 JSContext，用于 JS_ExecutePendingJob 失败注入时
     * 构造 EJSCoreError。该字段只在 EJS_TEST 中存在，生产结构体布局不包含测试状态。
     */
    void *test_active_context;
#endif
};

struct EJSPromiseRejectionState {
    JSValue promise;
    JSValue reason;
    uint64_t epoch;
    bool reported;
    EJSPromiseRejectionState *prev;
    EJSPromiseRejectionState *next;
};

struct EJSModuleSourceRecord {
    char *specifier;
    char *source_url;
    char *source;
    size_t source_len;
    EJSModuleSourceRecord *next;
};

/**
 * struct EJSEngineContext — QuickJS-ng 引擎上下文的内部表示
 *
 * 包装 QuickJS 的 JSContext，并管理定时器列表和异步调用列表。
 */
struct EJSEngineContext {
    EJSEngineRuntime *runtime; /* 反向引用所属的引擎运行时 */
    JSContext *context;        /* QuickJS 上下文实例，拥有独立的全局对象和模块作用域 */
    EJSTimerState *timer_list; /* 活跃定时器的单链表头 */
    uint64_t next_timer_id;   /* 下一个定时器的自增 ID，初始为 1 */
    EJSInvokeState *invoke_list;/* 挂起的异步调用的双链表头 */
    JSValue promise_rejection_tracker; /* __ejs_native__.events 注册的 Promise rejection 回调 */
    JSValue exception_reporter; /* __ejs_native__.events 注册的异步异常回调 */
    EJSPromiseRejectionState *promise_rejection_list; /* 已 reject、等待 checkpoint 或 late handled 的 Promise */
    EJSModuleSourceRecord *module_source_list; /* context-scoped 已审核模块源码表 */
    struct EJSEngineContext *pending_rejection_next; /* EJSEngineRuntime.pending_rejection_contexts 链表节点 */
    uint64_t promise_rejection_epoch; /* 每次 checkpoint 递增，避免本轮派发新产生的 rejection */
    bool reporting_exception; /* 防止 exception reporter 自身抛错时递归汇报 */
    bool reporting_promise_rejection; /* 防止 rejection tracker 回调重入风暴 */
    bool pending_rejection_queued; /* 当前 context 是否已挂入 runtime 的 pending_rejection_contexts */
    bool diagnostic_reported; /* reporter/tracker 自身失败时只输出一次内部诊断 */
};

/**
 * struct EJSInvokeState — 异步 invoke 调用的生命周期状态
 *
 * 当 JS 侧调用 __ejs_native__.invoke 时，会创建一个 EJSInvokeState 实例，
 * 并创建一个 JS Promise 返回给调用方。宿主完成操作后通过
 * ejs_invoke_completion_callback 通知，完成回调被投递到 owner 线程
 * 执行 JS 的 resolve/reject。
 *
 * 引用计数模型（三引用）：
 *   初始 ref_count = 1（链表引用）
 *   宿主接收后 +1（宿主引用）
 *   投递完成回调时 +1（任务队列引用）
 *   各引用方独立释放，归零时触发 ejs_invoke_state_dec_ref 中的资源清理
 *
 * completion_data 所有权：
 *   - 传给宿主的 completion_data 实际就是 EJSInvokeState *。
 *   - 宿主只把它保存为不透明指针，并在完成时原样传给 EJSCoreInvokeCompletion；
 *     宿主不得释放或解引用。
 *   - 首次 completion 后宿主引用会被释放；之后继续使用 completion_data 属于
 *     宿主生命周期错误，runtime 只能防御同步重复调用，不能保证悬挂指针安全。
 *   - host_ref_released 是防御性闸门，确保同步重复 completion 或上下文销毁路径
 *     不会把同一份宿主引用释放两次。
 *
 * host API 快照：
 *   - operations 在 invoke 创建时从当时注册的 host 中复制一份。
 *   - 后续 cancel/release 必须使用这份快照，而不是重新读取 context->host；
 *     否则 host 被重新注册后，旧 operation 可能被错误地交给新宿主释放。
 *   - 因此旧 operations.user_data 必须由宿主保持有效，直到旧 operation 全部结束。
 */
struct EJSInvokeState {
    _Atomic(JSContext *) ctx;  /* JSContext 原子指针，上下文销毁时置 NULL 以防止悬挂访问 */
    EJSCoreRuntime *runtime;       /* 所属的 EJSCoreRuntime，用于投递完成回调到事件循环 */
    JSValue resolve_func;      /* Promise resolve 函数引用，完成时调用 */
    JSValue reject_func;       /* Promise reject 函数引用，失败时调用 */
    atomic_int ref_count;      /* 原子引用计数，控制销毁时机 */
    _Atomic(bool) completed;   /* 原子标志，防止完成回调被重复调用 */
    EJSCoreHostOperation *op;      /* 关联的宿主异步操作，用于取消和释放 */
    pthread_mutex_t op_mutex;  /* 保护 host invoke 返回前的同步 completion/cancel 竞态 */
    bool op_release_requested; /* op 赋值前已经请求 release */
    bool op_cancel_requested;  /* op 赋值前已经请求 cancel */
    EJSRegisteredHost *host;   /* 创建 invoke 时的内部注册宿主对象，托管生命周期 */
    _Atomic(bool) host_ref_released; /* completion_data 对应的宿主引用是否已释放 */
    struct EJSInvokeState *prev; /* 双链表前驱指针 */
    struct EJSInvokeState *next; /* 双链表后继指针 */
};

/**
 * EJSInvokeCompletionTask — 异步调用完成回调的投递任务
 *
 * 当宿主操作完成时，将结果数据封装到此结构体中，通过
 * ejs_runtime_loop_post 投递到 owner 线程执行。
 * 所有指针字段（result_data、error_message、error_platform_domain）
 * 均为堆分配的副本，确保在跨线程传递时安全。
 */
typedef struct {
    EJSInvokeState *state;     /* 关联的异步调用状态 */
    uint8_t *result_data;      /* 操作结果的二进制数据副本（堆分配），可为 NULL */
    size_t result_size;        /* 结果数据的字节长度 */
    bool has_result;           /* 是否有显式结果；允许 zero-length ArrayBuffer */
    int has_error;             /* 是否包含错误（非零表示有错误） */
    EJSCoreHostError error;        /* 宿主错误结构体副本 */
    char *error_message;       /* 错误消息的堆分配副本（独立于原始 host_error 生命周期） */
    char *error_platform_domain; /* 平台错误域的堆分配副本 */
} EJSInvokeCompletionTask;

static void ejs_invoke_state_dec_ref(EJSInvokeState *state);

/**
 * ejs_error_from_exception — 从 QuickJS 当前异常创建 EJSCoreError
 *
 * 从 JSContext 中获取当前挂起的异常对象，提取其 message 和 stack 属性，
 * 封装为 EJSCoreError 返回。若当前无异常，使用 fallback_message 作为错误描述。
 *
 * 注意：此函数会消费掉 JSContext 中的当前异常（通过 JS_GetException 取出），
 * 调用后 JS_ClearException 不再需要。
 *
 * @param ctx             QuickJS 上下文
 * @param fallback_message 无异常时使用的默认错误消息
 * @return 新创建的 EJSCoreError 对象，调用方负责销毁
 */
static EJSCoreError * ejs_error_from_exception(JSContext *ctx, const char *fallback_message) {
    const char *message = fallback_message;
    const char *stack = NULL;
    JSValue exception = JS_GetException(ctx);
    JSValue stack_value = JS_UNDEFINED;

    if (!JS_IsUndefined(exception) && !JS_IsNull(exception)) {
        const char *exception_message = JS_ToCString(ctx, exception);

        if (exception_message != NULL) {
            message = exception_message;
        }

        if (JS_IsObject(exception)) {
            stack_value = JS_GetPropertyStr(ctx, exception, "stack");
        }

        if (!JS_IsUndefined(stack_value) && !JS_IsNull(stack_value)) {
            stack = JS_ToCString(ctx, stack_value);
        }

        EJSCoreError *error = ejs_error_create(EJS_ERROR_INTERNAL, message, stack, NULL, 0);

        if (stack != NULL) {
            JS_FreeCString(ctx, stack);
        }

        JS_FreeValue(ctx, stack_value);

        if (exception_message != NULL) {
            JS_FreeCString(ctx, exception_message);
        }

        JS_FreeValue(ctx, exception);
        return error;
    }

    JS_FreeValue(ctx, exception);
    return ejs_error_create(EJS_ERROR_INTERNAL, message, NULL, NULL, 0);
}

/**
 * ejs_result_from_eval — 将 QuickJS 求值结果转换为 EJSCoreResult
 *
 * 若 JSValue 为异常，从中提取错误信息返回失败结果；
 * 否则释放返回值并返回成功结果。
 * 注意：EJSCoreResult 不携带求值的返回值（因为 EJS 公共 API 不需要），
 * 仅表示执行是否成功。
 *
 * @param ctx   QuickJS 上下文
 * @param value QuickJS 求值返回值
 * @return 成功或失败的 EJSCoreResult
 */
static EJSCoreResult ejs_result_from_eval(JSContext *ctx, JSValue value) {
    if (JS_IsException(value)) {
        return ejs_result_error(ejs_error_from_exception(ctx, "JavaScript evaluation failed"));
    }

    JS_FreeValue(ctx, value);
    return ejs_result_ok();
}

static EJSCoreResult ejs_result_from_module_eval(EJSEngineContext *context, JSValue value) {
    JSContext *ctx = context->context;

    if (JS_IsException(value)) {
        return ejs_result_error(ejs_error_from_exception(ctx, "JavaScript module evaluation failed"));
    }

    if (!JS_IsPromise(value)) {
        JS_FreeValue(ctx, value);
        return ejs_result_ok();
    }

    EJSCoreResult jobs_result = ejs_engine_run_jobs(context->runtime);
    if (jobs_result.status != EJS_STATUS_OK) {
        JS_FreeValue(ctx, value);
        return jobs_result;
    }

    JSPromiseStateEnum state = JS_PromiseState(ctx, value);
    if (state == JS_PROMISE_FULFILLED) {
        JS_FreeValue(ctx, value);
        return ejs_result_ok();
    }

    if (state == JS_PROMISE_REJECTED) {
        JS_Throw(ctx, JS_PromiseResult(ctx, value));
        EJSCoreError *error = ejs_error_from_exception(ctx, "JavaScript module evaluation failed");
        JS_FreeValue(ctx, value);
        return ejs_result_error(error);
    }

    JS_FreeValue(ctx, value);
    return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                             "JavaScript module evaluation promise is still pending",
                                             NULL,
                                             NULL,
                                             0));
}

static EJSEngineContext * ejs_engine_context_from_js_context(JSContext *ctx) {
    EJSCoreContext *public_ctx = ctx != NULL ? (EJSCoreContext *)JS_GetContextOpaque(ctx) : NULL;

    if (public_ctx == NULL || public_ctx->engine_context == NULL) {
        return NULL;
    }

    return public_ctx->engine_context;
}

static void ejs_module_source_record_free(EJSModuleSourceRecord *record) {
    if (record == NULL) {
        return;
    }

    free(record->specifier);
    free(record->source_url);
    free(record->source);
    free(record);
}

static void ejs_module_source_list_free(EJSModuleSourceRecord *record) {
    while (record != NULL) {
        EJSModuleSourceRecord *next = record->next;
        ejs_module_source_record_free(record);
        record = next;
    }
}

static const char * ejs_module_source_canonical_specifier(const EJSModuleSourceRecord *record) {
    if (record == NULL) {
        return NULL;
    }

    return record->source_url != NULL ? record->source_url : record->specifier;
}

static EJSModuleSourceRecord * ejs_module_source_find(EJSEngineContext *context,
                                                      const char *specifier) {
    if (context == NULL || specifier == NULL) {
        return NULL;
    }

    for (EJSModuleSourceRecord *record = context->module_source_list;
         record != NULL;
         record = record->next) {
        if (record->specifier != NULL && strcmp(record->specifier, specifier) == 0) {
            return record;
        }
        if (record->source_url != NULL && strcmp(record->source_url, specifier) == 0) {
            return record;
        }
    }

    return NULL;
}

static char * ejs_copy_source_bytes(const char *source, size_t source_len) {
    if (source_len == (size_t)-1) {
        return NULL;
    }

    char *copy = (char *)malloc(source_len + 1u);

    if (copy == NULL) {
        return NULL;
    }

    if (source_len > 0u) {
        memcpy(copy, source, source_len);
    }
    copy[source_len] = '\0';
    return copy;
}

static EJSModuleSourceRecord * ejs_module_source_record_create(const EJSCoreModuleSource *source) {
    if (source == NULL ||
        source->specifier == NULL ||
        source->specifier[0] == '\0' ||
        source->source == NULL) {
        return NULL;
    }

    EJSModuleSourceRecord *record = (EJSModuleSourceRecord *)calloc(1u, sizeof(EJSModuleSourceRecord));
    if (record == NULL) {
        return NULL;
    }

    record->specifier = ejs_strdup_or_null(source->specifier);
    record->source_url = ejs_strdup_or_null(source->source_url != NULL ? source->source_url : source->specifier);
    record->source = ejs_copy_source_bytes(source->source, source->source_len);
    record->source_len = source->source_len;

    if (record->specifier == NULL || record->source_url == NULL || record->source == NULL) {
        ejs_module_source_record_free(record);
        return NULL;
    }

    return record;
}

static void ejs_module_source_upsert(EJSEngineContext *context, EJSModuleSourceRecord *record) {
    EJSModuleSourceRecord *prev = NULL;
    EJSModuleSourceRecord *current = context->module_source_list;

    while (current != NULL) {
        if (strcmp(current->specifier, record->specifier) == 0) {
            if (prev != NULL) {
                prev->next = current->next;
            } else {
                context->module_source_list = current->next;
            }
            ejs_module_source_record_free(current);
            break;
        }
        prev = current;
        current = current->next;
    }

    record->next = context->module_source_list;
    context->module_source_list = record;
}

static char * ejs_module_normalize_candidate(const char *base_name, const char *module_name) {
    if (module_name == NULL) {
        return NULL;
    }

    if (module_name[0] != '.') {
        return ejs_strdup_or_null(module_name);
    }

    const char *base = base_name != NULL ? base_name : "";
    const char *slash = strrchr(base, '/');
    size_t base_len = slash != NULL ? (size_t)(slash - base) : 0u;
    size_t module_len = strlen(module_name);
    if (base_len > (size_t)-1 - module_len - 2u) {
        return NULL;
    }
    size_t cap = base_len + module_len + 2u;
    char *filename = (char *)malloc(cap);

    if (filename == NULL) {
        return NULL;
    }

    if (base_len > 0u) {
        memcpy(filename, base, base_len);
    }
    filename[base_len] = '\0';

    const char *rest = module_name;
    for (;;) {
        if (rest[0] == '.' && rest[1] == '/') {
            rest += 2;
            continue;
        }
        if (rest[0] == '.' && rest[1] == '.' && rest[2] == '/') {
            if (filename[0] == '\0') {
                break;
            }
            char *last = strrchr(filename, '/');
            if (last == NULL) {
                last = filename;
            } else {
                last++;
            }
            if (strcmp(last, ".") == 0 || strcmp(last, "..") == 0) {
                break;
            }
            if (last > filename) {
                last--;
            }
            *last = '\0';
            rest += 3;
            continue;
        }
        break;
    }

    if (filename[0] != '\0') {
        strncat(filename, "/", cap - strlen(filename) - 1u);
    }
    strncat(filename, rest, cap - strlen(filename) - 1u);
    return filename;
}

static char * ejs_js_strdup(JSContext *ctx, const char *value) {
    if (ctx == NULL || value == NULL) {
        return NULL;
    }

    size_t len = strlen(value);
    char *copy = (char *)js_malloc(ctx, len + 1u);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, value, len + 1u);
    return copy;
}

static char * ejs_quickjs_module_normalize(JSContext *ctx,
                                           const char *base_name,
                                           const char *module_name,
                                           void *opaque) {
    (void)opaque;

    EJSEngineContext *engine_ctx = ejs_engine_context_from_js_context(ctx);
    char *candidate = ejs_module_normalize_candidate(base_name, module_name);

    if (candidate == NULL) {
        JS_ThrowOutOfMemory(ctx);
        return NULL;
    }

    EJSModuleSourceRecord *record = ejs_module_source_find(engine_ctx, candidate);
    if (record == NULL) {
        JS_ThrowReferenceError(ctx,
                               "could not resolve module '%s' from '%s'",
                               module_name != NULL ? module_name : "",
                               base_name != NULL ? base_name : "<module>");
        free(candidate);
        return NULL;
    }

    const char *canonical = ejs_module_source_canonical_specifier(record);
    char *normalized = ejs_js_strdup(ctx, canonical);
    free(candidate);
    if (normalized == NULL) {
        JS_ThrowOutOfMemory(ctx);
    }
    return normalized;
}

static int ejs_set_module_import_meta(JSContext *ctx,
                                      JSValueConst module_value,
                                      const char *source_url,
                                      bool is_main) {
    if (!JS_IsModule(module_value)) {
        return 0;
    }

    JSModuleDef *module = JS_VALUE_GET_PTR(module_value);
    JSValue meta = JS_GetImportMeta(ctx, module);

    if (JS_IsException(meta)) {
        return -1;
    }

    const char *url = source_url != NULL ? source_url : "";
    if (JS_DefinePropertyValueStr(ctx,
                                  meta,
                                  "url",
                                  JS_NewString(ctx, url),
                                  JS_PROP_C_W_E) < 0) {
        JS_FreeValue(ctx, meta);
        return -1;
    }
    if (JS_DefinePropertyValueStr(ctx,
                                  meta,
                                  "main",
                                  JS_NewBool(ctx, is_main),
                                  JS_PROP_C_W_E) < 0) {
        JS_FreeValue(ctx, meta);
        return -1;
    }

    JS_FreeValue(ctx, meta);
    return 0;
}

static JSModuleDef * ejs_quickjs_module_loader(JSContext *ctx,
                                               const char *module_name,
                                               void *opaque) {
    (void)opaque;

    EJSEngineContext *engine_ctx = ejs_engine_context_from_js_context(ctx);
    EJSModuleSourceRecord *record = ejs_module_source_find(engine_ctx, module_name);

    if (record == NULL) {
        JS_ThrowReferenceError(ctx,
                               "registered module source not found: '%s'",
                               module_name != NULL ? module_name : "");
        return NULL;
    }

    const char *canonical = ejs_module_source_canonical_specifier(record);
    JSValue module_value = JS_Eval(ctx,
                                   record->source,
                                   record->source_len,
                                   canonical,
                                   JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(module_value)) {
        return NULL;
    }

    if (ejs_set_module_import_meta(ctx, module_value, canonical, false) < 0) {
        JS_FreeValue(ctx, module_value);
        return NULL;
    }

    JSModuleDef *module = JS_VALUE_GET_PTR(module_value);
    JS_FreeValue(ctx, module_value);
    return module;
}

static bool ejs_engine_has_exception_reporter(JSContext *ctx) {
    EJSEngineContext *engine_ctx = ejs_engine_context_from_js_context(ctx);

    return engine_ctx != NULL &&
           !JS_IsUndefined(engine_ctx->exception_reporter) &&
           !JS_IsNull(engine_ctx->exception_reporter);
}

static void ejs_engine_record_internal_diagnostic(EJSEngineContext *engine_ctx,
                                                  const char *message) {
    if (engine_ctx == NULL || engine_ctx->diagnostic_reported) {
        return;
    }

    engine_ctx->diagnostic_reported = true;
    fprintf(stderr, "EJS internal diagnostic: %s\n",
            message != NULL ? message : "exception reporting failed");
}

static JSValue ejs_engine_create_error_value(JSContext *ctx, const char *message) {
    JSValue error = JS_NewError(ctx);

    if (JS_IsException(error)) {
        return error;
    }

    JSValue message_value = JS_NewString(ctx, message != NULL ? message : "JavaScript exception");

    if (JS_IsException(message_value)) {
        JS_FreeValue(ctx, error);
        return JS_EXCEPTION;
    }

    if (JS_DefinePropertyValueStr(ctx,
                                  error,
                                  "message",
                                  message_value,
                                  JS_PROP_C_W_E) < 0) {
        JS_FreeValue(ctx, error);
        return JS_EXCEPTION;
    }

    return error;
}

static bool ejs_engine_report_exception_value(JSContext *ctx,
                                              JSValue exception,
                                              const char *fallback_message) {
    EJSEngineContext *engine_ctx = ejs_engine_context_from_js_context(ctx);

    if (engine_ctx == NULL ||
        JS_IsUndefined(engine_ctx->exception_reporter) ||
        JS_IsNull(engine_ctx->exception_reporter)) {
        JS_FreeValue(ctx, exception);
        return false;
    }

    if (engine_ctx->reporting_exception) {
        ejs_engine_record_internal_diagnostic(engine_ctx, "exception reporter threw recursively");
        JS_FreeValue(ctx, exception);
        return true;
    }

    if (JS_IsUndefined(exception) || JS_IsNull(exception)) {
        JS_FreeValue(ctx, exception);
        exception = ejs_engine_create_error_value(ctx, fallback_message);
    }

    if (JS_IsException(exception)) {
        ejs_engine_record_internal_diagnostic(engine_ctx, "failed to create exception report value");
        JSValue creation_exception = JS_GetException(ctx);
        JS_FreeValue(ctx, creation_exception);
        return true;
    }

    engine_ctx->reporting_exception = true;
    JSValue callback = JS_DupValue(ctx, engine_ctx->exception_reporter);
    JSValue args[1] = { exception };
    JSValue ret = JS_Call(ctx, callback, JS_UNDEFINED, 1, args);

    if (JS_IsException(ret)) {
        JSValue reporter_exception = JS_GetException(ctx);
        JS_FreeValue(ctx, reporter_exception);
        ejs_engine_record_internal_diagnostic(engine_ctx, "exception reporter callback threw");
    }

    JS_FreeValue(ctx, ret);
    JS_FreeValue(ctx, callback);
    engine_ctx->reporting_exception = false;
    JS_FreeValue(ctx, exception);
    return true;
}

static bool ejs_engine_report_current_exception(JSContext *ctx, const char *fallback_message) {
    if (!ejs_engine_has_exception_reporter(ctx)) {
        return false;
    }

    JSValue exception = JS_GetException(ctx);
    return ejs_engine_report_exception_value(ctx, exception, fallback_message);
}

static void ejs_engine_clear_current_exception(JSContext *ctx) {
    JSValue exception = JS_GetException(ctx);
    JS_FreeValue(ctx, exception);
}

static void ejs_engine_report_or_clear_current_exception(JSContext *ctx,
                                                         const char *fallback_message) {
    if (!ejs_engine_report_current_exception(ctx, fallback_message)) {
        ejs_engine_clear_current_exception(ctx);
    }
}

static EJSPromiseRejectionState * ejs_promise_rejection_find(EJSEngineContext *engine_ctx,
                                                             JSValueConst promise) {
    if (engine_ctx == NULL) {
        return NULL;
    }

    EJSPromiseRejectionState *state = engine_ctx->promise_rejection_list;
    while (state != NULL) {
        if (JS_IsSameValue(engine_ctx->context, state->promise, promise)) {
            return state;
        }
        state = state->next;
    }
    return NULL;
}

static EJSPromiseRejectionState *
ejs_promise_rejection_find_unreported_before(EJSEngineContext *engine_ctx, uint64_t epoch) {
    if (engine_ctx == NULL) {
        return NULL;
    }

    EJSPromiseRejectionState *state = engine_ctx->promise_rejection_list;
    while (state != NULL) {
        if (!state->reported && state->epoch < epoch) {
            return state;
        }
        state = state->next;
    }
    return NULL;
}

static void ejs_promise_rejection_unlink(EJSEngineContext *engine_ctx,
                                         EJSPromiseRejectionState *state) {
    if (engine_ctx == NULL || state == NULL) {
        return;
    }

    if (state->prev != NULL) {
        state->prev->next = state->next;
    } else if (engine_ctx->promise_rejection_list == state) {
        engine_ctx->promise_rejection_list = state->next;
    }

    if (state->next != NULL) {
        state->next->prev = state->prev;
    }

    state->prev = NULL;
    state->next = NULL;
}

static void ejs_promise_rejection_free(JSContext *ctx, EJSPromiseRejectionState *state) {
    if (state == NULL) {
        return;
    }

    JS_FreeValue(ctx, state->promise);
    JS_FreeValue(ctx, state->reason);
    free(state);
}

static void ejs_engine_enqueue_pending_rejection_context(EJSEngineContext *engine_ctx) {
    if (engine_ctx == NULL ||
        engine_ctx->runtime == NULL ||
        engine_ctx->pending_rejection_queued) {
        return;
    }

    engine_ctx->pending_rejection_queued = true;
    engine_ctx->pending_rejection_next = engine_ctx->runtime->pending_rejection_contexts;
    engine_ctx->runtime->pending_rejection_contexts = engine_ctx;
}

static void ejs_engine_remove_pending_rejection_context(EJSEngineContext *engine_ctx) {
    if (engine_ctx == NULL || engine_ctx->runtime == NULL || !engine_ctx->pending_rejection_queued) {
        return;
    }

    EJSEngineContext **indirect = &engine_ctx->runtime->pending_rejection_contexts;
    while (*indirect != NULL) {
        if (*indirect == engine_ctx) {
            *indirect = engine_ctx->pending_rejection_next;
            break;
        }
        indirect = &(*indirect)->pending_rejection_next;
    }

    engine_ctx->pending_rejection_next = NULL;
    engine_ctx->pending_rejection_queued = false;
}

static void ejs_promise_rejection_clear_all(EJSEngineContext *engine_ctx) {
    if (engine_ctx == NULL) {
        return;
    }

    ejs_engine_remove_pending_rejection_context(engine_ctx);
    while (engine_ctx->promise_rejection_list != NULL) {
        EJSPromiseRejectionState *state = engine_ctx->promise_rejection_list;
        engine_ctx->promise_rejection_list = state->next;
        state->prev = NULL;
        state->next = NULL;
        ejs_promise_rejection_free(engine_ctx->context, state);
    }
}

static bool ejs_engine_dispatch_promise_rejection_event(EJSEngineContext *engine_ctx,
                                                        const char *kind_text,
                                                        JSValueConst promise,
                                                        JSValueConst reason) {
    JSContext *ctx = engine_ctx != NULL ? engine_ctx->context : NULL;

    if (ctx == NULL ||
        JS_IsUndefined(engine_ctx->promise_rejection_tracker) ||
        JS_IsNull(engine_ctx->promise_rejection_tracker)) {
        return false;
    }

    if (engine_ctx->reporting_promise_rejection) {
        ejs_engine_record_internal_diagnostic(engine_ctx, "promise rejection tracker re-entered");
        return true;
    }

    JSValue callback = JS_DupValue(ctx, engine_ctx->promise_rejection_tracker);
    JSValue kind = JS_NewString(ctx, kind_text != NULL ? kind_text : "unhandled");

    if (JS_IsException(kind)) {
        JS_FreeValue(ctx, callback);
        ejs_engine_report_or_clear_current_exception(ctx, "failed to create rejection tracker event");
        return true;
    }

    JSValue promise_arg = JS_DupValue(ctx, promise);
    JSValue reason_arg = JS_DupValue(ctx, reason);
    JSValue args[3] = { kind, promise_arg, reason_arg };

    engine_ctx->reporting_promise_rejection = true;
    JSValue ret = JS_Call(ctx, callback, JS_UNDEFINED, 3, args);
    engine_ctx->reporting_promise_rejection = false;

    JS_FreeValue(ctx, reason_arg);
    JS_FreeValue(ctx, promise_arg);
    JS_FreeValue(ctx, kind);
    JS_FreeValue(ctx, callback);

    if (JS_IsException(ret)) {
        ejs_engine_report_or_clear_current_exception(ctx, "promise rejection tracker callback threw");
    }

    JS_FreeValue(ctx, ret);
    return true;
}

static void ejs_engine_flush_promise_rejections_for_context(EJSEngineContext *engine_ctx) {
    if (engine_ctx == NULL || engine_ctx->context == NULL) {
        return;
    }

    uint64_t flush_epoch = ++engine_ctx->promise_rejection_epoch;
    for (;;) {
        EJSPromiseRejectionState *state =
            ejs_promise_rejection_find_unreported_before(engine_ctx, flush_epoch);
        if (state == NULL) {
            break;
        }

        if (JS_IsUndefined(engine_ctx->promise_rejection_tracker) ||
            JS_IsNull(engine_ctx->promise_rejection_tracker)) {
            ejs_promise_rejection_unlink(engine_ctx, state);
            ejs_promise_rejection_free(engine_ctx->context, state);
            continue;
        }

        state->reported = true;
        (void)ejs_engine_dispatch_promise_rejection_event(engine_ctx,
                                                          "unhandled",
                                                          state->promise,
                                                          state->reason);
    }
}

static void ejs_engine_flush_pending_promise_rejections(EJSEngineRuntime *engine) {
    if (engine == NULL) {
        return;
    }

    EJSEngineContext *pending_contexts = engine->pending_rejection_contexts;
    engine->pending_rejection_contexts = NULL;

    while (pending_contexts != NULL) {
        EJSEngineContext *engine_ctx = pending_contexts;
        pending_contexts = engine_ctx->pending_rejection_next;
        engine_ctx->pending_rejection_next = NULL;
        engine_ctx->pending_rejection_queued = false;
        ejs_engine_flush_promise_rejections_for_context(engine_ctx);
    }
}

static void ejs_quickjs_promise_rejection_tracker(JSContext *ctx,
                                                  JSValueConst promise,
                                                  JSValueConst reason,
                                                  bool is_handled,
                                                  void *opaque) {
    (void)opaque;

    EJSEngineContext *engine_ctx = ejs_engine_context_from_js_context(ctx);

    if (engine_ctx == NULL) {
        return;
    }

    EJSPromiseRejectionState *state = ejs_promise_rejection_find(engine_ctx, promise);

    if (is_handled) {
        if (state == NULL) {
            return;
        }

        bool reported = state->reported;
        JSValue promise_arg = JS_DupValue(ctx, state->promise);
        JSValue reason_arg = JS_DupValue(ctx, state->reason);
        ejs_promise_rejection_unlink(engine_ctx, state);
        ejs_promise_rejection_free(ctx, state);

        if (reported) {
            (void)ejs_engine_dispatch_promise_rejection_event(engine_ctx,
                                                              "handled",
                                                              promise_arg,
                                                              reason_arg);
        }

        JS_FreeValue(ctx, reason_arg);
        JS_FreeValue(ctx, promise_arg);
        return;
    }

    if (JS_IsUndefined(engine_ctx->promise_rejection_tracker) ||
        JS_IsNull(engine_ctx->promise_rejection_tracker)) {
        return;
    }

    if (state != NULL) {
        return;
    }

    state = (EJSPromiseRejectionState *)calloc(1u, sizeof(EJSPromiseRejectionState));
    if (state == NULL) {
        ejs_engine_record_internal_diagnostic(engine_ctx, "failed to allocate promise rejection state");
        return;
    }

    state->promise = JS_DupValue(ctx, promise);
    state->reason = JS_DupValue(ctx, reason);
    state->epoch = engine_ctx->promise_rejection_epoch;
    state->reported = false;
    state->next = engine_ctx->promise_rejection_list;
    if (engine_ctx->promise_rejection_list != NULL) {
        engine_ctx->promise_rejection_list->prev = state;
    }
    engine_ctx->promise_rejection_list = state;
    ejs_engine_enqueue_pending_rejection_context(engine_ctx);
}

static JSClassID ejs_array_buffer_class_id(JSContext *ctx) {
    static JSClassID cached_class_id = 0;
    if (cached_class_id != 0) {
        return cached_class_id;
    }

    const uint8_t zero = 0;
    JSValue empty_buffer = JS_NewArrayBufferCopy(ctx, &zero, 0);
    if (JS_IsException(empty_buffer)) {
        JS_FreeValue(ctx, empty_buffer);
        return 0;
    }

    cached_class_id = JS_GetClassID(empty_buffer);
    JS_FreeValue(ctx, empty_buffer);
    return cached_class_id;
}

/**
 * ejs_extract_binary_data — 从 JS 值中提取二进制数据指针
 *
 * 仅支持 ArrayBuffer 和 ArrayBufferView（TypedArray/DataView）：
 *   1. 对 ArrayBuffer 直接读取底层字节
 *   2. 对 ArrayBufferView 通过 JS_GetTypedArrayBuffer 获取底层 buffer、
 *      偏移和长度
 *
 * 返回的指针指向 QuickJS 管理的内存，调用方不应释放。
 * out_buffer_to_free 用于追踪需要后续释放的 ArrayBuffer JSValue，
 * 防止 ArrayBuffer 在使用前被 GC 回收。
 *
 * @param ctx               QuickJS 上下文
 * @param val               待提取的 JS 值
 * @param out_size          输出数据字节长度
 * @param out_buffer_to_free 输出需要后续 JS_FreeValue 的 ArrayBuffer 引用
 * @return 数据指针；若非二进制类型则返回 NULL
 */
static uint8_t * ejs_extract_binary_data(JSContext *ctx, JSValue val, size_t *out_size, JSValue *out_buffer_to_free) {
    *out_size = 0;
    *out_buffer_to_free = JS_UNDEFINED;

    if (!JS_IsObject(val)) {
        return NULL;
    }

    JSClassID class_id = JS_GetClassID(val);
    JSClassID array_buffer_class_id = ejs_array_buffer_class_id(ctx);
    if (array_buffer_class_id != 0 && class_id == array_buffer_class_id) {
        size_t ab_sz = 0;
        uint8_t *ab_ptr = JS_GetArrayBuffer(ctx, &ab_sz, val);
        if (ab_ptr != NULL) {
            *out_size = ab_sz;
            return ab_ptr;
        }
    }

    JSValue plain_object = JS_NewObject(ctx);
    if (JS_IsException(plain_object)) {
        return NULL;
    }
    JSClassID object_class_id = JS_GetClassID(plain_object);
    JS_FreeValue(ctx, plain_object);

    int typed_array_type = JS_GetTypedArrayType(val);
    bool is_data_view = JS_IsDataView(val);

    bool is_array_buffer_view =
        class_id != object_class_id &&
        (typed_array_type >= 0 || is_data_view);

    if (is_array_buffer_view) {
        size_t byte_offset = 0;
        size_t byte_length = 0;
        size_t bytes_per_element = 0;
        JSValue view_buffer = JS_GetTypedArrayBuffer(ctx,
                                                     val,
                                                     &byte_offset,
                                                     &byte_length,
                                                     &bytes_per_element);
        (void)bytes_per_element;
        if (JS_IsException(view_buffer)) {
            JS_FreeValue(ctx, view_buffer);
            return NULL;
        }

        size_t view_ab_sz = 0;
        uint8_t *view_ab_ptr = JS_GetArrayBuffer(ctx, &view_ab_sz, view_buffer);
        if (view_ab_ptr == NULL ||
            byte_offset > view_ab_sz ||
            byte_length > (view_ab_sz - byte_offset)) {
            JS_FreeValue(ctx, view_buffer);
            return NULL;
        }

        *out_size = byte_length;
        *out_buffer_to_free = view_buffer;
        return view_ab_ptr + byte_offset;
    }

    return NULL;
}

/**
 * ejs_invoke_completion_task_destroy — 销毁异步调用完成任务
 *
 * 释放任务中所有堆分配的字段（result_data、error_message、
 * error_platform_domain），然后释放任务结构体本身。
 */
static void ejs_invoke_completion_task_destroy(EJSInvokeCompletionTask *task) {
    if (task == NULL) {
        return;
    }

    free(task->result_data);
    free(task->error_message);
    free(task->error_platform_domain);
    free(task);
}

static void ejs_invoke_state_release_operation(EJSInvokeState *state) {
    if (state == NULL) {
        return;
    }

    EJSCoreHostOperation *op = NULL;
    pthread_mutex_lock(&state->op_mutex);
    if (state->op != NULL) {
        op = state->op;
        state->op = NULL;
    } else {
        state->op_release_requested = true;
    }
    pthread_mutex_unlock(&state->op_mutex);

    if (op != NULL && state->host != NULL && state->host->api.operations.release != NULL) {
        state->host->api.operations.release(state->host->api.operations.user_data, op);
    }
}

static void ejs_invoke_state_release_host_ref(EJSInvokeState *state) {
    if (state != NULL && !atomic_exchange(&state->host_ref_released, true)) {
        ejs_invoke_state_dec_ref(state);
    }
}

static void ejs_invoke_state_cancel_and_release_operation(EJSInvokeState *state) {
    if (state == NULL) {
        return;
    }

    EJSCoreHostOperation *op = NULL;
    pthread_mutex_lock(&state->op_mutex);
    state->op_cancel_requested = true;
    state->op_release_requested = true;
    if (state->op != NULL) {
        op = state->op;
        state->op = NULL;
    }
    pthread_mutex_unlock(&state->op_mutex);

    if (op != NULL && state->host != NULL) {
        if (state->host->api.operations.cancel != NULL) {
            state->host->api.operations.cancel(state->host->api.operations.user_data, op);
        }
        if (state->host->api.operations.release != NULL) {
            state->host->api.operations.release(state->host->api.operations.user_data, op);
        }
    }
}

static void ejs_invoke_state_assign_operation(EJSInvokeState *state, EJSCoreHostOperation *op) {
    if (state == NULL || op == NULL) {
        return;
    }

    bool should_cancel = false;
    bool should_release = false;

    pthread_mutex_lock(&state->op_mutex);
    should_cancel = state->op_cancel_requested;
    should_release = state->op_release_requested;
    if (!should_cancel && !should_release) {
        state->op = op;
        pthread_mutex_unlock(&state->op_mutex);
        return;
    }
    pthread_mutex_unlock(&state->op_mutex);

    if (state->host != NULL) {
        if (should_cancel && state->host->api.operations.cancel != NULL) {
            state->host->api.operations.cancel(state->host->api.operations.user_data, op);
        }
        if (state->host->api.operations.release != NULL) {
            state->host->api.operations.release(state->host->api.operations.user_data, op);
        }
    }
}

static void ejs_invoke_state_unlink_from_context(EJSInvokeState *state, JSContext *ctx) {
    if (state == NULL || ctx == NULL) {
        return;
    }

    EJSCoreContext *public_ctx = (EJSCoreContext *)JS_GetContextOpaque(ctx);

    if (public_ctx != NULL && public_ctx->engine_context != NULL) {
        EJSEngineContext *engine_ctx = public_ctx->engine_context;

        if (state->prev != NULL || state->next != NULL || engine_ctx->invoke_list == state) {
            if (state->prev != NULL) {
                state->prev->next = state->next;
            } else {
                engine_ctx->invoke_list = state->next;
            }

            if (state->next != NULL) {
                state->next->prev = state->prev;
            }

            state->prev = NULL;
            state->next = NULL;
            ejs_invoke_state_dec_ref(state);
        }
    }
}

static void ejs_invoke_state_reject_internal_error(JSContext *ctx,
                                                   EJSInvokeState *state,
                                                   const char *message) {
    JSValue err_obj = JS_NewError(ctx);
    JS_DefinePropertyValueStr(ctx,
                              err_obj,
                              "message",
                              JS_NewString(ctx, message != NULL ? message : "internal invoke error"),
                              JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx,
                              err_obj,
                              "code",
                              JS_NewInt32(ctx, EJS_ERROR_INTERNAL),
                              JS_PROP_C_W_E);
    JSValue ret = JS_Call(ctx, state->reject_func, JS_UNDEFINED, 1, &err_obj);
    JS_FreeValue(ctx, err_obj);
    JS_FreeValue(ctx, ret);
}

static JSValue ejs_host_error_to_js_error(JSContext *ctx,
                                          const EJSCoreHostError *host_error,
                                          const char *fallback_message) {
    EJSCoreErrorCode code = EJS_ERROR_INTERNAL;
    const char *message = fallback_message != NULL ? fallback_message : "host invoke failed";
    const char *platform_domain = NULL;
    int platform_code = 0;

    if (host_error != NULL) {
        if (host_error->code != EJS_ERROR_NONE) {
            code = host_error->code;
        }
        if (host_error->message != NULL) {
            message = host_error->message;
        }
        platform_domain = host_error->platform_domain;
        platform_code = host_error->platform_code;
    }

    JSValue err_obj = JS_NewError(ctx);
    JS_DefinePropertyValueStr(ctx,
                              err_obj,
                              "message",
                              JS_NewString(ctx, message),
                              JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx,
                              err_obj,
                              "code",
                              JS_NewInt32(ctx, code),
                              JS_PROP_C_W_E);

    if (platform_domain != NULL) {
        JS_DefinePropertyValueStr(ctx,
                                  err_obj,
                                  "platform_domain",
                                  JS_NewString(ctx, platform_domain),
                                  JS_PROP_C_W_E);
    }

    if (platform_code != 0) {
        JS_DefinePropertyValueStr(ctx,
                                  err_obj,
                                  "platform_code",
                                  JS_NewInt32(ctx, platform_code),
                                  JS_PROP_C_W_E);
    }

    return err_obj;
}

static bool ejs_host_error_code_is_valid(EJSCoreErrorCode code) {
    return code >= EJS_ERROR_NONE && code <= EJS_ERROR_INTERNAL;
}

static bool ejs_host_error_reserved_fields_are_zero(const EJSCoreHostError *host_error) {
    if (host_error == NULL || host_error->flags != 0u) {
        return false;
    }

    for (size_t i = 0u; i < sizeof(host_error->reserved) / sizeof(host_error->reserved[0]); i++) {
        if (host_error->reserved[i] != NULL) {
            return false;
        }
    }

    return true;
}

static bool ejs_host_error_is_valid(const EJSCoreHostError *host_error) {
    if (host_error == NULL) {
        return true;
    }

    if (ejs_native_validate_metadata(host_error, sizeof(EJSCoreHostError)) != EJS_NATIVE_VALIDATION_OK) {
        return false;
    }

    return ejs_host_error_reserved_fields_are_zero(host_error) &&
           ejs_host_error_code_is_valid(host_error->code);
}

static void ejs_host_error_init_internal(EJSCoreHostError *host_error,
                                         const char *message) {
    if (host_error == NULL) {
        return;
    }

    memset(host_error, 0, sizeof(*host_error));
    host_error->abi_version = EJS_NATIVE_ABI_VERSION;
    host_error->struct_size = sizeof(*host_error);
    host_error->code = EJS_ERROR_INTERNAL;
    host_error->message = message;
}

/**
 * ejs_invoke_state_dec_ref — 原子递减 EJSInvokeState 的引用计数
 *
 * 当引用计数从 N 降至 N-1 时，若旧值为 1（即归零），
 * 说明所有引用方都已释放，此时执行以下清理：
 *   1. 释放 Promise 的 resolve/reject 函数引用（若 JSContext 仍有效）
 *   2. 递减 EJSCoreRuntime 的 pending_host_operation_count 计数
 *   3. 释放 EJSInvokeState 结构体本身
 */
static void ejs_invoke_state_dec_ref(EJSInvokeState *state) {
    if (state == NULL) {
        return;
    }

    if (atomic_fetch_sub(&state->ref_count, 1) == 1) {
        JSContext *ctx = atomic_load(&state->ctx);

        if (ctx != NULL) {
            JS_FreeValue(ctx, state->resolve_func);
            JS_FreeValue(ctx, state->reject_func);
        }

        if (state->runtime != NULL) {
            EJSCoreRuntime *runtime = state->runtime;
            atomic_fetch_sub(&runtime->pending_host_operation_count, 1);
            ejs_runtime_release(runtime);
        }

        if (state->host != NULL) {
            ejs_registered_host_release(state->host);
            state->host = NULL;
        }

        pthread_mutex_destroy(&state->op_mutex);
        free(state);
    }
}

/**
 * ejs_invoke_completion_on_owner — 在 owner 线程上执行异步调用的完成回调
 *
 * 此函数通过 ejs_runtime_loop_post 投递到 owner 线程执行，确保所有
 * JS 操作（JS_Call、JS_FreeValue 等）在正确的线程上完成。
 *
 * 执行流程：
 *   1. 检查 JSContext 是否已被销毁（ctx == NULL），若是则静默回收
 *   2. 从 EJSEngineContext 的 invoke_list 双链表中摘除当前 state
 *   3. 根据是否有错误，调用 Promise 的 reject 或 resolve
 *   4. 释放 Promise 函数的 JS 引用计数
 *   5. 释放关联的 EJSCoreHostOperation（通过宿主的 release 回调）
 *   6. 递减引用计数（任务队列引用）并销毁完成任务
 *
 * @param user_data 指向 EJSInvokeCompletionTask 的指针
 */
static void ejs_invoke_completion_on_owner(void *user_data) {
    EJSInvokeCompletionTask *task = (EJSInvokeCompletionTask *)user_data;
    EJSInvokeState *state = task->state;

    JSContext *ctx = atomic_load(&state->ctx);

    if (ctx == NULL) {
        // 已经处于静默销毁流程，JSContext 已经或正在被释放，不碰任何 JS 逻辑，静默优雅回收
        ejs_invoke_state_release_operation(state);
        ejs_invoke_state_dec_ref(state);
        ejs_invoke_completion_task_destroy(task);
        return;
    }

    atomic_store(&state->ctx, NULL);

    ejs_invoke_state_unlink_from_context(state, ctx);
    ejs_runtime_enter_owner_callback(state->runtime);

    if (task->has_error && task->error.code != EJS_ERROR_NONE) {
        JSValue err_obj = ejs_host_error_to_js_error(ctx, &task->error, "");
        JSValue ret = JS_Call(ctx, state->reject_func, JS_UNDEFINED, 1, &err_obj);
        JS_FreeValue(ctx, err_obj);
        JS_FreeValue(ctx, ret);
    } else {
        JSValue res_val;

        if (task->has_result) {
            res_val = JS_NewArrayBufferCopy(ctx, task->result_data, task->result_size);
        } else {
            res_val = JS_UNDEFINED;
        }

        if (JS_IsException(res_val)) {
            JSValue exception = JS_GetException(ctx);
            JSValue ret = JS_Call(ctx, state->reject_func, JS_UNDEFINED, 1, &exception);
            JS_FreeValue(ctx, exception);
            JS_FreeValue(ctx, ret);
        } else {
            JSValue ret = JS_Call(ctx, state->resolve_func, JS_UNDEFINED, 1, &res_val);
            JS_FreeValue(ctx, res_val);
            JS_FreeValue(ctx, ret);
        }
    }
    ejs_runtime_leave_owner_callback(state->runtime);

    // 释放 JS 里的 resolve/reject 函数引用计数，防范 leak
    JS_FreeValue(ctx, state->resolve_func);
    JS_FreeValue(ctx, state->reject_func);
    state->resolve_func = JS_UNDEFINED;
    state->reject_func = JS_UNDEFINED;

    ejs_invoke_state_release_operation(state);

    // 任务引用释放
    ejs_invoke_state_dec_ref(state);
    ejs_invoke_completion_task_destroy(task);
}

static void ejs_invoke_completion_oom_on_owner(void *user_data) {
    EJSInvokeState *state = (EJSInvokeState *)user_data;

    if (state == NULL) {
        return;
    }

    JSContext *ctx = atomic_load(&state->ctx);

    if (ctx == NULL) {
        ejs_invoke_state_release_operation(state);
        ejs_invoke_state_dec_ref(state);
        return;
    }

    atomic_store(&state->ctx, NULL);
    ejs_invoke_state_unlink_from_context(state, ctx);
    ejs_invoke_state_reject_internal_error(ctx, state, "failed to allocate invoke completion task");

    JS_FreeValue(ctx, state->resolve_func);
    JS_FreeValue(ctx, state->reject_func);
    state->resolve_func = JS_UNDEFINED;
    state->reject_func = JS_UNDEFINED;

    ejs_invoke_state_release_operation(state);
    ejs_invoke_state_dec_ref(state);
}

/**
 * ejs_invoke_completion_callback — 宿主操作完成的回调入口
 *
 * 此函数由宿主在工作线程中调用，当异步操作完成（成功或失败）时触发。
 * 它负责将完成事件安全地投递到 owner 线程执行。
 *
 * 关键竞态保护：
 *   - 使用 atomic_exchange(&state->completed, true) 确保只处理第一次完成，
 *     防止宿主重复调用完成回调
 *   - 若 JSContext 已被销毁（ctx == NULL），直接释放引用并返回
 *
 * 引用计数变化：
 *   1. 投递前 +1（任务队列引用）：保证 state 在投递过程中不被销毁
 *   2. 释放宿主引用 -1：宿主操作已完成，不再需要持有引用
 *   3. 投递成功后，任务队列引用将在 ejs_invoke_completion_on_owner 中释放
 *   4. 若投递失败，手动扣减任务队列引用并销毁任务
 *
 * user_data 参数是 runtime 给宿主的 completion_data，不是宿主自己的
 * invoke_api.user_data。宿主不拥有它；第一次进入本函数后，runtime 会尽快释放
 * 宿主引用，宿主侧应立即丢弃该指针。
 *
 * @param user_data 指向 EJSInvokeState 的指针（创建 invoke 时传入）
 * @param result    操作结果的字节视图（零拷贝，宿主保证在回调返回前有效）
 * @param error     宿主错误信息，可为 NULL（无错误）
 */
void ejs_invoke_completion_callback(void               *user_data,
                                    EJSCoreByteView        result,
                                    const EJSCoreHostError *error) {
    EJSInvokeState *state = (EJSInvokeState *)user_data;

    if (state == NULL) {
        return;
    }

    if (atomic_exchange(&state->completed, true)) {
        /* 同一 completion_data 的同步重复调用会被忽略，并补释放宿主引用。 */
        ejs_invoke_state_release_host_ref(state);
        return;
    }

    JSContext *ctx = atomic_load(&state->ctx);

    if (ctx == NULL) {
        ejs_invoke_state_release_host_ref(state);
        return;
    }

    // 1. 投递前自增，代表任务队列的强引用
    atomic_fetch_add(&state->ref_count, 1);

    // 2. completion_data 已被消费，立刻释放宿主引用；宿主此后不得再使用该指针。
    ejs_invoke_state_release_host_ref(state);

    EJSInvokeCompletionTask *task =
        (EJSInvokeCompletionTask *)calloc(1u, sizeof(EJSInvokeCompletionTask));
#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 15) {
        free(task);
        task = NULL;
    }

#endif

    if (task == NULL) {
        EJSRuntimeLoop *loop = state->runtime != NULL ? state->runtime->runtime_loop : NULL;

        /*
         * OOM 时仍优先把 JS reject 投递回 owner 线程；如果投递也失败，
         * state 会继续挂在 invoke_list 上，最终由 context destroy 统一回收。
         */
        if (loop != NULL) {
            EJSCoreResult oom_result =
                ejs_runtime_loop_call_sync(loop, ejs_invoke_completion_oom_on_owner, state);

            if (oom_result.status != EJS_STATUS_OK) {
                ejs_error_destroy(oom_result.error);
                ejs_invoke_state_dec_ref(state); // 扣减任务队列引用
            }
        } else {
            ejs_invoke_state_dec_ref(state); // 扣减任务队列引用
        }

        return;
    }

    task->state = state;

    if (result.data == NULL && result.size > 0u) {
        task->has_error = true;
        ejs_host_error_init_internal(&task->error, "host invoke returned invalid result buffer");
    } else if (result.data != NULL) {
        task->has_result = true;
        task->result_size = result.size;

        if (result.size > 0) {
            task->result_data = (uint8_t *)malloc(result.size);
#ifdef EJS_TEST

            if (ejs_test_inject_engine_error == 16) {
                free(task->result_data);
                task->result_data = NULL;
            }

#endif

            if (task->result_data == NULL) {
                EJSRuntimeLoop *loop = state->runtime != NULL ? state->runtime->runtime_loop : NULL;

                if (loop != NULL) {
                    EJSCoreResult oom_result =
                        ejs_runtime_loop_call_sync(loop, ejs_invoke_completion_oom_on_owner, state);

                    if (oom_result.status != EJS_STATUS_OK) {
                        ejs_error_destroy(oom_result.error);
                        ejs_invoke_state_dec_ref(state); // 扣减任务队列引用
                    }
                } else {
                    ejs_invoke_state_dec_ref(state); // 扣减任务队列引用
                }

                ejs_invoke_completion_task_destroy(task);
                return;
            }

            memcpy(task->result_data, result.data, result.size);
        }
    }

    if (error != NULL && !ejs_host_error_is_valid(error)) {
        task->has_error = true;
        ejs_host_error_init_internal(&task->error, "invalid host error");
    } else if (error != NULL && error->code != EJS_ERROR_NONE) {
        task->has_error = true;
        task->error = *error;
        task->error_message = ejs_strdup_or_null(error->message);
        task->error_platform_domain = ejs_strdup_or_null(error->platform_domain);
        task->error.message = task->error_message;
        task->error.platform_domain = task->error_platform_domain;
    }

    EJSRuntimeLoop *loop = state->runtime != NULL ? state->runtime->runtime_loop : NULL;

    if (loop == NULL) {
        ejs_invoke_state_dec_ref(state); // 扣减任务队列引用
        ejs_invoke_completion_task_destroy(task);
        return;
    }

    EJSCoreResult post_result = ejs_runtime_loop_post(loop, ejs_invoke_completion_on_owner, task);

    if (post_result.status != EJS_STATUS_OK) {
        ejs_error_destroy(post_result.error);
        ejs_invoke_state_dec_ref(state); // 扣减任务队列引用
        ejs_invoke_completion_task_destroy(task);
    }
}

/**
 * ejs_native_invoke — __ejs_native__.invoke 的 QuickJS C 函数实现
 *
 * 这是 JS 侧 __ejs_native__.invoke(module_id, method_id, payload, transfer_buffer)
 * 的底层 C 实现，是 EJS "万能异步通道"的核心。
 *
 * 执行流程：
 *   1. 参数校验：确保至少 3 个参数，module_id 和 method_id 必须为字符串
 *   2. 提取 payload：支持字符串和 TypedArray/ArrayBuffer 二进制数据
 *   3. 提取 transfer_buffer（可选第 4 参数）：同上
 *   4. 创建 JS Promise 及 resolve/reject 函数对
 *   5. 创建 EJSInvokeState 并初始化原子引用计数
 *   6. 将 state 挂载到 EJSEngineContext.invoke_list 双链表
 *   7. 递增宿主引用计数和全局 pending_host_operation_count
 *   8. 调用宿主的 invoke_api.invoke 回调发起异步操作
 *   9. 返回 JS Promise 给调用方
 *
 * 内存管理：
 *   - 所有 JS_ToCString 转换的字符串在 invoke 调用后立即释放
 *   - TypedArray 的 ArrayBuffer 引用通过 payload_buf_to_free 追踪，调用后释放
 *   - EJSInvokeState 的引用计数确保在跨线程场景下安全
 *   - 传给宿主的 module_id/method_id/payload/transfer_buffer 都是借用数据，
 *     仅在 invoke_api.invoke 返回前有效；宿主异步使用必须自行复制
 *   - completion_data 由 runtime 管理，宿主只保存并在完成时原样传回
 *
 * @param ctx      QuickJS 上下文
 * @param this_val this 绑定（未使用）
 * @param argc     参数数量
 * @param argv     参数数组
 * @return JS Promise 对象；参数错误时返回 JS_EXCEPTION
 */
static JSValue ejs_native_invoke(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;

    if (argc < 3) {
        return JS_ThrowTypeError(ctx, "invoke expects at least 3 arguments");
    }

    EJSCoreContext *public_ctx = (EJSCoreContext *)JS_GetContextOpaque(ctx);

    if (public_ctx == NULL || public_ctx->runtime == NULL || public_ctx->engine_context == NULL) {
        return JS_ThrowInternalError(ctx, "invalid context or runtime");
    }

    EJSCoreRuntime *runtime = public_ctx->runtime;

    // 1. 强类型校验
    if (!JS_IsString(argv[0]) || !JS_IsString(argv[1])) {
        return JS_ThrowTypeError(ctx, "module_id and method_id must be strings");
    }

    const char *module_id = JS_ToCString(ctx, argv[0]);
    const char *method_id = JS_ToCString(ctx, argv[1]);
#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 10) {
        if (module_id != NULL) {
            JS_FreeCString(ctx, module_id);
            module_id = NULL;
        }
    }

#endif

    if (module_id == NULL || method_id == NULL) {
        if (module_id != NULL) {
            JS_FreeCString(ctx, module_id);
        }

        if (method_id != NULL) {
            JS_FreeCString(ctx, method_id);
        }

        return JS_ThrowTypeError(ctx, "module_id and method_id must be strings");
    }

    // 2. 提取二进制数据（完美支持 TypedArray）
    EJSCoreByteView payload;
    payload.data = NULL;
    payload.size = 0;
    const char *payload_str = NULL;
    JSValue payload_buf_to_free = JS_UNDEFINED;

    if (JS_IsString(argv[2])) {
        payload_str = JS_ToCString(ctx, argv[2]);
#ifdef EJS_TEST

        if (ejs_test_inject_engine_error == 29) {
            if (payload_str != NULL) {
                JS_FreeCString(ctx, payload_str);
            }
            payload_str = NULL;
        }

#endif

        if (payload_str == NULL) {
            JS_FreeCString(ctx, module_id);
            JS_FreeCString(ctx, method_id);
            return JS_ThrowOutOfMemory(ctx);
        }

        payload.data = (const uint8_t *)payload_str;
        payload.size = strlen(payload_str);
    } else if (!JS_IsUndefined(argv[2]) && !JS_IsNull(argv[2])) {
        size_t sz = 0;
        uint8_t *ptr = ejs_extract_binary_data(ctx, argv[2], &sz, &payload_buf_to_free);

        if (ptr != NULL) {
            payload.data = ptr;
            payload.size = sz;
        } else {
            JS_FreeCString(ctx, module_id);
            JS_FreeCString(ctx, method_id);
            JS_FreeValue(ctx, payload_buf_to_free);
            return JS_ThrowTypeError(ctx, "payload must be a string or binary buffer");
        }
    }

    EJSCoreByteView transfer_buffer;
    transfer_buffer.data = NULL;
    transfer_buffer.size = 0;
    JSValue transfer_buf_to_free = JS_UNDEFINED;

    if (argc >= 4 && !JS_IsUndefined(argv[3]) && !JS_IsNull(argv[3])) {
        size_t sz = 0;
        uint8_t *ptr = ejs_extract_binary_data(ctx, argv[3], &sz, &transfer_buf_to_free);

        if (ptr != NULL) {
            transfer_buffer.data = ptr;
            transfer_buffer.size = sz;
        } else {
            if (payload_str != NULL) {
                JS_FreeCString(ctx, payload_str);
            }
            JS_FreeCString(ctx, module_id);
            JS_FreeCString(ctx, method_id);
            JS_FreeValue(ctx, payload_buf_to_free);
            JS_FreeValue(ctx, transfer_buf_to_free);
            return JS_ThrowTypeError(ctx, "transfer_buffer must be a binary buffer");
        }
    }

    JSValue resolving_funcs[2];
    JSValue promise = JS_NewPromiseCapability(ctx, resolving_funcs);
#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 9) {
        if (!JS_IsException(promise)) {
            JS_FreeValue(ctx, promise);
            JS_FreeValue(ctx, resolving_funcs[0]);
            JS_FreeValue(ctx, resolving_funcs[1]);
            promise = JS_EXCEPTION;
        }
    }

#endif

    if (JS_IsException(promise)) {
        if (payload_str != NULL) {
            JS_FreeCString(ctx, payload_str);
        }

        JS_FreeCString(ctx, module_id);
        JS_FreeCString(ctx, method_id);
        JS_FreeValue(ctx, payload_buf_to_free);
        JS_FreeValue(ctx, transfer_buf_to_free);
        return JS_EXCEPTION;
    }

    // 5. Promise 之后再 acquire host，保持生命周期安全且最少持有
    EJSRegisteredHost *host = ejs_context_acquire_host(public_ctx);
    if (host == NULL || host->api.invoke_api.invoke == NULL) {
        if (host != NULL) {
            ejs_registered_host_release(host);
        }
        if (payload_str != NULL) {
            JS_FreeCString(ctx, payload_str);
        }
        JS_FreeCString(ctx, module_id);
        JS_FreeCString(ctx, method_id);
        JS_FreeValue(ctx, promise);
        JS_FreeValue(ctx, resolving_funcs[0]);
        JS_FreeValue(ctx, resolving_funcs[1]);
        JS_FreeValue(ctx, payload_buf_to_free);
        JS_FreeValue(ctx, transfer_buf_to_free);
        return JS_ThrowInternalError(ctx, "host invoke API is not registered");
    }

    EJSInvokeState *state = (EJSInvokeState *)calloc(1, sizeof(EJSInvokeState));
#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 8) {
        if (state != NULL) {
            free(state);
            state = NULL;
        }
    }

#endif

    if (state == NULL) {
        ejs_registered_host_release(host);
        if (payload_str != NULL) {
            JS_FreeCString(ctx, payload_str);
        }

        JS_FreeCString(ctx, module_id);
        JS_FreeCString(ctx, method_id);
        JS_FreeValue(ctx, promise);
        JS_FreeValue(ctx, resolving_funcs[0]);
        JS_FreeValue(ctx, resolving_funcs[1]);
        JS_FreeValue(ctx, payload_buf_to_free);
        JS_FreeValue(ctx, transfer_buf_to_free);
        return JS_ThrowOutOfMemory(ctx);
    }

    atomic_store(&state->ctx, ctx);
    state->runtime = runtime;
    ejs_runtime_retain(runtime);
    state->resolve_func = JS_DupValue(ctx, resolving_funcs[0]);
    state->reject_func = JS_DupValue(ctx, resolving_funcs[1]);
    state->host = host; // 所有权转移给 state->host
    pthread_mutex_init(&state->op_mutex, NULL);
    state->op_release_requested = false;
    state->op_cancel_requested = false;
    atomic_store(&state->ref_count, 1);
    atomic_store(&state->completed, false);
    atomic_store(&state->host_ref_released, false);
    JS_FreeValue(ctx, resolving_funcs[0]);
    JS_FreeValue(ctx, resolving_funcs[1]);

    // 3. 挂载到 EngineContext 的挂起双向链表中
    EJSEngineContext *engine_ctx = public_ctx->engine_context;
    state->next = engine_ctx->invoke_list;
    state->prev = NULL;

    if (engine_ctx->invoke_list != NULL) {
        engine_ctx->invoke_list->prev = state;
    }

    engine_ctx->invoke_list = state;

    // 4. 代表宿主自增引用计数（变为 2）
    atomic_fetch_add(&state->ref_count, 1);

    // 5. 递增全局挂起任务记账
    atomic_fetch_add(&runtime->pending_host_operation_count, 1);

    // Keep state alive while host invoke runs; hosts may complete synchronously.
    atomic_fetch_add(&state->ref_count, 1);
    EJSCoreHostOperation *op = host->api.invoke_api.invoke(
        host->api.invoke_api.user_data,
        module_id,
        method_id,
        payload,
        transfer_buffer,
        ejs_invoke_completion_callback,
        state
        );

    ejs_invoke_state_assign_operation(state, op);

    if (op == NULL) {
        atomic_store(&state->completed, true);
        ejs_invoke_state_reject_internal_error(ctx, state, "host invoke returned NULL operation");
        JS_FreeValue(ctx, state->resolve_func);
        JS_FreeValue(ctx, state->reject_func);
        state->resolve_func = JS_UNDEFINED;
        state->reject_func = JS_UNDEFINED;
        ejs_invoke_state_unlink_from_context(state, ctx);
        ejs_invoke_state_release_host_ref(state);
    }

    ejs_invoke_state_dec_ref(state);

    if (payload_str != NULL) {
        JS_FreeCString(ctx, payload_str);
    }

    JS_FreeCString(ctx, module_id);
    JS_FreeCString(ctx, method_id);
    JS_FreeValue(ctx, payload_buf_to_free);
    JS_FreeValue(ctx, transfer_buf_to_free);

    return promise;
}

static JSValue ejs_native_invoke_sync(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;

    if (argc < 3) {
        return JS_ThrowTypeError(ctx, "invokeSync expects at least 3 arguments");
    }

    EJSCoreContext *public_ctx = (EJSCoreContext *)JS_GetContextOpaque(ctx);

    if (public_ctx == NULL || public_ctx->runtime == NULL || public_ctx->engine_context == NULL) {
        return JS_ThrowInternalError(ctx, "invalid context or runtime");
    }

    if (!JS_IsString(argv[0]) || !JS_IsString(argv[1])) {
        return JS_ThrowTypeError(ctx, "module_id and method_id must be strings");
    }

    const char *module_id = JS_ToCString(ctx, argv[0]);
    const char *method_id = JS_ToCString(ctx, argv[1]);

    if (module_id == NULL || method_id == NULL) {
        if (module_id != NULL) {
            JS_FreeCString(ctx, module_id);
        }

        if (method_id != NULL) {
            JS_FreeCString(ctx, method_id);
        }

        return JS_ThrowTypeError(ctx, "module_id and method_id must be strings");
    }

    EJSCoreByteView payload;
    payload.data = NULL;
    payload.size = 0;
    const char *payload_str = NULL;
    JSValue payload_buf_to_free = JS_UNDEFINED;

    if (JS_IsString(argv[2])) {
        payload_str = JS_ToCString(ctx, argv[2]);
#ifdef EJS_TEST

        if (ejs_test_inject_engine_error == 30) {
            if (payload_str != NULL) {
                JS_FreeCString(ctx, payload_str);
            }
            payload_str = NULL;
        }

#endif

        if (payload_str == NULL) {
            JS_FreeCString(ctx, module_id);
            JS_FreeCString(ctx, method_id);
            return JS_ThrowOutOfMemory(ctx);
        }

        payload.data = (const uint8_t *)payload_str;
        payload.size = strlen(payload_str);
    } else if (!JS_IsUndefined(argv[2]) && !JS_IsNull(argv[2])) {
        size_t sz = 0;
        uint8_t *ptr = ejs_extract_binary_data(ctx, argv[2], &sz, &payload_buf_to_free);

        if (ptr != NULL) {
            payload.data = ptr;
            payload.size = sz;
        } else {
            JS_FreeCString(ctx, module_id);
            JS_FreeCString(ctx, method_id);
            JS_FreeValue(ctx, payload_buf_to_free);
            return JS_ThrowTypeError(ctx, "payload must be a string or binary buffer");
        }
    }

    EJSCoreByteView transfer_buffer;
    transfer_buffer.data = NULL;
    transfer_buffer.size = 0;
    JSValue transfer_buf_to_free = JS_UNDEFINED;

    if (argc >= 4 && !JS_IsUndefined(argv[3]) && !JS_IsNull(argv[3])) {
        size_t sz = 0;
        uint8_t *ptr = ejs_extract_binary_data(ctx, argv[3], &sz, &transfer_buf_to_free);

        if (ptr != NULL) {
            transfer_buffer.data = ptr;
            transfer_buffer.size = sz;
        } else {
            if (payload_str != NULL) {
                JS_FreeCString(ctx, payload_str);
            }
            JS_FreeCString(ctx, module_id);
            JS_FreeCString(ctx, method_id);
            JS_FreeValue(ctx, payload_buf_to_free);
            JS_FreeValue(ctx, transfer_buf_to_free);
            return JS_ThrowTypeError(ctx, "transfer_buffer must be a binary buffer");
        }
    }

    EJSRegisteredHost *host = ejs_context_acquire_host(public_ctx);

    if (host == NULL || host->api.sync_invoke_api.invoke_sync == NULL) {
        if (host != NULL) {
            ejs_registered_host_release(host);
        }
        if (payload_str != NULL) {
            JS_FreeCString(ctx, payload_str);
        }
        JS_FreeCString(ctx, module_id);
        JS_FreeCString(ctx, method_id);
        JS_FreeValue(ctx, payload_buf_to_free);
        JS_FreeValue(ctx, transfer_buf_to_free);
        return JS_ThrowInternalError(ctx, "host sync invoke API is not registered");
    }

    EJSCoreByteBuffer result;
    memset(&result, 0, sizeof(result));
    EJSCoreHostError host_error;
    memset(&host_error, 0, sizeof(host_error));
    host_error.abi_version = EJS_NATIVE_ABI_VERSION;
    host_error.struct_size = sizeof(host_error);
    host_error.code = EJS_ERROR_NONE;

    int status = host->api.sync_invoke_api.invoke_sync(host->api.sync_invoke_api.user_data,
                                                       module_id,
                                                       method_id,
                                                       payload,
                                                       transfer_buffer,
                                                       &result,
                                                       &host_error);

    JSValue return_value = JS_UNDEFINED;

    if (!ejs_host_error_is_valid(&host_error)) {
        JSValue err_obj = ejs_host_error_to_js_error(ctx, NULL, "invalid host error");
        return_value = JS_Throw(ctx, err_obj);
        ejs_byte_buffer_destroy(&result);
        goto cleanup;
    }

    if (status != 0 || host_error.code != EJS_ERROR_NONE) {
        JSValue err_obj = ejs_host_error_to_js_error(ctx, &host_error, "host sync invoke failed");
        return_value = JS_Throw(ctx, err_obj);
        ejs_byte_buffer_destroy(&result);
        goto cleanup;
    }

    if (result.data == NULL && result.size > 0u) {
        JSValue err_obj = ejs_host_error_to_js_error(ctx, NULL, "host sync invoke returned invalid result buffer");
        return_value = JS_Throw(ctx, err_obj);
        ejs_byte_buffer_destroy(&result);
        goto cleanup;
    }

    static const uint8_t empty_byte = 0u;
    const uint8_t *bytes = result.data != NULL ? result.data : &empty_byte;
    return_value = JS_NewArrayBufferCopy(ctx, bytes, result.size);
#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 31 && !JS_IsException(return_value)) {
        JS_FreeValue(ctx, return_value);
        return_value = JS_ThrowOutOfMemory(ctx);
    }

#endif

    if (JS_IsException(return_value)) {
        ejs_byte_buffer_destroy(&result);
        goto cleanup;
    }

    ejs_byte_buffer_destroy(&result);

cleanup:
    ejs_registered_host_release(host);
    if (payload_str != NULL) {
        JS_FreeCString(ctx, payload_str);
    }
    JS_FreeCString(ctx, module_id);
    JS_FreeCString(ctx, method_id);
    JS_FreeValue(ctx, payload_buf_to_free);
    JS_FreeValue(ctx, transfer_buf_to_free);
    return return_value;
}

static JSValue ejs_native_events_set_promise_rejection_tracker(JSContext *ctx,
                                                               JSValueConst this_val,
                                                               int argc,
                                                               JSValueConst *argv) {
    (void)this_val;

    EJSEngineContext *engine_ctx = ejs_engine_context_from_js_context(ctx);

    if (engine_ctx == NULL) {
        return JS_ThrowInternalError(ctx, "invalid context for promise rejection tracker");
    }

    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "setPromiseRejectionTracker expects a callback or null");
    }

    if (JS_IsUndefined(argv[0]) || JS_IsNull(argv[0])) {
        JS_FreeValue(ctx, engine_ctx->promise_rejection_tracker);
        engine_ctx->promise_rejection_tracker = JS_UNDEFINED;
        ejs_promise_rejection_clear_all(engine_ctx);
        return JS_UNDEFINED;
    }

    if (!JS_IsFunction(ctx, argv[0])) {
        return JS_ThrowTypeError(ctx, "promise rejection tracker must be a function");
    }

    JSValue callback = JS_DupValue(ctx, argv[0]);
    JS_FreeValue(ctx, engine_ctx->promise_rejection_tracker);
    engine_ctx->promise_rejection_tracker = callback;
    return JS_UNDEFINED;
}

static JSValue ejs_native_events_set_exception_reporter(JSContext *ctx,
                                                        JSValueConst this_val,
                                                        int argc,
                                                        JSValueConst *argv) {
    (void)this_val;

    EJSEngineContext *engine_ctx = ejs_engine_context_from_js_context(ctx);

    if (engine_ctx == NULL) {
        return JS_ThrowInternalError(ctx, "invalid context for exception reporter");
    }

    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "setExceptionReporter expects a callback or null");
    }

    if (JS_IsUndefined(argv[0]) || JS_IsNull(argv[0])) {
        JS_FreeValue(ctx, engine_ctx->exception_reporter);
        engine_ctx->exception_reporter = JS_UNDEFINED;
        return JS_UNDEFINED;
    }

    if (!JS_IsFunction(ctx, argv[0])) {
        return JS_ThrowTypeError(ctx, "exception reporter must be a function");
    }

    JSValue callback = JS_DupValue(ctx, argv[0]);
    JS_FreeValue(ctx, engine_ctx->exception_reporter);
    engine_ctx->exception_reporter = callback;
    return JS_UNDEFINED;
}

/**
 * ejs_timer_destroy_internal — 从引擎上下文的定时器链表中销毁指定定时器
 *
 * 在 timer_list 单链表中查找并摘除指定的 EJSTimerState，
 * 然后释放 JS 回调函数引用，销毁底层运行时定时器。
 * 定时器销毁时通过 ejs_runtime_timer_set_free_user_data 设置
 * free 作为 user_data 释放函数，使得底层定时器关闭时自动释放 state。
 *
 * @param ctx_state 引擎上下文
 * @param state     待销毁的定时器状态
 */
static void ejs_timer_destroy_internal(EJSEngineContext *ctx_state, EJSTimerState *state) {
    EJSTimerState **indirect = &ctx_state->timer_list;

    while (*indirect != state) {
        if (*indirect == NULL) {
            return;
        }

        indirect = &(*indirect)->next;
    }
    *indirect = state->next;

    if (state->firing) {
        state->pending_destroy = true;
    } else {
        JS_FreeValue(ctx_state->context, state->callback);
        state->callback = JS_UNDEFINED;
        state->ctx = NULL;
    }

    if (state->timer != NULL) {
        ejs_runtime_timer_destroy(state->timer);
        state->timer = NULL;
    } else {
        free(state);
    }
}

/**
 * ejs_runtime_timer_cb_impl — 运行时定时器到期回调的实现
 *
 * 当底层定时器（libuv timer）到期时，在 owner 线程上调用此函数。
 * 通过 JS_Call 调用保存的 JS 回调函数。若回调抛出异常，优先交给
 * __ejs_native__.events.setExceptionReporter 注册的 reporter；未注册时清理异常，
 * 保持旧的 timer 不向 C ABI 同步返回错误的行为。
 *
 * 对于非重复定时器（setTimeout），触发后自动调用
 * ejs_timer_destroy_internal 从链表中移除并销毁。
 * 对于重复定时器（setInterval），保持链表挂载状态，等待下次触发。
 *
 * @param user_data 指向 EJSTimerState 的指针
 */
static void ejs_runtime_timer_cb_impl(void *user_data) {
    EJSTimerState *state = (EJSTimerState *)user_data;
    JSContext *ctx = state->ctx;

    EJSCoreContext *public_ctx = (EJSCoreContext *)JS_GetContextOpaque(ctx);

    if (public_ctx == NULL || public_ctx->engine_context == NULL) {
        return;
    }

    EJSEngineContext *engine_ctx = public_ctx->engine_context;

    state->firing = true;
    ejs_runtime_enter_owner_callback(public_ctx->runtime);
    JSValue ret = JS_Call(ctx, state->callback, JS_UNDEFINED, 0, NULL);

    if (JS_IsException(ret)) {
        ejs_engine_report_or_clear_current_exception(ctx, "timer callback failed");
    }

    JS_FreeValue(ctx, ret);
    ejs_runtime_leave_owner_callback(public_ctx->runtime);
    state->firing = false;

    if (state->pending_destroy) {
        JS_FreeValue(ctx, state->callback);
        state->callback = JS_UNDEFINED;
        state->ctx = NULL;
        return;
    }

    if (!state->repeat) {
        if (state->timer != NULL) {
            ejs_timer_destroy_internal(engine_ctx, state);
        }
    }
}

/**
 * ejs_native_timers_create — __ejs_native__.timers.create 的 QuickJS C 函数实现
 *
 * 对应 JS 侧的 setTimeout/setInterval，创建一个底层运行时定时器。
 *
 * 参数：
 *   argv[0] — delay (number): 首次触发的延迟时间（毫秒）
 *   argv[1] — repeat (number): 重复间隔（毫秒），0 表示不重复
 *   argv[2] — callback (function): 定时器到期时的 JS 回调函数
 *
 * 返回值：定时器 ID（int64），用于 clearTimeout/clearInterval
 *
 * @param ctx      QuickJS 上下文
 * @param this_val this 绑定（未使用）
 * @param argc     参数数量
 * @param argv     参数数组
 * @return 定时器 ID；错误时返回 JS_EXCEPTION
 */
static JSValue ejs_native_timers_create(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;

    if (argc < 3) {
        return JS_ThrowTypeError(ctx, "create expects 3 arguments");
    }

    EJSCoreContext *public_ctx = (EJSCoreContext *)JS_GetContextOpaque(ctx);

    if (public_ctx == NULL || public_ctx->runtime == NULL || public_ctx->engine_context == NULL) {
        return JS_ThrowInternalError(ctx, "invalid context");
    }

    EJSEngineContext *engine_ctx = public_ctx->engine_context;

    int64_t delay = 0;

    if (JS_ToInt64(ctx, &delay, argv[0]) < 0) {
        return JS_EXCEPTION;
    }

    int64_t repeat = 0;

    if (JS_ToInt64(ctx, &repeat, argv[1]) < 0) {
        return JS_EXCEPTION;
    }

    if (delay < 0) {
        delay = 0;
    }

    if (repeat < 0) {
        repeat = 0;
    }

    JSValue callback = argv[2];

    if (!JS_IsFunction(ctx, callback)) {
        return JS_ThrowTypeError(ctx, "callback must be a function");
    }

    EJSTimerState *state = (EJSTimerState *)calloc(1, sizeof(EJSTimerState));
#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 5) {
        if (state != NULL) {
            free(state);
            state = NULL;
        }
    }

#endif

    if (state == NULL) {
        return JS_ThrowOutOfMemory(ctx);
    }

    state->ctx = ctx;
    state->callback = JS_DupValue(ctx, callback);
    state->timer_id = engine_ctx->next_timer_id++;
    state->repeat = (repeat > 0);

    // 错误注入点 12: 模拟 runtime loop 不可用的失败路径
#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 12) {
        JS_FreeValue(ctx, state->callback);
        free(state);
        return JS_ThrowInternalError(ctx, "runtime loop is not available");
    }

#endif

    EJSRuntimeTimer *timer = ejs_runtime_timer_create(public_ctx->runtime->runtime_loop,
                                                      (uint64_t)delay,
                                                      (uint64_t)(repeat > 0 ? repeat : 0),
                                                      ejs_runtime_timer_cb_impl,
                                                      state);
    // 错误注入点 13/14: 模拟 timer init/start 失败，需要先销毁已创建的 timer
#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 13 || ejs_test_inject_engine_error == 14) {
        if (timer != NULL) {
            ejs_runtime_timer_destroy(timer);
            timer = NULL;
        }
    }

#endif

    if (timer == NULL) {
        JS_FreeValue(ctx, state->callback);
        free(state);
        return JS_ThrowInternalError(ctx, "failed to initialize timer");
    }

    state->timer = timer;
    ejs_runtime_timer_set_free_user_data(timer, free);

    state->next = engine_ctx->timer_list;
    engine_ctx->timer_list = state;

    return JS_NewInt64(ctx, (int64_t)state->timer_id);
}

/**
 * ejs_native_timers_destroy — __ejs_native__.timers.destroy 的 QuickJS C 函数实现
 *
 * 对应 JS 侧的 clearTimeout/clearInterval，根据 timer_id 在链表中
 * 查找并销毁对应的定时器。若 timer_id 不存在，静默忽略（无操作）。
 *
 * 参数：
 *   argv[0] — timer_id (number): 由 timers.create 返回的定时器 ID
 *
 * @param ctx      QuickJS 上下文
 * @param this_val this 绑定（未使用）
 * @param argc     参数数量
 * @param argv     参数数组
 * @return JS_UNDEFINED
 */
static JSValue ejs_native_timers_destroy(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;

    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "destroy expects 1 argument");
    }

    EJSCoreContext *public_ctx = (EJSCoreContext *)JS_GetContextOpaque(ctx);

    if (public_ctx == NULL || public_ctx->engine_context == NULL) {
        return JS_ThrowInternalError(ctx, "invalid context");
    }

    EJSEngineContext *engine_ctx = public_ctx->engine_context;

    int64_t timer_id = 0;

    if (JS_ToInt64(ctx, &timer_id, argv[0]) < 0) {
        return JS_EXCEPTION;
    }

    EJSTimerState *curr = engine_ctx->timer_list;

    while (curr != NULL) {
        if (curr->timer_id == (uint64_t)timer_id) {
            ejs_timer_destroy_internal(engine_ctx, curr);
            break;
        }

        curr = curr->next;
    }

    return JS_UNDEFINED;
}

/**
 * ejs_quickjs_interrupt_handler — QuickJS 中断检查回调
 *
 * 由 QuickJS 引擎在 JS 执行过程中的检查点调用。若 interrupt_requested
 * 标志为 true，返回 1 触发 JS 执行中断（抛出 InternalError）；
 * 否则返回 0 继续执行。
 *
 * @param rt     QuickJS 运行时（未使用，中断状态通过 opaque 获取）
 * @param opaque 指向 EJSEngineRuntime 的指针
 * @return 1 表示请求中断，0 表示继续执行
 */
static int ejs_quickjs_interrupt_handler(JSRuntime *rt, void *opaque) {
    (void)rt;
    EJSEngineRuntime *eng = (EJSEngineRuntime *)opaque;

    if (eng != NULL && atomic_load(&eng->interrupt_requested)) {
        return 1;
    }

    return 0;
}

/**
 * ejs_engine_runtime_create — 创建 QuickJS-ng 引擎运行时实例
 *
 * 执行流程：
 *   1. 分配 EJSEngineRuntime 结构体
 *   2. 调用 JS_NewRuntime() 创建 QuickJS 运行时
 *   3. 初始化中断标志为 false
 *   4. 注册中断处理器（ejs_quickjs_interrupt_handler）
 *   5. 若 config 非空，设置内存限制和栈大小
 *
 * 错误处理：
 *   - calloc 失败：返回 NULL
 *   - JS_NewRuntime 失败：释放已分配内存，设置 out_error，返回 NULL
 *
 * @param config    运行时配置（内存限制、栈大小等），可为 NULL
 * @param out_error 输出错误对象，失败时设置；可为 NULL
 * @return 引擎运行时实例；失败时返回 NULL
 */
EJSEngineRuntime * ejs_engine_runtime_create(const EJSCoreRuntimeConfig *config, EJSCoreError **out_error) {
    EJSEngineRuntime *engine;

    (void)config;

    if (out_error != NULL) {
        *out_error = NULL;
    }

    engine = (EJSEngineRuntime *)calloc(1u, sizeof(EJSEngineRuntime));
#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 1) {
        if (engine != NULL) {
            free(engine);
            engine = NULL;
        }
    }

#endif

    if (engine == NULL) {
        return NULL;
    }

    engine->runtime = JS_NewRuntime();
#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 2) {
        if (engine->runtime != NULL) {
            JS_FreeRuntime(engine->runtime);
            engine->runtime = NULL;
        }
    }

#endif

    if (engine->runtime == NULL) {
        free(engine);

        if (out_error != NULL) {
            *out_error = ejs_error_create(EJS_ERROR_INTERNAL, "JS_NewRuntime failed", NULL, NULL, 0);
        }

        return NULL;
    }

    atomic_store(&engine->interrupt_requested, false);
    engine->pending_rejection_contexts = NULL;
#ifdef EJS_TEST
    engine->test_active_context = NULL;
#endif

    JS_SetInterruptHandler(engine->runtime, ejs_quickjs_interrupt_handler, engine);
    JS_SetHostPromiseRejectionTracker(engine->runtime,
                                      ejs_quickjs_promise_rejection_tracker,
                                      engine);
    JS_SetModuleLoaderFunc(engine->runtime,
                           ejs_quickjs_module_normalize,
                           ejs_quickjs_module_loader,
                           engine);

    if (config != NULL && config->memory_limit_bytes > 0u) {
        JS_SetMemoryLimit(engine->runtime, (size_t)config->memory_limit_bytes);
    }

    if (config != NULL && config->max_stack_size > 0u) {
        JS_SetMaxStackSize(engine->runtime, (size_t)config->max_stack_size);
    }

    return engine;
}

/**
 * ejs_engine_runtime_destroy — 销毁 QuickJS-ng 引擎运行时实例
 *
 * 释放 QuickJS JSRuntime 及其所有关联资源（包括所有 JSContext、
 * GC 管理的对象等），然后释放 EJSEngineRuntime 结构体。
 * 传入 NULL 安全（无操作）。
 */
void ejs_engine_runtime_destroy(EJSEngineRuntime *engine) {
    if (engine == NULL) {
        return;
    }

    if (engine->runtime != NULL) {
        JS_FreeRuntime(engine->runtime);
    }

    free(engine);
}

/**
 * ejs_engine_context_create — 在 QuickJS 运行时中创建执行上下文
 *
 * 创建一个新的 QuickJS JSContext，拥有独立的全局对象和模块作用域。
 * 初始化定时器链表和异步调用链表为空，设置起始 timer_id 为 1。
 *
 * @param engine    所属的引擎运行时，不可为 NULL
 * @param out_error 输出错误对象，失败时设置；可为 NULL
 * @return 引擎上下文实例；失败时返回 NULL
 */
EJSEngineContext * ejs_engine_context_create(EJSEngineRuntime *engine, EJSCoreError **out_error) {
    EJSEngineContext *context;

    if (out_error != NULL) {
        *out_error = NULL;
    }

    if (engine == NULL || engine->runtime == NULL) {
        if (out_error != NULL) {
            *out_error = ejs_error_create(EJS_ERROR_INVALID_ARGUMENT, "invalid engine runtime", NULL, NULL, 0);
        }

        return NULL;
    }

    context = (EJSEngineContext *)calloc(1u, sizeof(EJSEngineContext));
#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 3) {
        if (context != NULL) {
            free(context);
            context = NULL;
        }
    }

#endif

    if (context == NULL) {
        return NULL;
    }

    context->runtime = engine;
    context->context = JS_NewContext(engine->runtime);
#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 4) {
        if (context->context != NULL) {
            JS_FreeContext(context->context);
            context->context = NULL;
        }
    }

#endif

    if (context->context == NULL) {
        free(context);

        if (out_error != NULL) {
            *out_error = ejs_error_create(EJS_ERROR_INTERNAL, "JS_NewContext failed", NULL, NULL, 0);
        }

        return NULL;
    }

    context->timer_list = NULL;
    context->next_timer_id = 1;
    context->invoke_list = NULL;
    context->promise_rejection_tracker = JS_UNDEFINED;
    context->exception_reporter = JS_UNDEFINED;
    context->promise_rejection_list = NULL;
    context->module_source_list = NULL;
    context->pending_rejection_next = NULL;
    context->promise_rejection_epoch = 0;
    context->reporting_exception = false;
    context->reporting_promise_rejection = false;
    context->pending_rejection_queued = false;
    context->diagnostic_reported = false;
#ifdef EJS_TEST
    engine->test_active_context = context->context;
#endif

    return context;
}

/**
 * ejs_engine_context_register_core_bindings — 注册内核原语到 JS 全局对象
 *
 * 在 QuickJS 上下文的全局对象上注入 __ejs_native__ 对象及其子方法：
 *   - __ejs_native__.invoke(module_id, method_id, payload, transfer_buffer)
 *     万能异步通道，所有 WinterTC API 通过此方法跨层调用
 *   - __ejs_native__.timers.create(delay, repeat, callback)
 *     创建定时器，对应 JS 的 setTimeout/setInterval
 *   - __ejs_native__.timers.destroy(timer_id)
 *     销毁定时器，对应 JS 的 clearTimeout/clearInterval
 *
 * @param context 引擎上下文
 * @return 注册结果
 */
EJSCoreResult ejs_engine_context_register_core_bindings(EJSEngineContext *context) {
    if (context == NULL || context->context == NULL) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid context for bindings registration",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

#ifdef EJS_TEST

    if (ejs_test_inject_engine_error == 17) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                                 "injected bindings registration error",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

#endif

    JSContext *ctx = context->context;
    JSValue global = JS_UNDEFINED;
    JSValue native = JS_UNDEFINED;
    JSValue timers = JS_UNDEFINED;
    JSValue events = JS_UNDEFINED;
    JSValue invoke_func = JS_UNDEFINED;
    JSValue invoke_sync_func = JS_UNDEFINED;
    JSValue timer_create_func = JS_UNDEFINED;
    JSValue timer_destroy_func = JS_UNDEFINED;
    JSValue set_rejection_tracker_func = JS_UNDEFINED;
    JSValue set_exception_reporter_func = JS_UNDEFINED;
    const char *failure = "failed to register __ejs_native__ bindings";

    global = JS_GetGlobalObject(ctx);
    if (JS_IsException(global)
#ifdef EJS_TEST
        || ejs_test_inject_engine_error == 18
#endif
    ) {
        failure = "failed to get global object for __ejs_native__ bindings";
        goto fail;
    }

    native = JS_NewObject(ctx);
    if (JS_IsException(native)
#ifdef EJS_TEST
        || ejs_test_inject_engine_error == 19
#endif
    ) {
        failure = "failed to create __ejs_native__ binding object";
        goto fail;
    }

    invoke_func = JS_NewCFunction(ctx, ejs_native_invoke, "invoke", 3);
    if (JS_IsException(invoke_func)
#ifdef EJS_TEST
        || ejs_test_inject_engine_error == 20
#endif
    ) {
        failure = "failed to create __ejs_native__.invoke";
        goto fail;
    }
    int set_result = JS_SetPropertyStr(ctx, native, "invoke", invoke_func);
    invoke_func = JS_UNDEFINED;
    if (set_result < 0
#ifdef EJS_TEST
        || ejs_test_inject_engine_error == 21
#endif
    ) {
        failure = "failed to install __ejs_native__.invoke";
        goto fail;
    }

    invoke_sync_func = JS_NewCFunction(ctx, ejs_native_invoke_sync, "invokeSync", 3);
    if (JS_IsException(invoke_sync_func)) {
        failure = "failed to create __ejs_native__.invokeSync";
        goto fail;
    }
    set_result = JS_SetPropertyStr(ctx, native, "invokeSync", invoke_sync_func);
    invoke_sync_func = JS_UNDEFINED;
    if (set_result < 0) {
        failure = "failed to install __ejs_native__.invokeSync";
        goto fail;
    }

    timers = JS_NewObject(ctx);
    if (JS_IsException(timers)
#ifdef EJS_TEST
        || ejs_test_inject_engine_error == 22
#endif
    ) {
        failure = "failed to create __ejs_native__.timers";
        goto fail;
    }

    timer_create_func = JS_NewCFunction(ctx, ejs_native_timers_create, "create", 3);
    if (JS_IsException(timer_create_func)
#ifdef EJS_TEST
        || ejs_test_inject_engine_error == 23
#endif
    ) {
        failure = "failed to create __ejs_native__.timers.create";
        goto fail;
    }
    set_result = JS_SetPropertyStr(ctx, timers, "create", timer_create_func);
    timer_create_func = JS_UNDEFINED;
    if (set_result < 0
#ifdef EJS_TEST
        || ejs_test_inject_engine_error == 24
#endif
    ) {
        failure = "failed to install __ejs_native__.timers.create";
        goto fail;
    }

    timer_destroy_func = JS_NewCFunction(ctx, ejs_native_timers_destroy, "destroy", 1);
    if (JS_IsException(timer_destroy_func)
#ifdef EJS_TEST
        || ejs_test_inject_engine_error == 25
#endif
    ) {
        failure = "failed to create __ejs_native__.timers.destroy";
        goto fail;
    }
    set_result = JS_SetPropertyStr(ctx, timers, "destroy", timer_destroy_func);
    timer_destroy_func = JS_UNDEFINED;
    if (set_result < 0
#ifdef EJS_TEST
        || ejs_test_inject_engine_error == 26
#endif
    ) {
        failure = "failed to install __ejs_native__.timers.destroy";
        goto fail;
    }

    set_result = JS_SetPropertyStr(ctx, native, "timers", timers);
    timers = JS_UNDEFINED;
    if (set_result < 0
#ifdef EJS_TEST
        || ejs_test_inject_engine_error == 27
#endif
    ) {
        failure = "failed to install __ejs_native__.timers";
        goto fail;
    }

    events = JS_NewObject(ctx);
    if (JS_IsException(events)) {
        failure = "failed to create __ejs_native__.events";
        goto fail;
    }

    set_rejection_tracker_func = JS_NewCFunction(ctx,
                                                 ejs_native_events_set_promise_rejection_tracker,
                                                 "setPromiseRejectionTracker",
                                                 1);
    if (JS_IsException(set_rejection_tracker_func)) {
        failure = "failed to create __ejs_native__.events.setPromiseRejectionTracker";
        goto fail;
    }
    set_result = JS_SetPropertyStr(ctx,
                                   events,
                                   "setPromiseRejectionTracker",
                                   set_rejection_tracker_func);
    set_rejection_tracker_func = JS_UNDEFINED;
    if (set_result < 0) {
        failure = "failed to install __ejs_native__.events.setPromiseRejectionTracker";
        goto fail;
    }

    set_exception_reporter_func = JS_NewCFunction(ctx,
                                                  ejs_native_events_set_exception_reporter,
                                                  "setExceptionReporter",
                                                  1);
    if (JS_IsException(set_exception_reporter_func)) {
        failure = "failed to create __ejs_native__.events.setExceptionReporter";
        goto fail;
    }
    set_result = JS_SetPropertyStr(ctx,
                                   events,
                                   "setExceptionReporter",
                                   set_exception_reporter_func);
    set_exception_reporter_func = JS_UNDEFINED;
    if (set_result < 0) {
        failure = "failed to install __ejs_native__.events.setExceptionReporter";
        goto fail;
    }

    set_result = JS_SetPropertyStr(ctx, native, "events", events);
    events = JS_UNDEFINED;
    if (set_result < 0) {
        failure = "failed to install __ejs_native__.events";
        goto fail;
    }

    set_result = JS_SetPropertyStr(ctx, global, "__ejs_native__", native);
    native = JS_UNDEFINED;
    if (set_result < 0
#ifdef EJS_TEST
        || ejs_test_inject_engine_error == 28
#endif
    ) {
        failure = "failed to install __ejs_native__";
        goto fail;
    }

    JS_FreeValue(ctx, global);
    return ejs_result_ok();

fail:
    JS_FreeValue(ctx, set_exception_reporter_func);
    JS_FreeValue(ctx, set_rejection_tracker_func);
    JS_FreeValue(ctx, timer_destroy_func);
    JS_FreeValue(ctx, timer_create_func);
    JS_FreeValue(ctx, invoke_sync_func);
    JS_FreeValue(ctx, invoke_func);
    JS_FreeValue(ctx, events);
    JS_FreeValue(ctx, timers);
    JS_FreeValue(ctx, native);
    JS_FreeValue(ctx, global);
    return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                             failure,
                                             NULL,
                                             NULL,
                                             0));
}

/**
 * ejs_engine_context_destroy — 销毁 QuickJS 引擎上下文
 *
 * 执行以下清理步骤：
 *   1. 遍历 timer_list，销毁所有活跃定时器（释放 JS 回调引用）
 *   2. 遍历 invoke_list，取消并释放所有挂起的异步操作：
 *      a. 从双链表中摘除
 *      b. 调用宿主的 cancel 和 release 回调
 *      c. 释放 Promise 的 resolve/reject 函数引用（防范内存泄漏）
 *      d. 将 ctx 置 NULL（防止后续异步完成回调访问已销毁的上下文）
 *      e. 递减引用计数
 *   3. 释放 QuickJS JSContext
 *   4. 清除 test_active_context 引用
 *   5. 释放 EJSEngineContext 结构体
 *
 * 传入 NULL 安全（无操作）。
 */
void ejs_engine_context_destroy(EJSEngineContext *context) {
    if (context == NULL) {
        return;
    }

    while (context->timer_list != NULL)
        ejs_timer_destroy_internal(context, context->timer_list);

    while (context->invoke_list != NULL) {
        EJSInvokeState *state = context->invoke_list;
        context->invoke_list = state->next;

        if (state->next != NULL) {
            state->next->prev = NULL;
        }

        state->prev = NULL;
        state->next = NULL;

        ejs_invoke_state_cancel_and_release_operation(state);

        // 强制在 Context 销毁的 owner 线程中释放 Promise 相关的 callback 引用，防范 Leak
        JS_FreeValue(context->context, state->resolve_func);
        JS_FreeValue(context->context, state->reject_func);
        state->resolve_func = JS_UNDEFINED;
        state->reject_func = JS_UNDEFINED;

        atomic_store(&state->ctx, NULL);
        ejs_invoke_state_dec_ref(state);
    }

    if (context->context != NULL) {
        ejs_promise_rejection_clear_all(context);
        ejs_module_source_list_free(context->module_source_list);
        context->module_source_list = NULL;
        JS_FreeValue(context->context, context->promise_rejection_tracker);
        JS_FreeValue(context->context, context->exception_reporter);
        context->promise_rejection_tracker = JS_UNDEFINED;
        context->exception_reporter = JS_UNDEFINED;
        JS_FreeContext(context->context);
    }

#ifdef EJS_TEST

    if (context->runtime->test_active_context == context->context) {
        context->runtime->test_active_context = NULL;
    }

#endif
    free(context);
}

/**
 * ejs_engine_eval_script — 以全局模式执行 JS 脚本
 *
 * 在 QuickJS 上下文中以 JS_EVAL_TYPE_GLOBAL 模式执行 JS 源代码。
 * 执行前先清除中断标志，确保脚本不被之前的中断请求影响。
 * 执行是同步的，函数返回时脚本已执行完毕。
 */
EJSCoreResult ejs_engine_eval_script(EJSEngineContext *context,
                                 const char       *filename,
                                 const char       *source,
                                 size_t           source_len) {
    JSValue value;

    if (context == NULL || context->context == NULL || source == NULL) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid script evaluation input",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (context->runtime != NULL) {
        atomic_store(&context->runtime->interrupt_requested, false);
    }

    value = JS_Eval(context->context,
                    source,
                    source_len,
                    filename == NULL ? "<eval>" : filename,
                    JS_EVAL_TYPE_GLOBAL);
    return ejs_result_from_eval(context->context, value);
}

EJSCoreResult ejs_engine_register_module_sources(EJSEngineContext             *context,
                                                 const EJSCoreModuleSource   *sources,
                                                 size_t                       source_count) {
    if (context == NULL || context->context == NULL || (source_count > 0u && sources == NULL)) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid module source registration input",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    EJSModuleSourceRecord *pending = NULL;
    for (size_t i = 0u; i < source_count; i++) {
        EJSModuleSourceRecord *record = ejs_module_source_record_create(&sources[i]);
        if (record == NULL) {
            ejs_module_source_list_free(pending);
            return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                     "invalid module source entry",
                                                     NULL,
                                                     NULL,
                                                     0));
        }
        record->next = pending;
        pending = record;
    }

    while (pending != NULL) {
        EJSModuleSourceRecord *next = pending->next;
        pending->next = NULL;
        ejs_module_source_upsert(context, pending);
        pending = next;
    }

    return ejs_result_ok();
}

/**
 * ejs_engine_eval_module — 以 ES 模块模式执行 JS 代码
 *
 * 在 QuickJS 上下文中以 JS_EVAL_TYPE_MODULE 模式执行 JS 源代码，
 * 支持 import/export 语法。模块文件名优先级：
 *   source_url > specifier > "<module>"
 */
EJSCoreResult ejs_engine_eval_module(EJSEngineContext     *context,
                                 const EJSCoreEvalOptions *options,
                                 const char           *source,
                                 size_t               source_len) {
    JSValue value;
    const char *module_name;

    if (context == NULL || context->context == NULL || options == NULL || source == NULL) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid module evaluation input",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (context->runtime != NULL) {
        atomic_store(&context->runtime->interrupt_requested, false);
    }

    module_name = options->source_url != NULL ? options->source_url :
                  (options->specifier != NULL ? options->specifier : "<module>");
    value = JS_Eval(context->context,
                    source,
                    source_len,
                    module_name,
                    JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(value)) {
        return ejs_result_error(ejs_error_from_exception(context->context,
                                                        "JavaScript module evaluation failed"));
    }

    if (ejs_set_module_import_meta(context->context, value, module_name, true) < 0) {
        JS_FreeValue(context->context, value);
        return ejs_result_error(ejs_error_from_exception(context->context,
                                                        "JavaScript module evaluation failed"));
    }

    value = JS_EvalFunction(context->context, value);
    return ejs_result_from_module_eval(context, value);
}

/**
 * ejs_engine_run_jobs — 执行 QuickJS 中所有待处理的微任务
 *
 * 循环调用 JS_ExecutePendingJob 直到所有微任务执行完毕或出错。
 * 微任务包括 Promise 回调、async/await 续延等。
 * 若某个微任务抛出异常且没有 exception reporter，立即返回错误；已安装
 * reporter 时先汇报异常再继续 drain 后续微任务。
 */
EJSCoreResult ejs_engine_run_jobs(EJSEngineRuntime *engine) {
    JSContext *job_context = NULL;
    int result;
#ifdef EJS_TEST
    bool injected_job_failure = false;
#endif

    if (engine == NULL || engine->runtime == NULL) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid engine runtime",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    do {
#ifdef EJS_TEST

        if (ejs_test_inject_engine_error == 11 && !injected_job_failure) {
            /*
             * QuickJS 真实失败会通过 job_context 返回异常所属上下文；注入路径没有
             * 真实 pending job，因此使用测试专用 active context 让错误转换逻辑可测。
             */
            result = -1;
            job_context = (JSContext *)engine->test_active_context;
            injected_job_failure = true;
        } else

#endif
        {
            result = JS_ExecutePendingJob(engine->runtime, &job_context);
        }

        if (result < 0 && job_context != NULL && ejs_engine_has_exception_reporter(job_context)) {
            (void)ejs_engine_report_current_exception(job_context, "pending job failed");
            result = 1;
            continue;
        }

        if (result < 0 && job_context != NULL) {
            return ejs_result_error(ejs_error_from_exception(job_context, "pending job failed"));
        }

    } while (result > 0);

    ejs_engine_flush_pending_promise_rejections(engine);
    return ejs_result_ok();
}

bool ejs_engine_has_pending_jobs(EJSEngineRuntime *engine) {
    return engine != NULL &&
           engine->runtime != NULL &&
           JS_IsJobPending(engine->runtime);
}

/**
 * ejs_engine_request_interrupt — 请求中断 JS 执行
 *
 * 通过原子操作设置 interrupt_requested 标志，QuickJS 引擎将在
 * 下一个中断检查点调用 ejs_quickjs_interrupt_handler，若标志为 true
 * 则中断当前 JS 执行。
 */
void ejs_engine_request_interrupt(EJSEngineRuntime *engine) {
    if (engine != NULL) {
        atomic_store(&engine->interrupt_requested, true);
    }
}

/**
 * ejs_engine_context_associate_runtime_context — 将公共上下文与引擎上下文关联
 *
 * 通过 JS_SetContextOpaque 将 EJSCoreContext 指针存储到 QuickJS 上下文中，
 * 使得引擎回调（如 invoke、timer）可以通过 JS_GetContextOpaque
 * 获取到公共上下文。
 */
void ejs_engine_context_associate_runtime_context(EJSEngineContext *context, void *opaque) {
    if (context != NULL && context->context != NULL) {
        JS_SetContextOpaque(context->context, opaque);
    }
}

/**
 * ejs_engine_context_retrieve_runtime_context — 从引擎上下文获取关联的公共上下文
 *
 * 通过 JS_GetContextOpaque 获取之前关联的 EJSCoreContext 指针。
 */
void * ejs_engine_context_retrieve_runtime_context(EJSEngineContext *context) {
    if (context != NULL && context->context != NULL) {
        return JS_GetContextOpaque(context->context);
    }

    return NULL;
}

/**
 * ejs_engine_name — 返回当前引擎后端名称
 *
 * 用于诊断和日志，返回静态字符串 "quickjs-ng"（无需释放）。
 */
const char * ejs_engine_name(void) {
    return "quickjs-ng";
}

/**
 * ejs_runtime.c — 公共 runtime/context API 的生命周期调度层
 *
 * 本文件实现 core/include/ejs_runtime.h 暴露的主要入口。它不直接触碰
 * QuickJS 或 libuv 的细节，而是把公共 API 调用转换成 owner-thread 任务：
 *   - runtime 创建时组装 ABI 校验、runtime loop、engine runtime 三个部分；
 *   - context 创建/销毁、脚本/模块求值都通过 ejs_runtime_loop_call_sync
 *     串行进入 owner 线程；
 *   - host API 注册只保存经校验的 EJSCoreHostAPI 指针，具体 invoke 由引擎绑定处理；
 *   - 销毁路径先将 runtime 标记为不可用，再在 owner 线程清理 context/engine/loop。
 *
 * 线程模型约束：
 *   Public API 可以从宿主线程调用，但任何 JS 引擎对象的创建、访问、释放都必须
 *   通过 runtime loop 落到 owner 线程。这里的小 task 结构体是同步跨线程调用的
 *   栈上参数包，回调返回前不得被保存。
 *
 * 测试注入边界：
 *   ejs_test_inject_runtime_error 只在 EJS_TEST 构建中存在，用于覆盖创建失败、
 *   loop 失败、engine 失败、destroy 降级等错误路径。生产构建不应暴露该符号
 *   或任何注入分支。
 */

#include "ejs_runtime_internal.h"

#include <assert.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#ifdef EJS_TEST
int ejs_test_inject_runtime_error = 0;
#endif

#include "ejs_abi.h"
#include "ejs_engine.h"
#include "ejs_error.h"
#include "ejs_native_api.h"

typedef struct {
    EJSCoreRuntime *runtime;
    EJSCoreContext *context;
    EJSCoreError *engine_error;
} EJSCreateContextTask;

typedef struct {
    EJSCoreContext *context;
} EJSDestroyContextTask;

typedef struct {
    EJSCoreContext *context;
    const char *filename;
    const char *source;
    size_t source_len;
    EJSCoreResult result;
} EJSEvalScriptTask;

typedef struct {
    EJSCoreContext *context;
    const EJSCoreEvalOptions *options;
    const char *source;
    size_t source_len;
    EJSCoreResult result;
} EJSEvalModuleTask;

typedef struct {
    EJSCoreContext *context;
    const EJSCoreModuleSource *sources;
    size_t source_count;
    EJSCoreResult result;
} EJSRegisterModuleSourcesTask;

typedef struct {
    EJSCoreRuntime *runtime;
    EJSCoreResult result;
} EJSRunJobsTask;

static void ejs_destroy_waiter_queue_append(EJSCoreRuntime *runtime, EJSRuntimeDestroyWaiter *waiter) {
    waiter->next = NULL;
    if (runtime->destroy_waiters_tail != NULL) {
        runtime->destroy_waiters_tail->next = waiter;
    } else {
        runtime->destroy_waiters_head = waiter;
    }
    runtime->destroy_waiters_tail = waiter;
}

static void ejs_context_unlink_from_runtime(EJSCoreContext *context) {
    if (context == NULL || context->runtime == NULL) {
        return;
    }

    if (context->prev != NULL) {
        context->prev->next = context->next;
    } else if (context->runtime->context_list == context) {
        context->runtime->context_list = context->next;
    }

    if (context->next != NULL) {
        context->next->prev = context->prev;
    }

    context->prev = NULL;
    context->next = NULL;
}

static void ejs_context_finalize(EJSCoreContext *context) {
    if (context == NULL) {
        return;
    }

    if (context->host != NULL) {
        ejs_registered_host_release(context->host);
        context->host = NULL;
    }
    pthread_mutex_destroy(&context->host_mutex);

    context->engine_context = NULL;
    context->runtime = NULL;
    context->magic = 0u;
    context->destroy_next = NULL;
    context->destroy_queued = false;
    free(context);
}

static bool ejs_context_try_retain(EJSCoreContext *context) {
    return context != NULL && ejs_refcount_try_retain(&context->ref_count);
}

static bool ejs_runtime_try_retain(EJSCoreRuntime *runtime) {
    return runtime != NULL && ejs_refcount_try_retain(&runtime->ref_count);
}

static void ejs_context_release(EJSCoreContext *context) {
    if (context != NULL && ejs_refcount_release(&context->ref_count)) {
        ejs_context_finalize(context);
    }
}

static bool ejs_runtime_add_destroy_waiter(EJSCoreRuntime *runtime,
                                           EJSCoreRuntimeStopCompletion completion,
                                           void *user_data,
                                           bool allow_wait_on_oom) {
    if (completion == NULL) {
        return true;
    }

    EJSRuntimeDestroyWaiter *waiter =
        (EJSRuntimeDestroyWaiter *)calloc(1u, sizeof(EJSRuntimeDestroyWaiter));
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 9) {
        free(waiter);
        waiter = NULL;
    }

#endif

    pthread_mutex_lock(&runtime->destroy_mutex);
    if (atomic_load(&runtime->destroy_completed)) {
        pthread_mutex_unlock(&runtime->destroy_mutex);
        free(waiter);
        completion(user_data);
        return true;
    }

    if (waiter == NULL) {
        for (int i = 0; i < 4; i++) {
            if (!runtime->destroy_waiters_inline_used[i]) {
                waiter = &runtime->destroy_waiters_inline[i];
                runtime->destroy_waiters_inline_used[i] = true;
                waiter->is_inline = 1;
                break;
            }
        }
    }

    if (waiter == NULL) {
        if (allow_wait_on_oom) {
            while (!atomic_load(&runtime->destroy_completed)) {
                pthread_cond_wait(&runtime->destroy_cond, &runtime->destroy_mutex);
            }
            pthread_mutex_unlock(&runtime->destroy_mutex);
            completion(user_data);
            return true;
        }

        pthread_mutex_unlock(&runtime->destroy_mutex);
        return false;
    }

    waiter->completion = completion;
    waiter->user_data = user_data;
    ejs_destroy_waiter_queue_append(runtime, waiter);
    pthread_mutex_unlock(&runtime->destroy_mutex);
    return true;
}

static void ejs_runtime_complete_destroy(EJSCoreRuntime *runtime) {
    pthread_mutex_lock(&runtime->destroy_mutex);
    EJSRuntimeDestroyWaiter *waiters = runtime->destroy_waiters_head;
    runtime->destroy_waiters_head = NULL;
    runtime->destroy_waiters_tail = NULL;
    atomic_store(&runtime->destroy_completed, true);
    pthread_cond_broadcast(&runtime->destroy_cond);
    pthread_mutex_unlock(&runtime->destroy_mutex);

    EJSRuntimeDestroyWaiter *curr = waiters;
    while (curr != NULL) {
        EJSRuntimeDestroyWaiter *next = curr->next;
        if (curr->completion != NULL) {
            curr->completion(curr->user_data);
        }
        if (!curr->is_inline) {
            free(curr);
        }
        curr = next;
    }

}

void ejs_runtime_enqueue_deferred_context_destroy(EJSCoreContext *context) {
    if (context == NULL || context->runtime == NULL || context->destroy_queued) {
        return;
    }

    EJSCoreRuntime *runtime = context->runtime;
    ejs_context_unlink_from_runtime(context);
    context->destroy_queued = true;
    context->destroy_next = runtime->deferred_destroy_list;
    runtime->deferred_destroy_list = context;
}

void ejs_runtime_enter_owner_callback(EJSCoreRuntime *runtime) {
    if (runtime != NULL) {
        runtime->owner_callback_depth++;
    }
}

void ejs_runtime_leave_owner_callback(EJSCoreRuntime *runtime) {
    if (runtime != NULL && runtime->owner_callback_depth > 0u) {
        runtime->owner_callback_depth--;
    }
}

static bool ejs_runtime_can_flush_deferred_context_destroys(EJSCoreRuntime *runtime) {
    if (runtime == NULL || runtime->owner_callback_depth != 0u) {
        return false;
    }

    return runtime->engine_runtime == NULL ||
           !ejs_engine_has_pending_jobs(runtime->engine_runtime);
}

void ejs_runtime_force_flush_deferred_context_destroys(EJSCoreRuntime *runtime) {
    if (runtime == NULL) {
        return;
    }

    while (runtime->deferred_destroy_list != NULL) {
        EJSCoreContext *context = runtime->deferred_destroy_list;
        runtime->deferred_destroy_list = context->destroy_next;
        context->destroy_next = NULL;
        context->destroy_queued = false;

        if (context->engine_context != NULL) {
            ejs_engine_context_destroy(context->engine_context);
            context->engine_context = NULL;
        }

        ejs_context_release(context);
    }
}

void ejs_runtime_flush_deferred_context_destroys(EJSCoreRuntime *runtime) {
    if (!ejs_runtime_can_flush_deferred_context_destroys(runtime)) {
        return;
    }

    ejs_runtime_force_flush_deferred_context_destroys(runtime);
}

/**
 * ejs_create_context_task — 在 owner 线程内创建并挂载 engine context
 *
 * context 外壳由调用线程先分配，真正的 JS engine context、core bindings 注册、
 * runtime->context_list 链表挂载都在 owner 线程完成。这样 QuickJS 的
 * JS_NewContext、JS_SetContextOpaque 以及全局对象注入不会跨线程执行。
 */
static void ejs_create_context_task(void *user_data) {
    EJSCreateContextTask *task = (EJSCreateContextTask *)user_data;

    task->context->engine_context =
        ejs_engine_context_create(task->runtime->engine_runtime, &task->engine_error);

    if (task->context->engine_context != NULL) {
        ejs_engine_context_associate_runtime_context(task->context->engine_context, task->context);

        EJSCoreResult reg_res = ejs_engine_context_register_core_bindings(task->context->engine_context);

        if (reg_res.status != EJS_STATUS_OK) {
            if (task->engine_error == NULL) {
                task->engine_error = reg_res.error;
            } else {
                ejs_error_destroy(reg_res.error);
            }

            ejs_engine_context_destroy(task->context->engine_context);
            task->context->engine_context = NULL;
            return;
        }

        /* 挂入 runtime->context_list 双向链表；该链表只在 owner 线程变更。 */
        task->context->next = task->runtime->context_list;
        task->context->prev = NULL;

        if (task->runtime->context_list != NULL) {
            task->runtime->context_list->prev = task->context;
        }

        task->runtime->context_list = task->context;
    }
}

/**
 * ejs_destroy_context_task — 在 owner 线程内摘除并销毁 engine context
 *
 * 链表摘除和引擎资源释放必须在 owner 线程执行；最终物理释放由 context 的
 * 引用计数归零触发。runtime 正在降级销毁且 loop 已不可用时，调用方会直接
 * 执行该任务，此时不再有并发 JS 执行。
 */
static void ejs_destroy_context_task(void *user_data) {
    EJSDestroyContextTask *task = (EJSDestroyContextTask *)user_data;

    ejs_context_unlink_from_runtime(task->context);

    if (task->context->engine_context != NULL) {
        ejs_engine_context_destroy(task->context->engine_context);
        task->context->engine_context = NULL;
    }
    ejs_context_release(task->context);
}

/* 求值任务只封装参数转发；实际异常捕获和 EJSCoreError 构造由 engine 后端负责。 */
static void ejs_eval_script_task(void *user_data) {
    EJSEvalScriptTask *task = (EJSEvalScriptTask *)user_data;

    if (!ejs_context_is_valid(task->context)) {
        task->result = ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                         "invalid EJSCoreContext",
                                                         NULL,
                                                         NULL,
                                                         0));
        return;
    }

    ejs_runtime_enter_owner_callback(task->context->runtime);
    task->result = ejs_engine_eval_script(task->context->engine_context,
                                          task->filename,
                                          task->source,
                                          task->source_len);
    ejs_runtime_leave_owner_callback(task->context->runtime);
    ejs_runtime_flush_deferred_context_destroys(task->context->runtime);
}

/* 模块求值同样在 owner 线程串行执行，避免 QuickJS module state 跨线程访问。 */
static void ejs_eval_module_task(void *user_data) {
    EJSEvalModuleTask *task = (EJSEvalModuleTask *)user_data;

    if (!ejs_context_is_valid(task->context)) {
        task->result = ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                         "invalid EJSCoreContext",
                                                         NULL,
                                                         NULL,
                                                         0));
        return;
    }

    ejs_runtime_enter_owner_callback(task->context->runtime);
    task->result = ejs_engine_eval_module(task->context->engine_context,
                                          task->options,
                                          task->source,
                                          task->source_len);
    ejs_runtime_leave_owner_callback(task->context->runtime);
    ejs_runtime_flush_deferred_context_destroys(task->context->runtime);
}

/* 模块源码表注册必须在 owner 线程完成，避免 loader 表和 QuickJS module state 跨线程竞态。 */
static void ejs_register_module_sources_task(void *user_data) {
    EJSRegisterModuleSourcesTask *task = (EJSRegisterModuleSourcesTask *)user_data;

    if (!ejs_context_is_valid(task->context)) {
        task->result = ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                         "invalid EJSCoreContext",
                                                         NULL,
                                                         NULL,
                                                         0));
        return;
    }

    ejs_runtime_enter_owner_callback(task->context->runtime);
    task->result = ejs_engine_register_module_sources(task->context->engine_context,
                                                      task->sources,
                                                      task->source_count);
    ejs_runtime_leave_owner_callback(task->context->runtime);
    ejs_runtime_flush_deferred_context_destroys(task->context->runtime);
}

/* 测试/手动 drain 入口使用该任务在 owner 线程驱动 QuickJS pending jobs。 */
static void ejs_runtime_drain_task(void *user_data) {
    EJSRunJobsTask *task = (EJSRunJobsTask *)user_data;

    ejs_runtime_enter_owner_callback(task->runtime);
    task->result = ejs_engine_run_jobs(task->runtime->engine_runtime);
    ejs_runtime_leave_owner_callback(task->runtime);
    ejs_runtime_flush_deferred_context_destroys(task->runtime);
}

bool ejs_runtime_is_valid(const EJSCoreRuntime *runtime) {
    return runtime != NULL &&
           runtime->magic == EJS_RUNTIME_MAGIC &&
           atomic_load(&runtime->alive);
}

bool ejs_context_is_valid(const EJSCoreContext *context) {
    return context != NULL &&
           context->magic == EJS_CONTEXT_MAGIC &&
           atomic_load(&context->alive) &&
           ejs_runtime_is_valid(context->runtime);
}

void ejs_runtime_retain(EJSCoreRuntime *runtime) {
    if (runtime != NULL) {
        ejs_refcount_retain(&runtime->ref_count);
    }
}

void ejs_runtime_release(EJSCoreRuntime *runtime) {
    if (runtime != NULL && ejs_refcount_release(&runtime->ref_count)) {
        pthread_cond_destroy(&runtime->destroy_cond);
        pthread_mutex_destroy(&runtime->destroy_mutex);
        free(runtime);
    }
}

EJSCoreRuntime * ejs_runtime_create(const EJSCoreRuntimeConfig *config) {
    EJSCoreRuntime *runtime;
    EJSCoreError *engine_error = NULL;

    if (!ejs_abi_check_runtime_config(config)) {
        return NULL;
    }

    runtime = (EJSCoreRuntime *)calloc(1u, sizeof(EJSCoreRuntime));
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 1) {
        if (runtime != NULL) {
            free(runtime);
            runtime = NULL;
        }
    }

#endif

    if (runtime == NULL) {
        return NULL;
    }

    runtime->magic = EJS_RUNTIME_MAGIC;
    atomic_init(&runtime->alive, true);
    atomic_init(&runtime->state, EJS_RUNTIME_STATE_CREATED);
    atomic_init(&runtime->interrupt_requested, false);
    ejs_refcount_init(&runtime->ref_count, 1u);
    atomic_init(&runtime->pending_host_operation_count, 0u);
    runtime->deferred_destroy_list = NULL;
    pthread_mutex_init(&runtime->destroy_mutex, NULL);
    pthread_cond_init(&runtime->destroy_cond, NULL);
    runtime->destroy_waiters_head = NULL;
    runtime->destroy_waiters_tail = NULL;
    for (int i = 0; i < 4; i++) {
        runtime->destroy_waiters_inline[i].completion = NULL;
        runtime->destroy_waiters_inline[i].user_data = NULL;
        runtime->destroy_waiters_inline[i].is_inline = 1;
        runtime->destroy_waiters_inline[i].next = NULL;
        runtime->destroy_waiters_inline_used[i] = false;
    }
    atomic_init(&runtime->destroy_completed, false);
    runtime->runtime_name = config->runtime_name;
    runtime->runtime_version = config->runtime_version;
    runtime->memory_limit_bytes = config->memory_limit_bytes;
    runtime->max_stack_size = config->max_stack_size;

    /*
     * loop 持有 runtime 指针，libuv 后端的 prepare/check 句柄会用它驱动
     * QuickJS pending jobs。此时 runtime 已完成基础字段初始化，但尚未对外可用。
     */
    EJSCoreError *loop_err = NULL;
    runtime->runtime_loop = ejs_runtime_loop_create(runtime, &loop_err);
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 2) {
        if (runtime->runtime_loop != NULL) {
            ejs_runtime_loop_destroy(runtime->runtime_loop);
            runtime->runtime_loop = NULL;
        }

        if (loop_err == NULL) {
            loop_err = ejs_error_create(EJS_ERROR_INTERNAL, "injected runtime loop error", NULL, NULL, 0);
        }
    }

#endif

    if (runtime->runtime_loop == NULL) {
        if (engine_error == NULL) {
            engine_error = loop_err;
        } else {
            ejs_error_destroy(loop_err);
        }

        ejs_error_destroy(engine_error);
        pthread_cond_destroy(&runtime->destroy_cond);
        pthread_mutex_destroy(&runtime->destroy_mutex);
        free(runtime);
        return NULL;
    }

    EJSCoreError *engine_err = NULL;
    runtime->engine_runtime = ejs_engine_runtime_create(config, &engine_err);
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 3) {
        if (runtime->engine_runtime != NULL) {
            ejs_engine_runtime_destroy(runtime->engine_runtime);
            runtime->engine_runtime = NULL;
        }

        if (engine_err == NULL) {
            engine_err = ejs_error_create(EJS_ERROR_INTERNAL, "injected engine runtime error", NULL, NULL, 0);
        }
    }

#endif

    if (runtime->engine_runtime == NULL) {
        if (engine_error == NULL) {
            engine_error = engine_err;
        } else {
            ejs_error_destroy(engine_err);
        }

        ejs_runtime_loop_destroy(runtime->runtime_loop);
        ejs_error_destroy(engine_error);
        pthread_cond_destroy(&runtime->destroy_cond);
        pthread_mutex_destroy(&runtime->destroy_mutex);
        free(runtime);
        return NULL;
    }

    EJSCoreResult start_res = ejs_runtime_loop_start(runtime->runtime_loop);

    if (start_res.status != EJS_STATUS_OK) {
        ejs_engine_runtime_destroy(runtime->engine_runtime);
        ejs_runtime_loop_destroy(runtime->runtime_loop);
        ejs_error_destroy(start_res.error);
        pthread_cond_destroy(&runtime->destroy_cond);
        pthread_mutex_destroy(&runtime->destroy_mutex);
        free(runtime);
        return NULL;
    }

    atomic_store(&runtime->state, EJS_RUNTIME_STATE_RUNNING);

    return runtime;
}

typedef struct {
    EJSCoreRuntime *runtime;
} EJSAsyncDestroyContext;

/**
 * ejs_terminal_shutdown_task — owner 线程上的最终关闭任务
 *
 * 销毁路径已经先把 runtime->alive 置 false，新的公共 API 会被拒绝；该任务负责
 * 清空仍挂在 runtime 上的 context，释放 engine runtime，并关闭 loop handles。
 * ejs_runtime_loop_destroy 随后在 helper 线程中 join owner 线程并释放 loop 本体。
 */
static void ejs_terminal_shutdown_task(void *user_data) {
    EJSCoreRuntime *runtime = (EJSCoreRuntime *)user_data;

    ejs_runtime_force_flush_deferred_context_destroys(runtime);

    /* 1. 清理宿主未显式销毁的 context，避免 runtime 销毁后泄漏。 */
    while (runtime->context_list != NULL) {
        EJSCoreContext *c = runtime->context_list;
        ejs_context_unlink_from_runtime(c);

        atomic_store(&c->alive, false);
        if (c->engine_context != NULL) {
            ejs_engine_context_destroy(c->engine_context);
            c->engine_context = NULL;
        }
        ejs_context_release(c);
    }

    /* 2. QuickJS runtime 必须在所有 context 释放后销毁。 */
    if (runtime->engine_runtime != NULL) {
        ejs_engine_runtime_destroy(runtime->engine_runtime);
        runtime->engine_runtime = NULL;
    }

    /* 3. 只关闭句柄；loop 结构和线程 join 由 ejs_runtime_loop_destroy 完成。 */
    ejs_runtime_loop_close_handles(runtime->runtime_loop);
}

static bool ejs_runtime_try_local_terminal_shutdown(EJSCoreRuntime *runtime) {
    if (runtime == NULL || runtime->runtime_loop == NULL) {
        return false;
    }

    EJSRuntimeLoop *runtime_loop = runtime->runtime_loop;

    if (ejs_runtime_loop_is_thread_started(runtime_loop)) {
        EJSCoreResult stop_result = ejs_runtime_loop_stop(runtime_loop);

        if (stop_result.status != EJS_STATUS_OK) {
            ejs_error_destroy(stop_result.error);

            if (ejs_runtime_loop_is_thread_started(runtime_loop)) {
                return false;
            }
        } else {
            ejs_error_destroy(stop_result.error);
        }
    }

    ejs_terminal_shutdown_task(runtime);
    return true;
}

/**
 * ejs_async_destroy_thread_main — 非阻塞销毁的 helper 线程
 *
 * 公共异步 destroy 不能阻塞调用线程，所以单独起 helper 线程等待 owner-thread
 * 终止并释放 runtime 内存。所有 completion 由 runtime 的 destroy waiter 队列
 * 统一触发，重复 destroy 调用不会被提前误报为已完成。
 */
static void ejs_runtime_finish_destroy_on_helper(EJSCoreRuntime *runtime) {
    // 1. 同步投递 Terminal Shutdown Task 到 owner 线程中执行
    EJSCoreResult loop_result = ejs_runtime_loop_call_sync(runtime->runtime_loop, ejs_terminal_shutdown_task, runtime);
    if (loop_result.status != EJS_STATUS_OK) {
        ejs_error_destroy(loop_result.error);
        (void)ejs_runtime_try_local_terminal_shutdown(runtime);
    } else {
        ejs_error_destroy(loop_result.error);
    }

    // 2. 释放事件循环，在其内部清空多余 uv 队列并 join 其 loop 线程
    ejs_runtime_loop_destroy(runtime->runtime_loop);
    runtime->runtime_loop = NULL;

    // 3. 清理魔数与指针
    runtime->magic = 0u;

    ejs_runtime_complete_destroy(runtime);
    ejs_runtime_release(runtime);
}

static void ejs_runtime_owner_exit_before_close(void *user_data) {
    ejs_terminal_shutdown_task((EJSCoreRuntime *)user_data);
}

static void ejs_runtime_owner_exit_after_close(void *user_data) {
    EJSCoreRuntime *runtime = (EJSCoreRuntime *)user_data;
    runtime->runtime_loop = NULL;
    runtime->magic = 0u;
    ejs_runtime_complete_destroy(runtime);
    ejs_runtime_release(runtime);
}

static void ejs_runtime_destroy_after_owner_exit(EJSCoreRuntime *runtime) {
    ejs_runtime_loop_destroy_after_owner_exit(runtime->runtime_loop,
                                              ejs_runtime_owner_exit_before_close,
                                              ejs_runtime_owner_exit_after_close,
                                              runtime);
}

static void * ejs_async_destroy_thread_main(void *arg) {
    EJSAsyncDestroyContext *ctx = (EJSAsyncDestroyContext *)arg;
    EJSCoreRuntime *runtime = ctx->runtime;
    free(ctx);

    ejs_runtime_finish_destroy_on_helper(runtime);

    return NULL;
}

static void * ejs_async_destroy_runtime_thread_main(void *arg) {
    ejs_runtime_finish_destroy_on_helper((EJSCoreRuntime *)arg);

    return NULL;
}

static void ejs_runtime_destroy_marked_sync(EJSCoreRuntime *runtime) {
    if (runtime == NULL) {
        return;
    }

    if (runtime->runtime_loop != NULL) {
        if (ejs_runtime_loop_is_thread_started(runtime->runtime_loop)) {
            EJSCoreResult loop_result =
                ejs_runtime_loop_call_sync(runtime->runtime_loop,
                                           ejs_terminal_shutdown_task,
                                           runtime);
            if (loop_result.status != EJS_STATUS_OK) {
                ejs_error_destroy(loop_result.error);
                (void)ejs_runtime_try_local_terminal_shutdown(runtime);
            } else {
                ejs_error_destroy(loop_result.error);
            }
        } else {
            ejs_terminal_shutdown_task(runtime);
        }

        ejs_runtime_loop_destroy(runtime->runtime_loop);
        runtime->runtime_loop = NULL;
    }

    runtime->magic = 0u;
    ejs_runtime_complete_destroy(runtime);
    ejs_runtime_release(runtime);
}

void ejs_runtime_destroy_with_completion(EJSCoreRuntime               *runtime,
                                         EJSCoreRuntimeStopCompletion completion,
                                         void                     *user_data) {
    if (runtime == NULL) {
        if (completion != NULL) {
            completion(user_data);
        }

        return;
    }

    ejs_runtime_retain(runtime);
    bool called_from_owner = runtime->runtime_loop != NULL &&
                             ejs_runtime_loop_is_owner_thread(runtime->runtime_loop);

    /*
     * 先使 runtime/context validation 失败，再启动真正销毁。这样并发进入的
     * public API 会尽早退出，而不是继续向即将关闭的 loop 投递 JS 工作。
     */
    if (!atomic_exchange(&runtime->alive, false)) {
        if (atomic_load(&runtime->destroy_completed)) {
            if (completion != NULL) {
                completion(user_data);
            }
        } else {
            if (!ejs_runtime_add_destroy_waiter(runtime,
                                                completion,
                                                user_data,
                                                !called_from_owner)) {
                if (completion != NULL) {
                    completion(user_data);
                }
                ejs_runtime_release(runtime);
                return;
            }
        }

        ejs_runtime_release(runtime);
        return;
    }

    bool destroy_waiter_registered = ejs_runtime_add_destroy_waiter(runtime,
                                                                     completion,
                                                                     user_data,
                                                                     !called_from_owner);
    /*
     * 首次销毁时，即使 completion waiter 因资源不足注册失败，也必须继续推进
     * 销毁主流程，避免 runtime 仅被标记失活却未真正释放。
     */
    (void)destroy_waiter_registered;

    atomic_store(&runtime->state, EJS_RUNTIME_STATE_DESTROYED);
    atomic_store(&runtime->interrupt_requested, true);

    if (runtime->engine_runtime != NULL) {
        ejs_engine_request_interrupt(runtime->engine_runtime);
    }

    EJSAsyncDestroyContext *ctx = (EJSAsyncDestroyContext *)malloc(sizeof(EJSAsyncDestroyContext));
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 6 ||
        ejs_test_inject_runtime_error == 32) {
        free(ctx);
        ctx = NULL;
    }

#endif

    if (ctx == NULL && called_from_owner) {
        pthread_t helper;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        int create_result = 0;
#ifdef EJS_TEST

        if (ejs_test_inject_runtime_error == 32) {
            create_result = -1;
        } else

#endif
        {
            create_result = pthread_create(&helper, &attr, ejs_async_destroy_runtime_thread_main, runtime);
        }
        pthread_attr_destroy(&attr);
        if (create_result == 0) {
            ejs_runtime_release(runtime);
            return;
        }
        ejs_runtime_destroy_after_owner_exit(runtime);
        ejs_runtime_release(runtime);
        return;
    }

    if (ctx == NULL) {
        // 极端 OOM 情况下，降级为同步强制销毁
        ejs_runtime_destroy_marked_sync(runtime);

        ejs_runtime_release(runtime);
        return;
    }

    ctx->runtime = runtime;

    pthread_t helper;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);

    int create_result = 0;
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 7) {
        create_result = -1;
    } else

#endif
    {
        create_result = pthread_create(&helper, &attr, ejs_async_destroy_thread_main, ctx);
    }

    if (create_result != 0) {
        // 线程创建失败，降级同步
        free(ctx);
        pthread_attr_destroy(&attr);
        if (called_from_owner) {
            ejs_runtime_destroy_after_owner_exit(runtime);
            ejs_runtime_release(runtime);
            return;
        }
        ejs_runtime_destroy_marked_sync(runtime);

        ejs_runtime_release(runtime);
        return;
    }

    pthread_attr_destroy(&attr);
    ejs_runtime_release(runtime);
}

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int done;
} EJSDestroySyncBarrier;

/* 同步 destroy 只是异步销毁的屏障封装，避免维护第二套释放流程。 */
static void ejs_sync_destroy_completion(void *user_data) {
    EJSDestroySyncBarrier *barrier = (EJSDestroySyncBarrier *)user_data;

    pthread_mutex_lock(&barrier->mutex);
    barrier->done = 1;
    pthread_cond_signal(&barrier->cond);
    pthread_mutex_unlock(&barrier->mutex);
}

void ejs_runtime_destroy(EJSCoreRuntime *runtime) {
    if (runtime == NULL) {
        return;
    }

    if (runtime->runtime_loop != NULL &&
        ejs_runtime_loop_is_owner_thread(runtime->runtime_loop)) {
        ejs_runtime_destroy_with_completion(runtime, NULL, NULL);
        return;
    }

    EJSDestroySyncBarrier barrier;
    pthread_mutex_init(&barrier.mutex, NULL);
    pthread_cond_init(&barrier.cond, NULL);
    barrier.done = 0;

    ejs_runtime_destroy_with_completion(runtime, ejs_sync_destroy_completion, &barrier);

    pthread_mutex_lock(&barrier.mutex);

    while (!barrier.done)
        pthread_cond_wait(&barrier.cond, &barrier.mutex);
    pthread_mutex_unlock(&barrier.mutex);

    pthread_cond_destroy(&barrier.cond);
    pthread_mutex_destroy(&barrier.mutex);
}

EJSCoreContext * ejs_context_create(EJSCoreRuntime *runtime) {
    EJSCoreContext *context;

    if (!ejs_runtime_try_retain(runtime)) {
        return NULL;
    }

    if (!ejs_runtime_is_valid(runtime)) {
        ejs_runtime_release(runtime);
        return NULL;
    }

    context = (EJSCoreContext *)calloc(1u, sizeof(EJSCoreContext));
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 4) {
        if (context != NULL) {
            free(context);
            context = NULL;
        }
    }

#endif

    if (context == NULL) {
        ejs_runtime_release(runtime);
        return NULL;
    }

    context->magic = EJS_CONTEXT_MAGIC;
    atomic_init(&context->alive, true);
    ejs_refcount_init(&context->ref_count, 1u);
    context->runtime = runtime;
    pthread_mutex_init(&context->host_mutex, NULL);
    context->host = NULL;
    context->destroy_next = NULL;
    context->destroy_queued = false;

    EJSCreateContextTask task;
    task.runtime = runtime;
    task.context = context;
    task.engine_error = NULL;

    EJSCoreResult loop_result =
        ejs_runtime_loop_call_sync(runtime->runtime_loop, ejs_create_context_task, &task);

    if (loop_result.status != EJS_STATUS_OK) {
        ejs_error_destroy(loop_result.error);
        ejs_context_release(context);
        ejs_runtime_release(runtime);
        return NULL;
    }

    if (context->engine_context == NULL) {
        ejs_error_destroy(task.engine_error);
        ejs_context_release(context);
        ejs_runtime_release(runtime);
        return NULL;
    }

    ejs_runtime_release(runtime);
    return context;
}

void ejs_context_destroy(EJSCoreContext *context) {
    if (context == NULL) {
        return;
    }

    if (!atomic_exchange(&context->alive, false)) {
        return;
    }

    if (context->runtime != NULL &&
        context->runtime->runtime_loop != NULL &&
        ejs_runtime_loop_is_thread_started(context->runtime->runtime_loop)) {
        if (ejs_runtime_loop_is_owner_thread(context->runtime->runtime_loop)) {
            ejs_runtime_enqueue_deferred_context_destroy(context);
            return;
        }

        EJSRuntimeLoop *runtime_loop = context->runtime->runtime_loop;
        EJSDestroyContextTask task;
        task.context = context;
        EJSCoreResult loop_result =
            ejs_runtime_loop_call_sync(runtime_loop, ejs_destroy_context_task, &task);

        if (loop_result.status != EJS_STATUS_OK) {
            ejs_error_destroy(loop_result.error);
            /*
             * call_sync 在 loop 停机竞态中可能失败。仅当 owner 线程已经退出时，
             * 才允许本线程降级执行销毁；否则保持 owner-thread 约束，避免跨线程
             * 触发 engine context 销毁。
             */
            if (!ejs_runtime_loop_is_thread_started(runtime_loop)) {
                EJSDestroyContextTask fallback_task;
                fallback_task.context = context;
                ejs_destroy_context_task(&fallback_task);
            }
            return;
        }

        ejs_error_destroy(loop_result.error);
    } else {
        EJSDestroyContextTask task;
        task.context = context;
        ejs_destroy_context_task(&task);
    }
}

EJSRegisteredHost *ejs_registered_host_retain(EJSRegisteredHost *host) {
    if (host != NULL) {
        ejs_refcount_retain(&host->ref_count);
    }
    return host;
}

void ejs_registered_host_release(EJSRegisteredHost *host) {
    if (host == NULL) {
        return;
    }
    if (ejs_refcount_release(&host->ref_count)) {
        if (host->api.user_data.value != NULL && host->api.user_data.release != NULL) {
            host->api.user_data.release(host->api.user_data.value);
        }
        if (host->api.operations.user_data.value != NULL && host->api.operations.user_data.release != NULL) {
            host->api.operations.user_data.release(host->api.operations.user_data.value);
        }
        if (host->api.invoke_api.user_data.value != NULL && host->api.invoke_api.user_data.release != NULL) {
            host->api.invoke_api.user_data.release(host->api.invoke_api.user_data.value);
        }
        if (host->api.sync_invoke_api.user_data.value != NULL && host->api.sync_invoke_api.user_data.release != NULL) {
            host->api.sync_invoke_api.user_data.release(host->api.sync_invoke_api.user_data.value);
        }
        free(host);
    }
}

EJSRegisteredHost *ejs_context_acquire_host(EJSCoreContext *context) {
    if (context == NULL) {
        return NULL;
    }
    pthread_mutex_lock(&context->host_mutex);
    EJSRegisteredHost *host = context->host;
    if (host != NULL) {
        ejs_registered_host_retain(host);
    }
    pthread_mutex_unlock(&context->host_mutex);
    return host;
}

void ejs_context_register_host(EJSCoreContext *context, const EJSCoreHostAPI *host_api) {
    if (!ejs_context_try_retain(context)) {
        return;
    }

    if (!ejs_context_is_valid(context)) {
        ejs_context_release(context);
        return;
    }

    EJSRegisteredHost *new_host = NULL;
    if (host_api != NULL) {
        EJSCoreNativeValidationResult res = ejs_native_validate_host_api(host_api, EJS_NATIVE_PROVIDER_INVOKE);

        if (res != EJS_NATIVE_VALIDATION_OK) {
            pthread_mutex_lock(&context->host_mutex);
            EJSRegisteredHost *old_host = context->host;
            context->host = NULL;
            pthread_mutex_unlock(&context->host_mutex);

            if (old_host != NULL) {
                ejs_registered_host_release(old_host);
            }
            ejs_context_release(context);
            return;
        }

        new_host = (EJSRegisteredHost *)calloc(1u, sizeof(EJSRegisteredHost));
#ifdef EJS_TEST

        if (ejs_test_inject_runtime_error == 8) {
            free(new_host);
            new_host = NULL;
        }

#endif
        if (new_host == NULL) {
            // Keep the previously registered host on allocation failure.
            ejs_context_release(context);
            return;
        }

        ejs_refcount_init(&new_host->ref_count, 1u);
        size_t host_api_copy_size = host_api->struct_size;
        if (host_api_copy_size > sizeof(new_host->api)) {
            host_api_copy_size = sizeof(new_host->api);
        }
        memcpy(&new_host->api, host_api, host_api_copy_size);

        if (new_host->api.user_data.value != NULL && new_host->api.user_data.retain != NULL) {
            new_host->api.user_data.retain(new_host->api.user_data.value);
        }
        if (new_host->api.operations.user_data.value != NULL && new_host->api.operations.user_data.retain != NULL) {
            new_host->api.operations.user_data.retain(new_host->api.operations.user_data.value);
        }
        if (new_host->api.invoke_api.user_data.value != NULL && new_host->api.invoke_api.user_data.retain != NULL) {
            new_host->api.invoke_api.user_data.retain(new_host->api.invoke_api.user_data.value);
        }
        if (new_host->api.sync_invoke_api.user_data.value != NULL && new_host->api.sync_invoke_api.user_data.retain != NULL) {
            new_host->api.sync_invoke_api.user_data.retain(new_host->api.sync_invoke_api.user_data.value);
        }
    }

    pthread_mutex_lock(&context->host_mutex);
    EJSRegisteredHost *old_host = context->host;
    context->host = new_host;
    pthread_mutex_unlock(&context->host_mutex);

    if (old_host != NULL) {
        ejs_registered_host_release(old_host);
    }

    ejs_context_release(context);
}

EJSCoreResult ejs_eval_script(EJSCoreContext *context,
                          const char *filename,
                          const char *source,
                          size_t     source_len) {
    if (!ejs_context_try_retain(context)) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid EJSCoreContext",
                                                 NULL,
                                                 NULL,
                                                 0));
    }
    if (!ejs_context_is_valid(context)) {
        ejs_context_release(context);
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid EJSCoreContext",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    EJSEvalScriptTask task;
    task.context = context;
    task.filename = filename;
    task.source = source;
    task.source_len = source_len;
    task.result = ejs_result_ok();

    EJSCoreResult loop_result =
        ejs_runtime_loop_call_sync(context->runtime->runtime_loop, ejs_eval_script_task, &task);
    ejs_context_release(context);

    if (loop_result.status != EJS_STATUS_OK) {
        return loop_result;
    }

    return task.result;
}

EJSCoreResult ejs_eval_module(EJSCoreContext           *context,
                          const EJSCoreEvalOptions *options,
                          const char           *source,
                          size_t               source_len) {
    if (!ejs_context_try_retain(context)) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid EJSCoreContext",
                                                 NULL,
                                                 NULL,
                                                 0));
    }
    if (!ejs_context_is_valid(context)) {
        ejs_context_release(context);
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid EJSCoreContext",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (!ejs_abi_check_eval_options(options) || options->kind != EJS_EVAL_KIND_MODULE) {
        ejs_context_release(context);
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid module evaluation options",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    EJSEvalModuleTask task;
    task.context = context;
    task.options = options;
    task.source = source;
    task.source_len = source_len;
    task.result = ejs_result_ok();

    EJSCoreResult loop_result =
        ejs_runtime_loop_call_sync(context->runtime->runtime_loop, ejs_eval_module_task, &task);
    ejs_context_release(context);

    if (loop_result.status != EJS_STATUS_OK) {
        return loop_result;
    }

    return task.result;
}

EJSCoreResult ejs_context_register_module_sources(EJSCoreContext             *context,
                                                  const EJSCoreModuleSource *sources,
                                                  size_t                     source_count) {
    if (source_count > 0 && sources == NULL) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid module source table",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (!ejs_context_try_retain(context)) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid EJSCoreContext",
                                                 NULL,
                                                 NULL,
                                                 0));
    }
    if (!ejs_context_is_valid(context)) {
        ejs_context_release(context);
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid EJSCoreContext",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    EJSRegisterModuleSourcesTask task;
    task.context = context;
    task.sources = sources;
    task.source_count = source_count;
    task.result = ejs_result_ok();

    EJSCoreResult loop_result =
        ejs_runtime_loop_call_sync(context->runtime->runtime_loop, ejs_register_module_sources_task, &task);
    ejs_context_release(context);

    if (loop_result.status != EJS_STATUS_OK) {
        return loop_result;
    }

    return task.result;
}

EJSCoreResult ejs_runtime_drain_for_test(EJSCoreRuntime *runtime) {
    if (!ejs_runtime_is_valid(runtime)) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid EJSCoreRuntime",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (atomic_load(&runtime->state) == EJS_RUNTIME_STATE_RUNNING) {
        /* 正常 libuv runtime 需要同步进入 owner 线程执行 pending jobs。 */
        EJSRunJobsTask task;
        task.runtime = runtime;
        task.result = ejs_result_ok();
        EJSCoreResult loop_call_result =
            ejs_runtime_loop_call_sync(runtime->runtime_loop, ejs_runtime_drain_task, &task);

        if (loop_call_result.status != EJS_STATUS_OK) {
            return loop_call_result;
        }

        return task.result;
    }

    /*
     * 未启动独立 owner 线程的后端（例如 stub/测试配置）先 pump loop，再直接驱动
     * engine jobs，保持测试入口在两类 loop 后端上都可用。
     */
    EJSCoreResult loop_result = ejs_runtime_loop_pump(runtime->runtime_loop, 1u);

    if (loop_result.status != EJS_STATUS_OK) {
        return loop_result;
    }

    return ejs_engine_run_jobs(runtime->engine_runtime);
}

void ejs_request_interrupt(EJSCoreRuntime *runtime) {
    if (!ejs_runtime_try_retain(runtime)) {
        return;
    }

    if (!ejs_runtime_is_valid(runtime)) {
        ejs_runtime_release(runtime);
        return;
    }

    atomic_store(&runtime->interrupt_requested, true);
    ejs_engine_request_interrupt(runtime->engine_runtime);
    ejs_runtime_release(runtime);
}

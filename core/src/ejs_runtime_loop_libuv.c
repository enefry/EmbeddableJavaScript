/**
 * ejs_runtime_loop_libuv.c — 基于 libuv 的 owner-thread runtime loop
 *
 * 该后端为 EJS runtime 提供真实的跨线程调度和定时器能力。每个
 * EJSRuntimeLoop 拥有一个独立 pthread，线程内运行 uv_run，并作为 JS 引擎的
 * owner thread。公共 runtime 层通过 call_sync/post 将工作投递到该线程，确保
 * QuickJS 对象不会在多个线程上被直接访问。
 *
 * 核心机制：
 *   - uv_async_t wakeup：跨线程唤醒 owner thread 并处理任务队列；
 *   - uv_prepare_t / uv_check_t：在事件循环前后驱动 QuickJS pending jobs；
 *   - task_mutex/task_cond：保护同步/异步任务队列，并让 call_sync 等待完成；
 *   - active_timers：记录由 __ejs_native__.timers 创建的 libuv timer，runtime
 *     销毁时可统一关闭残留句柄。
 *
 * 测试注入边界：
 *   ejs_test_inject_runtime_error 只在 EJS_TEST 构建中声明和读取，用于模拟
 *   libuv 初始化、句柄启动和分配失败。生产构建不应编译这些分支。
 */

#include "ejs_runtime_loop.h"

#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef EJS_TEST
extern int ejs_test_inject_runtime_error;
#endif
#include <uv.h>


#include "ejs_engine.h"
#include "ejs_runtime_internal.h"

typedef struct EJSRuntimeLoopTask {
    EJSRuntimeLoopTaskCallback callback;
    void *user_data; /* 调用方上下文；任务队列只传递，不释放 */
    int sync;
    int done;
    struct EJSRuntimeLoopTask *next;
} EJSRuntimeLoopTask;

/**
 * struct EJSRuntimeTimer — libuv timer 的 EJS 包装
 *
 * timer 生命周期由 ejs_runtime_timer_destroy 发起关闭；真正 free 发生在
 * uv_close 的 close callback 中。prev/next 把 timer 挂到 loop->active_timers，
 * 使 runtime 销毁时能关闭宿主未显式清理的 timer。
 *
 * user_data 默认是借用指针，timer 不拥有。只有调用
 * ejs_runtime_timer_set_free_user_data 后，close callback 才会用该释放函数处理
 * user_data；这用于 QuickJS timer state 等需要跟随 timer close 释放的堆对象。
 */
struct EJSRuntimeTimer {
    uv_timer_t timer;
    EJSRuntimeTimerCallback callback;
    void *user_data; /* 定时器回调上下文；默认不释放 */
    void (*free_user_data)(void *user_data); /* 可选的 user_data 释放函数 */
    struct EJSRuntimeLoop *loop;
    struct EJSRuntimeTimer *prev;
    struct EJSRuntimeTimer *next;
};

static void ejs_runtime_timer_close_cb(uv_handle_t *handle);

/**
 * struct EJSRuntimeLoop — libuv 后端的完整 loop 状态
 *
 * running/thread_started/stop_requested 用原子变量跨线程读取；owner_thread 只在
 * has_owner_thread 为真时有效。task 队列可被任意线程入队，但只能由 owner
 * thread 在 ejs_runtime_loop_process_tasks 中出队执行。
 */
struct EJSRuntimeLoop {
    uv_loop_t loop;
    uv_async_t wakeup;
    int wakeup_initialized;
    uv_prepare_t prepare;
    int prepare_initialized;
    uv_check_t check;
    int check_initialized;
    struct EJSCoreRuntime *runtime;
    pthread_t thread;
    atomic_int running;
    atomic_int thread_started;
    atomic_int stop_requested;
    atomic_int finalize_on_exit;
    atomic_int handles_closed_on_stop;
    atomic_int thread_joined;
    pthread_mutex_t task_mutex;
    pthread_cond_t task_cond;
    EJSRuntimeLoopTask *task_head;
    EJSRuntimeLoopTask *task_tail;
    pthread_t owner_thread;
    atomic_int has_owner_thread;
    struct EJSRuntimeTimer *active_timers;
    pthread_mutex_t timer_mutex;
    EJSRuntimeLoopExitCallback exit_before_close;
    EJSRuntimeLoopExitCallback exit_after_close;
    void *exit_user_data;
};

static void ejs_runtime_loop_close_active_timers(EJSRuntimeLoop *runtime_loop);

#ifdef EJS_TEST
static atomic_int ejs_test_owner_stop_join_count = 0;
#endif

static void ejs_runtime_loop_close_handles_owner_exit_cb(void *user_data) {
    ejs_runtime_loop_close_handles((EJSRuntimeLoop *)user_data);
}

static void ejs_runtime_loop_destroy_sync_primitives(EJSRuntimeLoop *runtime_loop) {
    pthread_cond_destroy(&runtime_loop->task_cond);
    pthread_mutex_destroy(&runtime_loop->task_mutex);
    pthread_mutex_destroy(&runtime_loop->timer_mutex);
}

static void ejs_runtime_loop_drain_closed_handles(EJSRuntimeLoop *runtime_loop) {
    while (uv_run(&runtime_loop->loop, UV_RUN_NOWAIT) != 0) {
    }
}

static void ejs_runtime_loop_cleanup_failed_create(EJSRuntimeLoop *runtime_loop) {
    if (runtime_loop == NULL) {
        return;
    }

    if (runtime_loop->check_initialized) {
        uv_check_stop(&runtime_loop->check);
        uv_close((uv_handle_t *)&runtime_loop->check, NULL);
        runtime_loop->check_initialized = 0;
    }

    if (runtime_loop->prepare_initialized) {
        uv_prepare_stop(&runtime_loop->prepare);
        uv_close((uv_handle_t *)&runtime_loop->prepare, NULL);
        runtime_loop->prepare_initialized = 0;
    }

    if (runtime_loop->wakeup_initialized) {
        uv_close((uv_handle_t *)&runtime_loop->wakeup, NULL);
        runtime_loop->wakeup_initialized = 0;
    }

    ejs_runtime_loop_drain_closed_handles(runtime_loop);
    (void)uv_loop_close(&runtime_loop->loop);
    ejs_runtime_loop_destroy_sync_primitives(runtime_loop);
    free(runtime_loop);
}

/**
 * ejs_runtime_loop_process_tasks — 在 owner thread 上清空投递任务队列
 *
 * 每次只在持锁期间摘出一个任务，回调执行时不持锁，避免任务内部再次调用
 * call_sync/post 时死锁。同步任务使用栈上 EJSRuntimeLoopTask，执行后只标记
 * done 并唤醒等待方；异步任务由队列拥有，执行后直接 free。
 */
static void ejs_runtime_loop_process_tasks(EJSRuntimeLoop *runtime_loop) {
    for (;;) {
        pthread_mutex_lock(&runtime_loop->task_mutex);
        EJSRuntimeLoopTask *task = runtime_loop->task_head;

        if (task != NULL) {
            runtime_loop->task_head = task->next;

            if (runtime_loop->task_head == NULL) {
                runtime_loop->task_tail = NULL;
            }

            task->next = NULL;
        }

        pthread_mutex_unlock(&runtime_loop->task_mutex);

        if (task == NULL) {
            ejs_runtime_flush_deferred_context_destroys(runtime_loop->runtime);
            break;
        }

        task->callback(task->user_data);

        if (task->sync) {
            pthread_mutex_lock(&runtime_loop->task_mutex);
            task->done = 1;
            pthread_cond_broadcast(&runtime_loop->task_cond);
            pthread_mutex_unlock(&runtime_loop->task_mutex);
        } else {
            free(task);
        }
    }
}

/* uv_async_t 回调：跨线程唤醒点，同时承载 stop 请求。 */
static void ejs_runtime_loop_on_wakeup(uv_async_t *handle) {
    EJSRuntimeLoop *runtime_loop = (EJSRuntimeLoop *)handle->data;

    if (runtime_loop == NULL) {
        return;
    }

    ejs_runtime_loop_process_tasks(runtime_loop);

    if (atomic_load(&runtime_loop->stop_requested) != 0) {
        uv_stop(&runtime_loop->loop);
    }
}

static void ejs_runtime_loop_report_job_error(EJSCoreResult result) {
    if (result.status != EJS_STATUS_ERROR) {
        return;
    }

    fprintf(stderr,
            "EJS internal diagnostic: unhandled pending job error: %s\n",
            ejs_error_message(result.error) != NULL ? ejs_error_message(result.error) : "unknown error");
    ejs_error_destroy(result.error);
}

static void ejs_runtime_loop_run_jobs_for_watcher(EJSCoreRuntime *runtime) {
    if (runtime == NULL || runtime->engine_runtime == NULL) {
        return;
    }

    ejs_runtime_enter_owner_callback(runtime);
    EJSCoreResult result = ejs_engine_run_jobs(runtime->engine_runtime);
    ejs_runtime_leave_owner_callback(runtime);
    ejs_runtime_loop_report_job_error(result);
}

/* prepare/check 两侧都 drain QuickJS jobs，降低 Promise 回调在 I/O 间隙滞留的概率。 */
static void ejs_runtime_loop_on_prepare(uv_prepare_t *handle) {
    EJSCoreRuntime *runtime = (EJSCoreRuntime *)handle->data;

    if (runtime != NULL) {
        ejs_runtime_flush_deferred_context_destroys(runtime);
    }

    if (runtime != NULL && runtime->engine_runtime != NULL) {
        ejs_runtime_loop_run_jobs_for_watcher(runtime);
        ejs_runtime_flush_deferred_context_destroys(runtime);
    }
}

static void ejs_runtime_loop_on_check(uv_check_t *handle) {
    EJSCoreRuntime *runtime = (EJSCoreRuntime *)handle->data;

    if (runtime != NULL) {
        ejs_runtime_flush_deferred_context_destroys(runtime);
    }

    if (runtime != NULL && runtime->engine_runtime != NULL) {
        ejs_runtime_loop_run_jobs_for_watcher(runtime);
        ejs_runtime_flush_deferred_context_destroys(runtime);
    }
}

EJSRuntimeLoop * ejs_runtime_loop_create(struct EJSCoreRuntime *runtime, EJSCoreError **out_error) {
    EJSRuntimeLoop *runtime_loop = (EJSRuntimeLoop *)calloc(1u, sizeof(EJSRuntimeLoop));

#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 21) {
        if (runtime_loop != NULL) {
            free(runtime_loop);
            runtime_loop = NULL;
        }
    }

#endif

    if (runtime_loop == NULL) {
        return NULL;
    }

    runtime_loop->runtime = runtime;
    atomic_init(&runtime_loop->running, 0);
    atomic_init(&runtime_loop->thread_started, 0);
    atomic_init(&runtime_loop->stop_requested, 0);
    atomic_init(&runtime_loop->finalize_on_exit, 0);
    atomic_init(&runtime_loop->handles_closed_on_stop, 0);
    atomic_init(&runtime_loop->thread_joined, 0);
    atomic_init(&runtime_loop->has_owner_thread, 0);
    pthread_mutex_init(&runtime_loop->task_mutex, NULL);
    pthread_cond_init(&runtime_loop->task_cond, NULL);
    pthread_mutex_init(&runtime_loop->timer_mutex, NULL);
    runtime_loop->active_timers = NULL;

    int loop_init_res = uv_loop_init(&runtime_loop->loop);
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 22) {
        loop_init_res = -1;
    }

#endif

    if (loop_init_res != 0) {
        ejs_runtime_loop_destroy_sync_primitives(runtime_loop);
        free(runtime_loop);

        if (out_error != NULL) {
            *out_error = ejs_error_create(EJS_ERROR_INTERNAL,
                                          "failed to initialize libuv loop",
                                          NULL,
                                          "libuv",
                                          0);
        }

        return NULL;
    }

    int async_init_res = uv_async_init(&runtime_loop->loop, &runtime_loop->wakeup, ejs_runtime_loop_on_wakeup);
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 23) {
        async_init_res = -1;
    }

#endif

    if (async_init_res != 0) {
        (void)uv_loop_close(&runtime_loop->loop);
        ejs_runtime_loop_destroy_sync_primitives(runtime_loop);
        free(runtime_loop);

        if (out_error != NULL) {
            *out_error = ejs_error_create(EJS_ERROR_INTERNAL,
                                          "failed to initialize libuv async handle",
                                          NULL,
                                          "libuv",
                                          0);
        }

        return NULL;
    }

    runtime_loop->wakeup_initialized = 1;
    runtime_loop->wakeup.data = runtime_loop;

    int prep_init_res = uv_prepare_init(&runtime_loop->loop, &runtime_loop->prepare);
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 24) {
        prep_init_res = -1;
    }

#endif

    if (prep_init_res != 0) {
        ejs_runtime_loop_cleanup_failed_create(runtime_loop);

        if (out_error != NULL) {
            *out_error = ejs_error_create(EJS_ERROR_INTERNAL,
                                          "failed to initialize libuv prepare handle",
                                          NULL,
                                          "libuv",
                                          0);
        }

        return NULL;
    }

    runtime_loop->prepare.data = runtime;
    runtime_loop->prepare_initialized = 1;
    int prep_start_res = uv_prepare_start(&runtime_loop->prepare, ejs_runtime_loop_on_prepare);
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 25) {
        prep_start_res = -1;
    }

#endif

    if (prep_start_res != 0) {
        ejs_runtime_loop_cleanup_failed_create(runtime_loop);

        if (out_error != NULL) {
            *out_error = ejs_error_create(EJS_ERROR_INTERNAL,
                                          "failed to start libuv prepare handle",
                                          NULL,
                                          "libuv",
                                          0);
        }

        return NULL;
    }

    int chk_init_res = uv_check_init(&runtime_loop->loop, &runtime_loop->check);
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 26) {
        chk_init_res = -1;
    }

#endif

    if (chk_init_res != 0) {
        ejs_runtime_loop_cleanup_failed_create(runtime_loop);

        if (out_error != NULL) {
            *out_error = ejs_error_create(EJS_ERROR_INTERNAL,
                                          "failed to initialize libuv check handle",
                                          NULL,
                                          "libuv",
                                          0);
        }

        return NULL;
    }

    runtime_loop->check.data = runtime;
    runtime_loop->check_initialized = 1;
    int chk_start_res = uv_check_start(&runtime_loop->check, ejs_runtime_loop_on_check);
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 27) {
        chk_start_res = -1;
    }

#endif

    if (chk_start_res != 0) {
        ejs_runtime_loop_cleanup_failed_create(runtime_loop);

        if (out_error != NULL) {
            *out_error = ejs_error_create(EJS_ERROR_INTERNAL,
                                          "failed to start libuv check handle",
                                          NULL,
                                          "libuv",
                                          0);
        }

        return NULL;
    }

    if (out_error != NULL) {
        *out_error = NULL;
    }

    return runtime_loop;
}

static void * ejs_runtime_loop_thread_main(void *user_data) {
    EJSRuntimeLoop *runtime_loop = (EJSRuntimeLoop *)user_data;

    /*
     * owner_thread 的记录必须在线程入口完成；call_sync 用它判断重入调用是否可以
     * 直接执行，避免 owner thread 等待自己造成死锁。
     */
    runtime_loop->owner_thread = pthread_self();
    atomic_store(&runtime_loop->has_owner_thread, 1);
    atomic_store(&runtime_loop->running, 1);
    uv_run(&runtime_loop->loop, UV_RUN_DEFAULT);
    ejs_runtime_loop_process_tasks(runtime_loop);

    if (atomic_load(&runtime_loop->finalize_on_exit) != 0) {
        EJSRuntimeLoopExitCallback before_close = runtime_loop->exit_before_close;
        EJSRuntimeLoopExitCallback after_close = runtime_loop->exit_after_close;
        void *exit_user_data = runtime_loop->exit_user_data;

        if (before_close != NULL) {
            before_close(exit_user_data);
        }

        atomic_store(&runtime_loop->running, 0);
        atomic_store(&runtime_loop->thread_started, 0);
        atomic_store(&runtime_loop->has_owner_thread, 0);
        ejs_runtime_loop_drain_closed_handles(runtime_loop);
        int close_res = uv_loop_close(&runtime_loop->loop);
        assert(close_res == 0);
        ejs_runtime_loop_destroy_sync_primitives(runtime_loop);
        free(runtime_loop);
        if (after_close != NULL) {
            after_close(exit_user_data);
        }
        return NULL;
    }

    if (atomic_load(&runtime_loop->stop_requested) != 0) {
        ejs_runtime_loop_close_handles(runtime_loop);
        ejs_runtime_loop_drain_closed_handles(runtime_loop);
        int close_res = uv_loop_close(&runtime_loop->loop);
        assert(close_res == 0);
        atomic_store(&runtime_loop->handles_closed_on_stop, 1);
        atomic_store(&runtime_loop->thread_started, 0);
    }

    atomic_store(&runtime_loop->running, 0);
    atomic_store(&runtime_loop->has_owner_thread, 0);
    return NULL;
}

EJSCoreResult ejs_runtime_loop_start(EJSRuntimeLoop *runtime_loop) {
    if (runtime_loop == NULL) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid runtime loop",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (atomic_load(&runtime_loop->handles_closed_on_stop) != 0) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                                 "runtime loop is terminated",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (atomic_load(&runtime_loop->thread_started) != 0) {
        return ejs_result_ok();
    }

    atomic_store(&runtime_loop->stop_requested, 0);
    atomic_store(&runtime_loop->thread_joined, 0);
    int create_result = 0;
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 29) {
        create_result = -1;
    } else

#endif
    {
        create_result = pthread_create(&runtime_loop->thread,
                                       NULL,
                                       ejs_runtime_loop_thread_main,
                                       runtime_loop);
    }

    if (create_result != 0) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                                 "failed to start runtime loop thread",
                                                 NULL,
                                                 "pthread",
                                                 create_result));
    }

    atomic_store(&runtime_loop->thread_started, 1);
    return ejs_result_ok();
}

EJSCoreResult ejs_runtime_loop_stop(EJSRuntimeLoop *runtime_loop) {
    if (runtime_loop == NULL) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid runtime loop",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (atomic_load(&runtime_loop->thread_started) == 0) {
        atomic_store(&runtime_loop->running, 0);
        return ejs_result_ok();
    }

    atomic_store(&runtime_loop->stop_requested, 1);

    if (ejs_runtime_loop_is_owner_thread(runtime_loop)) {
        uv_stop(&runtime_loop->loop);
        atomic_store(&runtime_loop->running, 0);
        return ejs_result_ok();
    }

    if (runtime_loop->wakeup_initialized) {
        uv_async_send(&runtime_loop->wakeup);
    }

    int finalize_on_exit = atomic_load(&runtime_loop->finalize_on_exit);
    int join_result = pthread_join(runtime_loop->thread, NULL);

    if (join_result != 0) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                                 "failed to stop runtime loop thread",
                                                 NULL,
                                                 "pthread",
                                                 join_result));
    }

    if (finalize_on_exit != 0) {
        return ejs_result_ok();
    }

    atomic_store(&runtime_loop->thread_joined, 1);
    atomic_store(&runtime_loop->thread_started, 0);
    atomic_store(&runtime_loop->running, 0);
    return ejs_result_ok();
}

void ejs_runtime_loop_close_handles(EJSRuntimeLoop *runtime_loop) {
    if (runtime_loop == NULL) {
        return;
    }

    ejs_runtime_loop_close_active_timers(runtime_loop);

    if (runtime_loop->prepare_initialized) {
        uv_prepare_stop(&runtime_loop->prepare);
        uv_close((uv_handle_t *)&runtime_loop->prepare, NULL);
        runtime_loop->prepare_initialized = 0;
    }

    if (runtime_loop->check_initialized) {
        uv_check_stop(&runtime_loop->check);
        uv_close((uv_handle_t *)&runtime_loop->check, NULL);
        runtime_loop->check_initialized = 0;
    }

    if (runtime_loop->wakeup_initialized) {
        uv_close((uv_handle_t *)&runtime_loop->wakeup, NULL);
        runtime_loop->wakeup_initialized = 0;
    }
}

bool ejs_runtime_loop_is_thread_started(EJSRuntimeLoop *runtime_loop) {
    return runtime_loop != NULL && atomic_load(&runtime_loop->thread_started) != 0;
}

void ejs_runtime_loop_destroy(EJSRuntimeLoop *runtime_loop) {
    if (runtime_loop == NULL) {
        return;
    }

    if (atomic_load(&runtime_loop->thread_started) == 0) {
        if (atomic_load(&runtime_loop->handles_closed_on_stop) != 0) {
            if (atomic_load(&runtime_loop->thread_joined) == 0) {
                int join_result = pthread_join(runtime_loop->thread, NULL);

                if (join_result == 0) {
                    atomic_store(&runtime_loop->thread_joined, 1);
#ifdef EJS_TEST
                    atomic_fetch_add(&ejs_test_owner_stop_join_count, 1);
#endif
                }
            }
            ejs_runtime_loop_destroy_sync_primitives(runtime_loop);
            free(runtime_loop);
            return;
        }

        ejs_runtime_loop_cleanup_failed_create(runtime_loop);
        return;
    }

    if (ejs_runtime_loop_is_owner_thread(runtime_loop)) {
        ejs_runtime_loop_destroy_after_owner_exit(runtime_loop,
                                                  ejs_runtime_loop_close_handles_owner_exit_cb,
                                                  NULL,
                                                  runtime_loop);
        return;
    }

    runtime_loop->exit_before_close = ejs_runtime_loop_close_handles_owner_exit_cb;
    runtime_loop->exit_after_close = NULL;
    runtime_loop->exit_user_data = runtime_loop;
    atomic_store(&runtime_loop->finalize_on_exit, 1);
    (void)ejs_runtime_loop_stop(runtime_loop);
}

static void ejs_runtime_loop_close_active_timers(EJSRuntimeLoop *runtime_loop) {
    if (runtime_loop == NULL) {
        return;
    }

    pthread_mutex_lock(&runtime_loop->timer_mutex);
    struct EJSRuntimeTimer *curr = runtime_loop->active_timers;

    while (curr != NULL) {
        struct EJSRuntimeTimer *next = curr->next;
        curr->callback = NULL;
        curr->prev = NULL;
        curr->next = NULL;
        curr->loop = NULL;
        uv_timer_stop(&curr->timer);
        uv_close((uv_handle_t *)&curr->timer, ejs_runtime_timer_close_cb);
        curr = next;
    }
    runtime_loop->active_timers = NULL;
    pthread_mutex_unlock(&runtime_loop->timer_mutex);
}

EJSCoreResult ejs_runtime_loop_pump(EJSRuntimeLoop *runtime_loop, uint32_t max_iterations) {
    uint32_t iteration;

    if (runtime_loop == NULL) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid runtime loop",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (max_iterations == 0u) {
        max_iterations = 1u;
    }

    for (iteration = 0u; iteration < max_iterations; ++iteration) {
        if (uv_run(&runtime_loop->loop, UV_RUN_NOWAIT) == 0) {
            break;
        }
    }

    return ejs_result_ok();
}

bool ejs_runtime_loop_is_owner_thread(EJSRuntimeLoop *runtime_loop) {
    return runtime_loop != NULL &&
           atomic_load(&runtime_loop->has_owner_thread) != 0 &&
           pthread_equal(pthread_self(), runtime_loop->owner_thread);
}

void ejs_runtime_loop_destroy_after_owner_exit(EJSRuntimeLoop *runtime_loop,
                                               EJSRuntimeLoopExitCallback before_close,
                                               EJSRuntimeLoopExitCallback after_close,
                                               void *user_data) {
    if (runtime_loop == NULL) {
        return;
    }

    runtime_loop->exit_before_close = before_close;
    runtime_loop->exit_after_close = after_close;
    runtime_loop->exit_user_data = user_data;
    atomic_store(&runtime_loop->finalize_on_exit, 1);
    atomic_store(&runtime_loop->stop_requested, 1);
    (void)pthread_detach(pthread_self());
    uv_stop(&runtime_loop->loop);
}

#ifdef EJS_TEST
void ejs_runtime_loop_reset_owner_stop_join_count_for_test(void) {
    atomic_store(&ejs_test_owner_stop_join_count, 0);
}

int ejs_runtime_loop_owner_stop_join_count_for_test(void) {
    return atomic_load(&ejs_test_owner_stop_join_count);
}
#endif

/**
 * ejs_runtime_loop_enqueue — 将任务接到 loop 队列尾部并唤醒 owner thread
 *
 * 调用方只负责入队，实际 JS 工作统一由 owner thread 执行。未启动或正在停止的
 * loop 会拒绝入队，避免在调用线程上执行 JS 引擎任务。
 */
static EJSCoreResult ejs_runtime_loop_enqueue(EJSRuntimeLoop     *runtime_loop,
                                          EJSRuntimeLoopTask *task) {
    if (runtime_loop == NULL || task == NULL || task->callback == NULL) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid runtime loop task",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (atomic_load(&runtime_loop->stop_requested) != 0) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                                 "runtime loop is stopping",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (atomic_load(&runtime_loop->thread_started) == 0) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                                 "runtime loop is not started",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    pthread_mutex_lock(&runtime_loop->task_mutex);

    if (atomic_load(&runtime_loop->stop_requested) != 0) {
        pthread_mutex_unlock(&runtime_loop->task_mutex);
        return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                                 "runtime loop is stopping",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (atomic_load(&runtime_loop->thread_started) == 0) {
        pthread_mutex_unlock(&runtime_loop->task_mutex);
        return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                                 "runtime loop is not started",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (runtime_loop->task_tail != NULL) {
        runtime_loop->task_tail->next = task;
    } else {
        runtime_loop->task_head = task;
    }

    runtime_loop->task_tail = task;
    pthread_mutex_unlock(&runtime_loop->task_mutex);

    uv_async_send(&runtime_loop->wakeup);
    return ejs_result_ok();
}

EJSCoreResult ejs_runtime_loop_call_sync(EJSRuntimeLoop             *runtime_loop,
                                     EJSRuntimeLoopTaskCallback callback,
                                     void                       *user_data) {
    if (runtime_loop == NULL || callback == NULL) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid runtime loop task",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (ejs_runtime_loop_is_owner_thread(runtime_loop)) {
        /* owner thread 重入时直接执行，避免把同步任务排队给自己再等待。 */
        callback(user_data);
        return ejs_result_ok();
    }

    if (atomic_load(&runtime_loop->thread_started) == 0) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                                 "runtime loop is not started",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    EJSRuntimeLoopTask task;
    task.callback = callback;
    task.user_data = user_data;
    task.sync = 1;
    task.done = 0;
    task.next = NULL;

    EJSCoreResult enqueue_result = ejs_runtime_loop_enqueue(runtime_loop, &task);

    if (enqueue_result.status != EJS_STATUS_OK) {
        return enqueue_result;
    }

    pthread_mutex_lock(&runtime_loop->task_mutex);

    while (!task.done)
        pthread_cond_wait(&runtime_loop->task_cond, &runtime_loop->task_mutex);
    pthread_mutex_unlock(&runtime_loop->task_mutex);
    return ejs_result_ok();
}

EJSCoreResult ejs_runtime_loop_post(EJSRuntimeLoop             *runtime_loop,
                                EJSRuntimeLoopTaskCallback callback,
                                void                       *user_data) {
    if (runtime_loop == NULL || callback == NULL) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                                 "invalid runtime loop task",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (atomic_load(&runtime_loop->thread_started) == 0) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                                 "runtime loop is not started",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    if (atomic_load(&runtime_loop->stop_requested) != 0) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                                 "runtime loop is stopping",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    EJSRuntimeLoopTask *task = (EJSRuntimeLoopTask *)calloc(1u, sizeof(EJSRuntimeLoopTask));
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 33) {
        free(task);
        task = NULL;
    }

#endif

    if (task == NULL) {
        return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                                 "failed to allocate runtime loop task",
                                                 NULL,
                                                 NULL,
                                                 0));
    }

    task->callback = callback;
    task->user_data = user_data;
    task->sync = 0;
    task->done = 0;
    task->next = NULL;
    EJSCoreResult enqueue_result = ejs_runtime_loop_enqueue(runtime_loop, task);
    if (enqueue_result.status != EJS_STATUS_OK) {
        free(task);
    }
    return enqueue_result;
}

uv_loop_t * ejs_runtime_loop_uv(EJSRuntimeLoop *runtime_loop) {
    if (runtime_loop == NULL) {
        return NULL;
    }

    return &runtime_loop->loop;
}

/* 测试辅助：只暴露唤醒行为，不暴露 uv_async_t 句柄本身。 */
void ejs_runtime_loop_trigger_wakeup_test(EJSRuntimeLoop *runtime_loop) {
    if (runtime_loop != NULL && runtime_loop->wakeup_initialized) {
        uv_async_send(&runtime_loop->wakeup);
    }
}

#ifdef EJS_TEST
void ejs_runtime_loop_set_stop_requested_for_test(EJSRuntimeLoop *runtime_loop, int stop_requested) {
    if (runtime_loop != NULL) {
        atomic_store(&runtime_loop->stop_requested, stop_requested);
    }
}
#endif

static void ejs_runtime_timer_cb(uv_timer_t *handle) {
    EJSRuntimeTimer *timer = (EJSRuntimeTimer *)handle->data;

    if (timer != NULL && timer->callback != NULL) {
        timer->callback(timer->user_data);
    }
}

/**
 * ejs_runtime_timer_create — 创建并启动 owner-thread libuv timer
 *
 * 该函数应在 owner thread 上调用。timer 先加入 active_timers，再启动 uv_timer；
 * 如果启动失败，会走统一 destroy 路径从链表摘除并异步 close handle。
 * user_data 只保存为回调参数；创建成功后仍由调用方负责其生命周期，除非随后设置
 * free_user_data。
 */
EJSRuntimeTimer * ejs_runtime_timer_create(EJSRuntimeLoop          *loop,
                                           uint64_t                delay_ms,
                                           uint64_t                repeat_ms,
                                           EJSRuntimeTimerCallback callback,
                                           void                    *user_data) {
    if (loop == NULL || callback == NULL) {
        return NULL;
    }

    EJSRuntimeTimer *timer = (EJSRuntimeTimer *)calloc(1, sizeof(EJSRuntimeTimer));
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 28) {
        free(timer);
        timer = NULL;
    }

#endif

    if (timer == NULL) {
        return NULL;
    }

    timer->callback = callback;
    timer->user_data = user_data;
    timer->free_user_data = NULL;

    int r = 0;
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 30) {
        r = -1;
    } else

#endif
    {
        r = uv_timer_init(&loop->loop, &timer->timer);
    }

    if (r != 0) {
        free(timer);
        return NULL;
    }

    timer->timer.data = timer;

    pthread_mutex_lock(&loop->timer_mutex);
    timer->loop = loop;
    timer->next = loop->active_timers;
    timer->prev = NULL;

    if (loop->active_timers != NULL) {
        loop->active_timers->prev = timer;
    }

    loop->active_timers = timer;
    pthread_mutex_unlock(&loop->timer_mutex);

    r = 0;
#ifdef EJS_TEST

    if (ejs_test_inject_runtime_error == 31) {
        r = -1;
    } else

#endif
    {
        r = uv_timer_start(&timer->timer, ejs_runtime_timer_cb, delay_ms, repeat_ms);
    }

    if (r != 0) {
        ejs_runtime_timer_destroy(timer);
        return NULL;
    }

    return timer;
}

static void ejs_runtime_timer_close_cb(uv_handle_t *handle) {
    EJSRuntimeTimer *timer = (EJSRuntimeTimer *)handle->data;

    if (timer != NULL) {
        /* 只有显式配置释放函数时才处理 user_data；否则保持外部所有权。 */
        if (timer->free_user_data != NULL) {
            timer->free_user_data(timer->user_data);
        }

        free(timer);
    }
}

/**
 * ejs_runtime_timer_destroy — 停止 timer 并从 active_timers 摘除
 *
 * 摘链操作受 timer_mutex 保护，因为 runtime 销毁线程也会遍历 active_timers。
 * 关闭后 timer->callback 置空，防止 close 过程中残余事件再次回调 JS 层状态。
 * timer 本体和可选的 user_data 释放都延迟到 uv_close callback 中完成。
 */
void ejs_runtime_timer_destroy(EJSRuntimeTimer *timer) {
    if (timer == NULL) {
        return;
    }

    EJSRuntimeLoop *loop = timer->loop;

    if (loop != NULL) {
        pthread_mutex_lock(&loop->timer_mutex);

        if (timer->prev != NULL) {
            timer->prev->next = timer->next;
        } else if (loop->active_timers == timer) {
            loop->active_timers = timer->next;
        }

        if (timer->next != NULL) {
            timer->next->prev = timer->prev;
        }

        timer->prev = NULL;
        timer->next = NULL;
        timer->loop = NULL;
        pthread_mutex_unlock(&loop->timer_mutex);
    }

    timer->callback = NULL;
    uv_timer_stop(&timer->timer);
    uv_close((uv_handle_t *)&timer->timer, ejs_runtime_timer_close_cb);
}

void ejs_runtime_timer_set_free_user_data(EJSRuntimeTimer *timer, void (*free_user_data)(void *user_data)) {
    if (timer != NULL) {
        timer->free_user_data = free_user_data;
    }
}

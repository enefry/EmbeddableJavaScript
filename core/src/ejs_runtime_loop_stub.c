/**
 * ejs_runtime_loop_stub.c — runtime loop 的同步空后端
 *
 * Stub 后端用于无 libuv/无真实事件循环的编译和窄单元测试。它保留
 * ejs_runtime_loop.h 的接口形状，但所有任务都在调用线程同步执行，不创建
 * owner thread，也不支持真实 timer。
 *
 * 这个文件的价值是让 runtime/engine 抽象在最小依赖环境下可链接；任何依赖
 * 跨线程投递、uv handle 或 JS timer 触发的行为都应使用 libuv 后端验证。
 */

#include "ejs_runtime_loop.h"

#include <stdbool.h>
#include <stdlib.h>

struct EJSRuntimeLoop {
  /* 仅记录 post 是否允许执行；stub 后端没有独立线程或队列。 */
  bool running;
};

EJSRuntimeLoop *ejs_runtime_loop_create(struct EJSCoreRuntime *runtime, EJSCoreError **out_error) {
  (void)runtime;
  EJSRuntimeLoop *loop = (EJSRuntimeLoop *)calloc(1u, sizeof(EJSRuntimeLoop));
  if (out_error != NULL) {
    *out_error = NULL;
  }
  return loop;
}

void ejs_runtime_loop_destroy(EJSRuntimeLoop *loop) {
  free(loop);
}

void ejs_runtime_loop_close_handles(EJSRuntimeLoop *loop) {
  /* Stub 后端没有 uv handle；保留函数以复用 runtime 销毁流程。 */
  (void)loop;
}

bool ejs_runtime_loop_is_thread_started(EJSRuntimeLoop *loop) {
  (void)loop;
  return false;
}

bool ejs_runtime_loop_is_owner_thread(EJSRuntimeLoop *loop) {
  (void)loop;
  return false;
}

void ejs_runtime_loop_destroy_after_owner_exit(EJSRuntimeLoop *loop,
                                               EJSRuntimeLoopExitCallback before_close,
                                               EJSRuntimeLoopExitCallback after_close,
                                               void *user_data) {
  if (before_close != NULL) {
    before_close(user_data);
  }
  free(loop);
  if (after_close != NULL) {
    after_close(user_data);
  }
}

EJSCoreResult ejs_runtime_loop_start(EJSRuntimeLoop *loop) {
  if (loop == NULL) {
    return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                             "invalid runtime loop",
                                             NULL,
                                             NULL,
                                             0));
  }
  loop->running = true;
  return ejs_result_ok();
}

EJSCoreResult ejs_runtime_loop_stop(EJSRuntimeLoop *loop) {
  if (loop == NULL) {
    return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                             "invalid runtime loop",
                                             NULL,
                                             NULL,
                                             0));
  }
  loop->running = false;
  return ejs_result_ok();
}

EJSCoreResult ejs_runtime_loop_pump(EJSRuntimeLoop *loop, uint32_t max_iterations) {
  (void)max_iterations;
  if (loop == NULL) {
    return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                             "invalid runtime loop",
                                             NULL,
                                             NULL,
                                             0));
  }
  return ejs_result_ok();
}

EJSCoreResult ejs_runtime_loop_call_sync(EJSRuntimeLoop *loop,
                                     EJSRuntimeLoopTaskCallback callback,
                                     void *user_data) {
  if (loop == NULL || callback == NULL) {
    return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                             "invalid runtime loop task",
                                             NULL,
                                             NULL,
                                             0));
  }
  /* 没有 owner thread 时，同步调用就是直接调用。 */
  callback(user_data);
  return ejs_result_ok();
}

EJSCoreResult ejs_runtime_loop_post(EJSRuntimeLoop *loop,
                                EJSRuntimeLoopTaskCallback callback,
                                void *user_data) {
  if (loop == NULL || callback == NULL) {
    return ejs_result_error(ejs_error_create(EJS_ERROR_INVALID_ARGUMENT,
                                             "invalid runtime loop task",
                                             NULL,
                                             NULL,
                                             0));
  }
  if (!loop->running) {
    return ejs_result_error(ejs_error_create(EJS_ERROR_INTERNAL,
                                             "runtime loop is not started",
                                             NULL,
                                             NULL,
                                             0));
  }
  /*
   * post 在 stub 后端退化为立即执行。调用方仍需先 start loop，这样测试能覆盖
   * "loop 未启动" 的错误路径。
   */
  callback(user_data);
  return ejs_result_ok();
}

struct EJSRuntimeTimer {
  /* Stub timer 永远不会被创建；占位类型只满足不透明指针 ABI。 */
  void *dummy;
};

EJSRuntimeTimer *ejs_runtime_timer_create(EJSRuntimeLoop *loop,
                                          uint64_t delay_ms,
                                          uint64_t repeat_ms,
                                          EJSRuntimeTimerCallback callback,
                                          void *user_data) {
  (void)loop;
  (void)delay_ms;
  (void)repeat_ms;
  (void)callback;
  (void)user_data;
  /* 无事件源可驱动 timer，调用方应把 NULL 视为不支持/创建失败。 */
  return NULL;
}

void ejs_runtime_timer_destroy(EJSRuntimeTimer *timer) {
  (void)timer;
}

void ejs_runtime_timer_set_free_user_data(EJSRuntimeTimer *timer, void (*free_user_data)(void *user_data)) {
  (void)timer;
  (void)free_user_data;
}

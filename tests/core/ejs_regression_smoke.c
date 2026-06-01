#include <assert.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "ejs_native_api.h"
#include "ejs_runtime.h"
#include "ejs_runtime_internal.h"
#include "ejs_runtime_loop.h"

typedef struct {
  EJSCoreHostAPI api;
  EJSCoreContext *context;
  atomic_int invoke_count;
  atomic_int release_count;
} ReentrantDestroyHost;

static void reentrant_destroy_host_retain(void *user_data) {
  (void)user_data;
}

static void reentrant_destroy_host_release(void *user_data) {
  ReentrantDestroyHost *host = (ReentrantDestroyHost *)user_data;
  atomic_fetch_add(&host->release_count, 1);
}

static EJSCoreHostOperation *reentrant_destroy_host_invoke(EJSCoreUserData user_data,
                                                       const char *module_id,
                                                       const char *method_id,
                                                       EJSCoreByteView payload,
                                                       EJSCoreByteView transfer_buffer,
                                                       EJSCoreInvokeCompletion completion,
                                                       void *completion_data) {
  (void)module_id;
  (void)method_id;
  (void)payload;
  (void)transfer_buffer;
  (void)completion;
  (void)completion_data;

  ReentrantDestroyHost *host = (ReentrantDestroyHost *)user_data.value;
  atomic_fetch_add(&host->invoke_count, 1);

  if (host->context != NULL) {
    ejs_context_destroy(host->context);
    host->context = NULL;
  }

  return NULL;
}

static void init_reentrant_destroy_host_api(EJSCoreHostAPI *api, ReentrantDestroyHost *host) {
  *api = ejs_host_api_default_value();
  api->user_data = ejs_user_data_ref_make(host,
                                          reentrant_destroy_host_retain,
                                          reentrant_destroy_host_release);
  api->operations = ejs_native_operation_api();
  api->operations.user_data = ejs_user_data_ref_make(host,
                                                     reentrant_destroy_host_retain,
                                                     reentrant_destroy_host_release);
  api->invoke_api.user_data = ejs_user_data_ref_make(host,
                                                     reentrant_destroy_host_retain,
                                                     reentrant_destroy_host_release);
  api->invoke_api.invoke = reentrant_destroy_host_invoke;
}

static void run_reentrant_context_destroy_regression(void) {
  ReentrantDestroyHost host;
  memset(&host, 0, sizeof(host));
  atomic_init(&host.invoke_count, 0);
  atomic_init(&host.release_count, 0);

  EJSCoreHostAPI api;
  init_reentrant_destroy_host_api(&api, &host);

  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  assert(runtime != NULL);
  assert(context != NULL);

  host.context = context;
  ejs_context_register_host(context, &api);

  const char *js_code =
      "__ejs_native__.timers.create(1, 0, function() {\n"
      "  __ejs_native__.invoke('destroy', 'context', 'payload');\n"
      "});\n";
  EJSCoreResult eval_res =
      ejs_eval_script(context, "reentrant-destroy.js", js_code, strlen(js_code));
  assert(eval_res.status == EJS_STATUS_OK);

  int wait_limit = 200;
  while (atomic_load(&host.invoke_count) == 0 && wait_limit-- > 0) {
    usleep(1000);
    (void)ejs_runtime_drain_for_test(runtime);
  }
  assert(atomic_load(&host.invoke_count) == 1);

  wait_limit = 200;
  while (atomic_load(&host.release_count) < 3 && wait_limit-- > 0) {
    usleep(1000);
    (void)ejs_runtime_drain_for_test(runtime);
  }
  assert(atomic_load(&host.release_count) == 3);

  ejs_runtime_destroy(runtime);
}

typedef struct {
  atomic_int entered;
  atomic_int release;
} BlockingInvokeHost;

typedef struct {
  EJSCoreContext *context;
  atomic_int started;
  atomic_int finished;
  atomic_int status;
} QueuedEvalThreadState;

static EJSCoreHostOperation *blocking_invoke_host_invoke(EJSCoreUserData user_data,
                                                        const char *module_id,
                                                        const char *method_id,
                                                        EJSCoreByteView payload,
                                                        EJSCoreByteView transfer_buffer,
                                                        EJSCoreInvokeCompletion completion,
                                                        void *completion_data) {
  (void)module_id;
  (void)method_id;
  (void)payload;
  (void)transfer_buffer;
  (void)completion;
  (void)completion_data;

  BlockingInvokeHost *host = (BlockingInvokeHost *)user_data.value;
  atomic_store(&host->entered, 1);
  while (atomic_load(&host->release) == 0) {
    usleep(1000);
  }

  return ejs_native_operation_create(NULL, NULL, NULL);
}

static void init_blocking_invoke_host_api(EJSCoreHostAPI *api, BlockingInvokeHost *host) {
  *api = ejs_host_api_default_value();
  api->operations = ejs_native_operation_api();
  api->invoke_api.user_data = ejs_user_data_ref_make(host, NULL, NULL);
  api->invoke_api.invoke = blocking_invoke_host_invoke;
}

static void *blocking_eval_thread_main(void *arg) {
  EJSCoreContext *context = (EJSCoreContext *)arg;
  const char *js_code = "__ejs_native__.invoke('block', 'owner', 'payload');";
  EJSCoreResult eval_res = ejs_eval_script(context, "blocking-owner.js", js_code, strlen(js_code));
  if (eval_res.status == EJS_STATUS_ERROR) {
    ejs_error_destroy(eval_res.error);
  }
  return NULL;
}

static void *queued_eval_thread_main(void *arg) {
  QueuedEvalThreadState *state = (QueuedEvalThreadState *)arg;
  atomic_store(&state->started, 1);
  const char *js_code = "globalThis.__queued_after_destroy = 1;";
  EJSCoreResult eval_res = ejs_eval_script(state->context, "queued-after-destroy.js", js_code, strlen(js_code));
  atomic_store(&state->status, eval_res.status);
  atomic_store(&state->finished, 1);
  if (eval_res.status == EJS_STATUS_ERROR) {
    ejs_error_destroy(eval_res.error);
  }
  return NULL;
}

static void queued_destroy_completion(void *user_data) {
  atomic_int *count = (atomic_int *)user_data;
  atomic_fetch_add(count, 1);
}

static void run_queued_eval_destroy_boundary_regression(void) {
  EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  assert(runtime != NULL);
  assert(context != NULL);

  BlockingInvokeHost host;
  memset(&host, 0, sizeof(host));
  atomic_init(&host.entered, 0);
  atomic_init(&host.release, 0);

  EJSCoreHostAPI api;
  init_blocking_invoke_host_api(&api, &host);
  ejs_context_register_host(context, &api);

  pthread_t blocking_thread;
  assert(pthread_create(&blocking_thread, NULL, blocking_eval_thread_main, context) == 0);

  int wait_limit = 200;
  while (atomic_load(&host.entered) == 0 && wait_limit-- > 0) {
    usleep(1000);
  }
  assert(atomic_load(&host.entered) == 1);

  QueuedEvalThreadState queued;
  queued.context = context;
  atomic_init(&queued.started, 0);
  atomic_init(&queued.finished, 0);
  atomic_init(&queued.status, EJS_STATUS_OK);

  pthread_t queued_thread;
  assert(pthread_create(&queued_thread, NULL, queued_eval_thread_main, &queued) == 0);

  wait_limit = 200;
  while (atomic_load(&queued.started) == 0 && wait_limit-- > 0) {
    usleep(1000);
  }
  assert(atomic_load(&queued.started) == 1);
  usleep(10000);
  assert(atomic_load(&queued.finished) == 0);

  atomic_int destroy_done;
  atomic_init(&destroy_done, 0);
  ejs_runtime_destroy_with_completion(runtime, queued_destroy_completion, &destroy_done);
  atomic_store(&host.release, 1);

  assert(pthread_join(blocking_thread, NULL) == 0);
  assert(pthread_join(queued_thread, NULL) == 0);

  wait_limit = 1000;
  while (atomic_load(&destroy_done) == 0 && wait_limit-- > 0) {
    usleep(1000);
  }
  assert(atomic_load(&destroy_done) == 1);
  assert(atomic_load(&queued.status) == EJS_STATUS_ERROR);
}

static void run_microtask_context_destroy_regression(void) {
  ReentrantDestroyHost host;
  memset(&host, 0, sizeof(host));
  atomic_init(&host.invoke_count, 0);
  atomic_init(&host.release_count, 0);

  EJSCoreHostAPI api;
  init_reentrant_destroy_host_api(&api, &host);

  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  assert(runtime != NULL);
  assert(context != NULL);

  host.context = context;
  ejs_context_register_host(context, &api);

  const char *js_code =
      "Promise.resolve().then(function() {\n"
      "  __ejs_native__.invoke('destroy', 'context', 'payload');\n"
      "});\n"
      "Promise.resolve().then(function() {\n"
      "  var uaf_probe = 40 + 2;\n"
      "});\n";
  EJSCoreResult eval_res =
      ejs_eval_script(context, "microtask-reentrant-destroy.js", js_code, strlen(js_code));
  assert(eval_res.status == EJS_STATUS_OK);

  EJSCoreResult drain_res = ejs_runtime_drain_for_test(runtime);
  assert(drain_res.status == EJS_STATUS_OK);
  assert(atomic_load(&host.invoke_count) == 1);
  assert(atomic_load(&host.release_count) == 3);

  ejs_runtime_destroy(runtime);
}

static void dummy_timer_cb(void *user_data) {
  int *count = (int *)user_data;
  if (count != NULL) {
    *count += 1;
  }
}

static void owner_thread_stop_cb(void *user_data) {
  EJSRuntimeLoop *loop = (EJSRuntimeLoop *)user_data;
  EJSCoreResult stop_res = ejs_runtime_loop_stop(loop);
  assert(stop_res.status == EJS_STATUS_OK);
}

static void run_started_loop_destroy_regression(void) {
  EJSCoreError *err = NULL;
  EJSRuntimeLoop *loop = ejs_runtime_loop_create(NULL, &err);
  assert(loop != NULL);
  assert(err == NULL);

  EJSCoreResult start_res = ejs_runtime_loop_start(loop);
  assert(start_res.status == EJS_STATUS_OK);

  int fired = 0;
  EJSRuntimeTimer *timer =
      ejs_runtime_timer_create(loop, 1, 0, dummy_timer_cb, &fired);
  assert(timer != NULL);

  usleep(5000);
  ejs_runtime_loop_destroy(loop);
}

static void run_stopped_loop_destroy_regression(void) {
  EJSCoreError *err = NULL;
  EJSRuntimeLoop *loop = ejs_runtime_loop_create(NULL, &err);
  assert(loop != NULL);
  assert(err == NULL);

  EJSCoreResult start_res = ejs_runtime_loop_start(loop);
  assert(start_res.status == EJS_STATUS_OK);

  EJSCoreResult stop_on_owner = ejs_runtime_loop_call_sync(loop, owner_thread_stop_cb, loop);
  assert(stop_on_owner.status == EJS_STATUS_OK);

  int wait_limit = 200;
  while (ejs_runtime_loop_is_thread_started(loop) && wait_limit-- > 0) {
    usleep(1000);
  }
  assert(ejs_runtime_loop_is_thread_started(loop) == false);

  EJSCoreResult restart_res = ejs_runtime_loop_start(loop);
  assert(restart_res.status == EJS_STATUS_ERROR);
  ejs_error_destroy(restart_res.error);

  ejs_runtime_loop_destroy(loop);
}

#if defined(EJS_RUNTIME_LOOP_LIBUV) && defined(EJS_TEST)
static void run_stop_requested_enqueue_rejection_regression(void) {
  EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  assert(runtime != NULL);
  assert(runtime->runtime_loop != NULL);

  ejs_runtime_loop_set_stop_requested_for_test(runtime->runtime_loop, 1);
  int task_count = 0;
  EJSCoreResult sync_res =
      ejs_runtime_loop_call_sync(runtime->runtime_loop, dummy_timer_cb, &task_count);
  assert(sync_res.status == EJS_STATUS_ERROR);
  ejs_error_destroy(sync_res.error);
  assert(task_count == 0);

  EJSCoreResult post_res =
      ejs_runtime_loop_post(runtime->runtime_loop, dummy_timer_cb, &task_count);
  assert(post_res.status == EJS_STATUS_ERROR);
  ejs_error_destroy(post_res.error);
  assert(task_count == 0);

  ejs_runtime_loop_set_stop_requested_for_test(runtime->runtime_loop, 0);
  ejs_runtime_destroy(runtime);
}

static void run_context_destroy_call_sync_failure_regression(void) {
  EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  assert(runtime != NULL);
  assert(context != NULL);

  ejs_runtime_loop_set_stop_requested_for_test(runtime->runtime_loop, 1);
  ejs_context_destroy(context);
  assert(ejs_context_is_valid(context) == false);
  ejs_runtime_loop_set_stop_requested_for_test(runtime->runtime_loop, 0);

  atomic_int destroy_done;
  atomic_init(&destroy_done, 0);
  ejs_runtime_destroy_with_completion(runtime, queued_destroy_completion, &destroy_done);

  int wait_limit = 1000;
  while (atomic_load(&destroy_done) == 0 && wait_limit-- > 0) {
    usleep(1000);
  }
  assert(atomic_load(&destroy_done) == 1);
}
#endif

#ifdef EJS_TEST
static void run_destroy_waiter_oom_regression(void) {
  EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  assert(runtime != NULL);

  extern int ejs_test_inject_runtime_error;
  atomic_int completion_count;
  atomic_init(&completion_count, 0);

  ejs_test_inject_runtime_error = 9;
  ejs_runtime_destroy_with_completion(runtime, queued_destroy_completion, &completion_count);
  ejs_runtime_destroy_with_completion(runtime, queued_destroy_completion, &completion_count);
  ejs_test_inject_runtime_error = 0;

  int wait_limit = 1000;
  while (atomic_load(&completion_count) < 2 && wait_limit-- > 0) {
    usleep(1000);
  }
  assert(atomic_load(&completion_count) == 2);
}
#endif

int main(void) {
  setvbuf(stdout, NULL, _IONBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);

  run_reentrant_context_destroy_regression();
  run_queued_eval_destroy_boundary_regression();
  run_microtask_context_destroy_regression();
  run_started_loop_destroy_regression();
  run_stopped_loop_destroy_regression();
#if defined(EJS_RUNTIME_LOOP_LIBUV) && defined(EJS_TEST)
  run_stop_requested_enqueue_rejection_regression();
  run_context_destroy_call_sync_failure_regression();
#endif
#ifdef EJS_TEST
  run_destroy_waiter_oom_regression();
#endif

  printf("ejs_regression_smoke PASS\n");
  return 0;
}

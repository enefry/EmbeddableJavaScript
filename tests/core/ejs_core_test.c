#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stddef.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <errno.h>
#include <time.h>

#include "ejs_runtime.h"
#include "ejs_runtime_internal.h"
#include "ejs_fake_host.h"
#include "ejs_native_api.h"
#include "ejs_abi.h"
#include "ejs_error.h"
#include "ejs_engine.h"

typedef struct {
  pthread_mutex_t mutex;
  pthread_cond_t cond;
  int count;
} TestCompletionWaiter;

static void test_completion_waiter_init(TestCompletionWaiter *waiter) {
  assert(waiter != NULL);
  memset(waiter, 0, sizeof(*waiter));
  assert(pthread_mutex_init(&waiter->mutex, NULL) == 0);
  assert(pthread_cond_init(&waiter->cond, NULL) == 0);
}

static void test_completion_waiter_destroy(TestCompletionWaiter *waiter) {
  assert(waiter != NULL);
  assert(pthread_cond_destroy(&waiter->cond) == 0);
  assert(pthread_mutex_destroy(&waiter->mutex) == 0);
}

static void test_completion_waiter_signal(TestCompletionWaiter *waiter) {
  assert(waiter != NULL);
  assert(pthread_mutex_lock(&waiter->mutex) == 0);
  waiter->count += 1;
  assert(pthread_cond_broadcast(&waiter->cond) == 0);
  assert(pthread_mutex_unlock(&waiter->mutex) == 0);
}

static bool test_completion_waiter_wait_count(TestCompletionWaiter *waiter, int expected, int timeout_ms) {
  assert(waiter != NULL);
  assert(expected > 0);
  assert(timeout_ms > 0);

  struct timespec deadline;
  assert(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
  deadline.tv_sec += timeout_ms / 1000;
  long timeout_ns = (long)(timeout_ms % 1000) * 1000000L;
  deadline.tv_nsec += timeout_ns;
  if (deadline.tv_nsec >= 1000000000L) {
    deadline.tv_sec += deadline.tv_nsec / 1000000000L;
    deadline.tv_nsec %= 1000000000L;
  }

  assert(pthread_mutex_lock(&waiter->mutex) == 0);
  while (waiter->count < expected) {
    int wait_res = pthread_cond_timedwait(&waiter->cond, &waiter->mutex, &deadline);
    if (wait_res == ETIMEDOUT) {
      break;
    }
    assert(wait_res == 0);
  }
  bool reached = waiter->count >= expected;
  assert(pthread_mutex_unlock(&waiter->mutex) == 0);
  return reached;
}

// Define Whitebox access structures for EJSFakeHost
typedef struct {
  uint32_t abi_version;
  size_t struct_size;
} EJSNativeABIMetadata;

typedef struct EJSFakePending {
  struct EJSFakeHost *host;
  struct EJSFakePending *next;
  EJSCoreHostOperation *operation;
  char *module_id;
  char *method_id;
  EJSCoreInvokeCompletion completion;
  void *completion_data;
  bool canceled;
} EJSFakePending;

struct EJSFakeHost {
  EJSCoreHostAPI api;
  EJSFakePending *pending;
  size_t pending_count;
};

// -------------------------------------------------------------
// Test Suit 1: test_runtime_lifecycle
// -------------------------------------------------------------
static void test_stop_completion(void *user_data) {
  int *count = (int *)user_data;
  (*count)++;
}

static void test_waiter_completion(void *user_data) {
  test_completion_waiter_signal((TestCompletionWaiter *)user_data);
}

typedef struct {
  EJSCoreRuntime *runtime;
  TestCompletionWaiter *completion_waiter;
  int inject_runtime_error;
} OwnerDestroyPayload;

typedef struct {
  EJSCoreRuntime *runtime;
  TestCompletionWaiter *completion_waiter;
} TestOwnerReentrantOOMPayload;

typedef struct {
  EJSCoreRuntime *runtime;
  atomic_int primary_count;
  atomic_int nested_count;
} ReentrantDestroyPayload;

static void test_owner_reentrant_oom_cb(void *user_data) {
  TestOwnerReentrantOOMPayload *payload = (TestOwnerReentrantOOMPayload *)user_data;
#ifdef EJS_TEST
  extern int ejs_test_inject_runtime_error;
  ejs_test_inject_runtime_error = 9;
#endif
  for (int i = 0; i < 5; i++) {
    ejs_runtime_destroy_with_completion(payload->runtime,
                                        test_waiter_completion,
                                        payload->completion_waiter);
  }
#ifdef EJS_TEST
  ejs_test_inject_runtime_error = 0;
#endif
}

static void test_owner_thread_destroy_cb(void *user_data) {
  OwnerDestroyPayload *payload = (OwnerDestroyPayload *)user_data;
#ifdef EJS_TEST
  extern int ejs_test_inject_runtime_error;
  ejs_test_inject_runtime_error = payload->inject_runtime_error;
#endif
  ejs_runtime_destroy_with_completion(payload->runtime,
                                      test_waiter_completion,
                                      payload->completion_waiter);
#ifdef EJS_TEST
  ejs_test_inject_runtime_error = 0;
#endif
}

static void test_atomic_stop_completion(void *user_data) {
  atomic_int *count = (atomic_int *)user_data;
  atomic_fetch_add(count, 1);
}

static void test_loop_task_increment_cb(void *user_data) {
  int *count = (int *)user_data;
  (*count)++;
}

static void test_reentrant_destroy_completion(void *user_data) {
  ReentrantDestroyPayload *payload = (ReentrantDestroyPayload *)user_data;
  atomic_fetch_add(&payload->primary_count, 1);
  ejs_runtime_destroy_with_completion(payload->runtime,
                                      test_atomic_stop_completion,
                                      &payload->nested_count);
}

static void test_runtime_lifecycle(void) {
  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);
  config.runtime_name = "test_runtime";
  config.runtime_version = "1.0.0";
  config.memory_limit_bytes = 1024 * 1024 * 32;
  config.max_stack_size = 1024 * 256;

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  assert(runtime != NULL);
  assert(ejs_runtime_is_valid(runtime) == true);

  EJSCoreContext *context = ejs_context_create(runtime);
  assert(context != NULL);
  assert(ejs_context_is_valid(context) == true);

  EJSCoreResult eval_res = ejs_eval_script(context, "owner.js", "globalThis.__owner_test = 41 + 1;", 32);
  if (strcmp(ejs_engine_name(), "quickjs-ng") == 0) {
    assert(eval_res.status == EJS_STATUS_OK);
  } else {
    assert(eval_res.status == EJS_STATUS_ERROR);
    ejs_error_destroy(eval_res.error);
  }

  // Request interrupt on active runtime
  ejs_request_interrupt(runtime);

  ejs_context_destroy(context);

  TestCompletionWaiter stop_waiter;
  test_completion_waiter_init(&stop_waiter);
  ejs_runtime_destroy_with_completion(runtime, test_waiter_completion, &stop_waiter);
  assert(test_completion_waiter_wait_count(&stop_waiter, 1, 2000));
  test_completion_waiter_destroy(&stop_waiter);

  EJSCoreRuntime *dup_runtime = ejs_runtime_create(&config);
  assert(dup_runtime != NULL);
  TestCompletionWaiter dup_stop_waiter;
  test_completion_waiter_init(&dup_stop_waiter);
  ejs_runtime_destroy_with_completion(dup_runtime, test_waiter_completion, &dup_stop_waiter);
  ejs_runtime_destroy_with_completion(dup_runtime, test_waiter_completion, &dup_stop_waiter);
  assert(test_completion_waiter_wait_count(&dup_stop_waiter, 2, 2000));
  test_completion_waiter_destroy(&dup_stop_waiter);

  EJSCoreRuntime *reentrant_runtime = ejs_runtime_create(&config);
  assert(reentrant_runtime != NULL);
  ReentrantDestroyPayload reentrant_payload;
  reentrant_payload.runtime = reentrant_runtime;
  atomic_init(&reentrant_payload.primary_count, 0);
  atomic_init(&reentrant_payload.nested_count, 0);
  ejs_runtime_destroy_with_completion(reentrant_runtime,
                                      test_reentrant_destroy_completion,
                                      &reentrant_payload);

  int wait_limit = 1000;
  while ((atomic_load(&reentrant_payload.primary_count) == 0 ||
          atomic_load(&reentrant_payload.nested_count) == 0) &&
         wait_limit > 0) {
    usleep(1000);
    wait_limit--;
  }
  assert(atomic_load(&reentrant_payload.primary_count) == 1);
  assert(atomic_load(&reentrant_payload.nested_count) == 1);

  EJSCoreRuntime *owner_destroy_runtime = ejs_runtime_create(&config);
  assert(owner_destroy_runtime != NULL);
  TestCompletionWaiter owner_destroy_waiter;
  test_completion_waiter_init(&owner_destroy_waiter);
  OwnerDestroyPayload owner_payload;
  owner_payload.runtime = owner_destroy_runtime;
  owner_payload.completion_waiter = &owner_destroy_waiter;
  owner_payload.inject_runtime_error = 0;
  EJSCoreResult owner_destroy_res =
      ejs_runtime_loop_call_sync(owner_destroy_runtime->runtime_loop,
                                 test_owner_thread_destroy_cb,
                                 &owner_payload);
  assert(owner_destroy_res.status == EJS_STATUS_OK);
  assert(test_completion_waiter_wait_count(&owner_destroy_waiter, 1, 2000));
  test_completion_waiter_destroy(&owner_destroy_waiter);

#ifdef EJS_TEST
  EJSCoreRuntime *owner_ctx_oom_runtime = ejs_runtime_create(&config);
  assert(owner_ctx_oom_runtime != NULL);
  TestCompletionWaiter owner_ctx_oom_waiter;
  test_completion_waiter_init(&owner_ctx_oom_waiter);
  OwnerDestroyPayload owner_ctx_oom_payload;
  owner_ctx_oom_payload.runtime = owner_ctx_oom_runtime;
  owner_ctx_oom_payload.completion_waiter = &owner_ctx_oom_waiter;
  owner_ctx_oom_payload.inject_runtime_error = 6;
  EJSCoreResult owner_ctx_oom_res =
      ejs_runtime_loop_call_sync(owner_ctx_oom_runtime->runtime_loop,
                                 test_owner_thread_destroy_cb,
                                 &owner_ctx_oom_payload);
  assert(owner_ctx_oom_res.status == EJS_STATUS_OK);
  assert(test_completion_waiter_wait_count(&owner_ctx_oom_waiter, 1, 2000));
  test_completion_waiter_destroy(&owner_ctx_oom_waiter);

  EJSCoreRuntime *owner_helper_fail_runtime = ejs_runtime_create(&config);
  assert(owner_helper_fail_runtime != NULL);
  TestCompletionWaiter owner_helper_fail_waiter;
  test_completion_waiter_init(&owner_helper_fail_waiter);
  OwnerDestroyPayload owner_fail_payload;
  owner_fail_payload.runtime = owner_helper_fail_runtime;
  owner_fail_payload.completion_waiter = &owner_helper_fail_waiter;
  owner_fail_payload.inject_runtime_error = 7;
  EJSCoreResult owner_fail_res =
      ejs_runtime_loop_call_sync(owner_helper_fail_runtime->runtime_loop,
                                 test_owner_thread_destroy_cb,
                                 &owner_fail_payload);
  assert(owner_fail_res.status == EJS_STATUS_OK);
  assert(test_completion_waiter_wait_count(&owner_helper_fail_waiter, 1, 2000));
  test_completion_waiter_destroy(&owner_helper_fail_waiter);

  EJSCoreRuntime *owner_direct_helper_fail_runtime = ejs_runtime_create(&config);
  assert(owner_direct_helper_fail_runtime != NULL);
  TestCompletionWaiter owner_direct_helper_fail_waiter;
  test_completion_waiter_init(&owner_direct_helper_fail_waiter);
  OwnerDestroyPayload owner_direct_fail_payload;
  owner_direct_fail_payload.runtime = owner_direct_helper_fail_runtime;
  owner_direct_fail_payload.completion_waiter = &owner_direct_helper_fail_waiter;
  owner_direct_fail_payload.inject_runtime_error = 32;
  EJSCoreResult owner_direct_fail_res =
      ejs_runtime_loop_call_sync(owner_direct_helper_fail_runtime->runtime_loop,
                                 test_owner_thread_destroy_cb,
                                 &owner_direct_fail_payload);
  assert(owner_direct_fail_res.status == EJS_STATUS_OK);
  assert(test_completion_waiter_wait_count(&owner_direct_helper_fail_waiter, 1, 2000));
  test_completion_waiter_destroy(&owner_direct_helper_fail_waiter);

  EJSCoreRuntime *waiter_oom_runtime = ejs_runtime_create(&config);
  assert(waiter_oom_runtime != NULL);
  TestCompletionWaiter waiter_oom_waiter;
  test_completion_waiter_init(&waiter_oom_waiter);
  extern int ejs_test_inject_runtime_error;
  ejs_test_inject_runtime_error = 9;
  ejs_runtime_destroy_with_completion(waiter_oom_runtime, test_waiter_completion, &waiter_oom_waiter);
  ejs_runtime_destroy_with_completion(waiter_oom_runtime, test_waiter_completion, &waiter_oom_waiter);
  ejs_test_inject_runtime_error = 0;
  assert(test_completion_waiter_wait_count(&waiter_oom_waiter, 2, 2000));
  test_completion_waiter_destroy(&waiter_oom_waiter);

  // owner-thread 重复 destroy 且 OOM 登记失败的单元测试 (4个槽位占满，第5次失败)
  EJSCoreRuntime *owner_reentrant_oom_runtime = ejs_runtime_create(&config);
  assert(owner_reentrant_oom_runtime != NULL);
  TestCompletionWaiter owner_reentrant_oom_waiter;
  test_completion_waiter_init(&owner_reentrant_oom_waiter);
  TestOwnerReentrantOOMPayload owner_reentrant_oom_payload;
  owner_reentrant_oom_payload.runtime = owner_reentrant_oom_runtime;
  owner_reentrant_oom_payload.completion_waiter = &owner_reentrant_oom_waiter;

  EJSCoreResult owner_reentrant_oom_res =
      ejs_runtime_loop_call_sync(owner_reentrant_oom_runtime->runtime_loop,
                                 test_owner_reentrant_oom_cb,
                                 &owner_reentrant_oom_payload);
  assert(owner_reentrant_oom_res.status == EJS_STATUS_OK);

  assert(test_completion_waiter_wait_count(&owner_reentrant_oom_waiter, 5, 2000));
  test_completion_waiter_destroy(&owner_reentrant_oom_waiter);
#endif

  // Edge cases and parameter validation
  assert(ejs_runtime_create(NULL) == NULL);
  assert(ejs_context_create(NULL) == NULL);

  // Invalid magic/alive validation
  assert(ejs_runtime_is_valid(NULL) == false);
  assert(ejs_context_is_valid(NULL) == false);

  config.abi_version = 999;
  assert(ejs_runtime_create(&config) == NULL);

  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config) - 20;
  assert(ejs_runtime_create(&config) == NULL);

  ejs_context_destroy(NULL);
  ejs_runtime_destroy(NULL);
  ejs_runtime_destroy_with_completion(NULL, NULL, NULL);
  ejs_request_interrupt(NULL);

  printf("test_runtime_lifecycle PASS\n");
}

// -------------------------------------------------------------
// Test Suit 2: test_abi_checks
// -------------------------------------------------------------
static void test_abi_checks(void) {
  assert(ejs_abi_check_runtime_config(NULL) == false);
  assert(ejs_abi_check_eval_options(NULL) == false);

  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);
  assert(ejs_abi_check_runtime_config(&config) == true);

  EJSCoreRuntimeConfig default_config = ejs_runtime_config_default_value();
  assert(default_config.abi_version == EJS_RUNTIME_ABI_VERSION);
  assert(default_config.struct_size == sizeof(EJSCoreRuntimeConfig));
  assert(default_config.flags == 0u);
  assert(default_config.runtime_name == NULL);
  assert(default_config.runtime_version == NULL);
  assert(default_config.memory_limit_bytes == 0u);
  assert(default_config.max_stack_size == 0u);
  assert(ejs_abi_check_runtime_config(&default_config) == true);

  EJSCoreRuntimeConfig flagged_config = default_config;
  flagged_config.flags = 1u;
  assert(ejs_abi_check_runtime_config(&flagged_config) == false);
  assert(ejs_runtime_create(&flagged_config) == NULL);

  EJSCoreRuntimeConfig reserved_config = default_config;
  reserved_config.reserved[0] = (void *)0x1;
  assert(ejs_abi_check_runtime_config(&reserved_config) == false);
  assert(ejs_runtime_create(&reserved_config) == NULL);

  EJSCoreEvalOptions options;
  memset(&options, 0, sizeof(options));
  options.abi_version = EJS_RUNTIME_ABI_VERSION;
  options.struct_size = sizeof(options);
  assert(ejs_abi_check_eval_options(&options) == true);

  EJSCoreEvalOptions flagged_options = options;
  flagged_options.flags = 1u;
  assert(ejs_abi_check_eval_options(&flagged_options) == false);

  EJSCoreEvalOptions reserved_options = options;
  reserved_options.reserved[0] = (void *)0x1;
  assert(ejs_abi_check_eval_options(&reserved_options) == false);

  printf("test_abi_checks PASS\n");
}

// -------------------------------------------------------------
// Test Suit 3: test_error_handling
// -------------------------------------------------------------
static void test_error_handling(void) {
  EJSCoreError *error = ejs_error_create(EJS_ERROR_INVALID_ARGUMENT, "test msg", "test stack", "test domain", 42);
  assert(error != NULL);
  assert(ejs_error_code(error) == EJS_ERROR_INVALID_ARGUMENT);
  assert(strcmp(ejs_error_message(error), "test msg") == 0);
  assert(strcmp(ejs_error_stack(error), "test stack") == 0);
  assert(strcmp(ejs_error_platform_domain(error), "test domain") == 0);
  assert(ejs_error_platform_code(error) == 42);

  assert(ejs_error_code(NULL) == EJS_ERROR_NONE);
  assert(ejs_error_message(NULL) == NULL);
  assert(ejs_error_stack(NULL) == NULL);
  assert(ejs_error_platform_domain(NULL) == NULL);
  assert(ejs_error_platform_code(NULL) == 0);

  EJSCoreHostError host_err;
  memset(&host_err, 0, sizeof(host_err));
  host_err.abi_version = EJS_NATIVE_ABI_VERSION;
  host_err.struct_size = sizeof(host_err);
  host_err.code = EJS_ERROR_NETWORK;
  host_err.message = "network fail";
  host_err.platform_domain = "net";
  host_err.platform_code = -1;

  EJSCoreError *error2 = ejs_error_from_host_error(&host_err);
  assert(error2 != NULL);
  assert(ejs_error_code(error2) == EJS_ERROR_NETWORK);
  assert(strcmp(ejs_error_message(error2), "network fail") == 0);
  assert(strcmp(ejs_error_platform_domain(error2), "net") == 0);
  assert(ejs_error_platform_code(error2) == -1);

  EJSCoreError *error3 = ejs_error_from_host_error(NULL);
  assert(error3 != NULL);
  assert(ejs_error_code(error3) == EJS_ERROR_INTERNAL);

  EJSCoreResult run_jobs_err = ejs_runtime_drain_for_test(NULL);
  assert(run_jobs_err.status == EJS_STATUS_ERROR);
  ejs_error_destroy(run_jobs_err.error);

  ejs_error_destroy(error);
  ejs_error_destroy(error2);
  ejs_error_destroy(error3);
  ejs_error_destroy(NULL);

  printf("test_error_handling PASS\n");
}

// -------------------------------------------------------------
// Test Suit 4: Custom Test Host for Precision Invocations
// -------------------------------------------------------------
typedef struct {
  char last_module[128];
  char last_method[128];
  uint8_t last_payload[256];
  size_t last_payload_size;
  uint8_t last_transfer[256];
  size_t last_transfer_size;
  size_t invoke_count;

  EJSCoreInvokeCompletion last_completion;
  void *last_completion_data;

  EJSCoreHostOperation *last_op;
  bool op_canceled;
  bool op_released;
} TestHost;

static TestHost g_test_host;

struct EJSCoreHostOperation {
  TestHost *host;
  bool active;
};

struct EJSRuntimeTestHelper {
  uint32_t magic;
  bool alive;
  EJSRuntimeState state;
  bool interrupt_requested;
  void *engine_runtime;
  void *runtime_loop;
  void *engine_class_state;
  const char *runtime_name;
  const char *runtime_version;
  uint64_t memory_limit_bytes;
  uint32_t max_stack_size;
  uint64_t pending_host_operation_count;
  void *host;
};

static EJSCoreHostOperation *custom_host_invoke(EJSCoreUserData user_data,
                                             const char *module_id,
                                             const char *method_id,
                                             EJSCoreByteView payload,
                                             EJSCoreByteView transfer_buffer,
                                             EJSCoreInvokeCompletion completion,
                                             void *completion_data) {
  TestHost *th = (TestHost *)user_data.value;
  th->invoke_count++;
  strncpy(th->last_module, module_id ? module_id : "", sizeof(th->last_module) - 1);
  strncpy(th->last_method, method_id ? method_id : "", sizeof(th->last_method) - 1);

  memset(th->last_payload, 0, sizeof(th->last_payload));
  memset(th->last_transfer, 0, sizeof(th->last_transfer));

  if (payload.data && payload.size > 0) {
    size_t copy_sz = payload.size < (sizeof(th->last_payload) - 1) ? payload.size : (sizeof(th->last_payload) - 1);
    memcpy(th->last_payload, payload.data, copy_sz);
    th->last_payload_size = payload.size;
  } else {
    th->last_payload_size = 0;
  }

  if (transfer_buffer.data && transfer_buffer.size > 0) {
    size_t copy_sz = transfer_buffer.size < (sizeof(th->last_transfer) - 1) ? transfer_buffer.size : (sizeof(th->last_transfer) - 1);
    memcpy(th->last_transfer, transfer_buffer.data, copy_sz);
    th->last_transfer_size = transfer_buffer.size;
  } else {
    th->last_transfer_size = 0;
  }

  th->last_completion = completion;
  th->last_completion_data = completion_data;

  EJSCoreHostOperation *op = (EJSCoreHostOperation *)calloc(1, sizeof(EJSCoreHostOperation));
  op->host = th;
  op->active = true;
  th->last_op = op;
  th->op_canceled = false;
  th->op_released = false;

  if (method_id && strcmp(method_id, "inline_complete") == 0) {
    EJSCoreByteView result;
    result.data = (const uint8_t *)"inline_ok";
    result.size = strlen("inline_ok");
    completion(completion_data, result, NULL);
  }

  if (method_id && strcmp(method_id, "invalid_result_buffer") == 0) {
    EJSCoreByteView invalid_result;
    invalid_result.data = NULL;
    invalid_result.size = 4;
    EJSCoreHostError success_err;
    memset(&success_err, 0, sizeof(success_err));
    success_err.abi_version = EJS_NATIVE_ABI_VERSION;
    success_err.struct_size = sizeof(success_err);
    success_err.code = EJS_ERROR_NONE;
    completion(completion_data, invalid_result, &success_err);
  }

  return op;
}

static int custom_host_invoke_sync(EJSCoreUserData user_data,
                                   const char *module_id,
                                   const char *method_id,
                                   EJSCoreByteView payload,
                                   EJSCoreByteView transfer_buffer,
                                   EJSCoreByteBuffer *result_out,
                                   EJSCoreHostError *error_out) {
  TestHost *th = (TestHost *)user_data.value;
  strncpy(th->last_module, module_id ? module_id : "", sizeof(th->last_module) - 1);
  strncpy(th->last_method, method_id ? method_id : "", sizeof(th->last_method) - 1);

  memset(th->last_payload, 0, sizeof(th->last_payload));
  memset(th->last_transfer, 0, sizeof(th->last_transfer));

  if (payload.data && payload.size > 0) {
    size_t copy_sz = payload.size < (sizeof(th->last_payload) - 1) ? payload.size : (sizeof(th->last_payload) - 1);
    memcpy(th->last_payload, payload.data, copy_sz);
    th->last_payload_size = payload.size;
  } else {
    th->last_payload_size = 0;
  }

  if (transfer_buffer.data && transfer_buffer.size > 0) {
    size_t copy_sz = transfer_buffer.size < (sizeof(th->last_transfer) - 1) ? transfer_buffer.size : (sizeof(th->last_transfer) - 1);
    memcpy(th->last_transfer, transfer_buffer.data, copy_sz);
    th->last_transfer_size = transfer_buffer.size;
  } else {
    th->last_transfer_size = 0;
  }

  memset(result_out, 0, sizeof(*result_out));

  if (method_id != NULL && strcmp(method_id, "error") == 0) {
    memset(error_out, 0, sizeof(*error_out));
    error_out->abi_version = EJS_NATIVE_ABI_VERSION;
    error_out->struct_size = sizeof(*error_out);
    error_out->code = EJS_ERROR_UNSUPPORTED;
    error_out->message = "sync_unsupported";
    error_out->platform_domain = "test";
    error_out->platform_code = 42;
    return EJS_STATUS_ERROR;
  }

  if (method_id != NULL && strcmp(method_id, "bad_error") == 0) {
    memset(error_out, 0, sizeof(*error_out));
    error_out->abi_version = EJS_NATIVE_ABI_VERSION;
    error_out->struct_size = offsetof(EJSCoreHostError, code);
    error_out->code = EJS_ERROR_NETWORK;
    error_out->message = "bad_sync_error_should_not_leak";
    return EJS_STATUS_ERROR;
  }

  if (method_id != NULL && strcmp(method_id, "empty") == 0) {
    return EJS_STATUS_OK;
  }

  if (transfer_buffer.data != NULL || transfer_buffer.size > 0) {
    ejs_byte_buffer_init(result_out, (uint8_t *)transfer_buffer.data, transfer_buffer.size, NULL, NULL, NULL);
  } else {
    ejs_byte_buffer_init(result_out, (uint8_t *)payload.data, payload.size, NULL, NULL, NULL);
  }

  return EJS_STATUS_OK;
}

static int custom_host_cancel(EJSCoreUserData user_data, EJSCoreHostOperation *operation) {
  (void)user_data;
  if (operation) {
    operation->host->op_canceled = true;
  }
  return 0;
}

static void custom_host_release(EJSCoreUserData user_data, EJSCoreHostOperation *operation) {
  (void)user_data;
  if (operation) {
    operation->host->op_released = true;
    free(operation);
  }
}

static void init_custom_host_api(EJSCoreHostAPI *api, TestHost *th) {
  *api = ejs_host_api_default_value();
  api->user_data = ejs_user_data_ref_make(th, NULL, NULL);

  api->operations.user_data = ejs_user_data_ref_make(th, NULL, NULL);
  api->operations.cancel = custom_host_cancel;
  api->operations.release = custom_host_release;

  api->invoke_api.user_data = ejs_user_data_ref_make(th, NULL, NULL);
  api->invoke_api.invoke = custom_host_invoke;

  api->sync_invoke_api.user_data = ejs_user_data_ref_make(th, NULL, NULL);
  api->sync_invoke_api.invoke_sync = custom_host_invoke_sync;
}

#ifdef EJS_TEST
typedef struct {
  EJSCoreContext *context;
  const char *filename;
  const char *source;
  EJSCoreResult eval_result;
  EJSCoreResult result;
} InjectedRunJobsTask;

static void run_jobs_with_injected_error_task(void *user_data) {
  InjectedRunJobsTask *task = (InjectedRunJobsTask *)user_data;
  extern int ejs_test_inject_engine_error;

  ejs_runtime_enter_owner_callback(task->context->runtime);
  task->eval_result = ejs_engine_eval_script(task->context->engine_context,
                                             task->filename,
                                             task->source,
                                             strlen(task->source));
  ejs_runtime_leave_owner_callback(task->context->runtime);

  if (task->eval_result.status != EJS_STATUS_OK) {
    return;
  }

  ejs_test_inject_engine_error = 11;
  ejs_runtime_enter_owner_callback(task->context->runtime);
  task->result = ejs_engine_run_jobs(task->context->runtime->engine_runtime);
  ejs_runtime_leave_owner_callback(task->context->runtime);
  ejs_test_inject_engine_error = 0;
}
#endif

typedef struct {
  EJSCoreHostAPI api;
  EJSCoreContext *context;
  atomic_int invoke_count;
  atomic_int user_data_release_count;
} ReentrantDestroyHost;

static void reentrant_destroy_host_retain(void *user_data) {
  (void)user_data;
}

static void reentrant_destroy_host_release(void *user_data) {
  ReentrantDestroyHost *host = (ReentrantDestroyHost *)user_data;
  atomic_fetch_add(&host->user_data_release_count, 1);
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

// -------------------------------------------------------------
// Test Suit 4: test_js_invoke_validation
// -------------------------------------------------------------
static void test_js_invoke_validation(void) {
  memset(&g_test_host, 0, sizeof(g_test_host));
  EJSCoreHostAPI api;
  init_custom_host_api(&api, &g_test_host);

  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  ejs_context_register_host(context, &api);

  const char *js_code = 
    "try {\n"
    "  __ejs_native__.invoke(123, 'method', 'payload');\n"
    "} catch (e) {\n"
    "  if (e instanceof TypeError) {\n"
    "    __ejs_native__.invoke('test', 'report', 'type_error_ok1');\n"
    "  }\n"
    "}\n"
    "try {\n"
    "  __ejs_native__.invoke('module', 456, 'payload');\n"
    "} catch (e) {\n"
    "  if (e instanceof TypeError) {\n"
    "    __ejs_native__.invoke('test', 'report', 'type_error_ok2');\n"
    "  }\n"
    "}\n"
    "try {\n"
    "  __ejs_native__.invoke('module', 'method');\n"
    "} catch (e) {\n"
    "  if (e instanceof TypeError) {\n"
    "    __ejs_native__.invoke('test', 'report', 'type_error_ok3');\n"
    "  }\n"
    "}\n";

  EJSCoreResult res = ejs_eval_script(context, "test.js", js_code, strlen(js_code));
  assert(res.status == EJS_STATUS_OK);

  ejs_runtime_drain_for_test(runtime);

  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "report") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "type_error_ok3") == 0);

  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);

  printf("test_js_invoke_validation PASS\n");
}

// -------------------------------------------------------------
// Test Suit 5: test_js_invoke_binary
// -------------------------------------------------------------
static void test_js_invoke_binary(void) {
  memset(&g_test_host, 0, sizeof(g_test_host));
  EJSCoreHostAPI api;
  init_custom_host_api(&api, &g_test_host);

  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  ejs_context_register_host(context, &api);

  // String payload
  const char *js_str = "__ejs_native__.invoke('binary', 'string', 'hello_ejs');";
  EJSCoreResult res = ejs_eval_script(context, "test.js", js_str, strlen(js_str));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(strcmp(g_test_host.last_module, "binary") == 0);
  assert(strcmp(g_test_host.last_method, "string") == 0);
  assert(g_test_host.last_payload_size == 9);
  assert(strncmp((char *)g_test_host.last_payload, "hello_ejs", 9) == 0);

  // ArrayBuffer
  const char *js_ab = 
    "{\n"
    "  const ab = new ArrayBuffer(8);\n"
    "  const view = new Uint8Array(ab);\n"
    "  for (let i = 0; i < 8; i++) view[i] = i + 20;\n"
    "  __ejs_native__.invoke('binary', 'arraybuffer', ab);\n"
    "}\n";
  res = ejs_eval_script(context, "test.js", js_ab, strlen(js_ab));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(g_test_host.last_payload_size == 8);
  for (int i = 0; i < 8; i++) {
    assert(g_test_host.last_payload[i] == i + 20);
  }

  // TypedArray with offset
  const char *js_typed = 
    "{\n"
    "  const ab = new ArrayBuffer(16);\n"
    "  const view = new Uint8Array(ab, 4, 6);\n"
    "  for (let i = 0; i < 6; i++) view[i] = i + 50;\n"
    "  __ejs_native__.invoke('binary', 'typedarray', view);\n"
    "}\n";
  res = ejs_eval_script(context, "test.js", js_typed, strlen(js_typed));
  if (res.status != EJS_STATUS_OK) {
    printf("EJS_EVAL_SCRIPT ERROR: %s, stack: %s\n", ejs_error_message(res.error), ejs_error_stack(res.error));
  }
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(g_test_host.last_payload_size == 6);
  for (int i = 0; i < 6; i++) {
    assert(g_test_host.last_payload[i] == i + 50);
  }

  // Transfer Buffer (Arg 4)
  const char *js_transfer = 
    "{\n"
    "  const ab = new ArrayBuffer(5);\n"
    "  const view = new Uint8Array(ab);\n"
    "  for (let i = 0; i < 5; i++) view[i] = i + 80;\n"
    "  __ejs_native__.invoke('binary', 'transfer', 'payload_msg', ab);\n"
    "}\n";
  res = ejs_eval_script(context, "test.js", js_transfer, strlen(js_transfer));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(strcmp((char *)g_test_host.last_payload, "payload_msg") == 0);
  assert(g_test_host.last_transfer_size == 5);
  for (int i = 0; i < 5; i++) {
    assert(g_test_host.last_transfer[i] == i + 80);
  }

  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);

  printf("test_js_invoke_binary PASS\n");
}

// -------------------------------------------------------------
// Test Suit 6: test_js_invoke_async
// -------------------------------------------------------------
static void test_js_invoke_async(void) {
  memset(&g_test_host, 0, sizeof(g_test_host));
  EJSCoreHostAPI api;
  init_custom_host_api(&api, &g_test_host);

  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  ejs_context_register_host(context, &api);

  // Promise resolve
  const char *js_resolve = 
    "__ejs_native__.invoke('async', 'resolve_test', 'arg').then(res => {\n"
    "  var view = new Uint8Array(res);\n"
    "  if (view[0] === 9 && view[1] === 8) {\n"
    "    __ejs_native__.invoke('test', 'async_result', 'resolve_ok');\n"
    "  }\n"
    "});\n";
  EJSCoreResult res = ejs_eval_script(context, "test.js", js_resolve, strlen(js_resolve));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);

  assert(strcmp(g_test_host.last_module, "async") == 0);
  assert(strcmp(g_test_host.last_method, "resolve_test") == 0);
  assert(g_test_host.last_completion != NULL);

  uint8_t res_data[2] = {9, 8};
  EJSCoreByteView res_view = {res_data, 2};
  EJSCoreHostError success_err;
  memset(&success_err, 0, sizeof(success_err));
  success_err.abi_version = EJS_NATIVE_ABI_VERSION;
  success_err.struct_size = sizeof(success_err);
  success_err.code = EJS_ERROR_NONE;

  g_test_host.last_completion(g_test_host.last_completion_data, res_view, &success_err);

  ejs_runtime_drain_for_test(runtime);

  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "async_result") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "resolve_ok") == 0);

  // Promise reject
  const char *js_reject = 
    "__ejs_native__.invoke('async', 'reject_test', 'arg').catch(err => {\n"
    "  if (err.code === 3 && err.message === 'host_network_error') {\n"
    "    __ejs_native__.invoke('test', 'async_result', 'reject_ok');\n"
    "  }\n"
    "});\n";
  res = ejs_eval_script(context, "test.js", js_reject, strlen(js_reject));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);

  assert(strcmp(g_test_host.last_module, "async") == 0);
  assert(strcmp(g_test_host.last_method, "reject_test") == 0);
  assert(g_test_host.last_completion != NULL);

  EJSCoreHostError fail_err;
  memset(&fail_err, 0, sizeof(fail_err));
  fail_err.abi_version = EJS_NATIVE_ABI_VERSION;
  fail_err.struct_size = sizeof(fail_err);
  fail_err.code = EJS_ERROR_NETWORK;
  fail_err.message = "host_network_error";

  EJSCoreByteView empty_view = {NULL, 0};
  g_test_host.last_completion(g_test_host.last_completion_data, empty_view, &fail_err);

  ejs_runtime_drain_for_test(runtime);

  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "async_result") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "reject_ok") == 0);

  const char *js_bad_error =
    "__ejs_native__.invoke('async', 'bad_error_test', 'arg').catch(err => {\n"
    "  if (err.code === 8 && err.message === 'invalid host error') {\n"
    "    __ejs_native__.invoke('test', 'async_result', 'bad_error_ok');\n"
    "  }\n"
    "});\n";
  res = ejs_eval_script(context, "bad_error.js", js_bad_error, strlen(js_bad_error));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);

  assert(strcmp(g_test_host.last_module, "async") == 0);
  assert(strcmp(g_test_host.last_method, "bad_error_test") == 0);
  assert(g_test_host.last_completion != NULL);

  EJSCoreHostError bad_err;
  memset(&bad_err, 0, sizeof(bad_err));
  bad_err.abi_version = EJS_NATIVE_ABI_VERSION;
  bad_err.struct_size = offsetof(EJSCoreHostError, code);
  bad_err.code = EJS_ERROR_NETWORK;
  bad_err.message = "bad_async_error_should_not_leak";

  g_test_host.last_completion(g_test_host.last_completion_data, empty_view, &bad_err);

  ejs_runtime_drain_for_test(runtime);

  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "async_result") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "bad_error_ok") == 0);

  const char *js_invalid_result =
    "__ejs_native__.invoke('async', 'invalid_result_buffer', 'arg').then(() => {\n"
    "  __ejs_native__.invoke('test', 'async_result', 'invalid_result_buffer_resolved');\n"
    "}).catch(err => {\n"
    "  const message = String((err && err.message) || err);\n"
    "  if (message.indexOf('invalid result buffer') >= 0) {\n"
    "    __ejs_native__.invoke('test', 'async_result', 'invalid_result_buffer_ok');\n"
    "  } else {\n"
    "    __ejs_native__.invoke('test', 'async_result', 'invalid_result_buffer_bad:' + message);\n"
    "  }\n"
    "});\n";
  res = ejs_eval_script(context, "invalid_result_buffer.js", js_invalid_result, strlen(js_invalid_result));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  ejs_runtime_drain_for_test(runtime);

  if (strcmp((char *)g_test_host.last_payload, "invalid_result_buffer_ok") != 0) {
    fprintf(stderr, "invalid_result_buffer async payload=%s module=%s method=%s\n",
            g_test_host.last_payload,
            g_test_host.last_module,
            g_test_host.last_method);
  }
  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "async_result") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "invalid_result_buffer_ok") == 0);

  const char *js_inline =
    "__ejs_native__.invoke('async', 'inline_complete', 'arg').then(res => {\n"
    "  var view = new Uint8Array(res);\n"
    "  var text = String.fromCharCode.apply(null, view);\n"
    "  __ejs_native__.invoke('test', 'async_result', text);\n"
    "});\n";
  res = ejs_eval_script(context, "test_inline.js", js_inline, strlen(js_inline));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);

  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "async_result") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "inline_ok") == 0);

#ifdef EJS_TEST
  extern int ejs_test_inject_engine_error;
  ejs_test_inject_engine_error = 29;
  const char *js_async_payload_oom =
    "let asyncPayloadOOM = false;\n"
    "try {\n"
    "  __ejs_native__.invoke('async', 'payload_oom', 'x');\n"
    "} catch (err) {\n"
    "  asyncPayloadOOM = true;\n"
    "}\n"
    "if (!asyncPayloadOOM) throw new Error('async payload conversion did not throw');\n";
  res = ejs_eval_script(context, "async_payload_oom.js", js_async_payload_oom, strlen(js_async_payload_oom));
  assert(res.status == EJS_STATUS_OK);
  ejs_test_inject_engine_error = 0;
#endif

  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);

  printf("test_js_invoke_async PASS\n");
}

static void test_js_invoke_sync(void) {
  memset(&g_test_host, 0, sizeof(g_test_host));
  EJSCoreHostAPI api;
  init_custom_host_api(&api, &g_test_host);

  EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  ejs_context_register_host(context, &api);

  const char *js_sync_echo =
    "const syncRes = __ejs_native__.invokeSync('sync', 'echo', 'sync-ok');\n"
    "const syncText = String.fromCharCode.apply(null, new Uint8Array(syncRes));\n"
    "__ejs_native__.invoke('test', 'async_result', syncText);\n";
  EJSCoreResult res = ejs_eval_script(context, "sync_echo.js", js_sync_echo, strlen(js_sync_echo));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "async_result") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "sync-ok") == 0);

  const char *js_sync_transfer =
    "const transfer = new Uint8Array([65, 66, 67]);\n"
    "const syncRes2 = __ejs_native__.invokeSync('sync', 'transfer', 'payload', transfer);\n"
    "const syncText2 = String.fromCharCode.apply(null, new Uint8Array(syncRes2));\n"
    "__ejs_native__.invoke('test', 'async_result', syncText2);\n";
  res = ejs_eval_script(context, "sync_transfer.js", js_sync_transfer, strlen(js_sync_transfer));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "async_result") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "ABC") == 0);

  const char *js_sync_invalid_binary =
    "let invalidPayloadRejected = false;\n"
    "try {\n"
    "  __ejs_native__.invokeSync('sync', 'echo', { a: 1 });\n"
    "} catch (err) {\n"
    "  invalidPayloadRejected = err instanceof TypeError && String(err.message).indexOf('payload') >= 0;\n"
    "}\n"
    "let invalidTransferRejected = false;\n"
    "try {\n"
    "  __ejs_native__.invokeSync('sync', 'transfer', 'payload', { b: 2 });\n"
    "} catch (err) {\n"
    "  invalidTransferRejected = err instanceof TypeError && String(err.message).indexOf('transfer_buffer') >= 0;\n"
    "}\n"
    "if (!invalidPayloadRejected || !invalidTransferRejected) throw new Error('sync invalid binary accepted');\n";
  res = ejs_eval_script(context, "sync_invalid_binary.js", js_sync_invalid_binary, strlen(js_sync_invalid_binary));
  assert(res.status == EJS_STATUS_OK);

  const char *js_sync_empty =
    "const empty = __ejs_native__.invokeSync('sync', 'empty', 'x');\n"
    "__ejs_native__.invoke('test', 'async_result', String(new Uint8Array(empty).byteLength));\n";
  res = ejs_eval_script(context, "sync_empty.js", js_sync_empty, strlen(js_sync_empty));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "async_result") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "0") == 0);

#ifdef EJS_TEST
  extern int ejs_test_inject_engine_error;
  ejs_test_inject_engine_error = 30;
  const char *js_sync_payload_oom =
    "let syncPayloadOOM = false;\n"
    "try {\n"
    "  __ejs_native__.invokeSync('sync', 'echo', 'x');\n"
    "} catch (err) {\n"
    "  syncPayloadOOM = true;\n"
    "}\n"
    "if (!syncPayloadOOM) throw new Error('sync payload conversion did not throw');\n";
  res = ejs_eval_script(context, "sync_payload_oom.js", js_sync_payload_oom, strlen(js_sync_payload_oom));
  assert(res.status == EJS_STATUS_OK);
  ejs_test_inject_engine_error = 0;

  ejs_test_inject_engine_error = 31;
  const char *js_sync_copy_oom =
    "let syncCopyOOM = false;\n"
    "try {\n"
    "  __ejs_native__.invokeSync('sync', 'echo', 'x');\n"
    "} catch (err) {\n"
    "  syncCopyOOM = true;\n"
    "}\n"
    "if (!syncCopyOOM) throw new Error('sync result copy did not throw');\n";
  res = ejs_eval_script(context, "sync_copy_oom.js", js_sync_copy_oom, strlen(js_sync_copy_oom));
  assert(res.status == EJS_STATUS_OK);
  ejs_test_inject_engine_error = 0;
#endif

  const char *js_sync_error =
    "try {\n"
    "  __ejs_native__.invokeSync('sync', 'error', 'x');\n"
    "} catch (err) {\n"
    "  if (err.code === 6 && err.message === 'sync_unsupported' && err.platform_domain === 'test' && err.platform_code === 42) {\n"
    "    __ejs_native__.invoke('test', 'async_result', 'sync_error_ok');\n"
    "  }\n"
    "}\n";
  res = ejs_eval_script(context, "sync_error.js", js_sync_error, strlen(js_sync_error));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "async_result") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "sync_error_ok") == 0);

  const char *js_sync_bad_error =
    "try {\n"
    "  __ejs_native__.invokeSync('sync', 'bad_error', 'x');\n"
    "} catch (err) {\n"
    "  if (err.code === 8 && err.message === 'invalid host error') {\n"
    "    __ejs_native__.invoke('test', 'async_result', 'sync_bad_error_ok');\n"
    "  }\n"
    "}\n";
  res = ejs_eval_script(context, "sync_bad_error.js", js_sync_bad_error, strlen(js_sync_bad_error));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "async_result") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "sync_bad_error_ok") == 0);

  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);

  printf("test_js_invoke_sync PASS\n");
}

static void test_host_api_partial_struct_copy(void) {
  memset(&g_test_host, 0, sizeof(g_test_host));
  EJSCoreHostAPI api;
  init_custom_host_api(&api, &g_test_host);

  api.struct_size = offsetof(EJSCoreHostAPI, sync_invoke_api);
  assert(ejs_native_validate_host_api(&api, EJS_NATIVE_PROVIDER_INVOKE) == EJS_NATIVE_VALIDATION_OK);
  assert(ejs_native_validate_host_api(&api, EJS_NATIVE_PROVIDER_INVOKE | EJS_NATIVE_PROVIDER_SYNC_INVOKE) == EJS_NATIVE_VALIDATION_STRUCT_SIZE);

  EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  ejs_context_register_host(context, &api);

  const char *js =
    "let ok = false;\n"
    "try {\n"
    "  __ejs_native__.invokeSync('sync', 'echo', 'tail-leak');\n"
    "} catch (err) {\n"
    "  ok = String(err && err.message).indexOf('host sync invoke API is not registered') >= 0;\n"
    "}\n"
    "if (!ok) throw new Error('partial host API unexpectedly exposed sync invoke');\n";
  EJSCoreResult res = ejs_eval_script(context, "partial_host_api.js", js, strlen(js));
  assert(res.status == EJS_STATUS_OK);

  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);

  printf("test_host_api_partial_struct_copy PASS\n");
}

// -------------------------------------------------------------
#ifdef EJS_RUNTIME_LOOP_LIBUV
static void test_timers_libuv(void) {
  memset(&g_test_host, 0, sizeof(g_test_host));
  EJSCoreHostAPI api;
  init_custom_host_api(&api, &g_test_host);

  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  ejs_context_register_host(context, &api);

  const char *js_timer = 
    "__ejs_native__.timers.create(1, 0, function() {\n"
    "  __ejs_native__.invoke('test', 'timer', 'fired_ok');\n"
    "});\n";
  EJSCoreResult res = ejs_eval_script(context, "test.js", js_timer, strlen(js_timer));
  assert(res.status == EJS_STATUS_OK);

  // Pump loop until timer fires
  for (int i = 0; i < 20; i++) {
    ejs_runtime_drain_for_test(runtime);
    usleep(2000);
  }

  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "timer") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "fired_ok") == 0);

  // Verify destroy timer
  const char *js_destroy = 
    "const id = __ejs_native__.timers.create(100, 0, function() {\n"
    "  __ejs_native__.invoke('test', 'timer', 'should_not_fire');\n"
    "});\n"
    "__ejs_native__.timers.destroy(id);\n"
    "__ejs_native__.timers.create(1, 0, function() {\n"
    "  __ejs_native__.invoke('test', 'timer', 'fired_after_destroy');\n"
    "});\n";
  res = ejs_eval_script(context, "test.js", js_destroy, strlen(js_destroy));
  assert(res.status == EJS_STATUS_OK);

  for (int i = 0; i < 20; i++) {
    ejs_runtime_drain_for_test(runtime);
    usleep(2000);
  }

  assert(strcmp((char *)g_test_host.last_payload, "fired_after_destroy") == 0);

  const char *js_self_clear =
    "let self_id = 0;\n"
    "self_id = __ejs_native__.timers.create(1, 0, function() {\n"
    "  __ejs_native__.timers.destroy(self_id);\n"
    "  __ejs_native__.invoke('test', 'timer', 'self_destroy_ok');\n"
    "});\n";
  res = ejs_eval_script(context, "test.js", js_self_clear, strlen(js_self_clear));
  assert(res.status == EJS_STATUS_OK);

  for (int i = 0; i < 20; i++) {
    ejs_runtime_drain_for_test(runtime);
    usleep(2000);
  }

  assert(strcmp((char *)g_test_host.last_payload, "self_destroy_ok") == 0);

  // Timer parameter checks and error coverage
  // Callback parameter TypeError validation
  const char *js_timer_err = 
    "try {\n"
    "  __ejs_native__.timers.create(1, 0, 123);\n"
    "} catch (e) {\n"
    "  if (e instanceof TypeError) {\n"
    "    __ejs_native__.invoke('test', 'timer_err', 'type_error_caught');\n"
    "  }\n"
    "}\n";
  res = ejs_eval_script(context, "test.js", js_timer_err, strlen(js_timer_err));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(strcmp((char *)g_test_host.last_payload, "type_error_caught") == 0);

  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);

  printf("test_timers_libuv PASS\n");
}

static void test_events_hooks_libuv(void) {
  memset(&g_test_host, 0, sizeof(g_test_host));
  EJSCoreHostAPI api;
  init_custom_host_api(&api, &g_test_host);

  EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  ejs_context_register_host(context, &api);

  const char *js_events_shape =
    "if (!__ejs_native__.events ||\n"
    "    typeof __ejs_native__.events.setPromiseRejectionTracker !== 'function' ||\n"
    "    typeof __ejs_native__.events.setExceptionReporter !== 'function') {\n"
    "  throw new Error('events hooks missing');\n"
    "}\n";
  EJSCoreResult res = ejs_eval_script(context, "events_shape.js", js_events_shape, strlen(js_events_shape));
  assert(res.status == EJS_STATUS_OK);

  const char *js_unhandled =
    "__ejs_native__.events.setPromiseRejectionTracker(function(kind, promise, reason) {\n"
    "  const text = kind + ':' + (reason && reason.message ? reason.message : String(reason));\n"
    "  __ejs_native__.invoke('test', 'rejection', text);\n"
    "});\n"
    "Promise.reject(new Error('unhandled-sentinel'));\n";
  res = ejs_eval_script(context, "rejection_unhandled.js", js_unhandled, strlen(js_unhandled));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "rejection") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "unhandled:unhandled-sentinel") == 0);

  g_test_host.last_method[0] = '\0';
  memset(g_test_host.last_payload, 0, sizeof(g_test_host.last_payload));
  g_test_host.invoke_count = 0;
  const char *js_same_turn_handled =
    "const sameTurn = Promise.reject(new Error('same-turn-sentinel'));\n"
    "sameTurn.catch(function() {});\n";
  res = ejs_eval_script(context,
                        "rejection_same_turn_handled.js",
                        js_same_turn_handled,
                        strlen(js_same_turn_handled));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(g_test_host.invoke_count == 0);
  assert(g_test_host.last_method[0] == '\0');

  g_test_host.last_method[0] = '\0';
  memset(g_test_host.last_payload, 0, sizeof(g_test_host.last_payload));
  g_test_host.invoke_count = 0;
  const char *js_late_unhandled =
    "globalThis.lateForHandled = Promise.reject(new Error('late-sentinel'));\n";
  res = ejs_eval_script(context,
                        "rejection_late_unhandled.js",
                        js_late_unhandled,
                        strlen(js_late_unhandled));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(g_test_host.invoke_count == 1);
  assert(strcmp(g_test_host.last_method, "rejection") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "unhandled:late-sentinel") == 0);

  g_test_host.last_method[0] = '\0';
  memset(g_test_host.last_payload, 0, sizeof(g_test_host.last_payload));
  g_test_host.invoke_count = 0;
  const char *js_late_handled =
    "globalThis.lateForHandled.catch(function() {});\n";
  res = ejs_eval_script(context,
                        "rejection_late_handled.js",
                        js_late_handled,
                        strlen(js_late_handled));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(g_test_host.invoke_count == 1);
  assert(strcmp(g_test_host.last_method, "rejection") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "handled:late-sentinel") == 0);

  g_test_host.last_method[0] = '\0';
  memset(g_test_host.last_payload, 0, sizeof(g_test_host.last_payload));
  g_test_host.invoke_count = 0;
  const char *js_callback_handles_other_rejection =
    "__ejs_native__.events.setPromiseRejectionTracker(function(kind, promise, reason) {\n"
    "  if (reason && reason.message === 'primary-sentinel') {\n"
    "    globalThis.secondaryForCallbackCatch.catch(function() {});\n"
    "  }\n"
    "  const text = kind + ':' + (reason && reason.message ? reason.message : String(reason));\n"
    "  __ejs_native__.invoke('test', 'rejection', text);\n"
    "});\n"
    "globalThis.secondaryForCallbackCatch = Promise.reject(new Error('secondary-sentinel'));\n"
    "Promise.reject(new Error('primary-sentinel'));\n";
  res = ejs_eval_script(context,
                        "rejection_callback_handles_other.js",
                        js_callback_handles_other_rejection,
                        strlen(js_callback_handles_other_rejection));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(g_test_host.invoke_count == 1);
  assert(strcmp(g_test_host.last_method, "rejection") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "unhandled:primary-sentinel") == 0);

  g_test_host.last_method[0] = '\0';
  memset(g_test_host.last_payload, 0, sizeof(g_test_host.last_payload));
  g_test_host.invoke_count = 0;
  const char *js_rejection_tracker_self_unset =
    "__ejs_native__.events.setPromiseRejectionTracker(function(kind, promise, reason) {\n"
    "  __ejs_native__.events.setPromiseRejectionTracker(null);\n"
    "  const text = kind + ':' + (reason && reason.message ? reason.message : String(reason));\n"
    "  __ejs_native__.invoke('test', 'rejection_self_unset', text);\n"
    "});\n"
    "Promise.reject(new Error('self-unset-rejection'));\n";
  res = ejs_eval_script(context,
                        "rejection_tracker_self_unset.js",
                        js_rejection_tracker_self_unset,
                        strlen(js_rejection_tracker_self_unset));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);
  assert(g_test_host.invoke_count == 1);
  assert(strcmp(g_test_host.last_method, "rejection_self_unset") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "unhandled:self-unset-rejection") == 0);

  g_test_host.last_method[0] = '\0';
  memset(g_test_host.last_payload, 0, sizeof(g_test_host.last_payload));
  const char *js_timer_exception =
    "__ejs_native__.events.setExceptionReporter(function(error) {\n"
    "  __ejs_native__.invoke('test', 'exception', error && error.message ? error.message : String(error));\n"
    "});\n"
    "__ejs_native__.timers.create(1, 0, function() { throw new Error('timer-sentinel'); });\n";
  res = ejs_eval_script(context, "timer_exception_reporter.js", js_timer_exception, strlen(js_timer_exception));
  assert(res.status == EJS_STATUS_OK);
  for (int i = 0; i < 20 && strcmp(g_test_host.last_method, "exception") != 0; i++) {
    ejs_runtime_drain_for_test(runtime);
    usleep(2000);
  }
  assert(strcmp(g_test_host.last_method, "exception") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "timer-sentinel") == 0);

  g_test_host.last_method[0] = '\0';
  memset(g_test_host.last_payload, 0, sizeof(g_test_host.last_payload));
  const char *js_reporter_throw =
    "__ejs_native__.events.setExceptionReporter(function(error) {\n"
    "  __ejs_native__.invoke('test', 'reporter_throw', error && error.message ? error.message : String(error));\n"
    "  throw new Error('reporter failed');\n"
    "});\n"
    "__ejs_native__.timers.create(1, 0, function() { throw new Error('recursive-sentinel'); });\n";
  res = ejs_eval_script(context, "reporter_throw.js", js_reporter_throw, strlen(js_reporter_throw));
  assert(res.status == EJS_STATUS_OK);
  for (int i = 0; i < 20 && strcmp(g_test_host.last_method, "reporter_throw") != 0; i++) {
    ejs_runtime_drain_for_test(runtime);
    usleep(2000);
  }
  assert(strcmp(g_test_host.last_method, "reporter_throw") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "recursive-sentinel") == 0);

  g_test_host.last_method[0] = '\0';
  memset(g_test_host.last_payload, 0, sizeof(g_test_host.last_payload));
  const char *js_reporter_self_unset =
    "__ejs_native__.events.setExceptionReporter(function(error) {\n"
    "  __ejs_native__.events.setExceptionReporter(null);\n"
    "  __ejs_native__.invoke('test', 'reporter_self_unset', error && error.message ? error.message : String(error));\n"
    "});\n"
    "__ejs_native__.timers.create(1, 0, function() { throw new Error('self-unset-exception'); });\n";
  res = ejs_eval_script(context, "reporter_self_unset.js", js_reporter_self_unset, strlen(js_reporter_self_unset));
  assert(res.status == EJS_STATUS_OK);
  for (int i = 0; i < 20 && strcmp(g_test_host.last_method, "reporter_self_unset") != 0; i++) {
    ejs_runtime_drain_for_test(runtime);
    usleep(2000);
  }
  assert(strcmp(g_test_host.last_method, "reporter_self_unset") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "self-unset-exception") == 0);

#ifdef EJS_TEST
  extern int ejs_test_inject_engine_error;
  g_test_host.last_method[0] = '\0';
  memset(g_test_host.last_payload, 0, sizeof(g_test_host.last_payload));
  g_test_host.invoke_count = 0;
  const char *js_job_reporter =
    "__ejs_native__.events.setExceptionReporter(function(error) {\n"
    "  __ejs_native__.invoke('test', 'job_exception', 'job-reported');\n"
    "});\n"
    "Promise.resolve().then(function() {\n"
    "  __ejs_native__.invoke('test', 'job_before_injected_exception', 'before-injected');\n"
    "  Promise.resolve().then(function() {\n"
    "    __ejs_native__.invoke('test', 'job_after_injected_exception', 'after-injected');\n"
    "  });\n"
    "});\n";
  InjectedRunJobsTask injected_task;
  injected_task.context = context;
  injected_task.filename = "job_exception_reporter.js";
  injected_task.source = js_job_reporter;
  injected_task.eval_result = ejs_result_ok();
  injected_task.result = ejs_result_ok();
  EJSCoreResult call_result =
    ejs_runtime_loop_call_sync(runtime->runtime_loop,
                               run_jobs_with_injected_error_task,
                               &injected_task);
  assert(call_result.status == EJS_STATUS_OK);
  assert(injected_task.eval_result.status == EJS_STATUS_OK);
  EJSCoreResult drain = injected_task.result;
  assert(drain.status == EJS_STATUS_OK);
  assert(g_test_host.invoke_count >= 2);
  assert(strcmp(g_test_host.last_method, "job_after_injected_exception") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "after-injected") == 0);

  res = ejs_eval_script(context,
                        "job_reporter_unset.js",
                        "__ejs_native__.events.setExceptionReporter(null);\n",
                        strlen("__ejs_native__.events.setExceptionReporter(null);\n"));
  assert(res.status == EJS_STATUS_OK);
  ejs_test_inject_engine_error = 11;
  drain = ejs_runtime_drain_for_test(runtime);
  ejs_test_inject_engine_error = 0;
  assert(drain.status == EJS_STATUS_ERROR);
  assert(drain.error != NULL);
  ejs_error_destroy(drain.error);
#endif

  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);

  printf("test_events_hooks_libuv PASS\n");
}

static void test_timer_reentrant_context_destroy(void) {
  ReentrantDestroyHost host;
  memset(&host, 0, sizeof(host));
  atomic_init(&host.invoke_count, 0);
  atomic_init(&host.user_data_release_count, 0);

  EJSCoreHostAPI api;
  init_reentrant_destroy_host_api(&api, &host);

  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  assert(runtime != NULL && context != NULL);

  host.context = context;
  ejs_context_register_host(context, &api);

  const char *js_code =
    "__ejs_native__.timers.create(1, 0, function() {\n"
    "  __ejs_native__.invoke('destroy', 'context', 'payload');\n"
    "});\n";
  EJSCoreResult eval_res = ejs_eval_script(context, "reentrant-destroy.js", js_code, strlen(js_code));
  assert(eval_res.status == EJS_STATUS_OK);

  int wait_limit = 200;
  while (atomic_load(&host.invoke_count) == 0 && wait_limit-- > 0) {
    usleep(1000);
    (void)ejs_runtime_drain_for_test(runtime);
  }
  assert(atomic_load(&host.invoke_count) == 1);

  wait_limit = 200;
  while (atomic_load(&host.user_data_release_count) < 3 && wait_limit-- > 0) {
    usleep(1000);
    (void)ejs_runtime_drain_for_test(runtime);
  }
  assert(atomic_load(&host.user_data_release_count) == 3);

  ejs_runtime_destroy(runtime);
  printf("test_timer_reentrant_context_destroy PASS\n");
}
#endif

// -------------------------------------------------------------
// Test Suit 8: test_libuv_microtask_integration
// -------------------------------------------------------------
static void test_libuv_microtask_integration(void) {
  memset(&g_test_host, 0, sizeof(g_test_host));
  EJSCoreHostAPI api;
  init_custom_host_api(&api, &g_test_host);

  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  ejs_context_register_host(context, &api);

  const char *js_micro = 
    "Promise.resolve().then(() => {\n"
    "  __ejs_native__.invoke('test', 'micro', 'resolved_ok');\n"
    "});\n";
  EJSCoreResult res = ejs_eval_script(context, "test.js", js_micro, strlen(js_micro));
  assert(res.status == EJS_STATUS_OK);

  // Under libuv, prepare/check hooks will flush microtasks automatically during drain.
  ejs_runtime_drain_for_test(runtime);

  assert(strcmp(g_test_host.last_module, "test") == 0);
  assert(strcmp(g_test_host.last_method, "micro") == 0);
  assert(strcmp((char *)g_test_host.last_payload, "resolved_ok") == 0);

  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);

  printf("test_libuv_microtask_integration PASS\n");
}

// -------------------------------------------------------------
// Test Suit 9: test_safe_lifecycle_cancel
// -------------------------------------------------------------
static void test_safe_lifecycle_cancel(void) {
  EJSFakeHost *fake_host = ejs_fake_host_create();
  assert(fake_host != NULL);
  assert(ejs_fake_host_pending_count(fake_host) == 0);

  EJSCoreHostAPI *api = ejs_fake_host_api(fake_host);
  assert(api != NULL);

  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  ejs_context_register_host(context, api);

  // Trigger an asynchronous invoke that hangs
  const char *js_long = "__ejs_native__.invoke('fs', 'read_large_file', 'path');";
  EJSCoreResult res = ejs_eval_script(context, "test.js", js_long, strlen(js_long));
  assert(res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);

  assert(ejs_fake_host_pending_count(fake_host) == 1);
  assert(fake_host->pending != NULL);
  assert(fake_host->pending->canceled == false);

  // Destroy context directly while invoke is pending
  ejs_context_destroy(context);

  // The operation must be cancelled and released, and host pending list is cleaned
  assert(ejs_fake_host_pending_count(fake_host) == 0);
  assert(fake_host->pending == NULL);

  // Edge cases for fake host coverage
  assert(ejs_fake_host_api(NULL) == NULL);
  assert(ejs_fake_host_pending_count(NULL) == 0);
  ejs_fake_host_destroy(NULL);

  ejs_fake_host_complete_all(fake_host);

  ejs_runtime_destroy(runtime);
  ejs_fake_host_destroy(fake_host);

  printf("test_safe_lifecycle_cancel PASS\n");
}

// -------------------------------------------------------------
// Test Suit 10: test_uaf_prevention
// -------------------------------------------------------------
static void test_uaf_prevention(void) {
  // 1. cancel + release
  EJSCoreHostOperation *op1 = ejs_native_operation_create(NULL, NULL, NULL);
  assert(op1 != NULL);
  assert(ejs_native_operation_state(op1) == EJS_NATIVE_OPERATION_PENDING);

  int cancel_ret = ejs_native_operation_cancel(op1);
  assert(cancel_ret == 0);
  assert(ejs_native_operation_state(op1) == EJS_NATIVE_OPERATION_CANCEL_REQUESTED);

  ejs_native_operation_release(op1);

  // 2. complete
  EJSCoreHostOperation *op2 = ejs_native_operation_create(NULL, NULL, NULL);
  assert(op2 != NULL);
  
  bool comp_ret = ejs_native_operation_complete(op2);
  assert(comp_ret == true);

  // 3. Null checks
  assert(ejs_native_operation_state(NULL) == EJS_NATIVE_OPERATION_RELEASED);
  assert(ejs_native_operation_cancel(NULL) == 0);
  ejs_native_operation_release(NULL);
  assert(ejs_native_operation_complete(NULL) == false);

  // 4. EJSCoreByteBuffer testing
  EJSCoreByteBuffer buf;
  uint8_t buf_data[4] = {1, 2, 3, 4};
  ejs_byte_buffer_init(&buf, buf_data, 4, NULL, NULL, NULL);
  ejs_byte_buffer_secure_destroy(&buf);

  // Wipe testing
  uint8_t zero_data[4] = {1, 2, 3, 4};
  ejs_secure_wipe(zero_data, 4);
  assert(zero_data[0] == 0 && zero_data[1] == 0 && zero_data[2] == 0 && zero_data[3] == 0);

  // Metadata validation checks
  assert(ejs_native_validate_metadata(NULL, 10) == EJS_NATIVE_VALIDATION_NULL);
  
  EJSNativeABIMetadata meta;
  meta.abi_version = 999;
  meta.struct_size = 100;
  assert(ejs_native_validate_metadata(&meta, 10) == EJS_NATIVE_VALIDATION_ABI_VERSION);

  meta.abi_version = EJS_NATIVE_ABI_VERSION;
  meta.struct_size = 5;
  assert(ejs_native_validate_metadata(&meta, 10) == EJS_NATIVE_VALIDATION_STRUCT_SIZE);

  printf("test_uaf_prevention PASS\n");
}

// -------------------------------------------------------------
// Test Suit 11: test_eval_module
// -------------------------------------------------------------
static void test_eval_module(void) {
  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);

  // Null & invalid options module checks
  EJSCoreResult res = ejs_eval_module(context, NULL, "export const x = 42;", 20);
  assert(res.status == EJS_STATUS_ERROR);
  ejs_error_destroy(res.error);

  EJSCoreEvalOptions options;
  memset(&options, 0, sizeof(options));
  options.abi_version = EJS_RUNTIME_ABI_VERSION;
  options.struct_size = sizeof(options);
  options.kind = EJS_EVAL_KIND_SCRIPT;

  res = ejs_eval_module(context, &options, "export const x = 42;", 20);
  assert(res.status == EJS_STATUS_ERROR);
  ejs_error_destroy(res.error);

  res = ejs_eval_module(NULL, &options, "export const x = 42;", 20);
  assert(res.status == EJS_STATUS_ERROR);
  ejs_error_destroy(res.error);

  res = ejs_eval_script(NULL, "test.js", "1+1", 3);
  assert(res.status == EJS_STATUS_ERROR);
  ejs_error_destroy(res.error);

  options.kind = EJS_EVAL_KIND_MODULE;
  options.specifier = "math";
  options.source_url = "file:///math.js";

  res = ejs_eval_module(context, &options, "export const x = 42;", 20);
  if (res.status == EJS_STATUS_ERROR) {
    ejs_error_destroy(res.error);
  }

  options.specifier = "rejecting-module";
  options.source_url = "file:///rejecting-module.js";
  const char *rejecting_module = "await Promise.reject(new Error('tla-sentinel'));";
  res = ejs_eval_module(context, &options, rejecting_module, strlen(rejecting_module));
  assert(res.status == EJS_STATUS_ERROR);
  assert(strstr(ejs_error_message(res.error), "tla-sentinel") != NULL);
  ejs_error_destroy(res.error);

#ifdef EJS_ENGINE_QUICKJS_NG
  const char *dep_source =
      "globalThis.__depLoadCount = (globalThis.__depLoadCount || 0) + 1;\n"
      "export const dep = 41;\n"
      "export const meta = import.meta.url;\n";
  const char *cycle_a_source =
      "import { getB } from './cycle-b.js';\n"
      "export function getA() { return 'a'; }\n"
      "export function getPair() { return getA() + getB(); }\n";
  const char *cycle_b_source =
      "import { getA } from './cycle-a.js';\n"
      "export function getB() { return 'b'; }\n"
      "export function getPair() { return getA() + getB(); }\n";
  const char *bad_source = "export const = ;";
  EJSCoreModuleSource sources[] = {
    {
      "ejs-pkg://test/dep.js",
      "ejs-pkg://test/dep.js",
      dep_source,
      strlen(dep_source)
    },
    {
      "ejs-pkg://test/cycle-a.js",
      "ejs-pkg://test/cycle-a.js",
      cycle_a_source,
      strlen(cycle_a_source)
    },
    {
      "ejs-pkg://test/cycle-b.js",
      "ejs-pkg://test/cycle-b.js",
      cycle_b_source,
      strlen(cycle_b_source)
    },
    {
      "ejs-pkg://test/bad.js",
      "ejs-pkg://test/bad.js",
      bad_source,
      strlen(bad_source)
    }
  };

  res = ejs_context_register_module_sources(context, sources, sizeof(sources) / sizeof(sources[0]));
  assert(res.status == EJS_STATUS_OK);

  options.specifier = "source-table-main";
  options.source_url = "ejs-pkg://test/main.js";
  const char *source_table_main =
      "import { dep, meta } from './dep.js';\n"
      "import { dep as dep2 } from 'ejs-pkg://test/dep.js';\n"
      "if (dep !== 41 || dep2 !== 41) throw new Error('source table import failed');\n"
      "if (meta !== 'ejs-pkg://test/dep.js') throw new Error('import.meta.url failed: ' + meta);\n"
      "if (globalThis.__depLoadCount !== 1) throw new Error('module cache failed: ' + globalThis.__depLoadCount);\n";
  res = ejs_eval_module(context, &options, source_table_main, strlen(source_table_main));
  assert(res.status == EJS_STATUS_OK);

  options.source_url = "ejs-pkg://test/cycle-main.js";
  const char *cycle_main =
      "import { getPair } from './cycle-a.js';\n"
      "if (getPair() !== 'ab') throw new Error('cycle failed');\n";
  res = ejs_eval_module(context, &options, cycle_main, strlen(cycle_main));
  assert(res.status == EJS_STATUS_OK);

  options.source_url = "ejs-pkg://test/missing-main.js";
  const char *missing_main = "import './missing.js';";
  res = ejs_eval_module(context, &options, missing_main, strlen(missing_main));
  assert(res.status == EJS_STATUS_ERROR);
  assert(strstr(ejs_error_message(res.error), "could not resolve module './missing.js' from 'ejs-pkg://test/missing-main.js'") != NULL);
  ejs_error_destroy(res.error);

  options.source_url = "ejs-pkg://test/syntax-main.js";
  const char *syntax_main = "import './bad.js';";
  res = ejs_eval_module(context, &options, syntax_main, strlen(syntax_main));
  assert(res.status == EJS_STATUS_ERROR);
  assert((ejs_error_stack(res.error) != NULL &&
          strstr(ejs_error_stack(res.error), "ejs-pkg://test/bad.js") != NULL) ||
         strstr(ejs_error_message(res.error), "ejs-pkg://test/bad.js") != NULL);
  ejs_error_destroy(res.error);

  res = ejs_context_register_module_sources(context, NULL, 1);
  assert(res.status == EJS_STATUS_ERROR);
  ejs_error_destroy(res.error);
#endif

  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);

  printf("test_eval_module PASS\n");
}

// -------------------------------------------------------------
// Test Suit 12: test_coverage_booster
// -------------------------------------------------------------
static void my_buf_destroy(void *user_data, uint8_t *data, size_t size) {
  int *cnt = (int *)user_data;
  (*cnt)++;
}

static void my_buf_secure_destroy(void *user_data, uint8_t *data, size_t size) {
  int *cnt = (int *)user_data;
  (*cnt) += 10;
}

static void my_user_data_retain(void *user_data) {
  (void)user_data;
}

static int my_host_cancel(EJSCoreUserData user_data, EJSCoreHostOperation *operation) {
  (void)user_data;
  (void)operation;
  return 0;
}

static int my_op_cancel(void *user_data) {
  (void)user_data;
  return 0;
}

static void my_op_release(EJSCoreUserData user_data, EJSCoreHostOperation *operation) {
  (void)user_data;
  (void)operation;
}

static void my_op_destroy(void *user_data) {
  (void)user_data;
}

static void test_coverage_booster(void) {
  // 1. ejs_native_validate_operation_api & ejs_native_validate_host_api
  EJSCoreHostOperationAPI op_api;
  memset(&op_api, 0, sizeof(op_api));
  op_api.abi_version = EJS_NATIVE_ABI_VERSION;
  op_api.struct_size = sizeof(op_api);
  
  assert(ejs_native_validate_operation_api(&op_api) == EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK);
  
  op_api.cancel = my_host_cancel;
  op_api.release = my_op_release;
  assert(ejs_native_validate_operation_api(&op_api) == EJS_NATIVE_VALIDATION_OK);
  
  EJSCoreHostAPI host_api;
  memset(&host_api, 0, sizeof(host_api));
  host_api.abi_version = EJS_NATIVE_ABI_VERSION;
  host_api.struct_size = sizeof(host_api);
  host_api.operations = op_api;
  assert(ejs_native_validate_host_api(&host_api, EJS_NATIVE_PROVIDER_INVOKE) == EJS_NATIVE_VALIDATION_ABI_VERSION);
  
  host_api.invoke_api.abi_version = EJS_NATIVE_ABI_VERSION;
  host_api.invoke_api.struct_size = sizeof(host_api.invoke_api);
  host_api.invoke_api.invoke = NULL;
  assert(ejs_native_validate_host_api(&host_api, EJS_NATIVE_PROVIDER_INVOKE) == EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK);
  
  host_api.invoke_api.invoke = (void *)1;
  host_api.sync_invoke_api.abi_version = EJS_NATIVE_ABI_VERSION;
  host_api.sync_invoke_api.struct_size = sizeof(host_api.sync_invoke_api);
  host_api.sync_invoke_api.user_data = ejs_user_data_ref_null();
  host_api.sync_invoke_api.invoke_sync = NULL;
  assert(ejs_native_validate_host_api(&host_api, EJS_NATIVE_PROVIDER_INVOKE) == EJS_NATIVE_VALIDATION_OK);

  EJSCoreHostAPI partial_sync_tail = host_api;
  partial_sync_tail.struct_size = offsetof(EJSCoreHostAPI, sync_invoke_api) + sizeof(uint32_t);
  assert(ejs_native_validate_host_api(&partial_sync_tail, EJS_NATIVE_PROVIDER_INVOKE) == EJS_NATIVE_VALIDATION_STRUCT_SIZE);

  host_api.sync_invoke_api.user_data = ejs_user_data_ref_make(&host_api, my_user_data_retain, NULL);
  assert(ejs_native_validate_host_api(&host_api, EJS_NATIVE_PROVIDER_INVOKE) == EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK);
  host_api.sync_invoke_api.user_data = ejs_user_data_ref_null();

  EJSCoreHostAPI default_host_api = ejs_host_api_default_value();
  assert(default_host_api.abi_version == EJS_NATIVE_ABI_VERSION);
  assert(default_host_api.struct_size == sizeof(EJSCoreHostAPI));
  assert(default_host_api.operations.abi_version == EJS_NATIVE_ABI_VERSION);
  assert(default_host_api.operations.struct_size == sizeof(EJSCoreHostOperationAPI));
  assert(default_host_api.operations.cancel != NULL);
  assert(default_host_api.operations.release != NULL);
  assert(default_host_api.invoke_api.abi_version == EJS_NATIVE_ABI_VERSION);
  assert(default_host_api.invoke_api.struct_size == sizeof(EJSCoreHostInvokeAPI));
  assert(default_host_api.invoke_api.invoke == NULL);
  assert(default_host_api.sync_invoke_api.abi_version == EJS_NATIVE_ABI_VERSION);
  assert(default_host_api.sync_invoke_api.struct_size == sizeof(EJSCoreHostSyncInvokeAPI));
  assert(default_host_api.sync_invoke_api.invoke_sync == NULL);
  assert(ejs_native_validate_host_api(&default_host_api, 0) == EJS_NATIVE_VALIDATION_OK);
  assert(ejs_native_validate_host_api(&default_host_api, EJS_NATIVE_PROVIDER_INVOKE) == EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK);

  EJSCoreHostAPI reserved_host_api = ejs_host_api_default_value();
  reserved_host_api.invoke_api.invoke = custom_host_invoke;
  assert(ejs_native_validate_host_api(&reserved_host_api, EJS_NATIVE_PROVIDER_INVOKE) == EJS_NATIVE_VALIDATION_OK);
  reserved_host_api.flags = 1u;
  assert(ejs_native_validate_host_api(&reserved_host_api, EJS_NATIVE_PROVIDER_INVOKE) != EJS_NATIVE_VALIDATION_OK);
  reserved_host_api.flags = 0u;
  reserved_host_api.reserved[0] = (void *)0x1;
  assert(ejs_native_validate_host_api(&reserved_host_api, EJS_NATIVE_PROVIDER_INVOKE) != EJS_NATIVE_VALIDATION_OK);
  reserved_host_api.reserved[0] = NULL;
  reserved_host_api.operations.flags = 1u;
  assert(ejs_native_validate_host_api(&reserved_host_api, EJS_NATIVE_PROVIDER_INVOKE) != EJS_NATIVE_VALIDATION_OK);
  reserved_host_api.operations.flags = 0u;
  reserved_host_api.operations.reserved[0] = (void *)0x1;
  assert(ejs_native_validate_host_api(&reserved_host_api, EJS_NATIVE_PROVIDER_INVOKE) != EJS_NATIVE_VALIDATION_OK);
  reserved_host_api.operations.reserved[0] = NULL;
  reserved_host_api.invoke_api.flags = 1u;
  assert(ejs_native_validate_host_api(&reserved_host_api, EJS_NATIVE_PROVIDER_INVOKE) != EJS_NATIVE_VALIDATION_OK);
  reserved_host_api.invoke_api.flags = 0u;
  reserved_host_api.invoke_api.reserved[0] = (void *)0x1;
  assert(ejs_native_validate_host_api(&reserved_host_api, EJS_NATIVE_PROVIDER_INVOKE) != EJS_NATIVE_VALIDATION_OK);
  reserved_host_api.invoke_api.reserved[0] = NULL;
  reserved_host_api.sync_invoke_api.flags = 1u;
  assert(ejs_native_validate_host_api(&reserved_host_api, EJS_NATIVE_PROVIDER_INVOKE) != EJS_NATIVE_VALIDATION_OK);
  reserved_host_api.sync_invoke_api.flags = 0u;
  reserved_host_api.sync_invoke_api.reserved[0] = (void *)0x1;
  assert(ejs_native_validate_host_api(&reserved_host_api, EJS_NATIVE_PROVIDER_INVOKE) != EJS_NATIVE_VALIDATION_OK);

  host_api.sync_invoke_api.abi_version = EJS_NATIVE_ABI_VERSION;
  host_api.sync_invoke_api.struct_size = sizeof(host_api.sync_invoke_api);
  host_api.sync_invoke_api.invoke_sync = NULL;
  assert(ejs_native_validate_host_api(&host_api, EJS_NATIVE_PROVIDER_INVOKE | EJS_NATIVE_PROVIDER_SYNC_INVOKE) == EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK);

  host_api.sync_invoke_api.invoke_sync = custom_host_invoke_sync;
  assert(ejs_native_validate_host_api(&host_api, EJS_NATIVE_PROVIDER_INVOKE | EJS_NATIVE_PROVIDER_SYNC_INVOKE) == EJS_NATIVE_VALIDATION_OK);
  
  // 2. EJSCoreByteBuffer custom destroy & secure_destroy
  int destroy_cnt = 0;
  EJSCoreByteBuffer buf1;
  uint8_t data1[4] = {1, 2, 3, 4};
  ejs_byte_buffer_init(&buf1, data1, 4, &destroy_cnt, my_buf_destroy, my_buf_secure_destroy);
  ejs_byte_buffer_destroy(&buf1);
  assert(destroy_cnt == 1);
  
  EJSCoreByteBuffer buf2;
  uint8_t data2[4] = {5, 6, 7, 8};
  ejs_byte_buffer_init(&buf2, data2, 4, &destroy_cnt, my_buf_destroy, my_buf_secure_destroy);
  ejs_byte_buffer_secure_destroy(&buf2);
  assert(destroy_cnt == 11);

  EJSCoreByteBuffer null_buf1;
  ejs_byte_buffer_init(&null_buf1, NULL, 123, &destroy_cnt, my_buf_destroy, my_buf_secure_destroy);
  ejs_byte_buffer_destroy(&null_buf1);
  assert(destroy_cnt == 11);
  assert(null_buf1.data == NULL);
  assert(null_buf1.size == 0);
  assert(null_buf1.user_data == NULL);
  assert(null_buf1.destroy == NULL);
  assert(null_buf1.secure_destroy == NULL);

  EJSCoreByteBuffer null_buf2;
  ejs_byte_buffer_init(&null_buf2, NULL, 456, &destroy_cnt, my_buf_destroy, my_buf_secure_destroy);
  ejs_byte_buffer_secure_destroy(&null_buf2);
  assert(destroy_cnt == 11);
  assert(null_buf2.data == NULL);
  assert(null_buf2.size == 0);
  assert(null_buf2.user_data == NULL);
  assert(null_buf2.destroy == NULL);
  assert(null_buf2.secure_destroy == NULL);

  int zero_destroy_cnt = 0;
  EJSCoreByteBuffer zero_buf;
  ejs_byte_buffer_init(&zero_buf, NULL, 0, &zero_destroy_cnt, my_buf_destroy, NULL);
  ejs_byte_buffer_destroy(&zero_buf);
  assert(zero_destroy_cnt == 1);
  assert(zero_buf.data == NULL);
  assert(zero_buf.size == 0);
  assert(zero_buf.user_data == NULL);
  assert(zero_buf.destroy == NULL);
  assert(zero_buf.secure_destroy == NULL);

  EJSCoreByteBuffer zero_secure_buf;
  ejs_byte_buffer_init(&zero_secure_buf, NULL, 0, &zero_destroy_cnt, my_buf_destroy, my_buf_secure_destroy);
  ejs_byte_buffer_secure_destroy(&zero_secure_buf);
  assert(zero_destroy_cnt == 11);
  assert(zero_secure_buf.data == NULL);
  assert(zero_secure_buf.size == 0);
  assert(zero_secure_buf.user_data == NULL);
  assert(zero_secure_buf.destroy == NULL);
  assert(zero_secure_buf.secure_destroy == NULL);
  
  // 3. ejs_native_operation_user_data & double complete
  int user_marker = 100;
  EJSCoreHostOperation *op = ejs_native_operation_create(&user_marker, my_op_cancel, my_op_destroy);
  assert(op != NULL);
  assert(ejs_native_operation_user_data(op) == &user_marker);
  assert(ejs_native_operation_user_data(NULL) == NULL);
  
  bool comp1 = ejs_native_operation_complete(op);
  assert(comp1 == true);
  bool comp2 = ejs_native_operation_complete(op);
  assert(comp2 == false);
  
  // 4. JS Engine exceptions & stack trace coverage
  printf("BOOSTER STAGE 4.0\n");
  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);
  
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  
  const char *js_err = "throw new Error('test runtime error message');";
  EJSCoreResult res_err = ejs_eval_script(context, "test.js", js_err, strlen(js_err));
  assert(res_err.status == EJS_STATUS_ERROR);
  printf("EXCEPTION MESSAGE DEBUG: '%s'\n", ejs_error_message(res_err.error));
  assert(strcmp(ejs_error_message(res_err.error), "Error: test runtime error message") == 0);
  assert(ejs_error_stack(res_err.error) != NULL);
  ejs_error_destroy(res_err.error);
  
  // JS Promise Microtask exception coverage
  printf("BOOSTER STAGE 4.1\n");
  const char *js_micro_err = "Promise.resolve().then(() => { throw new Error('micro_err'); });";
  EJSCoreResult res_micro = ejs_eval_script(context, "test.js", js_micro_err, strlen(js_micro_err));
  assert(res_micro.status == EJS_STATUS_OK);
  printf("BOOSTER STAGE 4.2\n");
  ejs_runtime_drain_for_test(runtime);
  printf("BOOSTER STAGE 4.3\n");
  
  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);
  printf("BOOSTER STAGE 4.4\n");
  
  // 5. Host Invoke not registered / invalid context JS TypeError coverage
  printf("BOOSTER STAGE 5.0\n");
  EJSCoreRuntimeConfig config_nohost;
  memset(&config_nohost, 0, sizeof(config_nohost));
  config_nohost.abi_version = EJS_RUNTIME_ABI_VERSION;
  config_nohost.struct_size = sizeof(config_nohost);
  
  EJSCoreRuntime *runtime_nohost = ejs_runtime_create(&config_nohost);
  EJSCoreContext *context_nohost = ejs_context_create(runtime_nohost);
  
  const char *js_nohost = 
    "try {\n"
    "  __ejs_native__.invoke('mod', 'meth', 'arg');\n"
    "} catch(e) {\n"
    "  if (e instanceof Error) {\n"
    "    // caught correctly\n"
    "  }\n"
    "}\n";
  EJSCoreResult res_nohost = ejs_eval_script(context_nohost, "test.js", js_nohost, strlen(js_nohost));
  assert(res_nohost.status == EJS_STATUS_OK);
  printf("BOOSTER STAGE 5.1\n");
  
  ejs_context_destroy(context_nohost);
  ejs_runtime_destroy(runtime_nohost);
  printf("BOOSTER STAGE 5.2\n");
  
  // 6. Fake Host complete_next / complete_all & concurrent invoke链表 remove
  printf("BOOSTER STAGE 6.0\n");
  EJSFakeHost *fake_host = ejs_fake_host_create();
  EJSCoreHostAPI *fake_api = ejs_fake_host_api(fake_host);
  
  EJSCoreRuntimeConfig config_fake;
  memset(&config_fake, 0, sizeof(config_fake));
  config_fake.abi_version = EJS_RUNTIME_ABI_VERSION;
  config_fake.struct_size = sizeof(config_fake);
  
  EJSCoreRuntime *runtime_fake = ejs_runtime_create(&config_fake);
  EJSCoreContext *context_fake = ejs_context_create(runtime_fake);
  ejs_context_register_host(context_fake, fake_api);
  printf("BOOSTER STAGE 6.1\n");
  
  const char *js_fake_con = 
    "__ejs_native__.invoke('fs', 'read', 'path').then(res => {\n"
    "  // resolved fs\n"
    "});\n"
    "__ejs_native__.invoke('http', 'get', 'url').then(res => {\n"
    "  // resolved http\n"
    "});\n";
  EJSCoreResult res_fake = ejs_eval_script(context_fake, "test.js", js_fake_con, strlen(js_fake_con));
  assert(res_fake.status == EJS_STATUS_OK);
  printf("BOOSTER STAGE 6.2\n");
  
  assert(ejs_fake_host_pending_count(fake_host) == 2);
  
  ejs_fake_host_complete_next(fake_host);
  printf("BOOSTER STAGE 6.3\n");
  for (int i = 0; i < 100; ++i) {
    if (ejs_fake_host_pending_count(fake_host) == 1) {
      break;
    }
    usleep(2000);
  }
  assert(ejs_fake_host_pending_count(fake_host) == 1);
  printf("BOOSTER STAGE 6.4\n");
  
  ejs_fake_host_complete_all(fake_host);
  printf("BOOSTER STAGE 6.5\n");
  for (int i = 0; i < 100; ++i) {
    if (ejs_fake_host_pending_count(fake_host) == 0) {
      break;
    }
    usleep(2000);
  }
  assert(ejs_fake_host_pending_count(fake_host) == 0);
  printf("BOOSTER STAGE 6.6\n");
  
  // 额外给后台 Loop 线程一小会儿窗口期以彻底跑完任务收尾流程，避免 UAF
  usleep(50000);
  printf("BOOSTER STAGE 6.7\n");
  
  ejs_context_destroy(context_fake);
  printf("BOOSTER STAGE 6.8\n");
  ejs_runtime_destroy(runtime_fake);
  printf("BOOSTER STAGE 6.9\n");
  ejs_fake_host_destroy(fake_host);
  
  printf("test_coverage_booster PASS\n");
}

// -------------------------------------------------------------
// Test Suit 13: test_whitebox_precision_coverage
// -------------------------------------------------------------
static void test_whitebox_precision_coverage(void) {
  // 1. ejs_fake_host_destroy 时 pending 不为空的分支
  {
    EJSFakeHost *fake_host = ejs_fake_host_create();
    EJSCoreHostAPI *fake_api = ejs_fake_host_api(fake_host);

    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);
    ejs_context_register_host(context, fake_api);

    const char *js_code = "__ejs_native__.invoke('fs', 'read', 'path');";
    EJSCoreResult res = ejs_eval_script(context, "test.js", js_code, strlen(js_code));
    assert(res.status == EJS_STATUS_OK);
    ejs_runtime_drain_for_test(runtime);

    assert(ejs_fake_host_pending_count(fake_host) == 1);

    // 直接销毁 fake_host 触发 while (host->pending != NULL) 循环中的 release 分支
    ejs_fake_host_destroy(fake_host);
    ejs_context_register_host(context, NULL);
    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
  }

  // 2. ejs_fake_host 中 slot = &(*slot)->next; 链表移动分支
  {
    EJSFakeHost *fake_host = ejs_fake_host_create();
    EJSCoreHostAPI *fake_api = ejs_fake_host_api(fake_host);

    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);
    ejs_context_register_host(context, fake_api);

    const char *js_code = 
      "__ejs_native__.invoke('fs', 'read_first', 'path1');\n"
      "__ejs_native__.invoke('fs', 'read_second', 'path2');\n";
    EJSCoreResult res = ejs_eval_script(context, "test.js", js_code, strlen(js_code));
    assert(res.status == EJS_STATUS_OK);
    ejs_runtime_drain_for_test(runtime);

    assert(ejs_fake_host_pending_count(fake_host) == 2);

    // 获取 pending 链表。因为是后插，所以 read_second 在头部，read_first 在尾部。
    // 我们如果直接 release 首个发起的 op (read_first，在尾部)，就会走到 slot = &(*slot)->next
    EJSFakePending *first_pending = NULL;
    EJSFakePending *curr = fake_host->pending;
    while (curr != NULL) {
      if (strcmp(curr->method_id, "read_first") == 0) {
        first_pending = curr;
        break;
      }
      curr = curr->next;
    }
    assert(first_pending != NULL);
    ejs_native_operation_cancel(first_pending->operation);

    assert(ejs_fake_host_pending_count(fake_host) == 1);

    ejs_fake_host_destroy(fake_host);
    ejs_context_register_host(context, NULL);
    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
  }

  // 3. ejs_fake_host_complete_next 边界与 canceled 分支与 module_id else 分支
  {
    EJSFakeHost *fake_host = ejs_fake_host_create();
    ejs_fake_host_complete_next(NULL);
    ejs_fake_host_complete_next(fake_host); // pending 为 NULL

    EJSCoreHostAPI *fake_api = ejs_fake_host_api(fake_host);

    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);
    ejs_context_register_host(context, fake_api);

    // a. canceled 分支
    const char *js_code_cancel = "__ejs_native__.invoke('fs', 'read_cancel', 'path');";
    EJSCoreResult res = ejs_eval_script(context, "test.js", js_code_cancel, strlen(js_code_cancel));
    assert(res.status == EJS_STATUS_OK);
    ejs_runtime_drain_for_test(runtime);

    assert(ejs_fake_host_pending_count(fake_host) == 1);
    fake_host->pending->canceled = true;
    ejs_fake_host_complete_next(fake_host); // 触发 canceled 分支中的 aborted
    ejs_runtime_drain_for_test(runtime);
    assert(ejs_fake_host_pending_count(fake_host) == 0);

    // b. db module (else 分支)
    const char *js_code_db = "__ejs_native__.invoke('db', 'query', 'sql');";
    res = ejs_eval_script(context, "test.js", js_code_db, strlen(js_code_db));
    assert(res.status == EJS_STATUS_OK);
    ejs_runtime_drain_for_test(runtime);
    assert(ejs_fake_host_pending_count(fake_host) == 1);
    ejs_fake_host_complete_next(fake_host); // 触发 else 分支

    ejs_fake_host_destroy(fake_host);
    ejs_context_register_host(context, NULL);
    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
  }

  // 4. ejs_runtime_loop_pump & loop_destroy 空白覆盖
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSRuntimeLoop *loop = runtime->runtime_loop;

    ejs_runtime_loop_destroy(NULL);


    EJSCoreResult pump_res = ejs_runtime_loop_pump(NULL, 10);
    assert(pump_res.status == EJS_STATUS_ERROR);
    ejs_error_destroy(pump_res.error);

    pump_res = ejs_runtime_loop_pump(loop, 0);
    assert(pump_res.status == EJS_STATUS_OK);

    // drain loop 失败分支
    runtime->runtime_loop = NULL;
    EJSCoreResult run_res = ejs_runtime_drain_for_test(runtime);
    assert(run_res.status == EJS_STATUS_ERROR);
    ejs_error_destroy(run_res.error);
    runtime->runtime_loop = loop;

    ejs_runtime_destroy(runtime);
  }

  // 5. ejs_engine_quickjs_ng.c 中的 JS_GetException 抛出 undefined 的分支
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);

    const char *js_err = "throw undefined;";
    EJSCoreResult res_err = ejs_eval_script(context, "test.js", js_err, strlen(js_err));
    assert(res_err.status == EJS_STATUS_ERROR);
    ejs_error_destroy(res_err.error);

    js_err = "throw null;";
    res_err = ejs_eval_script(context, "test.js", js_err, strlen(js_err));
    assert(res_err.status == EJS_STATUS_ERROR);
    ejs_error_destroy(res_err.error);

    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
  }

  // 6. typed array 带有非 ArrayBuffer 类型的 "buffer" 属性的分支
  {
    EJSFakeHost *fake_host = ejs_fake_host_create();
    EJSCoreHostAPI *fake_api = ejs_fake_host_api(fake_host);

    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);
    ejs_context_register_host(context, fake_api);

    const char *js_buf = 
      "try { __ejs_native__.invoke('mod', 'meth', { buffer: 123 }); } catch (e) {}\n"
      "try { __ejs_native__.invoke('mod', 'meth', { buffer: {} }); } catch (e) {}\n"
      "try { __ejs_native__.invoke('mod', 'meth', { a: 1 }); } catch (e) {}\n";
    EJSCoreResult res = ejs_eval_script(context, "test.js", js_buf, strlen(js_buf));
    assert(res.status == EJS_STATUS_OK);

    ejs_fake_host_destroy(fake_host);
    ejs_context_register_host(context, NULL);
    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
  }

  // 7. invoke state 移除时非首部分支 (state->prev != NULL)
  {
    EJSFakeHost *fake_host = ejs_fake_host_create();
    EJSCoreHostAPI *fake_api = ejs_fake_host_api(fake_host);

    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);
    ejs_context_register_host(context, fake_api);

    const char *js_fake_con = 
      "__ejs_native__.invoke('fs', 'read_first', 'path1').then(res => {\n"
      "  __ejs_native__.invoke('test', 'report', 'first_resolved');\n"
      "});\n"
      "__ejs_native__.invoke('fs', 'read_second', 'path2').then(res => {\n"
      "  __ejs_native__.invoke('test', 'report', 'second_resolved');\n"
      "});\n";
    EJSCoreResult res_fake = ejs_eval_script(context, "test.js", js_fake_con, strlen(js_fake_con));
    assert(res_fake.status == EJS_STATUS_OK);
    ejs_runtime_drain_for_test(runtime);

    assert(ejs_fake_host_pending_count(fake_host) == 2);

    // 我们先完成 read_first，因为 read_first 先创建，在 invoke_list 中位于较后位置，
    // 即其 state->prev != NULL。这会覆盖 state->prev->next = state->next;
    EJSFakePending *first_pending = NULL;
    EJSFakePending *curr = fake_host->pending;
    while (curr != NULL) {
      if (strcmp(curr->method_id, "read_first") == 0) {
        first_pending = curr;
        break;
      }
      curr = curr->next;
    }
    assert(first_pending != NULL);

    EJSCoreHostError success_err;
    memset(&success_err, 0, sizeof(success_err));
    success_err.abi_version = EJS_NATIVE_ABI_VERSION;
    success_err.struct_size = sizeof(success_err);
    success_err.code = EJS_ERROR_NONE;
    EJSCoreByteView empty_view = {NULL, 0};

    first_pending->completion(first_pending->completion_data, empty_view, &success_err);

    // 完成它
    (void)ejs_native_operation_complete(first_pending->operation);

    ejs_runtime_drain_for_test(runtime);

    ejs_fake_host_destroy(fake_host);
    ejs_context_register_host(context, NULL);
    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
  }

  // 8. 异步 invoke 中空 result 且 error_none 时，返回 JS_UNDEFINED 分支
  {
    memset(&g_test_host, 0, sizeof(g_test_host));
    EJSCoreHostAPI api;
    init_custom_host_api(&api, &g_test_host);

    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);
    ejs_context_register_host(context, &api);

    const char *js_empty = 
      "__ejs_native__.invoke('async', 'empty_res', 'arg').then(res => {\n"
      "  if (res === undefined) {\n"
      "    __ejs_native__.invoke('test', 'async_result', 'empty_ok');\n"
      "  }\n"
      "});\n";
    EJSCoreResult res = ejs_eval_script(context, "test.js", js_empty, strlen(js_empty));
    assert(res.status == EJS_STATUS_OK);
    ejs_runtime_drain_for_test(runtime);

    assert(g_test_host.last_completion != NULL);

    EJSCoreByteView empty_res = {NULL, 0};
    EJSCoreHostError success_err;
    memset(&success_err, 0, sizeof(success_err));
    success_err.abi_version = EJS_NATIVE_ABI_VERSION;
    success_err.struct_size = sizeof(success_err);
    success_err.code = EJS_ERROR_NONE;

    g_test_host.last_completion(g_test_host.last_completion_data, empty_res, &success_err);

    ejs_runtime_drain_for_test(runtime);

    assert(strcmp((char *)g_test_host.last_payload, "empty_ok") == 0);

    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
  }

  // 9. 调用 invoke 时 Opaque 缺失的分支
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);

    ejs_engine_context_associate_runtime_context(context->engine_context, NULL);

    const char *js_op = 
      "try {\n"
      "  __ejs_native__.invoke('mod', 'meth', 'arg');\n"
      "} catch (e) {\n"
      "  if (e.message.indexOf('invalid context') >= 0) {\n"
      "    // ok\n"
      "  }\n"
      "}\n";
    EJSCoreResult res = ejs_eval_script(context, "test.js", js_op, strlen(js_op));
    assert(res.status == EJS_STATUS_OK);

    ejs_engine_context_associate_runtime_context(context->engine_context, context);

    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
  }

#ifdef EJS_RUNTIME_LOOP_LIBUV
  // 10. timer 销毁非首部 timer 的链表移动分支 (curr = curr->next)
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);

    const char *js_timer = 
      "const id1 = __ejs_native__.timers.create(100, 0, () => {});\n"
      "const id2 = __ejs_native__.timers.create(100, 0, () => {});\n"
      "__ejs_native__.timers.destroy(id1);\n" // 销毁先创建 of id1，处于链表后部
      "__ejs_native__.timers.destroy(9999);\n"; // 销毁不存在 of id 走完循环
    EJSCoreResult res = ejs_eval_script(context, "test.js", js_timer, strlen(js_timer));
    assert(res.status == EJS_STATUS_OK);

    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
  }

  // 11. timer 触发前 Opaque 缺失的分支 (return;) & JS exception 分支
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);

    // a. Opaque 缺失分支
    const char *js_timer_op = 
      "__ejs_native__.timers.create(2, 0, () => {\n"
      "  // should not execute due to missing opaque\n"
      "});\n";
    EJSCoreResult res = ejs_eval_script(context, "test.js", js_timer_op, strlen(js_timer_op));
    assert(res.status == EJS_STATUS_OK);
    ejs_runtime_drain_for_test(runtime);

    ejs_engine_context_associate_runtime_context(context->engine_context, NULL);
    usleep(3000);
    // 泵送循环，timer 会触发但因为 opaque 为 NULL 会直接 return;
    ejs_runtime_drain_for_test(runtime);

    ejs_engine_context_associate_runtime_context(context->engine_context, context);

    // b. JS exception 分支
    const char *js_timer_exc = 
      "__ejs_native__.timers.create(1, 0, () => {\n"
      "  throw new Error('timer error');\n"
      "});\n";
    res = ejs_eval_script(context, "test.js", js_timer_exc, strlen(js_timer_exc));
    assert(res.status == EJS_STATUS_OK);

    usleep(2000);
    ejs_runtime_drain_for_test(runtime); // 触发异常分支并且 free(exception)

    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
  }

  // 12. timer 创/毁参数校验分支
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);

    const char *js_timer_err = 
      "try { __ejs_native__.timers.create(1, 0); } catch(e) {}\n"
      "try { __ejs_native__.timers.create(Symbol('delay'), 0, () => {}); } catch(e) {}\n"
      "try { __ejs_native__.timers.create(1, Symbol('repeat'), () => {}); } catch(e) {}\n"
      "try { __ejs_native__.timers.destroy(); } catch(e) {}\n"
      "try { __ejs_native__.timers.destroy(Symbol('id')); } catch(e) {}\n";
    EJSCoreResult res = ejs_eval_script(context, "test.js", js_timer_err, strlen(js_timer_err));
    assert(res.status == EJS_STATUS_OK);

    // timers create/destroy Opaque 缺失分支
    ejs_engine_context_associate_runtime_context(context->engine_context, NULL);
    const char *js_timer_op_err = 
      "try { __ejs_native__.timers.create(1, 0, () => {}); } catch(e) {}\n"
      "try { __ejs_native__.timers.destroy(1); } catch(e) {}\n";
    res = ejs_eval_script(context, "test.js", js_timer_op_err, strlen(js_timer_op_err));
    assert(res.status == EJS_STATUS_OK);
    ejs_engine_context_associate_runtime_context(context->engine_context, context);

    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
  }
#endif

  // 13. ejs_context_create 失败分支 (Line 93-95)
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    void *saved = runtime->engine_runtime;
    
    // 强行把 engine_runtime 置空，使 ejs_engine_context_create 返回 NULL
    runtime->engine_runtime = NULL;
    EJSCoreContext *context = ejs_context_create(runtime);
    assert(context == NULL);

    runtime->engine_runtime = saved;
    ejs_runtime_destroy(runtime);
  }

  // 14. API 防御性分支
  {
    ejs_fake_host_destroy(NULL);
    assert(ejs_fake_host_api(NULL) == NULL);
    assert(ejs_runtime_create(NULL) == NULL);
    assert(ejs_context_create(NULL) == NULL);
    ejs_runtime_destroy(NULL);
    ejs_context_destroy(NULL);
  }

  // ==============================================================
  // 额外追加的极致物理覆盖率冲刺测试集
  // ==============================================================
  {
    // 1. ejs_fake_host_api(NULL) 以及 unlink_pending 分支
    ejs_fake_host_destroy(NULL);
    assert(ejs_fake_host_api(NULL) == NULL);

    // 2. unlink_pending 的 host == NULL 以及 slot 查找覆盖
    EJSFakePending dummy_pending;
    memset(&dummy_pending, 0, sizeof(dummy_pending));
    // 这是为了覆盖 ejs_fake_unlink_pending 里的 if (host == NULL) return;
    dummy_pending.host = NULL; 
    
#ifdef EJS_TEST
    // 3. invoke module_id/method_id 强转 C 字符串 OOM / 失败拦截测试 (ejs_test_inject_engine_error == 10)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      EJSFakeHost *fake_host = ejs_fake_host_create();
      EJSCoreHostAPI *fake_api = ejs_fake_host_api(fake_host);

      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      EJSCoreContext *context = ejs_context_create(runtime);
      ejs_context_register_host(context, fake_api);

      extern int ejs_test_inject_engine_error;
      ejs_test_inject_engine_error = 10;
      const char *js_inv_null = "try { __ejs_native__.invoke('mod', 'meth', 'arg'); } catch(e) {}";
      EJSCoreResult eval_res = ejs_eval_script(context, "test.js", js_inv_null, strlen(js_inv_null));
      assert(eval_res.status == EJS_STATUS_OK);
      ejs_test_inject_engine_error = 0;

      // 4. promise 异常捕获覆盖 (ejs_test_inject_engine_error == 9)
      ejs_test_inject_engine_error = 9;
      const char *js_inv_promise_fail = "try { __ejs_native__.invoke('mod', 'meth', 'arg'); } catch(e) {}";
      eval_res = ejs_eval_script(context, "test.js", js_inv_promise_fail, strlen(js_inv_promise_fail));
      assert(eval_res.status == EJS_STATUS_OK);
      ejs_test_inject_engine_error = 0;

      // 5. invoke state OOM (ejs_test_inject_engine_error == 8)
      ejs_test_inject_engine_error = 8;
      const char *js_inv_state_oom = "try { __ejs_native__.invoke('mod', 'meth', 'arg'); } catch(e) {}";
      eval_res = ejs_eval_script(context, "test.js", js_inv_state_oom, strlen(js_inv_state_oom));
      assert(eval_res.status == EJS_STATUS_OK);
      ejs_test_inject_engine_error = 0;

      // 6. timers loop 为 NULL 失败路径 (ejs_test_inject_engine_error == 12)
      ejs_test_inject_engine_error = 12;
      const char *js_timer_loop_err = "try { __ejs_native__.timers.create(1, 0, () => {}); } catch(e) {}";
      eval_res = ejs_eval_script(context, "test.js", js_timer_loop_err, strlen(js_timer_loop_err));
      assert(eval_res.status == EJS_STATUS_OK);
      ejs_test_inject_engine_error = 0;

      // 7. timers init 失败路径 (ejs_test_inject_engine_error == 13)
      ejs_test_inject_engine_error = 13;
      const char *js_timer_init_err = "try { __ejs_native__.timers.create(1, 0, () => {}); } catch(e) {}";
      eval_res = ejs_eval_script(context, "test.js", js_timer_init_err, strlen(js_timer_init_err));
      assert(eval_res.status == EJS_STATUS_OK);
      ejs_test_inject_engine_error = 0;

      // 8. timers start 失败路径 (ejs_test_inject_engine_error == 14)
      ejs_test_inject_engine_error = 14;
      const char *js_timer_start_err = "try { __ejs_native__.timers.create(1, 0, () => {}); } catch(e) {}";
      eval_res = ejs_eval_script(context, "test.js", js_timer_start_err, strlen(js_timer_start_err));
      assert(eval_res.status == EJS_STATUS_OK);
      ejs_test_inject_engine_error = 0;

      // 9. ejs_engine_run_jobs 失败分支 (ejs_test_inject_engine_error == 11)
      ejs_test_inject_engine_error = 11;
      EJSCoreResult run_res = ejs_runtime_drain_for_test(runtime);
      assert(run_res.status == EJS_STATUS_ERROR);
      ejs_error_destroy(run_res.error);
      ejs_test_inject_engine_error = 0;

      ejs_context_destroy(context);
      ejs_runtime_destroy(runtime);
      ejs_fake_host_destroy(fake_host);
    }

    // 10. runtime engine calloc 失败注入 (ejs_test_inject_engine_error == 1)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_engine_error;
      ejs_test_inject_engine_error = 1;
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_engine_error = 0;

      // JS_NewRuntime 失败注入 (ejs_test_inject_engine_error == 2)
      ejs_test_inject_engine_error = 2;
      runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_engine_error = 0;
    }

    // 11. context engine context calloc 失败注入 (ejs_test_inject_engine_error == 3)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime != NULL);

      extern int ejs_test_inject_engine_error;
      ejs_test_inject_engine_error = 3;
      EJSCoreContext *context = ejs_context_create(runtime);
      assert(context == NULL);
      ejs_test_inject_engine_error = 0;

      // JS_NewContext 失败注入 (ejs_test_inject_engine_error == 4)
      ejs_test_inject_engine_error = 4;
      context = ejs_context_create(runtime);
      assert(context == NULL);
      ejs_test_inject_engine_error = 0;

      // core bindings 注册失败注入 (ejs_test_inject_engine_error == 17)
      ejs_test_inject_engine_error = 17;
      context = ejs_context_create(runtime);
      assert(context == NULL);
      ejs_test_inject_engine_error = 0;

      ejs_runtime_destroy(runtime);
    }

    // 11b. core bindings 逐阶段安装失败注入 (ejs_test_inject_engine_error == 18..28)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime != NULL);

      extern int ejs_test_inject_engine_error;
      for (int injection = 18; injection <= 28; injection++) {
        ejs_test_inject_engine_error = injection;
        EJSCoreContext *context = ejs_context_create(runtime);
        assert(context == NULL);
        ejs_test_inject_engine_error = 0;
      }

      ejs_runtime_destroy(runtime);
    }

    // 12. runtime calloc 失败注入 (ejs_test_inject_runtime_error == 1)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_runtime_error;
      ejs_test_inject_runtime_error = 1;
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_runtime_error = 0;
    }

    // 13. runtime loop create 失败注入 (ejs_test_inject_runtime_error == 2)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_runtime_error;
      ejs_test_inject_runtime_error = 2;
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_runtime_error = 0;
    }

    // 14. engine runtime create 失败注入 (ejs_test_inject_runtime_error == 3)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_runtime_error;
      ejs_test_inject_runtime_error = 3;
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_runtime_error = 0;
    }

    // 14b. runtime loop start 失败注入 (ejs_test_inject_runtime_error == 29)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_runtime_error;
      ejs_test_inject_runtime_error = 29;
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_runtime_error = 0;
    }

    // 15. EJSCoreContext calloc 失败注入 (ejs_test_inject_runtime_error == 4)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime != NULL);

      extern int ejs_test_inject_runtime_error;
      ejs_test_inject_runtime_error = 4;
      EJSCoreContext *context = ejs_context_create(runtime);
      assert(context == NULL);
      ejs_test_inject_runtime_error = 0;

      ejs_runtime_destroy(runtime);
    }

    // 15b. destroy 降级路径：helper 上下文分配失败 / 线程创建失败
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_runtime_error;
      int completion_count = 0;

      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime != NULL);
      ejs_test_inject_runtime_error = 6;
      ejs_runtime_destroy_with_completion(runtime, test_stop_completion, &completion_count);
      assert(completion_count == 1);
      ejs_test_inject_runtime_error = 0;

      runtime = ejs_runtime_create(&config);
      assert(runtime != NULL);
      ejs_test_inject_runtime_error = 7;
      ejs_runtime_destroy_with_completion(runtime, test_stop_completion, &completion_count);
      assert(completion_count == 2);
      ejs_test_inject_runtime_error = 0;
    }

    // 16. libuv runtime loop calloc 失败 (ejs_test_inject_runtime_error == 21)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_runtime_error;
      ejs_test_inject_runtime_error = 21;
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_runtime_error = 0;
    }

    // 17. uv_loop_init 失败 (ejs_test_inject_runtime_error == 22)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_runtime_error;
      ejs_test_inject_runtime_error = 22;
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_runtime_error = 0;
    }

    // 18. uv_async_init 失败 (ejs_test_inject_runtime_error == 23)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_runtime_error;
      ejs_test_inject_runtime_error = 23;
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_runtime_error = 0;
    }

    // 19. uv_prepare_init 失败 (ejs_test_inject_runtime_error == 24)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_runtime_error;
      ejs_test_inject_runtime_error = 24;
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_runtime_error = 0;
    }

    // 20. uv_prepare_start 失败 (ejs_test_inject_runtime_error == 25)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_runtime_error;
      ejs_test_inject_runtime_error = 25;
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_runtime_error = 0;
    }

    // 21. uv_check_init 失败 (ejs_test_inject_runtime_error == 26)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_runtime_error;
      ejs_test_inject_runtime_error = 26;
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_runtime_error = 0;
    }

    // 22. uv_check_start 失败 (ejs_test_inject_runtime_error == 27)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      extern int ejs_test_inject_runtime_error;
      ejs_test_inject_runtime_error = 27;
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime == NULL);
      ejs_test_inject_runtime_error = 0;
    }

    // 23. EJSFakePending 分配失败 (ejs_test_inject_fake_host_error == 1)
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      EJSFakeHost *fake_host = ejs_fake_host_create();
      EJSCoreHostAPI *fake_api = ejs_fake_host_api(fake_host);

      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      EJSCoreContext *context = ejs_context_create(runtime);
      ejs_context_register_host(context, fake_api);

      extern int ejs_test_inject_fake_host_error;
      ejs_test_inject_fake_host_error = 1;
      const char *js_code = "try { __ejs_native__.invoke('fs', 'read', 'path'); } catch(e) {}";
      EJSCoreResult eval_res = ejs_eval_script(context, "test.js", js_code, strlen(js_code));
      assert(eval_res.status == EJS_STATUS_OK);
      ejs_runtime_drain_for_test(runtime);
      assert(atomic_load(&runtime->pending_host_operation_count) == 0);
      assert(ejs_fake_host_pending_count(fake_host) == 0);
      ejs_test_inject_fake_host_error = 0;

      // 24. pending->operation 创建失败 (ejs_test_inject_fake_host_error == 2)
      ejs_test_inject_fake_host_error = 2;
      eval_res = ejs_eval_script(context, "test.js", js_code, strlen(js_code));
      assert(eval_res.status == EJS_STATUS_OK);
      ejs_runtime_drain_for_test(runtime);
      assert(atomic_load(&runtime->pending_host_operation_count) == 0);
      assert(ejs_fake_host_pending_count(fake_host) == 0);
      ejs_test_inject_fake_host_error = 0;

      ejs_context_destroy(context);
      ejs_runtime_destroy(runtime);
      ejs_fake_host_destroy(fake_host);
    }

    // 25. EJSFakeHost calloc 失败 (ejs_test_inject_fake_host_error == 3)
    {
      extern int ejs_test_inject_fake_host_error;
      ejs_test_inject_fake_host_error = 3;
      EJSFakeHost *fake_host = ejs_fake_host_create();
      assert(fake_host == NULL);
      ejs_test_inject_fake_host_error = 0;
    }
#endif

    // 26. loop pump iteration break 覆盖以及 wakeup 触发覆盖
    {
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      assert(runtime != NULL);

      // 覆盖 loop pump 在空闲时的 break
      ejs_runtime_loop_pump(runtime->runtime_loop, 10u);

#ifdef EJS_RUNTIME_LOOP_LIBUV
      // 覆盖 ejs_runtime_loop_on_wakeup 回调通过 uv_async_send
      ejs_runtime_loop_trigger_wakeup_test(runtime->runtime_loop);
      ejs_runtime_loop_pump(runtime->runtime_loop, 10u);
#endif

      ejs_runtime_destroy(runtime);
    }

    // 27. 引擎无效入参防御性分支、get_opaque、name 覆盖
    {
      assert(ejs_eval_script(NULL, NULL, NULL, 0).status == EJS_STATUS_ERROR);
      assert(ejs_eval_module(NULL, NULL, NULL, 0).status == EJS_STATUS_ERROR);
      assert(ejs_runtime_drain_for_test(NULL).status == EJS_STATUS_ERROR);
      
      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);
      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      EJSCoreContext *context = ejs_context_create(runtime);

      void *opq = ejs_engine_context_retrieve_runtime_context(context->engine_context);
      assert(opq == context);
      
      assert(ejs_engine_context_retrieve_runtime_context(NULL) == NULL);

      const char *eng_name = ejs_engine_name();
      assert(eng_name != NULL);

      ejs_context_destroy(context);
      ejs_runtime_destroy(runtime);
    }
  }

  printf("test_whitebox_precision_coverage PASS\n");
}

// -------------------------------------------------------------
// Test Suit 15: High-intensity and concurrency verification
// -------------------------------------------------------------
static void *interrupt_trigger_thread(void *arg) {
  EJSCoreRuntime *runtime = (EJSCoreRuntime *)arg;
  usleep(30 * 1000); // 30ms
  ejs_request_interrupt(runtime);
  return NULL;
}

static void test_infinite_loop_interrupt(void) {
  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);

  pthread_t thread;
  pthread_create(&thread, NULL, interrupt_trigger_thread, runtime);

  // 运行无限死循环脚本
  EJSCoreResult res = ejs_eval_script(context, "infinite.js", "for(;;);", 8);
  // 由于被中断，它应该返回 ERROR 状态
  assert(res.status == EJS_STATUS_ERROR);
  ejs_error_destroy(res.error);

  pthread_join(thread, NULL);

  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);
  printf("test_infinite_loop_interrupt PASS\n");
}

static void test_abi_validation(void) {
  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);

  // 1. ABI 版本不匹配的 host api
  EJSCoreHostAPI invalid_api;
  memset(&invalid_api, 0, sizeof(invalid_api));
  invalid_api.abi_version = 0xDEADC0DEu; // 错误的 abi version
  invalid_api.struct_size = sizeof(invalid_api);

  ejs_context_register_host(context, &invalid_api);
  // 应该被优雅拒绝，拒绝后 host_api 设为 NULL
  assert(context->host == NULL);

  // 2. Struct size 不匹配的 host api
  memset(&invalid_api, 0, sizeof(invalid_api));
  invalid_api.abi_version = EJS_NATIVE_ABI_VERSION;
  invalid_api.struct_size = 12; // 错误的 struct size

  ejs_context_register_host(context, &invalid_api);
  assert(context->host == NULL);

  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);
  printf("test_abi_validation PASS\n");
}

static void test_multi_context_batch_destruction(void) {
  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);

  // 批量创建 20 个 Context
  for (int i = 0; i < 20; i++) {
    EJSCoreContext *ctx = ejs_context_create(runtime);
    assert(ctx != NULL);
  }

  // 直接销毁 runtime，期待其内部自动释放所有 context
  ejs_runtime_destroy(runtime);
  printf("test_multi_context_batch_destruction PASS\n");
}

typedef struct {
  EJSCoreHostAPI api;
  _Atomic(bool) context_destroyed;
} TestUAFHost;

typedef struct {
  EJSCoreInvokeCompletion completion;
  void *completion_data;
  EJSCoreHostOperation *operation;
} UAFThreadPayload;

static void *uaf_completion_runner_thread(void *arg) {
  UAFThreadPayload *pl = (UAFThreadPayload *)arg;
  // 模拟一点延迟，使得它和销毁线程正好交织
  usleep(rand() % 100);

  EJSCoreHostError err;
  memset(&err, 0, sizeof(err));
  err.abi_version = EJS_NATIVE_ABI_VERSION;
  err.struct_size = sizeof(err);
  err.code = EJS_ERROR_NONE;

  EJSCoreByteView result;
  result.data = (const uint8_t *)"uaf_test_ok";
  result.size = 11;

  // 触发回调
  pl->completion(pl->completion_data, result, &err);
  ejs_native_operation_complete(pl->operation);
  free(pl);
  return NULL;
}

static EJSCoreHostOperation *uaf_host_invoke(EJSCoreUserData user_data,
                                         const char *module_id,
                                         const char *method_id,
                                         EJSCoreByteView payload,
                                         EJSCoreByteView transfer_buffer,
                                         EJSCoreInvokeCompletion completion,
                                         void *completion_data) {
  (void)user_data; (void)module_id; (void)method_id; (void)payload; (void)transfer_buffer;

  UAFThreadPayload *pl = (UAFThreadPayload *)calloc(1, sizeof(UAFThreadPayload));
  if (pl != NULL) {
    EJSCoreHostOperation *op = ejs_native_operation_create(NULL, NULL, NULL);
    if (op == NULL) {
      free(pl);
      return NULL;
    }

    pl->completion = completion;
    pl->completion_data = completion_data;
    pl->operation = op;

    pthread_t th;
    if (pthread_create(&th, NULL, uaf_completion_runner_thread, pl) != 0) {
      ejs_native_operation_release(op);
      ejs_native_operation_complete(op);
      free(pl);
      return NULL;
    }
    pthread_detach(th);
    return op;
  }

  return NULL;
}

static void test_high_concurrency_uaf(void) {
  TestUAFHost uaf_host;
  memset(&uaf_host, 0, sizeof(uaf_host));
  uaf_host.api.abi_version = EJS_NATIVE_ABI_VERSION;
  uaf_host.api.struct_size = sizeof(uaf_host.api);
  uaf_host.api.user_data = ejs_user_data_ref_make(&uaf_host, NULL, NULL);
  uaf_host.api.operations = ejs_native_operation_api();
  uaf_host.api.operations.user_data = ejs_user_data_ref_make(&uaf_host, NULL, NULL);

  uaf_host.api.invoke_api.abi_version = EJS_NATIVE_ABI_VERSION;
  uaf_host.api.invoke_api.struct_size = sizeof(uaf_host.api.invoke_api);
  uaf_host.api.invoke_api.user_data = ejs_user_data_ref_make(&uaf_host, NULL, NULL);
  uaf_host.api.invoke_api.invoke = uaf_host_invoke;
  uaf_host.api.sync_invoke_api.abi_version = EJS_NATIVE_ABI_VERSION;
  uaf_host.api.sync_invoke_api.struct_size = sizeof(uaf_host.api.sync_invoke_api);
  uaf_host.api.sync_invoke_api.user_data = ejs_user_data_ref_null();
  uaf_host.api.sync_invoke_api.invoke_sync = NULL;

  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  ejs_context_register_host(context, &uaf_host.api);

  // 启动大量并发的 JS 异步 invoke 任务
  const char *js_code = 
    "for (let i = 0; i < 100; i++) {\n"
    "  __ejs_native__.invoke('uaf', 'test', 'payload' + i);\n"
    "}\n";
  ejs_eval_script(context, "uaf.js", js_code, strlen(js_code));

  // 与此同时，直接暴躁地在宿主线程上直接销毁 context，触发跨线程竞争！
  usleep(100);
  ejs_context_destroy(context);

  // 稍等以让后台线程有机会竞争 and 运行完成
  usleep(50 * 1000);

  ejs_runtime_destroy(runtime);
  printf("test_high_concurrency_uaf PASS\n");
}

// -------------------------------------------------------------
// Test Suit: test_duplicate_host_completion_idempotency
// -------------------------------------------------------------
typedef struct {
  EJSCoreInvokeCompletion completion;
  void *completion_data;
  EJSCoreHostOperation *operation;
} DuplicateCompletionPayload;

static DuplicateCompletionPayload g_dup_payload;

static EJSCoreHostOperation *dup_host_invoke(EJSCoreUserData user_data,
                                         const char *module_id,
                                         const char *method_id,
                                         EJSCoreByteView payload,
                                         EJSCoreByteView transfer_buffer,
                                         EJSCoreInvokeCompletion completion,
                                         void *completion_data) {
  (void)user_data; (void)module_id; (void)method_id; (void)payload; (void)transfer_buffer;
  EJSCoreHostOperation *op = ejs_native_operation_create(NULL, NULL, NULL);
  if (op == NULL) {
    return NULL;
  }

  g_dup_payload.completion = completion;
  g_dup_payload.completion_data = completion_data;
  g_dup_payload.operation = op;
  return op;
}

static void test_duplicate_host_completion_idempotency(void) {
  TestUAFHost dup_host;
  memset(&dup_host, 0, sizeof(dup_host));
  dup_host.api.abi_version = EJS_NATIVE_ABI_VERSION;
  dup_host.api.struct_size = sizeof(dup_host.api);
  dup_host.api.user_data = ejs_user_data_ref_make(&dup_host, NULL, NULL);
  dup_host.api.operations = ejs_native_operation_api();
  dup_host.api.operations.user_data = ejs_user_data_ref_make(&dup_host, NULL, NULL);

  dup_host.api.invoke_api.abi_version = EJS_NATIVE_ABI_VERSION;
  dup_host.api.invoke_api.struct_size = sizeof(dup_host.api.invoke_api);
  dup_host.api.invoke_api.user_data = ejs_user_data_ref_make(&dup_host, NULL, NULL);
  dup_host.api.invoke_api.invoke = dup_host_invoke;
  dup_host.api.sync_invoke_api.abi_version = EJS_NATIVE_ABI_VERSION;
  dup_host.api.sync_invoke_api.struct_size = sizeof(dup_host.api.sync_invoke_api);
  dup_host.api.sync_invoke_api.user_data = ejs_user_data_ref_null();
  dup_host.api.sync_invoke_api.invoke_sync = NULL;

  EJSCoreRuntimeConfig config;
  memset(&config, 0, sizeof(config));
  config.abi_version = EJS_RUNTIME_ABI_VERSION;
  config.struct_size = sizeof(config);

  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  ejs_context_register_host(context, &dup_host.api);

  g_dup_payload.completion = NULL;
  g_dup_payload.completion_data = NULL;
  g_dup_payload.operation = NULL;

  const char *js_code = "__ejs_native__.invoke('dup', 'test', 'payload');";
  ejs_eval_script(context, "dup.js", js_code, strlen(js_code));

  // 驱动 loop 让任务投递发生并让 JS 挂起 invoke
  ejs_runtime_drain_for_test(runtime);

  assert(g_dup_payload.completion != NULL);

  EJSCoreHostError err;
  memset(&err, 0, sizeof(err));
  err.abi_version = EJS_NATIVE_ABI_VERSION;
  err.struct_size = sizeof(err);
  err.code = EJS_ERROR_NONE;

  EJSCoreByteView result;
  result.data = (const uint8_t *)"dup_test_ok";
  result.size = 11;

  // 1. 触发第一次回调
  g_dup_payload.completion(g_dup_payload.completion_data, result, &err);

  // 2. 故意重复触发第二次回调 (Buggy Provider 行为)
  // 如果没有幂等拦截，这会导致 Double Free / UAF Crash。
  g_dup_payload.completion(g_dup_payload.completion_data, result, &err);
  ejs_native_operation_complete(g_dup_payload.operation);

  // 再次驱动 loop，确保第一次回调的任务能被执行跑完
  ejs_runtime_drain_for_test(runtime);

  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);
  printf("test_duplicate_host_completion_idempotency PASS\n");
}

// -------------------------------------------------------------
// Test Suit: test_whitebox_precision_coverage_ext
// -------------------------------------------------------------
static int my_host_api_cancel(EJSCoreUserData user_data, EJSCoreHostOperation *operation) {
  (void)user_data;
  (void)operation;
  return 0;
}

static void my_host_api_release(EJSCoreUserData user_data, EJSCoreHostOperation *operation) {
  (void)user_data;
  (void)operation;
}

static void test_whitebox_precision_coverage_ext(void) {
  // 1. ejs_native_operation_api_cancel & ejs_native_operation_api_release 覆盖
  {
    EJSCoreHostAPI api;
    memset(&api, 0, sizeof(api));
    api.abi_version = EJS_NATIVE_ABI_VERSION;
    api.struct_size = sizeof(api);
    api.operations = ejs_native_operation_api();

    EJSCoreHostOperation *op = ejs_native_operation_create(NULL, NULL, NULL);
    assert(op != NULL);

    int cancel_ret = api.operations.cancel(api.operations.user_data, op);
    assert(cancel_ret == 0);

    api.operations.release(api.operations.user_data, op);
  }

  // 2. ejs_native_api.c 空指针边界覆盖
  {
    ejs_byte_buffer_init(NULL, NULL, 0, NULL, NULL, NULL);
    ejs_byte_buffer_destroy(NULL);
    ejs_byte_buffer_secure_destroy(NULL);
    assert(ejs_native_operation_user_data(NULL) == NULL);

    EJSCoreHostOperation *op = ejs_native_operation_create(NULL, NULL, NULL);
    assert(op != NULL);
    ejs_native_operation_release(op);
    ejs_native_operation_release(NULL);
  }

  // 3. EJSCoreByteBuffer secure_destroy 退化到 ejs_secure_wipe + destroy 的分支
  {
    int destroy_called = 0;
    EJSCoreByteBuffer buf;
    uint8_t data[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    ejs_byte_buffer_init(&buf, data, 8, &destroy_called, my_buf_destroy, NULL);
    ejs_byte_buffer_secure_destroy(&buf);
    assert(destroy_called == 1);
  }

  // 4. ejs_native_validate_host_api 失败路径
  {
    // operations 的 abi_version 为 0，导致 validation 发生 EJS_NATIVE_VALIDATION_ABI_VERSION 失败
    EJSCoreHostAPI invalid_api;
    memset(&invalid_api, 0, sizeof(invalid_api));
    invalid_api.abi_version = EJS_NATIVE_ABI_VERSION;
    invalid_api.struct_size = sizeof(invalid_api);
    assert(ejs_native_validate_host_api(&invalid_api, 0) == EJS_NATIVE_VALIDATION_ABI_VERSION);

    // operations 缺少必需的回调，导致 validation 发生 EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK 失败
    EJSCoreHostAPI invalid_api_nocallback;
    memset(&invalid_api_nocallback, 0, sizeof(invalid_api_nocallback));
    invalid_api_nocallback.abi_version = EJS_NATIVE_ABI_VERSION;
    invalid_api_nocallback.struct_size = sizeof(invalid_api_nocallback);
    invalid_api_nocallback.operations.abi_version = EJS_NATIVE_ABI_VERSION;
    invalid_api_nocallback.operations.struct_size = sizeof(invalid_api_nocallback.operations);
    assert(ejs_native_validate_host_api(&invalid_api_nocallback, 0) == EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK);

    EJSCoreHostAPI invalid_invoke_api;
    memset(&invalid_invoke_api, 0, sizeof(invalid_invoke_api));
    invalid_invoke_api.abi_version = EJS_NATIVE_ABI_VERSION;
    invalid_invoke_api.struct_size = sizeof(invalid_invoke_api);
    invalid_invoke_api.operations.abi_version = EJS_NATIVE_ABI_VERSION;
    invalid_invoke_api.operations.struct_size = sizeof(invalid_invoke_api.operations);
    invalid_invoke_api.operations.cancel = my_host_api_cancel;
    invalid_invoke_api.operations.release = my_host_api_release;
    
    invalid_invoke_api.invoke_api.abi_version = 9999;
    invalid_invoke_api.invoke_api.struct_size = sizeof(invalid_invoke_api.invoke_api);
    assert(ejs_native_validate_host_api(&invalid_invoke_api, EJS_NATIVE_PROVIDER_INVOKE) == EJS_NATIVE_VALIDATION_ABI_VERSION);
  }

  // 5. ejs_runtime_loop_libuv.c 空指针边界覆盖
  {
    ejs_runtime_loop_destroy(NULL);
    assert(ejs_runtime_loop_is_thread_started(NULL) == false);

    EJSCoreResult start_res = ejs_runtime_loop_start(NULL);
    assert(start_res.status == EJS_STATUS_ERROR);
    ejs_error_destroy(start_res.error);

    EJSCoreResult stop_res = ejs_runtime_loop_stop(NULL);
    assert(stop_res.status == EJS_STATUS_ERROR);
    ejs_error_destroy(stop_res.error);

    EJSCoreResult call_res = ejs_runtime_loop_call_sync(NULL, NULL, NULL);
    assert(call_res.status == EJS_STATUS_ERROR);
    ejs_error_destroy(call_res.error);

    EJSCoreResult post_res = ejs_runtime_loop_post(NULL, NULL, NULL);
    assert(post_res.status == EJS_STATUS_ERROR);
    ejs_error_destroy(post_res.error);

    ejs_runtime_loop_destroy_after_owner_exit(NULL, NULL, NULL, NULL);
    ejs_runtime_timer_destroy(NULL);
    ejs_runtime_timer_set_free_user_data(NULL, NULL);
    ejs_runtime_loop_close_handles(NULL);
    assert(ejs_runtime_timer_create(NULL, 1, 0, test_stop_completion, NULL) == NULL);

    EJSCoreError *loop_error = NULL;
    EJSRuntimeLoop *idle_loop = ejs_runtime_loop_create(NULL, &loop_error);
    assert(idle_loop != NULL);
    assert(loop_error == NULL);

    int task_count = 0;
    call_res = ejs_runtime_loop_call_sync(idle_loop, test_loop_task_increment_cb, &task_count);
    assert(call_res.status == EJS_STATUS_ERROR);
    ejs_error_destroy(call_res.error);
    assert(task_count == 0);

    post_res = ejs_runtime_loop_post(idle_loop, test_loop_task_increment_cb, &task_count);
    assert(post_res.status == EJS_STATUS_ERROR);
    ejs_error_destroy(post_res.error);
    assert(task_count == 0);

    EJSCoreResult pump_res = ejs_runtime_loop_pump(idle_loop, 10);
    assert(pump_res.status == EJS_STATUS_OK);
    ejs_runtime_loop_destroy(idle_loop);
  }

  // 5b. runtime/engine public invalid-argument branches
  {
    int completion_count = 0;
    ejs_runtime_destroy_with_completion(NULL, test_stop_completion, &completion_count);
    assert(completion_count == 1);

    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    assert(runtime != NULL);
    ejs_runtime_destroy_with_completion(runtime, test_stop_completion, &completion_count);
    int wait_limit = 1000;
    while (completion_count < 2 && wait_limit > 0) {
      usleep(1000);
      wait_limit--;
    }
    assert(completion_count == 2);
    runtime = NULL;

    EJSCoreResult invalid_script = ejs_eval_script(NULL, "invalid.js", "1", 1);
    assert(invalid_script.status == EJS_STATUS_ERROR);
    ejs_error_destroy(invalid_script.error);

    EJSCoreEvalOptions module_options;
    memset(&module_options, 0, sizeof(module_options));
    module_options.abi_version = EJS_RUNTIME_ABI_VERSION;
    module_options.struct_size = sizeof(module_options);
    module_options.kind = EJS_EVAL_KIND_MODULE;
    EJSCoreResult invalid_module = ejs_eval_module(NULL, &module_options, "export {}", 9);
    assert(invalid_module.status == EJS_STATUS_ERROR);
    ejs_error_destroy(invalid_module.error);

    EJSCoreResult invalid_drain = ejs_runtime_drain_for_test(NULL);
    assert(invalid_drain.status == EJS_STATUS_ERROR);
    ejs_error_destroy(invalid_drain.error);

    ejs_request_interrupt(NULL);
    ejs_context_register_host(NULL, NULL);
    assert(ejs_context_acquire_host(NULL) == NULL);
    assert(ejs_registered_host_retain(NULL) == NULL);
    ejs_registered_host_release(NULL);
    ejs_engine_runtime_destroy(NULL);
    ejs_engine_context_destroy(NULL);

    EJSCoreResult invalid_bindings = ejs_engine_context_register_core_bindings(NULL);
    assert(invalid_bindings.status == EJS_STATUS_ERROR);
    ejs_error_destroy(invalid_bindings.error);

    EJSCoreResult invalid_engine_script = ejs_engine_eval_script(NULL, "invalid.js", "1", 1);
    assert(invalid_engine_script.status == EJS_STATUS_ERROR);
    ejs_error_destroy(invalid_engine_script.error);

    EJSCoreResult invalid_engine_module = ejs_engine_eval_module(NULL, &module_options, "export {}", 9);
    assert(invalid_engine_module.status == EJS_STATUS_ERROR);
    ejs_error_destroy(invalid_engine_module.error);

    EJSCoreResult invalid_jobs = ejs_engine_run_jobs(NULL);
    assert(invalid_jobs.status == EJS_STATUS_ERROR);
    ejs_error_destroy(invalid_jobs.error);

    ejs_runtime_destroy(runtime);
  }

#ifdef EJS_TEST
  // 5bb. stopped loop 上的 context/eval/destroy 降级路径
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);
    assert(runtime != NULL && context != NULL);

    EJSCoreResult stop_res = ejs_runtime_loop_stop(runtime->runtime_loop);
    assert(stop_res.status == EJS_STATUS_OK);

    EJSCoreContext *failed_context = ejs_context_create(runtime);
    assert(failed_context == NULL);

    EJSCoreResult eval_res = ejs_eval_script(context, "stopped.js", "1 + 1;", 6);
    assert(eval_res.status == EJS_STATUS_ERROR);
    ejs_error_destroy(eval_res.error);

    EJSCoreEvalOptions module_options;
    memset(&module_options, 0, sizeof(module_options));
    module_options.abi_version = EJS_RUNTIME_ABI_VERSION;
    module_options.struct_size = sizeof(module_options);
    module_options.kind = EJS_EVAL_KIND_MODULE;
    eval_res = ejs_eval_module(context, &module_options, "export const y = 1;", strlen("export const y = 1;"));
    assert(eval_res.status == EJS_STATUS_ERROR);
    ejs_error_destroy(eval_res.error);

    int completion_count = 0;
    extern int ejs_test_inject_runtime_error;
    ejs_test_inject_runtime_error = 6;
    ejs_runtime_destroy_with_completion(runtime, test_stop_completion, &completion_count);
    assert(completion_count == 1);
    ejs_test_inject_runtime_error = 0;
  }
#endif

#if defined(EJS_RUNTIME_LOOP_LIBUV) && defined(EJS_TEST)
  // 5bc. terminal shutdown call_sync 失败时仍需执行本地兜底清理
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);
    EJSFakeHost *fake_host = ejs_fake_host_create();
    assert(runtime != NULL && context != NULL && fake_host != NULL);

    ejs_context_register_host(context, ejs_fake_host_api(fake_host));
    assert(ejs_fake_host_retain_count(fake_host) == 3);

    ejs_runtime_loop_set_stop_requested_for_test(runtime->runtime_loop, 1);
    int completion_count = 0;
    ejs_runtime_destroy_with_completion(runtime, test_stop_completion, &completion_count);
    int wait_limit = 2000;
    while (completion_count < 1 && wait_limit-- > 0) {
      usleep(1000);
    }
    assert(completion_count == 1);
    assert(ejs_fake_host_release_count(fake_host) == 3);
    ejs_fake_host_destroy(fake_host);
  }
#endif

  // 5c. context list unlink branches and terminal shutdown host release
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    assert(runtime != NULL);
    EJSCoreContext *ctx1 = ejs_context_create(runtime);
    EJSCoreContext *ctx2 = ejs_context_create(runtime);
    EJSCoreContext *ctx3 = ejs_context_create(runtime);
    assert(ctx1 != NULL && ctx2 != NULL && ctx3 != NULL);

    ejs_context_destroy(ctx2);
    ejs_context_destroy(ctx1);
    ejs_context_destroy(ctx3);
    ejs_runtime_destroy(runtime);

    runtime = ejs_runtime_create(&config);
    assert(runtime != NULL);
    EJSCoreContext *host_context = ejs_context_create(runtime);
    assert(host_context != NULL);
    EJSFakeHost *fake_host = ejs_fake_host_create();
    assert(fake_host != NULL);
    ejs_context_register_host(host_context, ejs_fake_host_api(fake_host));
    ejs_runtime_destroy(runtime);
    assert(ejs_fake_host_release_count(fake_host) == 3);
    ejs_fake_host_destroy(fake_host);
  }

#ifdef EJS_TEST
  // 5d. registered host allocation failure keeps the previous host active
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);
    EJSFakeHost *fake_host = ejs_fake_host_create();
    assert(runtime != NULL && context != NULL && fake_host != NULL);

    ejs_context_register_host(context, ejs_fake_host_api(fake_host));
    assert(ejs_fake_host_retain_count(fake_host) == 3);

    extern int ejs_test_inject_runtime_error;
    ejs_test_inject_runtime_error = 8;
    ejs_context_register_host(context, ejs_fake_host_api(fake_host));
    assert(context->host != NULL);
    assert(ejs_fake_host_release_count(fake_host) == 0);
    ejs_test_inject_runtime_error = 0;

    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
    assert(ejs_fake_host_release_count(fake_host) == 3);
    ejs_fake_host_destroy(fake_host);
  }
#endif

  // 6. ejs_runtime_loop_libuv.c 状态幂等测试
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    assert(runtime != NULL);
    assert(runtime->runtime_loop != NULL);
    assert(ejs_runtime_timer_create(runtime->runtime_loop, 10, 0, NULL, NULL) == NULL);

    EJSCoreResult re_start = ejs_runtime_loop_start(runtime->runtime_loop);
    assert(re_start.status == EJS_STATUS_OK);

    // cb 必须非空，复用 test_stop_completion
    EJSRuntimeTimer *timer = ejs_runtime_timer_create(runtime->runtime_loop, 10, 0, test_stop_completion, NULL);
    assert(timer != NULL);
    ejs_runtime_timer_set_free_user_data(timer, free);
    ejs_runtime_timer_destroy(timer);

#if defined(EJS_RUNTIME_LOOP_LIBUV) && defined(EJS_TEST)
    ejs_runtime_loop_set_stop_requested_for_test(runtime->runtime_loop, 1);
    int stopped_task_count = 0;
    EJSCoreResult stopped_sync =
        ejs_runtime_loop_call_sync(runtime->runtime_loop,
                                   test_loop_task_increment_cb,
                                   &stopped_task_count);
    assert(stopped_sync.status == EJS_STATUS_ERROR);
    ejs_error_destroy(stopped_sync.error);
    assert(stopped_task_count == 0);

    EJSCoreResult stopped_post =
        ejs_runtime_loop_post(runtime->runtime_loop,
                              test_loop_task_increment_cb,
                              &stopped_task_count);
    assert(stopped_post.status == EJS_STATUS_ERROR);
    ejs_error_destroy(stopped_post.error);
    assert(stopped_task_count == 0);
    ejs_runtime_loop_set_stop_requested_for_test(runtime->runtime_loop, 0);
#endif

    ejs_runtime_destroy(runtime);
  }

#ifdef EJS_TEST
  // 6b. timer allocation failure
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    assert(runtime != NULL);

    extern int ejs_test_inject_runtime_error;
    ejs_test_inject_runtime_error = 28;
    assert(ejs_runtime_timer_create(runtime->runtime_loop, 10, 0, test_stop_completion, NULL) == NULL);
    ejs_test_inject_runtime_error = 0;

    ejs_test_inject_runtime_error = 30;
    assert(ejs_runtime_timer_create(runtime->runtime_loop, 10, 0, test_stop_completion, NULL) == NULL);
    ejs_test_inject_runtime_error = 0;

    ejs_test_inject_runtime_error = 31;
    assert(ejs_runtime_timer_create(runtime->runtime_loop, 10, 0, test_stop_completion, NULL) == NULL);
    ejs_test_inject_runtime_error = 0;

    ejs_test_inject_runtime_error = 33;
    int post_task_count = 0;
    EJSCoreResult post_oom =
        ejs_runtime_loop_post(runtime->runtime_loop,
                              test_loop_task_increment_cb,
                              &post_task_count);
    assert(post_oom.status == EJS_STATUS_ERROR);
    ejs_error_destroy(post_oom.error);
    assert(post_task_count == 0);
    ejs_test_inject_runtime_error = 0;

    ejs_runtime_destroy(runtime);
  }
#endif

  // 7. ejs_native_api.c 中的原子 CAS 重试及取消竞态的分支覆盖
  {
    EJSCoreHostOperation *op = ejs_native_operation_create(NULL, NULL, NULL);
    assert(op != NULL);
    
    bool comp = ejs_native_operation_complete(op);
    assert(comp == true);
    
    bool comp2 = ejs_native_operation_complete(op);
    assert(comp2 == false);
    
    ejs_native_operation_release(op);
  }

  // 8. engine edge branches: invalid binary view, negative timers, module specifier fallback
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);
    assert(runtime != NULL && context != NULL);

    const char *timer_code =
      "const id = __ejs_native__.timers.create(-1, -1, () => {});"
      "__ejs_native__.timers.destroy(id);";
    EJSCoreResult eval_res = ejs_eval_script(context, "timer-negative.js", timer_code, strlen(timer_code));
    assert(eval_res.status == EJS_STATUS_OK);
    ejs_runtime_drain_for_test(runtime);

    EJSFakeHost *fake_host = ejs_fake_host_create();
    assert(fake_host != NULL);
    ejs_context_register_host(context, ejs_fake_host_api(fake_host));
    const char *invalid_view_code =
      "let getterCalled = false;\n"
      "const fakeView = {\n"
      "  get buffer() { getterCalled = true; return new ArrayBuffer(8); },\n"
      "  get byteOffset() { getterCalled = true; return 0; },\n"
      "  get byteLength() { getterCalled = true; return 1; }\n"
      "};\n"
      "let invalidRejected = false;\n"
      "try {\n"
      "  __ejs_native__.invoke('bin', 'invalid', fakeView);\n"
      "} catch (error) {\n"
      "  invalidRejected = error instanceof TypeError;\n"
      "}\n"
      "if (!invalidRejected) throw new Error('invalid binary payload accepted getter=' + getterCalled);\n"
      "if (getterCalled) throw new Error('binary extraction triggered user getter');\n"
      "__ejs_native__.invoke('bin', 'valid', new Uint8Array([1, 2, 3]));";
    eval_res = ejs_eval_script(context, "invalid-view.js", invalid_view_code, strlen(invalid_view_code));
    assert(eval_res.status == EJS_STATUS_OK);
    ejs_runtime_drain_for_test(runtime);
    assert(ejs_fake_host_pending_count(fake_host) == 1u);
    ejs_fake_host_complete_all(fake_host);
    ejs_runtime_drain_for_test(runtime);

    EJSCoreEvalOptions module_options;
    memset(&module_options, 0, sizeof(module_options));
    module_options.abi_version = EJS_RUNTIME_ABI_VERSION;
    module_options.struct_size = sizeof(module_options);
    module_options.kind = EJS_EVAL_KIND_MODULE;
    module_options.specifier = "specifier-only-module";
    eval_res = ejs_eval_module(context, &module_options, "export const x = 1;", strlen("export const x = 1;"));
    assert(eval_res.status == EJS_STATUS_OK);

    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
    ejs_fake_host_destroy(fake_host);
  }

#ifdef EJS_TEST
  // 9. completion task / result buffer OOM owner-thread cleanup
  {
    for (int injection = 15; injection <= 16; injection++) {
      memset(&g_test_host, 0, sizeof(g_test_host));
      EJSCoreHostAPI api;
      init_custom_host_api(&api, &g_test_host);

      EJSCoreRuntimeConfig config;
      memset(&config, 0, sizeof(config));
      config.abi_version = EJS_RUNTIME_ABI_VERSION;
      config.struct_size = sizeof(config);

      EJSCoreRuntime *runtime = ejs_runtime_create(&config);
      EJSCoreContext *context = ejs_context_create(runtime);
      ejs_context_register_host(context, &api);

      const char *js_code = "__ejs_native__.invoke('oom', 'completion', 'payload');";
      EJSCoreResult eval_res = ejs_eval_script(context, "oom.js", js_code, strlen(js_code));
      assert(eval_res.status == EJS_STATUS_OK);
      ejs_runtime_drain_for_test(runtime);
      assert(g_test_host.last_completion != NULL);

      extern int ejs_test_inject_engine_error;
      ejs_test_inject_engine_error = injection;

      EJSCoreHostError err;
      memset(&err, 0, sizeof(err));
      err.abi_version = EJS_NATIVE_ABI_VERSION;
      err.struct_size = sizeof(err);
      err.code = EJS_ERROR_NONE;

      EJSCoreByteView result;
      result.data = injection == 16 ? (const uint8_t *)"oom_result" : NULL;
      result.size = injection == 16 ? strlen("oom_result") : 0;
      g_test_host.last_completion(g_test_host.last_completion_data, result, &err);
      ejs_test_inject_engine_error = 0;

      ejs_runtime_drain_for_test(runtime);
      ejs_context_destroy(context);
      ejs_runtime_destroy(runtime);
    }
  }

  // 10. timer allocation OOM and completion NULL defensive entry
  {
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);
    assert(runtime != NULL && context != NULL);

    extern int ejs_test_inject_engine_error;
    ejs_test_inject_engine_error = 5;
    const char *timer_oom_code = "try { __ejs_native__.timers.create(1, 0, () => {}); } catch(e) {}";
    EJSCoreResult eval_res = ejs_eval_script(context, "timer-oom.js", timer_oom_code, strlen(timer_oom_code));
    assert(eval_res.status == EJS_STATUS_OK);
    ejs_test_inject_engine_error = 0;

#if defined(EJS_ENGINE_QUICKJS_NG)
    extern void ejs_invoke_completion_callback(void *, EJSCoreByteView, const EJSCoreHostError *);
    EJSCoreByteView empty = {NULL, 0};
    ejs_invoke_completion_callback(NULL, empty, NULL);
#endif

    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
  }
#endif

  printf("test_whitebox_precision_coverage_ext PASS\n");
}

// -------------------------------------------------------------
// Test Suit: test_whitebox_precision_coverage_super
// -------------------------------------------------------------
static void dummy_sync_cb(void *user_data) {
  int *val = (int *)user_data;
  if (val != NULL) {
    *val = 42;
  }
}

static void my_owner_thread_stop_cb(void *user_data) {
  EJSRuntimeLoop *loop = (EJSRuntimeLoop *)user_data;

  // 1. 覆盖 owner 线程同步重入直接执行分支
  int sync_val = 0;
  EJSCoreResult r = ejs_runtime_loop_call_sync(loop, dummy_sync_cb, &sync_val);
  assert(r.status == EJS_STATUS_OK);
  assert(sync_val == 42);

  // 2. 覆盖 owner 线程内直接 stop 退出分支
  EJSCoreResult stop_r = ejs_runtime_loop_stop(loop);
  assert(stop_r.status == EJS_STATUS_OK);
}

#if defined(EJS_RUNTIME_LOOP_LIBUV)
void * ejs_runtime_loop_uv(EJSRuntimeLoop *runtime_loop);
#endif
#if defined(EJS_RUNTIME_LOOP_LIBUV) && defined(EJS_TEST)
void ejs_runtime_loop_set_stop_requested_for_test(EJSRuntimeLoop *runtime_loop, int stop_requested);
void ejs_runtime_loop_reset_owner_stop_join_count_for_test(void);
int ejs_runtime_loop_owner_stop_join_count_for_test(void);
#endif

static void test_whitebox_precision_coverage_super(void) {
  // 1. 覆盖 thread_started == 0 时同步投递会被拒绝，避免破坏 owner-thread 约束
  {
    printf("SUPER STAGE 1.0\n");
    EJSCoreError *err = NULL;
    EJSRuntimeLoop *loop = ejs_runtime_loop_create(NULL, &err);
    assert(loop != NULL);
    assert(ejs_runtime_loop_is_thread_started(loop) == false);

    int sync_val = 0;
    EJSCoreResult sync_r = ejs_runtime_loop_call_sync(loop, dummy_sync_cb, &sync_val);
    assert(sync_r.status == EJS_STATUS_ERROR);
    assert(sync_val == 0);
    ejs_error_destroy(sync_r.error);

    EJSCoreResult async_r = ejs_runtime_loop_post(loop, dummy_sync_cb, NULL);
    assert(async_r.status == EJS_STATUS_ERROR);
    ejs_error_destroy(async_r.error);

    ejs_runtime_loop_destroy(loop);
  }

  // 2. 覆盖 ejs_runtime_loop_close_handles 强制退役注销 Timer 链表的分支
  {
    printf("SUPER STAGE 2.0\n");
    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    assert(runtime != NULL);

    // 延迟设为 1ms 并采用安全的 dummy 回调，规避 pthread_join 阻塞与空指针锁死
    EJSRuntimeTimer *timer = ejs_runtime_timer_create(runtime->runtime_loop, 1, 0, dummy_sync_cb, NULL);
    assert(timer != NULL);

#if defined(EJS_RUNTIME_LOOP_LIBUV)
    assert(ejs_runtime_loop_uv(NULL) == NULL);
    assert(ejs_runtime_loop_uv(runtime->runtime_loop) != NULL);
#endif

    ejs_runtime_destroy(runtime);
  }

  // 3. 覆盖 owner 线程同步重入直接执行 & owner 线程直接 stop 退出分支
  {
    printf("SUPER STAGE 3.0\n");
#if defined(EJS_RUNTIME_LOOP_LIBUV) && defined(EJS_TEST)
    ejs_runtime_loop_reset_owner_stop_join_count_for_test();
#endif
    EJSCoreError *err = NULL;
    EJSRuntimeLoop *loop = ejs_runtime_loop_create(NULL, &err);
    assert(loop != NULL);
    EJSCoreResult start_res = ejs_runtime_loop_start(loop);
    assert(start_res.status == EJS_STATUS_OK);

    EJSCoreResult run_r = ejs_runtime_loop_call_sync(loop, my_owner_thread_stop_cb, loop);
    assert(run_r.status == EJS_STATUS_OK);

    int wait_limit = 1000;
    while (ejs_runtime_loop_is_thread_started(loop) && wait_limit-- > 0) {
      usleep(1000);
    }
    assert(ejs_runtime_loop_is_thread_started(loop) == false);

    EJSCoreResult restart_after_stop = ejs_runtime_loop_start(loop);
    assert(restart_after_stop.status == EJS_STATUS_ERROR);
    ejs_error_destroy(restart_after_stop.error);

    ejs_runtime_loop_destroy(loop);
#if defined(EJS_RUNTIME_LOOP_LIBUV) && defined(EJS_TEST)
    assert(ejs_runtime_loop_owner_stop_join_count_for_test() == 1);
#endif
  }

  // 4. 覆盖 Context 销毁后的并发/静默异步回调释放分支 (ctx == NULL 释放逻辑)
  {
    printf("SUPER STAGE 4.0\n");
    memset(&g_test_host, 0, sizeof(g_test_host));
    EJSCoreHostAPI api;
    init_custom_host_api(&api, &g_test_host);

    EJSCoreRuntimeConfig config;
    memset(&config, 0, sizeof(config));
    config.abi_version = EJS_RUNTIME_ABI_VERSION;
    config.struct_size = sizeof(config);

    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    EJSCoreContext *context = ejs_context_create(runtime);
    ejs_context_register_host(context, &api);

    const char *js_code = "__ejs_native__.invoke('async', 'concurrent', 'payload');";
    EJSCoreResult eval_res = ejs_eval_script(context, "test.js", js_code, strlen(js_code));
    assert(eval_res.status == EJS_STATUS_OK);

    ejs_runtime_drain_for_test(runtime);

    assert(g_test_host.last_completion != NULL);
    EJSCoreInvokeCompletion saved_completion = g_test_host.last_completion;
    void *saved_completion_data = g_test_host.last_completion_data;

    ejs_context_destroy(context);

    EJSCoreHostError err;
    memset(&err, 0, sizeof(err));
    err.abi_version = EJS_NATIVE_ABI_VERSION;
    err.struct_size = sizeof(err);
    err.code = EJS_ERROR_NONE;
    EJSCoreByteView result_view = {(const uint8_t *)"late_result", 11};

    printf("SUPER STAGE 4.1\n");
    saved_completion(saved_completion_data, result_view, &err);

    usleep(5000);
    printf("SUPER STAGE 4.2\n");
    ejs_runtime_destroy(runtime);
  }

  printf("SUPER STAGE 5.0\n");
  printf("test_whitebox_precision_coverage_super PASS\n");
}

static void dummy_user_data_retain(void *user_data) { (void)user_data; }
static void dummy_user_data_release(void *user_data) { (void)user_data; }

static EJSCoreHostOperation *dummy_host_invoke(EJSCoreUserData user_data,
                                           const char *module_id,
                                           const char *method_id,
                                           EJSCoreByteView payload,
                                           EJSCoreByteView transfer_buffer,
                                           EJSCoreInvokeCompletion completion,
                                           void *completion_data) {
  (void)user_data; (void)module_id; (void)method_id; (void)payload;
  (void)transfer_buffer; (void)completion; (void)completion_data;
  return NULL;
}

static void test_host_lifecycle_upgrade(void) {
  EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);

  // 1. Double-callback validation rules (retained vs borrowed)
  EJSCoreHostAPI api = ejs_host_api_default_value();
  api.invoke_api.invoke = dummy_host_invoke;
  // Valid borrowed: value != NULL, retain=NULL, release=NULL
  api.user_data = ejs_user_data_ref_make((void*)0x123, NULL, NULL);
  ejs_context_register_host(context, &api);
  assert(context->host != NULL);

  // Invalid: value != NULL, retain != NULL, release == NULL
  api.user_data = ejs_user_data_ref_make((void*)0x123, dummy_user_data_retain, NULL);
  ejs_context_register_host(context, &api);
  assert(context->host == NULL); // Rejected

  // Invalid: value != NULL, retain == NULL, release != NULL
  api.user_data = ejs_user_data_ref_make((void*)0x123, NULL, dummy_user_data_release);
  ejs_context_register_host(context, &api);
  assert(context->host == NULL); // Rejected

  // 2. Stack copy of host API test (deep copying during registration)
  {
    EJSCoreHostAPI stack_api = ejs_host_api_default_value();
    stack_api.invoke_api.invoke = dummy_host_invoke;
    stack_api.user_data = ejs_user_data_ref_make((void*)0x456, NULL, NULL);
    ejs_context_register_host(context, &stack_api);
    memset(&stack_api, 0xAA, sizeof(stack_api)); // Corrupt stack memory
  }
  // The registered host api must still be valid and safe
  assert(context->host != NULL);
  assert(context->host->api.user_data.value == (void*)0x456);

  // 3. Post-register swap release delay test with fake host
  EJSFakeHost *fake_host1 = ejs_fake_host_create();
  EJSCoreHostAPI *api1 = ejs_fake_host_api(fake_host1);

  ejs_context_register_host(context, api1);
  assert(ejs_fake_host_retain_count(fake_host1) == 3); // Registered: user_data, operations, invoke_api

  // Trigger pending async invoke
  const char *js_code = "__ejs_native__.invoke('fs', 'read_file', 'test');";
  EJSCoreResult eval_res = ejs_eval_script(context, "test.js", js_code, strlen(js_code));
  assert(eval_res.status == EJS_STATUS_OK);
  ejs_runtime_drain_for_test(runtime);

  assert(ejs_fake_host_pending_count(fake_host1) == 1);

  // Now swap with new host API
  EJSFakeHost *fake_host2 = ejs_fake_host_create();
  EJSCoreHostAPI *api2 = ejs_fake_host_api(fake_host2);
  ejs_context_register_host(context, api2);

  // Since fake_host1 has pending invoke, it must NOT be fully released/freed yet!
  assert(ejs_fake_host_release_count(fake_host1) == 0);

  // Complete fake_host1's pending operation
  ejs_fake_host_complete_next(fake_host1);
  ejs_runtime_drain_for_test(runtime);

  // Now that pending invoke is complete, EJSInvokeState is freed, releasing the old host record.
  assert(ejs_fake_host_release_count(fake_host1) == 3);

  // Clean up
  ejs_context_destroy(context);
  ejs_runtime_destroy(runtime);
  ejs_fake_host_destroy(fake_host1);
  ejs_fake_host_destroy(fake_host2);

  printf("test_host_lifecycle_upgrade PASS\n");
}

// -------------------------------------------------------------
// Test Suit: Public API Verification of Core Safety Issues
// -------------------------------------------------------------

typedef struct {
  EJSCoreContext *context;
} PublicUAFHost;

static EJSCoreHostOperation* public_uaf_invoke(EJSCoreUserData user_data,
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

  PublicUAFHost *host = (PublicUAFHost *)user_data.value;
  if (host->context != NULL) {
    // 经由公共 ABI 销毁 Context，Owner 线程上它会进入延迟队列
    ejs_context_destroy(host->context);
    host->context = NULL;
  }
  return NULL;
}

// 1. 验证 P1-2: Owner 线程微任务执行中 Context 销毁导致的 UAF 崩溃
// 说明：此测试在未修复 UAF 前运行，第二个微任务在执行时会访问已被释放的 context 内存，导致 Crash
static void test_public_microtask_uaf(void) {
  EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  
  PublicUAFHost host = { context };
  EJSCoreHostAPI api = ejs_host_api_default_value();
  api.user_data = ejs_user_data_ref_make(&host, NULL, NULL);
  api.invoke_api.user_data = ejs_user_data_ref_make(&host, NULL, NULL);
  api.invoke_api.invoke = public_uaf_invoke;
  ejs_context_register_host(context, &api);

  const char *js_code =
      "Promise.resolve().then(() => {\n"
      "  __ejs_native__.invoke('test', 'destroy', '');\n"
      "});\n"
      "Promise.resolve().then(() => {\n"
      "  var uaf_probe = 40 + 2;\n"
      "});\n";

  EJSCoreResult res = ejs_eval_script(context, "test.js", js_code, strlen(js_code));
  assert(res.status == EJS_STATUS_OK);

  // 驱动微任务执行，在未修复前此处将引发 UAF 崩溃或内存错误
  printf("[DEMO TEST] Running microtask UAF verification...\n");
  ejs_runtime_drain_for_test(runtime);
  
  printf("test_public_microtask_uaf PASS\n");
}

// 2. 验证 P0-1: 销毁退场时在调用线程执行 uv_loop_close 违背线程契约
// 说明：此测试在未修复前，非 Owner 线程调用 ejs_runtime_destroy 会导致在调用线程执行 uv_loop_close，
// 从而引发 libuv 的跨线程 handle 操作 assertion 报错或崩溃
static void test_public_thread_boundary_violation(void) {
  EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  assert(runtime != NULL);
  
  EJSCoreContext *context = ejs_context_create(runtime);
  assert(context != NULL);
  ejs_context_destroy(context);

  printf("[DEMO TEST] Running thread boundary violation verification...\n");
  // 非 owner 线程调用公共销毁接口，在 Owner 线程退出后，在当前调用线程上强行执行 uv_loop_close
  ejs_runtime_destroy(runtime);

  printf("test_public_thread_boundary_violation PASS\n");
}

static void* public_blocking_js_thread(void *arg) {
  EJSCoreContext *context = (EJSCoreContext *)arg;
  ejs_eval_script(context, "infinite.js", "while(true) {}", 13);
  return NULL;
}

// 3. 验证 P0-2: 宿主死循环导致 ejs_runtime_destroy 阻塞挂起
// 说明：此测试运行后由于 Owner 线程被 JS 死循环独占，当前调用线程会在 pthread_join 上永久挂起死锁
static void test_public_destroy_hang(void) {
  EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();
  EJSCoreRuntime *runtime = ejs_runtime_create(&config);
  EJSCoreContext *context = ejs_context_create(runtime);
  
  pthread_t thread;
  pthread_create(&thread, NULL, public_blocking_js_thread, context);
  usleep(50000); // 确保死循环已占满 Owner 线程

  printf("[DEMO TEST] Calling ejs_runtime_destroy on blocked thread, expecting HANG...\n");
  ejs_runtime_destroy(runtime); 

  printf("test_public_destroy_hang PASS (This line should never be reached under deadlock)\n");
}

// -------------------------------------------------------------
// MAIN ENTRY
// -------------------------------------------------------------
int main(void) {
  setvbuf(stdout, NULL, _IONBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);
  printf("=========================================\n");
  printf("        STARTING EJS CORE TESTS         \n");
  printf("=========================================\n");

  test_runtime_lifecycle();
  test_abi_checks();
  test_error_handling();
  test_js_invoke_validation();
  test_js_invoke_binary();
  test_js_invoke_async();
  test_js_invoke_sync();
  test_host_api_partial_struct_copy();
#ifdef EJS_RUNTIME_LOOP_LIBUV
  test_timers_libuv();
  test_events_hooks_libuv();
  test_timer_reentrant_context_destroy();
#endif
  test_libuv_microtask_integration();
  test_safe_lifecycle_cancel();
  test_uaf_prevention();
  test_eval_module();
  test_coverage_booster();
  test_whitebox_precision_coverage();

  // High-intensity core upgrade test cases
  test_infinite_loop_interrupt();
  test_abi_validation();
  test_multi_context_batch_destruction();
  test_high_concurrency_uaf();
  test_duplicate_host_completion_idempotency();
  test_whitebox_precision_coverage_ext();
  test_whitebox_precision_coverage_super();

  // Upgrade lifecycle test cases
  test_host_lifecycle_upgrade();

  test_public_microtask_uaf();
  test_public_thread_boundary_violation();
  if (getenv("EJS_RUN_DEMO_HANG_TEST") != NULL) {
    test_public_destroy_hang();
  }

  printf("=========================================\n");
  printf("        ALL EJS CORE TESTS PASSED!      \n");

  printf("=========================================\n");
  return 0;
}

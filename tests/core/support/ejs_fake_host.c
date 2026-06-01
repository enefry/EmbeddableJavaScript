#include "ejs_fake_host.h"

#include <stdlib.h>
#include <string.h>

int ejs_test_inject_fake_host_error = 0;

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

#include <stdatomic.h>

struct EJSFakeHost {
  EJSCoreHostAPI api;
  EJSFakePending *pending;
  size_t pending_count;
  _Atomic(size_t) retain_count;
  _Atomic(size_t) release_count;
};

static void ejs_fake_host_user_data_retain(void *user_data) {
  EJSFakeHost *host = (EJSFakeHost *)user_data;
  if (host != NULL) {
    atomic_fetch_add(&host->retain_count, 1u);
  }
}

static void ejs_fake_host_user_data_release(void *user_data) {
  EJSFakeHost *host = (EJSFakeHost *)user_data;
  if (host != NULL) {
    atomic_fetch_add(&host->release_count, 1u);
  }
}

static void ejs_fake_unlink_pending(EJSFakePending *pending) {
  EJSFakeHost *host = pending->host;
  if (host == NULL) {
    return;
  }
  EJSFakePending **slot = &host->pending;
  while (*slot != NULL) {
    if (*slot == pending) {
      *slot = pending->next;
      host->pending_count--;
      return;
    }
    slot = &(*slot)->next;
  }
}

static int ejs_fake_pending_cancel(void *user_data) {
  EJSFakePending *pending = (EJSFakePending *)user_data;
  pending->canceled = true;
  if (pending->host != NULL) {
    ejs_fake_unlink_pending(pending);
    ejs_native_operation_release(pending->operation);
  }
  return 0;
}

static void ejs_fake_pending_destroy(void *user_data) {
  EJSFakePending *pending = (EJSFakePending *)user_data;
  ejs_fake_unlink_pending(pending);
  free(pending->module_id);
  free(pending->method_id);
  free(pending);
}

static EJSCoreHostOperation *ejs_fake_host_invoke(EJSCoreUserData user_data,
                                              const char *module_id,
                                              const char *method_id,
                                              EJSCoreByteView payload,
                                              EJSCoreByteView transfer_buffer,
                                              EJSCoreInvokeCompletion completion,
                                              void *completion_data) {
  (void)payload;
  (void)transfer_buffer;
  EJSFakeHost *host = (EJSFakeHost *)user_data.value;

  EJSFakePending *pending = (EJSFakePending *)calloc(1, sizeof(EJSFakePending));
  if (ejs_test_inject_fake_host_error == 1) {
    free(pending);
    pending = NULL;
  }
  if (pending == NULL) {
    return NULL;
  }

  pending->host = host;
  pending->module_id = module_id == NULL ? NULL : strdup(module_id);
  pending->method_id = method_id == NULL ? NULL : strdup(method_id);
  pending->completion = completion;
  pending->completion_data = completion_data;
  pending->operation =
      ejs_native_operation_create(pending, ejs_fake_pending_cancel, ejs_fake_pending_destroy);
  if (ejs_test_inject_fake_host_error == 2) {
    if (pending->operation != NULL) {
      ejs_native_operation_release(pending->operation);
      pending->operation = NULL;
    }
  }

  if (pending->operation == NULL) {
    free(pending->module_id);
    free(pending->method_id);
    free(pending);
    return NULL;
  }

  pending->next = host->pending;
  host->pending = pending;
  host->pending_count++;

  return pending->operation;
}

static void ejs_fake_fill_api(EJSFakeHost *host) {
  memset(&host->api, 0, sizeof(host->api));
  host->api.abi_version = EJS_NATIVE_ABI_VERSION;
  host->api.struct_size = sizeof(host->api);
  host->api.user_data = ejs_user_data_ref_make(host, ejs_fake_host_user_data_retain, ejs_fake_host_user_data_release);

  host->api.operations = ejs_native_operation_api();
  host->api.operations.user_data = ejs_user_data_ref_make(host, ejs_fake_host_user_data_retain, ejs_fake_host_user_data_release);

  host->api.invoke_api.abi_version = EJS_NATIVE_ABI_VERSION;
  host->api.invoke_api.struct_size = sizeof(host->api.invoke_api);
  host->api.invoke_api.user_data = ejs_user_data_ref_make(host, ejs_fake_host_user_data_retain, ejs_fake_host_user_data_release);
  host->api.invoke_api.invoke = ejs_fake_host_invoke;

  host->api.sync_invoke_api.abi_version = EJS_NATIVE_ABI_VERSION;
  host->api.sync_invoke_api.struct_size = sizeof(host->api.sync_invoke_api);
  host->api.sync_invoke_api.user_data = ejs_user_data_ref_null();
  host->api.sync_invoke_api.invoke_sync = NULL;
}

EJSFakeHost *ejs_fake_host_create(void) {
  EJSFakeHost *host = (EJSFakeHost *)calloc(1u, sizeof(EJSFakeHost));
  if (ejs_test_inject_fake_host_error == 3) {
    free(host);
    host = NULL;
  }
  if (host == NULL) {
    return NULL;
  }
  ejs_fake_fill_api(host);
  return host;
}

void ejs_fake_host_destroy(EJSFakeHost *host) {
  if (host == NULL) {
    return;
  }
  EJSFakePending *curr = host->pending;
  while (curr != NULL) {
    EJSFakePending *next = curr->next;
    curr->host = NULL;
    ejs_native_operation_release(curr->operation);
    curr = next;
  }
  free(host);
}

EJSCoreHostAPI *ejs_fake_host_api(EJSFakeHost *host) {
  if (host == NULL) {
    return NULL;
  }
  return &host->api;
}

size_t ejs_fake_host_pending_count(const EJSFakeHost *host) {
  if (host == NULL) {
    return 0u;
  }
  return host->pending_count;
}

void ejs_fake_host_complete_next(EJSFakeHost *host) {
  EJSFakePending *pending;
  if (host == NULL || host->pending == NULL) {
    return;
  }

  pending = host->pending;
  ejs_fake_unlink_pending(pending);

  EJSCoreHostError aborted;
  memset(&aborted, 0, sizeof(aborted));
  aborted.abi_version = EJS_NATIVE_ABI_VERSION;
  aborted.struct_size = sizeof(aborted);
  aborted.code = EJS_ERROR_ABORTED;
  aborted.message = "aborted";

  if (pending->canceled) {
    if (pending->completion != NULL) {
      EJSCoreByteView empty_res = {NULL, 0};
      pending->completion(pending->completion_data, empty_res, &aborted);
    }
  } else {
    EJSCoreByteView result;
    result.data = NULL;
    result.size = 0;

    EJSCoreHostError success_err;
    memset(&success_err, 0, sizeof(success_err));
    success_err.abi_version = EJS_NATIVE_ABI_VERSION;
    success_err.struct_size = sizeof(success_err);
    success_err.code = EJS_ERROR_NONE;

    if (pending->module_id != NULL && strcmp(pending->module_id, "fs") == 0) {
      const char *mock_file = "mock file contents from fake host";
      result.data = (const uint8_t *)mock_file;
      result.size = strlen(mock_file);
    } else if (pending->module_id != NULL && strcmp(pending->module_id, "http") == 0) {
      const char *mock_http = "mock http response from fake host";
      result.data = (const uint8_t *)mock_http;
      result.size = strlen(mock_http);
    } else {
      const char *mock_gen = "mock generic response";
      result.data = (const uint8_t *)mock_gen;
      result.size = strlen(mock_gen);
    }

    if (pending->completion != NULL) {
      pending->completion(pending->completion_data, result, &success_err);
    }
  }

  EJSCoreHostOperation *op = pending->operation;
  (void)ejs_native_operation_complete(op);
}

void ejs_fake_host_complete_all(EJSFakeHost *host) {
  while (host != NULL && host->pending != NULL) {
    ejs_fake_host_complete_next(host);
  }
}

size_t ejs_fake_host_retain_count(const EJSFakeHost *host) {
  if (host == NULL) return 0;
  return atomic_load(&host->retain_count);
}

size_t ejs_fake_host_release_count(const EJSFakeHost *host) {
  if (host == NULL) return 0;
  return atomic_load(&host->release_count);
}

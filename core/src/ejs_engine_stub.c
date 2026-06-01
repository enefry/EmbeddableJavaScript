/**
 * ejs_engine_stub.c — 引擎后端的空实现（Stub）
 *
 * 本文件实现了 ejs_engine.h 中定义的所有引擎后端接口函数，
 * 但不提供实际的 JS 执行能力。主要用于：
 *   - 编译测试：验证核心运行时代码在没有真实 JS 引擎时能否正确编译
 *   - 独立测试：测试运行时的生命周期管理和错误处理逻辑，
 *     而不依赖 QuickJS 的行为
 *
 * Stub 实现的特点：
 *   - runtime/context 创建：仅分配空结构体，不初始化 JS 引擎
 *   - 脚本/模块求值：始终返回 EJS_ERROR_UNSUPPORTED 错误
 *   - 微任务执行：直接返回成功（无微任务可执行）
 *   - 中断请求：设置布尔标志（无实际效果）
 *   - 上下文关联：使用简单的 void* opaque 指针
 *
 * 注意：ejs_test_inject_engine_error 变量必须在此文件中定义，
 * 即使 stub 后端不使用错误注入，因为链接时该符号必须存在。
 */

#include "ejs_engine.h"

#include <stdlib.h>

/**
 * ejs_test_inject_engine_error — 错误注入开关（stub 版本，始终为 0）
 *
 * 在 stub 后端中不使用错误注入机制，但符号必须定义以满足链接要求。
 * 详见 ejs_engine_quickjs_ng.c 中的完整说明。
 */
#ifdef EJS_TEST
int ejs_test_inject_engine_error = 0;
#endif

/**
 * struct EJSEngineRuntime — Stub 引擎运行时
 *
 * 仅包含中断请求标志，无 QuickJS 运行时实例。
 */
struct EJSEngineRuntime {
  bool interrupt_requested; /* 中断请求标志（无实际效果） */
};

/**
 * struct EJSEngineContext — Stub 引擎上下文
 *
 * 仅包含运行时反向引用和上下文关联的 opaque 指针。
 */
struct EJSEngineContext {
  EJSEngineRuntime *runtime; /* 反向引用所属的引擎运行时 */
  void *opaque;              /* 关联的公共 EJSCoreContext 指针 */
};

/**
 * ejs_engine_runtime_create — 创建 Stub 引擎运行时
 *
 * 分配一个空的 EJSEngineRuntime 结构体，不初始化任何 JS 引擎。
 */
EJSEngineRuntime *ejs_engine_runtime_create(const EJSCoreRuntimeConfig *config, EJSCoreError **out_error) {
  (void)config;
  if (out_error != NULL) {
    *out_error = NULL;
  }
  return (EJSEngineRuntime *)calloc(1u, sizeof(EJSEngineRuntime));
}

/**
 * ejs_engine_runtime_destroy — 销毁 Stub 引擎运行时
 *
 * 直接释放结构体内存。
 */
void ejs_engine_runtime_destroy(EJSEngineRuntime *engine) {
  free(engine);
}

EJSEngineContext *ejs_engine_context_create(EJSEngineRuntime *engine, EJSCoreError **out_error) {
  EJSEngineContext *context;
  if (out_error != NULL) {
    *out_error = NULL;
  }
  if (engine == NULL) {
    if (out_error != NULL) {
      *out_error = ejs_error_create(EJS_ERROR_INVALID_ARGUMENT, "invalid engine runtime", NULL, NULL, 0);
    }
    return NULL;
  }
  context = (EJSEngineContext *)calloc(1u, sizeof(EJSEngineContext));
  if (context != NULL) {
    context->runtime = engine;
  }
  return context;
}

/**
 * ejs_engine_context_destroy — 销毁 Stub 引擎上下文
 *
 * Stub context 不持有 JS 对象或定时器，因此只释放结构体本身。
 */
void ejs_engine_context_destroy(EJSEngineContext *context) {
  free(context);
}

/**
 * ejs_engine_context_register_core_bindings — Stub 绑定注册
 *
 * 没有真实 JS 全局对象可注入；返回 OK 让 runtime 生命周期测试能够覆盖
 * context 创建路径。
 */
EJSCoreResult ejs_engine_context_register_core_bindings(EJSEngineContext *context) {
  (void)context;
  return ejs_result_ok();
}

/**
 * ejs_engine_context_associate_runtime_context — 保存公共 context 反向引用
 *
 * Stub 后端用简单 opaque 指针模拟 QuickJS 的 JS_SetContextOpaque。
 */
void ejs_engine_context_associate_runtime_context(EJSEngineContext *context, void *opaque) {
  if (context != NULL) {
    context->opaque = opaque;
  }
}

/**
 * ejs_engine_context_retrieve_runtime_context — 读取 Stub opaque 指针
 */
void *ejs_engine_context_retrieve_runtime_context(EJSEngineContext *context) {
  return context == NULL ? NULL : context->opaque;
}

/**
 * ejs_engine_eval_script — Stub 不支持脚本执行
 *
 * 返回 UNSUPPORTED 而不是伪造成功，避免调用方误以为 JS 已实际运行。
 */
EJSCoreResult ejs_engine_eval_script(EJSEngineContext *context,
                                 const char *filename,
                                 const char *source,
                                 size_t source_len) {
  (void)context;
  (void)filename;
  (void)source;
  (void)source_len;
  return ejs_result_error(ejs_error_create(EJS_ERROR_UNSUPPORTED,
                                           "script evaluation requires a real JS engine backend",
                                           NULL,
                                           NULL,
                                           0));
}

/**
 * ejs_engine_eval_module — Stub 不支持模块执行
 */
EJSCoreResult ejs_engine_eval_module(EJSEngineContext *context,
                                 const EJSCoreEvalOptions *options,
                                 const char *source,
                                 size_t source_len) {
  (void)context;
  (void)options;
  (void)source;
  (void)source_len;
  return ejs_result_error(ejs_error_create(EJS_ERROR_UNSUPPORTED,
                                           "module evaluation requires a real JS engine backend",
                                           NULL,
                                           NULL,
                                           0));
}

EJSCoreResult ejs_engine_register_module_sources(EJSEngineContext *context,
                                                 const EJSCoreModuleSource *sources,
                                                 size_t source_count) {
  (void)context;
  (void)sources;
  (void)source_count;
  return ejs_result_error(ejs_error_create(EJS_ERROR_UNSUPPORTED,
                                           "module source registration requires a real JS engine backend",
                                           NULL,
                                           NULL,
                                           0));
}

/**
 * ejs_engine_run_jobs — Stub 没有微任务队列
 *
 * 直接返回 OK，使 runtime drain 测试可以在无真实 engine 时执行。
 */
EJSCoreResult ejs_engine_run_jobs(EJSEngineRuntime *engine) {
    (void)engine;
    return ejs_result_ok();
}

bool ejs_engine_has_pending_jobs(EJSEngineRuntime *engine) {
    (void)engine;
    return false;
}

/**
 * ejs_engine_request_interrupt — 记录中断请求
 *
 * Stub 无执行中的 JS 可打断，但保留状态便于生命周期路径保持一致。
 */
void ejs_engine_request_interrupt(EJSEngineRuntime *engine) {
  if (engine != NULL) {
    engine->interrupt_requested = true;
  }
}

/**
 * ejs_engine_name — 返回 Stub 后端名称
 */
const char *ejs_engine_name(void) {
  return "stub";
}

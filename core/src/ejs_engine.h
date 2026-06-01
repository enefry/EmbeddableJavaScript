/**
 * ejs_engine.h — JS 引擎后端的抽象接口
 *
 * 本头文件定义了 EJS 运行时与底层 JS 引擎之间的抽象层接口。
 * 通过这层抽象，EJS 可以支持多种 JS 引擎后端（如 QuickJS-ng、V8 等），
 * 而核心运行时代码无需关心引擎的具体实现细节。
 *
 * 引擎后端必须实现以下功能：
 *   1. 运行时生命周期：ejs_engine_runtime_create / destroy
 *   2. 上下文生命周期：ejs_engine_context_create / destroy
 *   3. 脚本/模块求值：ejs_engine_eval_script / eval_module
 *   4. 微任务执行：ejs_engine_run_jobs
 *   5. 中断请求：ejs_engine_request_interrupt
 *   6. 核心绑定注册：ejs_engine_context_register_core_bindings
 *   7. 上下文关联：associate / retrieve_runtime_context
 *   8. 引擎标识：ejs_engine_name
 *
 * 当前提供的后端实现：
 *   - ejs_engine_quickjs_ng.c: 基于 QuickJS-ng 的完整实现
 *   - ejs_engine_stub.c: 空实现，用于编译测试和独立测试
 *
 * 线程安全：
 *   所有引擎操作必须在 owner 线程（即运行时事件循环线程）上执行。
 *   ejs_runtime_loop_call_sync 负责将调用投递到正确的线程。
 */

#ifndef EJS_ENGINE_H
#define EJS_ENGINE_H

#include <stdbool.h>
#include <stddef.h>

#include "ejs_error.h"
#include "ejs_runtime.h"

/**
 * EJSEngineRuntime — 引擎后端运行时的不透明类型
 *
 * 由各引擎后端自行定义内部结构（如 QuickJS-ng 的 JSRuntime 包装）。
 */
typedef struct EJSEngineRuntime   EJSEngineRuntime;

/**
 * EJSEngineContext — 引擎后端上下文的不透明类型
 *
 * 由各引擎后端自行定义内部结构（如 QuickJS-ng 的 JSContext 包装）。
 */
typedef struct EJSEngineContext   EJSEngineContext;

/**
 * ejs_engine_runtime_create — 创建引擎运行时实例
 *
 * 根据 config 配置初始化底层 JS 引擎运行时。具体行为：
 *   - QuickJS-ng 后端：调用 JS_NewRuntime()，设置内存/栈限制，
 *     注册中断处理器
 *   - Stub 后端：分配空结构体
 *
 * @param config    运行时配置（内存限制、栈大小等），可为 NULL（使用默认值）
 * @param out_error 输出错误对象，失败时设置；可为 NULL
 * @return 引擎运行时实例；失败时返回 NULL
 */
EJSEngineRuntime * ejs_engine_runtime_create(const EJSCoreRuntimeConfig *config, EJSCoreError **out_error);

/**
 * ejs_engine_runtime_destroy — 销毁引擎运行时实例
 *
 * 释放底层 JS 引擎运行时及其所有关联资源。
 * 传入 NULL 是安全的（无操作）。
 *
 * @param engine 引擎运行时实例，可为 NULL
 */
void ejs_engine_runtime_destroy(EJSEngineRuntime *engine);

/**
 * ejs_engine_context_create — 在引擎运行时中创建执行上下文
 *
 * 创建一个新的 JS 执行环境，包含独立的全局对象和模块作用域。
 *
 * @param engine    所属的引擎运行时，不可为 NULL
 * @param out_error 输出错误对象，失败时设置；可为 NULL
 * @return 引擎上下文实例；失败时返回 NULL
 */
EJSEngineContext * ejs_engine_context_create(EJSEngineRuntime *engine, EJSCoreError **out_error);

/**
 * ejs_engine_context_destroy — 销毁引擎上下文
 *
 * 释放上下文及其所有关联的 JS 对象、定时器、挂起操作等。
 * 传入 NULL 是安全的（无操作）。
 *
 * @param context 引擎上下文实例，可为 NULL
 */
void ejs_engine_context_destroy(EJSEngineContext *context);

/**
 * ejs_engine_eval_script — 以全局模式执行 JS 脚本
 *
 * 在指定上下文中以 JS_EVAL_TYPE_GLOBAL 模式执行 JS 源代码。
 * 执行是同步的，函数返回时脚本已执行完毕。
 *
 * @param context    引擎上下文
 * @param filename   源文件名，用于堆栈跟踪；可为 NULL
 * @param source     JS 源代码
 * @param source_len 源代码字节长度
 * @return 执行结果
 */
EJSCoreResult ejs_engine_eval_script(EJSEngineContext *context,
                                 const char       *filename,
                                 const char       *source,
                                 size_t           source_len);

/**
 * ejs_engine_eval_module — 以 ES 模块模式执行 JS 代码
 *
 * 在指定上下文中以 JS_EVAL_TYPE_MODULE 模式执行 JS 源代码，
 * 支持 import/export 语法。
 *
 * @param context    引擎上下文
 * @param options    模块求值选项（specifier、source_url、kind）
 * @param source     JS 模块源代码
 * @param source_len 源代码字节长度
 * @return 执行结果
 */
EJSCoreResult ejs_engine_eval_module(EJSEngineContext     *context,
                                 const EJSCoreEvalOptions *options,
                                 const char           *source,
                                 size_t               source_len);

/**
 * ejs_engine_register_module_sources — 注册引擎上下文的内存模块源码表
 *
 * 供 core public API 在 owner 线程调用。引擎实现必须深拷贝 sources，并保证
 * 后续 module loader 只从注册表同步读取源码，不触发 I/O 或 provider 调用。
 */
EJSCoreResult ejs_engine_register_module_sources(EJSEngineContext             *context,
                                                 const EJSCoreModuleSource   *sources,
                                                 size_t                       source_count);

/**
 * ejs_engine_run_jobs — 执行引擎中所有待处理的微任务
 *
 * 循环调用 JS_ExecutePendingJob 直到所有微任务执行完毕或出错。
 * 微任务包括 Promise 回调、async/await 续延等。
 *
 * @param engine 引擎运行时
 * @return 执行结果；若某个微任务抛出异常则返回错误
 */
EJSCoreResult ejs_engine_run_jobs(EJSEngineRuntime *engine);

/**
 * ejs_engine_has_pending_jobs — 查询引擎运行时是否仍有待执行微任务
 *
 * runtime 层用它判断 owner-thread 上延迟销毁的 context 是否已经到达安全
 * 释放点。只要 QuickJS job 队列里还有任务，就不能释放任何 JSContext：
 * pending job 自身持有创建它的 JSContext 指针。
 */
bool ejs_engine_has_pending_jobs(EJSEngineRuntime *engine);

/**
 * ejs_engine_request_interrupt — 请求中断 JS 执行
 *
 * 设置引擎的中断标志，引擎将在下一个检查点中断当前 JS 执行。
 *
 * @param engine 引擎运行时，可为 NULL
 */
void ejs_engine_request_interrupt(EJSEngineRuntime *engine);

/**
 * ejs_engine_context_register_core_bindings — 注册内核原语到 JS 全局对象
 *
 * 在上下文的全局对象上注入 __ejs_native__ 对象及其子方法：
 *   - __ejs_native__.invoke(module_id, method_id, payload, transfer_buffer)
 *     万能异步通道，所有 WinterTC API 通过此方法跨层调用
 *   - __ejs_native__.invokeSync(module_id, method_id, payload, transfer_buffer)
 *     可选同步通道，用于 bounded native provider 能力
 *   - __ejs_native__.timers.create(delay, repeat, callback)
 *     创建定时器，对应 JS 的 setTimeout/setInterval
 *   - __ejs_native__.timers.destroy(timer_id)
 *     销毁定时器，对应 JS 的 clearTimeout/clearInterval
 *   - __ejs_native__.events.setPromiseRejectionTracker(callback)
 *     注册 engine-neutral Promise rejection 事件回调
 *   - __ejs_native__.events.setExceptionReporter(callback)
 *     注册 timer/job 等异步异常回调
 *
 * @param context 引擎上下文
 * @return 注册结果
 */
EJSCoreResult ejs_engine_context_register_core_bindings(EJSEngineContext *context);

/**
 * ejs_engine_context_associate_runtime_context — 将公共上下文与引擎上下文关联
 *
 * 通过 JS_SetContextOpaque 将 EJSCoreContext 指针存储到引擎上下文中，
 * 使得引擎回调（如 invoke、timer）可以通过 JS_GetContextOpaque
 * 获取到公共上下文。
 *
 * @param context 引擎上下文
 * @param opaque  公共 EJSCoreContext 指针
 */
void ejs_engine_context_associate_runtime_context(EJSEngineContext *context, void *opaque);

/**
 * ejs_engine_context_retrieve_runtime_context — 从引擎上下文获取关联的公共上下文
 *
 * 通过 JS_GetContextOpaque 获取之前关联的 EJSCoreContext 指针。
 *
 * @param context 引擎上下文
 * @return 关联的公共 EJSCoreContext 指针，未关联时返回 NULL
 */
void * ejs_engine_context_retrieve_runtime_context(EJSEngineContext *context);

/**
 * ejs_engine_name — 获取当前引擎后端的名称
 *
 * 用于诊断和日志，返回静态字符串（无需释放）：
 *   - QuickJS-ng 后端返回 "quickjs-ng"
 *   - Stub 后端返回 "stub"
 *
 * @return 引擎名称字符串
 */
const char * ejs_engine_name(void);

#endif /* ifndef EJS_ENGINE_H */

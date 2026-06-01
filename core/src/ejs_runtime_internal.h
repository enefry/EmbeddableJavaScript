/**
 * ejs_runtime_internal.h — EJS 运行时内部数据结构与辅助函数
 *
 * 本头文件定义了 EJSCoreRuntime 和 EJSCoreContext 的完整内部结构，
 * 以及运行时内部使用的辅助函数。这些定义仅对 core/src/ 内部的
 * 实现文件可见，不对外暴露。
 *
 * 架构概览：
 *   EJSCoreRuntime（运行时）
 *     ├── EJSEngineRuntime（JS 引擎运行时，如 QuickJS JSRuntime）
 *     ├── EJSRuntimeLoop（事件循环，基于 libuv 或 stub）
 *     ├── engine_class_state（引擎类状态，预留）
 *     └── context_list（双链表，挂载所有 EJSCoreContext）
 *
 *   EJSCoreContext（执行上下文）
 *     ├── EJSEngineContext（JS 引擎上下文，如 QuickJS JSContext）
 *     ├── runtime（反向引用所属的 EJSCoreRuntime）
 *     ├── host（原子指针，指向注册的 EJSCoreHostAPI）
 *     └── prev/next（双链表节点，用于 runtime->context_list）
 *
 * 线程安全约定：
 *   - EJSCoreRuntime 和 EJSCoreContext 不是线程安全的
 *   - 所有对同一 EJSCoreRuntime 的操作必须在 owner 线程上执行
 *   - host 指针使用原子操作（_Atomic），因为宿主注册和 JS 读取
 *     可能来自不同线程
 *   - pending_host_operation_count 使用原子计数器，宿主线程和
 *     JS 线程均可递增/递减
 */

#ifndef EJS_RUNTIME_INTERNAL_H
#define EJS_RUNTIME_INTERNAL_H

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include "ejs_refcount.h"
#include "ejs_runtime.h"
#include "ejs_runtime_loop.h"

/**
 * EJSEngineRuntime / EJSEngineContext — 引擎后端的不透明类型
 *
 * 具体定义由各引擎后端提供（如 ejs_engine_quickjs_ng.c），
 * 此处仅做前向声明。
 */
typedef struct EJSEngineRuntime          EJSEngineRuntime;
typedef struct EJSEngineContext          EJSEngineContext;
typedef struct EJSRegisteredHost         EJSRegisteredHost;
typedef struct EJSRuntimeDestroyWaiter   EJSRuntimeDestroyWaiter;

struct EJSRuntimeDestroyWaiter {
    EJSCoreRuntimeStopCompletion completion;
    void *user_data;
    int is_inline;
    EJSRuntimeDestroyWaiter *next;
};

/**
 * 魔数常量 — 用于运行时和上下文的结构体验证
 *
 * EJS_RUNTIME_MAGIC = 0x454a5352u — ASCII "EJSR"（EJS Runtime）
 * EJS_CONTEXT_MAGIC = 0x454a5343u — ASCII "EJSC"（EJS Context）
 *
 * 创建时写入 magic 字段，销毁时清零。用于 ejs_runtime_is_valid /
 * ejs_context_is_valid 快速检测悬挂指针或已释放的对象。
 */
enum {
    EJS_RUNTIME_MAGIC = 0x454a5352u,
    EJS_CONTEXT_MAGIC = 0x454a5343u
};

/**
 * EJSRuntimeState — 运行时的生命周期状态
 *
 * 状态转换图：
 *   CREATED → RUNNING → STOPPING → STOPPED → DESTROYED
 *
 *   CREATED:  刚创建，事件循环尚未启动
 *   RUNNING:  事件循环已启动，可正常执行 JS 代码
 *   STOPPING: 正在优雅停止（预留状态，当前未使用）
 *   STOPPED:  事件循环已停止
 *   DESTROYED: 已标记销毁，所有后续操作将被拒绝
 */
typedef enum {
    EJS_RUNTIME_STATE_CREATED   = 0,
    EJS_RUNTIME_STATE_RUNNING   = 1,
    EJS_RUNTIME_STATE_STOPPING  = 2,
    EJS_RUNTIME_STATE_STOPPED   = 3,
    EJS_RUNTIME_STATE_DESTROYED = 4
} EJSRuntimeState;

/**
 * struct EJSCoreRuntime — JS 运行时实例的完整内部表示
 *
 * 一个 EJSCoreRuntime 包含一个 JS 引擎运行时和一个事件循环，
 * 以及零个或多个通过双链表挂载的 EJSCoreContext。
 */
struct EJSCoreRuntime {
    EJSRefCount ref_count; /* runtime 物理内存引用计数，覆盖迟到 host completion */
    uint32_t magic;           /* 结构体验证魔数，必须为 EJS_RUNTIME_MAGIC */
    _Atomic(bool) alive;      /* 存活标志，销毁时置为 false */
    _Atomic(EJSRuntimeState) state; /* 当前生命周期状态 */
    _Atomic(bool) interrupt_requested;/* 中断请求标志，由 ejs_request_interrupt 设置 */
    EJSEngineRuntime *engine_runtime; /* JS 引擎后端运行时实例 */
    EJSRuntimeLoop *runtime_loop;   /* 事件循环实例（libuv 或 stub） */
    void *engine_class_state; /* 引擎类状态，预留扩展 */
    const char *runtime_name;  /* 运行时名称标识，仅诊断用，不拥有内存 */
    const char *runtime_version; /* 运行时版本号，仅诊断用，不拥有内存 */
    uint64_t memory_limit_bytes; /* JS 堆内存上限，0 表示不限制 */
    uint32_t max_stack_size;   /* JS 调用栈上限，0 表示引擎默认 */
    _Atomic(uint64_t) pending_host_operation_count; /* 挂起的宿主操作计数，原子变量 */
    struct EJSCoreContext *context_list; /* 挂载的所有上下文的双链表头 */
    struct EJSCoreContext *deferred_destroy_list; /* owner-thread 延后释放的 context 链表 */
    uint32_t owner_callback_depth; /* owner 线程正在执行 JS/Native 回调的嵌套深度 */
    pthread_mutex_t destroy_mutex; /* 保护 destroy completion 等待队列 */
    pthread_cond_t destroy_cond; /* waiter 分配失败时等待真实销毁完成 */
    EJSRuntimeDestroyWaiter *destroy_waiters_head;
    EJSRuntimeDestroyWaiter *destroy_waiters_tail;
    EJSRuntimeDestroyWaiter destroy_waiters_inline[4];
    bool destroy_waiters_inline_used[4];
    _Atomic(bool) destroy_completed;
};

struct EJSRegisteredHost {
    EJSRefCount ref_count;
    EJSCoreHostAPI api;
};

/**
 * struct EJSCoreContext — JS 执行上下文的完整内部表示
 *
 * 每个 EJSCoreContext 拥有独立的 JS 引擎上下文（全局对象、模块作用域），
 * 并通过 prev/next 指针挂载在所属 EJSCoreRuntime 的 context_list 中。
 * host 指针使用原子类型，因为注册（宿主线程）和读取（JS 线程）
 * 可能跨线程进行。
 */
struct EJSCoreContext {
    EJSRefCount ref_count; /* Context 物理生命周期引用计数 */
    uint32_t magic;        /* 结构体验证魔数，必须为 EJS_CONTEXT_MAGIC */
    _Atomic(bool) alive;   /* 存活标志，销毁时置为 false */
    EJSEngineContext *engine_context; /* JS 引擎后端上下文实例 */
    EJSCoreRuntime *runtime;   /* 反向引用所属的运行时 */
    pthread_mutex_t host_mutex; /* 互斥锁，保护 host 交换与内部引用计数 */
    EJSRegisteredHost *host;    /* 指向内部注册并托管生命周期的 host API */
    struct EJSCoreContext *prev; /* 双链表前驱指针 */
    struct EJSCoreContext *next; /* 双链表后继指针 */
    struct EJSCoreContext *destroy_next; /* owner-thread 延后释放链表节点 */
    bool destroy_queued; /* 是否已经挂入 deferred_destroy_list */
};

/**
 * ejs_runtime_is_valid — 检查运行时实例是否有效
 *
 * 通过 magic 和 alive 标志联合判断，用于在公共 API 入口处
 * 防御悬挂指针和已销毁的对象。
 *
 * @param runtime 运行时指针，可为 NULL
 * @return true 表示运行时有效且存活
 */
bool ejs_runtime_is_valid(const EJSCoreRuntime *runtime);

/**
 * ejs_context_is_valid — 检查上下文实例是否有效
 *
 * 除了检查自身的 magic 和 alive 外，还递归检查所属运行时是否有效，
 * 确保在运行时已销毁的情况下不会误判上下文为有效。
 *
 * @param context 上下文指针，可为 NULL
 * @return true 表示上下文及其所属运行时均有效且存活
 */
bool ejs_context_is_valid(const EJSCoreContext *context);

void ejs_runtime_retain(EJSCoreRuntime *runtime);
void ejs_runtime_release(EJSCoreRuntime *runtime);
void ejs_runtime_enter_owner_callback(EJSCoreRuntime *runtime);
void ejs_runtime_leave_owner_callback(EJSCoreRuntime *runtime);
void ejs_runtime_enqueue_deferred_context_destroy(EJSCoreContext *context);
void ejs_runtime_flush_deferred_context_destroys(EJSCoreRuntime *runtime);
void ejs_runtime_force_flush_deferred_context_destroys(EJSCoreRuntime *runtime);

/**
 * ejs_runtime_drain_for_test — 在测试中驱动运行时处理挂起的微任务
 *
 * 此函数仅供测试使用。它会在 owner 线程上同步执行 JS 引擎的
 * 待处理微任务（Promise 回调等），以便在测试中验证异步行为。
 *
 * @param runtime 运行时实例
 * @return 执行结果
 */
EJSCoreResult ejs_runtime_drain_for_test(EJSCoreRuntime *runtime);

EJSRegisteredHost * ejs_registered_host_retain(EJSRegisteredHost *host);
void ejs_registered_host_release(EJSRegisteredHost *host);
EJSRegisteredHost * ejs_context_acquire_host(EJSCoreContext *context);

#endif /* ifndef EJS_RUNTIME_INTERNAL_H */

/**
 * ejs_runtime_loop.h — EJS 运行时事件循环的公共接口
 *
 * 本头文件定义了运行时事件循环和定时器的抽象接口。
 * 事件循环是 EJS 运行时的核心线程基础设施，负责：
 *   - 驱动 JS 引擎的微任务（Promise 回调等）
 *   - 调度定时器（setTimeout/setInterval）
 *   - 处理异步 I/O 事件（网络、文件系统等）
 *   - 跨线程任务投递（同步调用和异步投递）
 *
 * 当前提供的后端实现：
 *   - ejs_runtime_loop_libuv.c: 基于 libuv 的完整实现，支持多线程、
 *     异步 I/O、定时器、prepare/check 句柄驱动微任务
 *   - ejs_runtime_loop_stub.c: 空实现，用于编译测试和独立测试
 *
 * 事件循环线程模型：
 *   - libuv 后端：创建独立的 owner 线程运行 uv_run 循环，
 *     所有 JS 引擎操作在此线程上执行
 *   - stub 后端：在同一线程执行，无实际事件循环
 *
 * 线程安全：
 *   - ejs_runtime_loop_call_sync / post 可从任意线程安全调用
 *   - 内部通过互斥锁和条件变量（libuv 后端）或简单函数调用（stub 后端）
 *     将任务投递到 owner 线程
 */

#ifndef EJS_RUNTIME_LOOP_H
#define EJS_RUNTIME_LOOP_H

#include <stdint.h>

#include "ejs_error.h"

/**
 * EJSRuntimeLoop — 运行时事件循环的不透明类型
 *
 * 具体定义由各事件循环后端提供（libuv 或 stub）。
 */
typedef struct EJSRuntimeLoop EJSRuntimeLoop;

/**
 * EJSCoreRuntime — 前向声明
 *
 * 用于事件循环创建时接收 runtime 指针。
 */
struct EJSCoreRuntime;

/**
 * EJSRuntimeLoopTaskCallback — 事件循环任务的回调函数类型
 *
 * 所有投递到事件循环的任务都通过此类型的回调函数执行。
 * 回调在 owner 线程上被调用。
 *
 * @param user_data 任务的用户上下文数据
 */
typedef void (*EJSRuntimeLoopTaskCallback)(void *user_data);
typedef void (*EJSRuntimeLoopExitCallback)(void *user_data);

/**
 * ejs_runtime_loop_create — 创建事件循环实例
 *
 * 初始化底层事件循环基础设施：
 *   - libuv 后端：创建 uv_loop_t、async 句柄、prepare/check 句柄
 *   - stub 后端：分配一个简单的结构体
 *
 * @param runtime   所属的 EJSCoreRuntime，用于 prepare/check 句柄中
 *                  访问引擎运行时以驱动微任务
 * @param out_error 输出错误对象，失败时设置；可为 NULL
 * @return 事件循环实例；失败时返回 NULL
 */
EJSRuntimeLoop *ejs_runtime_loop_create(struct EJSCoreRuntime *runtime, EJSCoreError **out_error);

/**
 * ejs_runtime_loop_destroy — 销毁事件循环实例
 *
 * 优雅停止事件循环，清理所有句柄和资源，然后释放事件循环结构体。
 * 传入 NULL 是安全的（无操作）。
 *
 * @param loop 事件循环实例，可为 NULL
 */
void ejs_runtime_loop_destroy(EJSRuntimeLoop *loop);

/**
 * ejs_runtime_loop_start — 启动事件循环
 *
 * 在独立的 owner 线程上启动事件循环：
 *   - libuv 后端：创建 pthread 线程并运行 uv_run(UV_RUN_DEFAULT)
 *   - stub 后端：简单设置 running 标志
 *
 * @param loop 事件循环实例
 * @return 启动结果；若线程创建失败则返回错误
 */
EJSCoreResult ejs_runtime_loop_start(EJSRuntimeLoop *loop);

/**
 * ejs_runtime_loop_stop — 停止事件循环
 *
 * 请求停止事件循环并等待 owner 线程退出：
 *   - libuv 后端：设置 stop_requested 标志，发送 uv_async_send 唤醒循环，
 *     然后 pthread_join 等待线程退出。stop 后的 loop 进入终止态，只能 destroy，
 *     不能再次 start
 *   - stub 后端：清除 running 标志
 *
 * 调用约束：如果 owner 线程可能正在执行长时间 JS，runtime 层必须先请求
 * engine interrupt，再调用本底层 stop；否则 owner 线程无法回到 uv_run 消费
 * wakeup 时，调用线程会按 pthread_join 语义等待。
 *
 * @param loop 事件循环实例
 * @return 停止结果
 */
EJSCoreResult ejs_runtime_loop_stop(EJSRuntimeLoop *loop);

/**
 * ejs_runtime_loop_pump — 手动驱动事件循环执行一次
 *
 * 非阻塞地运行事件循环的一个迭代，处理当前就绪的事件和任务。
 * 主要用于测试和同步模式下的手动事件处理。
 *
 * @param loop          事件循环实例
 * @param max_iterations 最大迭代次数，0 表示 1 次
 * @return 执行结果
 */
EJSCoreResult ejs_runtime_loop_pump(EJSRuntimeLoop *loop, uint32_t max_iterations);

/**
 * ejs_runtime_loop_call_sync — 同步投递任务到事件循环的 owner 线程
 *
 * 如果当前线程就是 owner 线程，则直接执行回调；
 * 否则将任务加入队列，发送唤醒信号，然后通过条件变量等待任务完成。
 *
 * 此函数是线程安全的，可被任意线程调用。
 * user_data 是调用方上下文，事件循环只传递、不拥有、不释放。由于本函数会等待
 * callback 执行结束才返回，栈上 user_data 在 callback 期间保持有效即可。
 *
 * @param loop      事件循环实例
 * @param callback  任务回调函数，在 owner 线程上执行
 * @param user_data 传递给回调的用户数据
 * @return 投递结果
 */
EJSCoreResult ejs_runtime_loop_call_sync(EJSRuntimeLoop *loop,
                                      EJSRuntimeLoopTaskCallback callback,
                                      void *user_data);

/**
 * ejs_runtime_loop_post — 异步投递任务到事件循环的 owner 线程
 *
 * 将任务加入队列并发送唤醒信号，但不等待任务完成。
 * 任务将在 owner 线程上异步执行。
 *
 * 此函数是线程安全的，可被任意线程调用。
 * user_data 是调用方上下文，事件循环只保存指针并在未来回调时原样传回，不会复制
 * 或释放。调用方必须保证 user_data 活到 callback 返回；若需要自动释放，请在
 * callback 内自行释放或使用上层对象的引用计数管理。
 *
 * @param loop      事件循环实例
 * @param callback  任务回调函数，在 owner 线程上执行
 * @param user_data 传递给回调的用户数据
 * @return 投递结果
 */
EJSCoreResult ejs_runtime_loop_post(EJSRuntimeLoop *loop,
                                 EJSRuntimeLoopTaskCallback callback,
                                 void *user_data);

/**
 * ejs_runtime_loop_close_handles — 关闭事件循环的所有活跃句柄
 *
 * 在 owner 线程中优雅关闭事件循环的所有活跃句柄（prepare、check、async），
 * 但不销毁事件循环本身。用于异步销毁流程中的中间步骤。
 *
 * @param loop 事件循环实例
 */
void ejs_runtime_loop_close_handles(EJSRuntimeLoop *loop);

/**
 * ejs_runtime_loop_is_thread_started — 检查事件循环线程是否已启动
 *
 * @param loop 事件循环实例
 * @return true 表示 owner 线程已启动且正在运行
 */
bool ejs_runtime_loop_is_thread_started(EJSRuntimeLoop *loop);

/**
 * ejs_runtime_loop_is_owner_thread — 检查当前线程是否是 loop owner 线程
 *
 * 该接口仅供 runtime 销毁状态机判断同步 destroy 是否会自锁；不暴露底层线程句柄。
 *
 * @param loop 事件循环实例
 * @return true 表示当前线程就是 owner 线程
 */
bool ejs_runtime_loop_is_owner_thread(EJSRuntimeLoop *loop);

/**
 * ejs_runtime_loop_destroy_after_owner_exit — owner 线程退出后自清理 loop
 *
 * 仅供 owner-thread destroy 的极端降级路径使用。调用方必须已经在 owner 线程上，
 * 本函数会请求 uv_run 退出；线程主函数在当前回调栈完全返回后调用 before_close，
 * drain/close/free loop，并在 after_close 非空时继续回调 after_close。
 */
void ejs_runtime_loop_destroy_after_owner_exit(EJSRuntimeLoop *loop,
                                               EJSRuntimeLoopExitCallback before_close,
                                               EJSRuntimeLoopExitCallback after_close,
                                               void *user_data);

/**
 * EJSRuntimeTimer — 运行时定时器的不透明类型
 *
 * 具体定义由各事件循环后端提供。
 */
typedef struct EJSRuntimeTimer EJSRuntimeTimer;

/**
 * EJSRuntimeTimerCallback — 定时器到期回调函数类型
 *
 * 当定时器到期时，在 owner 线程上调用此回调。
 *
 * @param user_data 定时器的用户上下文数据
 */
typedef void (*EJSRuntimeTimerCallback)(void *user_data);

/**
 * ejs_runtime_timer_create — 创建定时器
 *
 * 创建一个定时器，在 delay_ms 毫秒后首次触发，之后每隔 repeat_ms
 * 毫秒重复触发（若 repeat_ms 为 0 则只触发一次）。
 * user_data 只随定时器回调传回，默认不释放。若 user_data 指向堆对象且希望定时器
 * 销毁时自动释放，必须调用 ejs_runtime_timer_set_free_user_data 设置释放函数。
 *
 * @param loop       所属的事件循环
 * @param delay_ms   首次触发的延迟时间（毫秒）
 * @param repeat_ms  重复间隔（毫秒），0 表示不重复
 * @param callback   定时器到期回调
 * @param user_data  传递给回调的用户数据
 * @return 定时器实例；失败时返回 NULL
 */
EJSRuntimeTimer *ejs_runtime_timer_create(EJSRuntimeLoop *loop,
                                           uint64_t delay_ms,
                                           uint64_t repeat_ms,
                                           EJSRuntimeTimerCallback callback,
                                           void *user_data);

/**
 * ejs_runtime_timer_destroy — 销毁定时器
 *
 * 停止定时器，从活跃定时器列表中移除，释放相关资源。
 * 传入 NULL 是安全的（无操作）。
 *
 * @param timer 定时器实例，可为 NULL
 */
void ejs_runtime_timer_destroy(EJSRuntimeTimer *timer);

/**
 * ejs_runtime_timer_set_free_user_data — 设置定时器 user_data 的释放函数
 *
 * 当定时器被销毁时，如果设置了此函数，则调用它来释放 user_data。
 * 可用于自动释放定时器关联的堆分配对象。
 * 未设置时，定时器销毁只释放 EJSRuntimeTimer 自身，不触碰 user_data。
 *
 * @param timer         定时器实例
 * @param free_user_data user_data 的释放函数，可为 NULL
 */
void ejs_runtime_timer_set_free_user_data(EJSRuntimeTimer *timer, void (*free_user_data)(void *user_data));

#ifdef EJS_RUNTIME_LOOP_LIBUV
/**
 * ejs_runtime_loop_trigger_wakeup_test — 测试辅助函数：触发事件循环唤醒
 *
 * 仅在 libuv 后端下可用。发送 uv_async_send 唤醒事件循环，
 * 用于测试事件循环的任务处理机制。
 *
 * @param loop 事件循环实例
 */
void ejs_runtime_loop_trigger_wakeup_test(EJSRuntimeLoop *loop);
#ifdef EJS_TEST
void ejs_runtime_loop_set_stop_requested_for_test(EJSRuntimeLoop *loop, int stop_requested);
#endif
#endif

#endif

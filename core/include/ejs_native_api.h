/**
 * ejs_native_api.h — EJS 原生宿主接口 ABI 定义
 *
 * 本头文件定义了 EJS 运行时内核与宿主原生层之间的最小交互契约，
 * 是"万能异步通道"（__ejs_native__.invoke）的 C 层基础设施。
 *
 * 核心概念：
 *   - EJSCoreHostAPI：宿主向运行时注册的完整 API 集合，包含操作管理、异步调用和可选同步调用子接口
 *   - EJSCoreHostOperation：异步操作的生命周期管理，基于原子状态机 + 引用计数
 *   - EJSCoreByteBuffer / EJSCoreByteView：零拷贝的二进制数据传递原语
 *   - EJSCoreHostError：宿主侧错误信息的标准化传递结构
 *
 * 宿主集成步骤：
 *   1. 填充 EJSCoreHostAPI 结构体（设置 abi_version、struct_size、回调函数）
 *   2. 通过 ejs_context_register_host 注册到上下文
 *   3. JS 侧 __ejs_native__.invoke 调用将触发 invoke_api.invoke 回调
 *   4. 宿主在操作完成后调用 EJSCoreInvokeCompletion 回调通知 JS 侧
 *
 * user_data 所有权总则：
 *   - EJSCoreHostAPI 及其内嵌 invoke_api/sync_invoke_api/operations 中的 user_data 使用
 *     EJSCoreUserData 表达生命周期。若 value 非空且 retain/release 均非空，
 *     core 会在注册和异步 invoke 持有期间配对调用 retain/release。
 *   - value 非空且 retain/release 均为空表示 borrowed/static lifetime；
 *     core 只保存并传回 value，不会延长其生命周期。
 *   - EJSCoreByteView 是借用视图，runtime 不拥有 data，也不会释放 data。
 *   - EJSCoreByteBuffer 只有在调用 ejs_byte_buffer_destroy/secure_destroy 时，
 *     才会通过宿主提供的 destroy/secure_destroy 释放 data/user_data 所关联资源。
 *   - EJSCoreInvokeCompletion 的第一个参数不是宿主上下文，而是 runtime 交给宿主
 *     的 completion_data；宿主只负责原样传回一次，不得释放或解引用。
 */

#ifndef EJS_NATIVE_API_H
#define EJS_NATIVE_API_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * EJS_NATIVE_ABI_VERSION — 原生接口 ABI 版本号
 *
 * 当本头文件中的结构体布局发生不兼容变更时递增。宿主传入的所有
 * 结构体的 abi_version 必须与此值匹配，否则校验失败。
 */
#define EJS_NATIVE_ABI_VERSION 20260525u

typedef void (*EJSCoreRetainCallback)(void *user_data);
typedef void (*EJSCoreReleaseCallback)(void *user_data);

typedef struct {
    unsigned long long userFlag;    // 备用用户标记
    void *value;    // 用户数据
    EJSCoreRetainCallback retain; // 引用增加
    EJSCoreReleaseCallback release; //引用减少
} EJSCoreUserData;

#define EJS_USER_DATA_REF_NULL { 0u, NULL, NULL, NULL }

static inline EJSCoreUserData ejs_user_data_ref_null(void) {
    EJSCoreUserData ref = EJS_USER_DATA_REF_NULL;

    return ref;
}

static inline EJSCoreUserData ejs_user_data_ref_make(void               *value,
                                                 EJSCoreRetainCallback  retain,
                                                 EJSCoreReleaseCallback release) {
    EJSCoreUserData ref = { 0u, value, retain, release };

    return ref;
}

/**
 * EJSCoreHostOperation — 宿主异步操作（不透明句柄）
 *
 * 代表一次通过 __ejs_native__.invoke 发起的异步调用。宿主通过
 * cancel/release 回调管理其生命周期；运行时通过原子状态机
 * 和引用计数确保并发安全。详细实现见 ejs_native_api.c。
 */
typedef struct EJSCoreHostOperation EJSCoreHostOperation;

/**
 * EJSCoreErrorCode — 标准化的错误分类码
 *
 * 运行时与宿主层共享的错误码枚举。宿主在 EJSCoreHostError.code 中使用这些值，
 * 运行时将据此在 JS 侧构造对应类型的错误对象。
 *
 *   EJS_ERROR_NONE            — 无错误（操作成功）
 *   EJS_ERROR_INVALID_ARGUMENT — 参数不合法
 *   EJS_ERROR_ABORTED         — 操作被中止（如 AbortController.abort()）
 *   EJS_ERROR_NETWORK         — 网络层错误（连接失败、DNS 解析失败等）
 *   EJS_ERROR_TLS             — TLS/SSL 错误（证书验证失败、握手失败等）
 *   EJS_ERROR_TIMEOUT         — 操作超时
 *   EJS_ERROR_UNSUPPORTED     — 不支持的特性或操作
 *   EJS_ERROR_SECURITY        — 安全策略违规（权限不足、CORS 等）
 *   EJS_ERROR_INTERNAL        — 运行时内部错误
 */
typedef enum {
    EJS_ERROR_NONE = 0,
    EJS_ERROR_INVALID_ARGUMENT,
    EJS_ERROR_ABORTED,
    EJS_ERROR_NETWORK,
    EJS_ERROR_TLS,
    EJS_ERROR_TIMEOUT,
    EJS_ERROR_UNSUPPORTED,
    EJS_ERROR_SECURITY,
    EJS_ERROR_INTERNAL
} EJSCoreErrorCode;

/**
 * EJSCoreHostError — 宿主侧向 JS 侧传递的错误信息
 *
 * 当宿主操作的 EJSCoreInvokeCompletion 回调携带非 EJS_ERROR_NONE 的错误码时，
 * 运行时将根据此结构构造 JS Error 对象，包含 code、message 等属性，
 * 并将 platform_domain 和 platform_code 附加到错误对象上供诊断使用。
 *
 * 约定：message 和 platform_domain 指针必须在 completion 回调返回前保持有效，
 * 运行时会在回调内复制字符串内容，宿主无需保证指针在回调后仍有效。
 */
typedef struct {
    uint32_t abi_version;     /* ABI 版本号，必须为 EJS_NATIVE_ABI_VERSION */
    size_t struct_size;                                           /* 结构体大小，必须为 sizeof(EJSCoreHostError) */
    uint64_t flags;                                               /* 行为标志位，当前保留，必须为 0 */
    void *reserved[2];                                            /* 保留字段，必须为 NULL */

    EJSCoreErrorCode code;                                            /* 错误分类码 */
    const char *message;                                          /* 人类可读的错误描述，可为 NULL */
    const char *platform_domain;/* 平台错误域（如 "libuv"、"ssl"），可为 NULL */
    int platform_code;                                            /* 平台特定错误码（如 UV_ECONNREFUSED） */
} EJSCoreHostError;

typedef struct {
    const uint8_t *data;                                          /* 借用的只读字节视图；runtime 不拥有、不释放 */
    size_t size;                                                  /* data 指向区域的字节长度 */
} EJSCoreByteView;

/**
 * EJSCoreByteBuffer — 可拥有内存的字节缓冲区
 *
 * 与 EJSCoreByteView 不同，ByteBuffer 可以携带 destroy/secure_destroy 回调，
 * 用于把宿主分配的内存交给 runtime 生命周期管理。secure_destroy 用于密钥、
 * token 等敏感数据，允许宿主在释放前执行平台级安全擦除。
 *
 * 所有权说明：
 *   - data 的所有权由 destroy/secure_destroy 回调决定；未设置释放回调时，
 *     ejs_byte_buffer_destroy 只清空结构体字段，不释放 data。
 *   - user_data 不会被 runtime 单独释放，只会作为第一个参数传给释放回调。
 *   - 调用 destroy/secure_destroy 后，buffer 字段会被清空，防止重复释放。
 */
typedef struct {
    uint8_t *data;                                                /* 可写字节缓冲区，所有权由 destroy 回调约定 */
    size_t size;                                                  /* data 指向区域的字节长度 */
    void (*destroy)(void *user_data, uint8_t *data, size_t size); /* 普通释放回调 */
    void (*secure_destroy)(void *user_data, uint8_t *data, size_t size); /* 安全擦除释放回调 */
    void *user_data;                                              /* 传回 destroy/secure_destroy 的宿主上下文 */
} EJSCoreByteBuffer;

/**
 * EJSCoreHostOperationAPI — 宿主异步操作控制与生命周期管理接口 (内核 -> 宿主)
 *
 * 【核心设计与定位】：
 *   本接口负责“异步操作生命周期管理”的下行通路 (Downstream Path)。
 *   内核无法预知宿主具体业务类型，仅通过不透明句柄 `EJSCoreHostOperation` 管理每次挂起的异步任务。
 *   当 JS 发生控制行为（如 Abort 信号）或被动注销（如 Promise 垃圾回收、Context 销毁）时，
 *   EJS 内核将通过此接口通知宿主进行对应的干预与清理动作。
 *
 * 【职责】：
 *   - cancel:  当 JS 侧请求取消时（例如 AbortController.abort()），内核会调用此方法，
 *              通知宿主应立刻中止底层异步 I/O (例如关闭 Socket 连接、停止文件读取)。
 *   - release: 当调用方放弃结果或发生垃圾回收时，内核会调用此方法，
 *              通知宿主应扣减引用计数，在引用归零时销毁 operation 及其 user_data 资源。
 *
 * 【默认实现】：
 *   对于大多数标准的 `EJSCoreHostOperation` 生命周期状态机，宿主可以直接调用 `ejs_native_operation_api()`
 *   获得标准实现的 `EJSCoreHostOperationAPI` 实例，无需自行实现复杂的 cancel/release 竞态原语。
 *
 * 【数据说明】：
 *   operations.user_data 是宿主操作管理器的上下文。runtime 注册 host 时会复制
 *   EJSCoreHostOperationAPI，并按 EJSCoreUserData 规则托管其 user_data。每个 pending
 *   invoke 会持有创建时的 registered host，因此重新注册/注销 host 后，旧 operation
 *   的 cancel/release 仍会走创建时的 operations 回调。
 */
typedef struct {
    uint32_t abi_version;
    size_t struct_size;
    uint64_t flags;
    void *reserved[4];

    EJSCoreUserData user_data;
    int (*cancel)(EJSCoreUserData user_data, EJSCoreHostOperation *operation);
    void (*release)(EJSCoreUserData user_data, EJSCoreHostOperation *operation);
} EJSCoreHostOperationAPI;

/**
 * EJSCoreInvokeCompletion — 宿主完成一次 invoke 的回调
 *
 * 宿主可在任意工作线程调用该回调；runtime 会复制 result/error 中需要跨线程
 * 保存的数据，并把 Promise resolve/reject 投递回 owner thread。result/error
 * 指针只需在回调返回前有效。
 *
 * 参数说明：
 *   - user_data 是 invoke_api.invoke 收到的 completion_data，不是
 *     EJSCoreHostInvokeAPI.user_data。它由 runtime 分配并通过引用计数管理。
 *   - 宿主必须把 completion_data 原样传回；不要释放、不要解引用，也不要保存
 *     到完成之后继续使用。
 *   - 首次 completion 返回后，该 completion_data 视为已消费。重复 completion
 *     会被 runtime 防御性忽略，但在指针已经释放后再调用仍属于宿主侧生命周期错误。
 */
typedef void (*EJSCoreInvokeCompletion)(void               *completion_token,
                                    EJSCoreByteView        result,
                                    const EJSCoreHostError *error);

/**
 * EJSCoreHostInvokeAPI — __ejs_native__.invoke 的调用发起与业务入口 (JS -> 宿主)
 *
 * 【核心设计与定位】：
 *   本接口负责“万能异步通道”的上行发起通路 (Upstream Path)，是具体的业务分发点。
 *   当 JS 侧调用 `__ejs_native__.invoke(...)` 时，EJS 内核会将调用解析并原样转发到此接口的 `invoke` 方法中。
 *
 * 【职责】：
 *   - 路由分发: 宿主在该方法内部读取 `module_id`/`method_id` 并分发到具体业务（如 fs、fetch、crypto 等）。
 *   - 参数解析: 读取并可选拷贝只读字节视图 `payload` 和 `transfer_buffer`。
 *   - 异步调度: 在 C/宿主侧调度工作线程、发起系统 I/O。
 *   - 句柄返回: **必须** 创建并返回一个代表该次异步逻辑的 `EJSCoreHostOperation` 句柄（可使用默认原语创建）；
 *               若返回 NULL，内核将立即向 JS 侧 Promise 抛出内部错误。
 *
 * 【数据生命周期约束】：
 *   invoke_api.user_data 是宿主 provider 上下文，runtime 注册 host 时会复制
 *   EJSCoreHostInvokeAPI，并按 EJSCoreUserData 规则托管其 user_data。module_id、method_id、
 *   payload 和 transfer_buffer 都只在 invoke 回调返回前有效；若宿主需要异步使用
 *   这些数据，必须在 invoke 内自行复制。
 *
 *   若 invoke 返回非 NULL EJSCoreHostOperation，宿主可把 completion/completion_data
 *   保存到该异步操作对象中，操作完成时调用一次。若 invoke 返回 NULL，runtime 会
 *   立即 reject JS Promise，并把 completion_data 视为未创建操作的失败 token；
 *   宿主不得在返回 NULL 后保存或调用该 completion_data。
 */
typedef struct {
    uint32_t abi_version;
    size_t struct_size;
    uint64_t flags;
    void *reserved[4];

    EJSCoreUserData user_data;
    EJSCoreHostOperation *(*invoke)(EJSCoreUserData user_data,
                                const char *module_id,
                                const char *method_id,
                                EJSCoreByteView payload,
                                EJSCoreByteView transfer_buffer,
                                EJSCoreInvokeCompletion completion,
                                void *completion_data);
} EJSCoreHostInvokeAPI;

/**
 * EJSCoreHostSyncInvokeAPI — __ejs_native__.invokeSync 的同步宿主入口
 *
 * 本接口用于 bounded、同步完成的小型宿主能力，例如安全随机数、单调时钟、
 * 小型编码转换等。它不是异步 invoke 的快捷形式，严禁用于网络、文件大 I/O、
 * 压缩大块数据或任何可能长时间阻塞 owner thread 的操作。
 *
 * 返回约定：
 *   - 返回 0 且 error_out->code 为 EJS_ERROR_NONE/未设置时，runtime
 *     会把 result_out 复制成 JS ArrayBuffer，并在复制后调用 ejs_byte_buffer_destroy。
 *   - 返回非 0 或 error_out->code 非 EJS_ERROR_NONE 时，runtime
 *     会按 EJSCoreHostError 创建 JS Error 并抛出。
 *   - module_id、method_id、payload、transfer_buffer 都只在回调期间有效；
 *     同步 provider 不得保存这些指针。
 */
typedef int (*EJSCoreHostSyncInvokeCallback)(EJSCoreUserData user_data,
                                             const char *module_id,
                                             const char *method_id,
                                             EJSCoreByteView payload,
                                             EJSCoreByteView transfer_buffer,
                                             EJSCoreByteBuffer *result_out,
                                             EJSCoreHostError *error_out);

typedef struct {
    uint32_t abi_version;
    size_t struct_size;
    uint64_t flags;
    void *reserved[4];

    EJSCoreUserData user_data;
    EJSCoreHostSyncInvokeCallback invoke_sync;
} EJSCoreHostSyncInvokeAPI;

/**
 * EJSCoreHostAPI — 注册到单个 EJSCoreContext 的完整宿主 API 契约
 *
 * 【核心设计与协同】：
 *   EJSCoreHostAPI 是 EJS “万能异步通道”在宿主侧的顶层代表。它将异步操作的“业务发起”与“生命周期控制”完美整合：
 *     1. **`invoke_api` (发起端/上行通道)**：用于处理 JS -> C 的正向异步业务路由，宿主在此处拦截调用并产生操作句柄。
 *     2. **`sync_invoke_api` (可选同步通道)**：用于 bounded 同步能力，宿主未提供时 JS 侧 `invokeSync` 会抛错。
 *     3. **`operations` (控制端/下行生命周期)**：用于处理 C -> C 的反向取消/销毁通知，由内核在需要退场时回调宿主。
 *   两者的无缝协同，构成了 EJS 高性能、零拷贝、并发安全的异步交互基石。
 *
 * 【资源托管与更新】：
 *   当前 core 只要求 invoke provider。注册时 runtime 会复制 EJSCoreHostAPI 结构体，
 *   调用方无需保证传入结构体在 ejs_context_register_host 返回后继续存活；但结构体
 *   内的回调函数代码必须至少活到相关 context 和 pending invoke 全部结束。
 *
 *   user_data 字段目前作为宿主顶层上下文保留，core 不主动读取；若它使用 retained
 *   EJSCoreUserData，runtime 仍会按 registered host 生命周期托管 retain/release。
 *   真正传入 invoke/sync invoke/operation 回调的是各子 API 自己的 user_data。
 *   重新注册 host 会替换 context 当前 host，但 pending invoke 会继续强持有旧的
 *   registered host，直到对应 state 销毁后再释放旧 host 资源。
 */
typedef struct EJSCoreHostAPI {
    uint32_t abi_version;
    size_t struct_size;
    uint64_t flags;
    void *reserved[4];

    EJSCoreUserData user_data;
    EJSCoreHostOperationAPI operations;
    EJSCoreHostInvokeAPI invoke_api;
    EJSCoreHostSyncInvokeAPI sync_invoke_api;
} EJSCoreHostAPI;

/**
 * EJSCoreNativeValidationResult — 宿主 ABI 校验失败原因
 *
 * 这些值用于内部注册路径区分 NULL、版本、结构体大小和必需回调缺失。
 */
typedef enum {
    EJS_NATIVE_VALIDATION_OK = 0,
    EJS_NATIVE_VALIDATION_NULL,
    EJS_NATIVE_VALIDATION_ABI_VERSION,
    EJS_NATIVE_VALIDATION_STRUCT_SIZE,
    EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK
} EJSCoreNativeValidationResult;

/**
 * EJSCoreNativeProviderMask — 注册时要求的 provider 位掩码
 *
 * 预留给未来多个 provider。当前只有 invoke，因此 runtime 注册 host API 时
 * 使用 EJS_NATIVE_PROVIDER_INVOKE。
 */
typedef enum {
    EJS_NATIVE_PROVIDER_INVOKE = 1u << 0,
    EJS_NATIVE_PROVIDER_SYNC_INVOKE = 1u << 1
} EJSCoreNativeProviderMask;

/**
 * EJSCoreNativeOperationState — EJSCoreHostOperation 的原子状态机
 *
 * 状态表示宿主操作从 pending 到取消请求、完成或释放的生命周期。它是 C 层
 * 防止 cancel/complete/release 竞态造成重复释放的核心约定。
 */
typedef enum {
    EJS_NATIVE_OPERATION_PENDING          = 0,
    EJS_NATIVE_OPERATION_CANCEL_REQUESTED = 1,
    EJS_NATIVE_OPERATION_COMPLETED        = 2,
    EJS_NATIVE_OPERATION_RELEASED         = 3
} EJSCoreNativeOperationState;

typedef int (*EJSCoreNativeOperationCancelCallback)(void *user_data);
typedef void (*EJSCoreNativeOperationDestroyCallback)(void *user_data);

EJSCoreNativeValidationResult ejs_native_validate_metadata(const void *value,
                                                       size_t     minimum_struct_size);
EJSCoreNativeValidationResult ejs_native_validate_operation_api(const EJSCoreHostOperationAPI *api);
EJSCoreNativeValidationResult ejs_native_validate_host_api(const EJSCoreHostAPI *api,
                                                       uint32_t         required_providers);

void ejs_byte_buffer_init(EJSCoreByteBuffer *buffer,
                          uint8_t *data,
                          size_t size,
                          void *user_data,
                          void (*destroy)(void *user_data, uint8_t *data, size_t size),
                          void (*secure_destroy)(void *user_data, uint8_t *data, size_t size));
void ejs_byte_buffer_destroy(EJSCoreByteBuffer *buffer);
void ejs_byte_buffer_secure_destroy(EJSCoreByteBuffer *buffer);
void ejs_secure_wipe(void *data, size_t size);

EJSCoreHostOperation * ejs_native_operation_create(void                              *user_data,
                                               EJSCoreNativeOperationCancelCallback  cancel,
                                               EJSCoreNativeOperationDestroyCallback destroy);
int ejs_native_operation_cancel(EJSCoreHostOperation *operation);
void ejs_native_operation_release(EJSCoreHostOperation *operation);
bool ejs_native_operation_complete(EJSCoreHostOperation *operation);
EJSCoreNativeOperationState ejs_native_operation_state(const EJSCoreHostOperation *operation);
void * ejs_native_operation_user_data(EJSCoreHostOperation *operation);

EJSCoreHostOperationAPI ejs_native_operation_api(void);

/**
 * EJS_HOST_API_DEFAULT_VALUE / ejs_host_api_default_value
 *
 * EJSCoreHostAPI 的快捷默认初始化。默认值填充 ABI 元数据，并为 operations
 * 接上标准 cancel/release；调用方通常只需要设置 user_data、invoke_api.user_data
 * 和 invoke_api.invoke。
 */
static inline int ejs_host_api_default_cancel(EJSCoreUserData user_data, EJSCoreHostOperation *operation) {
    (void)user_data;
    return ejs_native_operation_cancel(operation);
}

static inline void ejs_host_api_default_release(EJSCoreUserData user_data, EJSCoreHostOperation *operation) {
    (void)user_data;
    ejs_native_operation_release(operation);
}

#define EJS_HOST_API_DEFAULT_VALUE                                                                                   \
    { EJS_NATIVE_ABI_VERSION, sizeof(EJSCoreHostAPI), 0u, { NULL, NULL, NULL, NULL }, EJS_USER_DATA_REF_NULL,            \
      { EJS_NATIVE_ABI_VERSION, sizeof(EJSCoreHostOperationAPI), 0u, { NULL, NULL, NULL, NULL }, EJS_USER_DATA_REF_NULL, \
        ejs_host_api_default_cancel, ejs_host_api_default_release },                                                 \
      { EJS_NATIVE_ABI_VERSION, sizeof(EJSCoreHostInvokeAPI), 0u, { NULL, NULL, NULL, NULL }, EJS_USER_DATA_REF_NULL, NULL }, \
      { EJS_NATIVE_ABI_VERSION, sizeof(EJSCoreHostSyncInvokeAPI), 0u, { NULL, NULL, NULL, NULL }, EJS_USER_DATA_REF_NULL, NULL } }

static inline EJSCoreHostAPI ejs_host_api_default_value(void) {
    EJSCoreHostAPI api = EJS_HOST_API_DEFAULT_VALUE;

    return api;
}

#ifdef __cplusplus
}
#endif

#endif // ifndef EJS_NATIVE_API_H

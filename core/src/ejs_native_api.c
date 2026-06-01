/**
 * ejs_native_api.c — EJS 原生操作与字节缓冲区的核心实现
 *
 * 本文件实现了 EJS 运行时内核与宿主原生层之间的底层交互原语，包括：
 *
 * 1. ABI 元数据校验 — 验证宿主传入的结构体是否符合版本与大小要求，
 *    防止 ABI 不匹配导致的内存越界或未定义行为。
 *
 * 2. 字节缓冲区（EJSCoreByteBuffer）— 提供零拷贝的物理内存管理，支持自定义
 *    析构函数与安全擦除（secure_destroy），用于在 JS 与原生层之间传递
 *    二进制数据（如网络响应体、加密密钥材料等）。
 *
 * 3. 宿主操作（EJSCoreHostOperation）— 基于原子状态机的异步操作生命周期管理，
 *    支持 PENDING -> CANCEL_REQUESTED -> COMPLETED/RELEASED 的状态转换，
 *    使用引用计数确保并发取消与完成之间的安全竞态处理。
 *
 * 这些原语是 EJS "万能异步通道"（__ejs_native__.invoke）的底层基石，
 * 所有高层 WinterTC API（fetch、crypto、fs 等）的跨层调用均依赖此模块。
 */

#include "ejs_native_api.h"

#include <stddef.h>
#include <stdatomic.h>
#include <stdlib.h>

/**
 * EJSNativeABIMetadata — 所有需要 ABI 校验的结构体的公共头部
 *
 * 约定：凡是传入运行时的宿主 API 结构体，前两个成员必须是 abi_version 和
 * struct_size，以便运行时统一校验。这与 EJS_NATIVE_ABI_VERSION 和
 * EJS_RUNTIME_ABI_VERSION 配合使用。
 */
typedef struct {
    uint32_t abi_version;
    size_t struct_size;
} EJSNativeABIMetadata;

/**
 * EJSCoreHostOperation — 宿主异步操作的内部表示
 *
 * 生命周期模型（双所有权 + 引用计数）：
 *   创建时 ref_count = 2（一份归调用方，一份归完成方），
 *   任意一方 release/complete 后 ref_count 减 1，双方都释放后触发 finalize。
 *
 * 状态机：
 *   PENDING --cancel()--> CANCEL_REQUESTED
 *   PENDING --complete()--> COMPLETED（触发 finalize）
 *   PENDING/CANCEL_REQUESTED --release()--> RELEASED（ref_count 减 1）
 *
 * 所有状态转换均使用原子操作，确保在多线程场景下（如宿主工作线程完成操作
 * 同时 JS 线程发起取消）不会出现 use-after-free。
 */
struct EJSCoreHostOperation {
    atomic_int state;          /* 操作当前状态，对应 EJSCoreNativeOperationState 枚举 */
    void *user_data;           /* 宿主自定义上下文；operation 本身不释放，只传给回调 */
    EJSCoreNativeOperationCancelCallback cancel; /* 取消回调，宿主用于中断正在进行的操作 */
    EJSCoreNativeOperationDestroyCallback destroy; /* 最终销毁回调；宿主在这里释放 user_data 关联资源 */
    atomic_int ref_count;      /* 引用计数，初始为 2，归零时调用 finalize */
    atomic_bool caller_released; /* 调用方引用是否已释放，保证 release 幂等 */
    atomic_bool completion_released; /* 完成方引用是否已释放，保证 complete 幂等 */
};

static void ejs_native_operation_finalize(EJSCoreHostOperation *operation);

/**
 * ejs_native_operation_dec_ref — 原子递减引用计数
 *
 * 当引用计数从 1 降至 0 时（即 atomic_fetch_sub 返回旧值 1），
 * 说明调用方和完成方都已释放，触发 finalize 销毁操作。
 * 这是双所有权模型的核心：调用方持有一次引用（通过 release 释放），
 * 完成方持有一次引用（通过 complete 释放）。
 */
static void ejs_native_operation_dec_ref(EJSCoreHostOperation *operation) {
    if (operation == NULL) {
        return;
    }

    if (atomic_fetch_sub(&operation->ref_count, 1) == 1) {
        ejs_native_operation_finalize(operation);
    }
}

/**
 * ejs_native_operation_finalize — 操作的最终销毁
 *
 * 在引用计数归零后调用。如果宿主注册了 destroy 回调，则先调用它
 * 以释放宿主侧关联的资源（如网络连接、文件句柄等），然后释放
 * EJSCoreHostOperation 结构体本身。
 *
 * 注意：operation->user_data 的所有权始终属于宿主。这里不会直接 free(user_data)，
 * 只会调用宿主提供的 destroy(user_data)，由宿主决定如何关闭句柄、取消 I/O
 * 或释放堆对象。
 */
static void ejs_native_operation_finalize(EJSCoreHostOperation *operation) {
    if (operation == NULL) {
        return;
    }

    if (operation->destroy != NULL) {
        operation->destroy(operation->user_data);
    }

    free(operation);
}

/**
 * ejs_native_validate_metadata — 校验 ABI 结构体的版本与大小
 *
 * 所有从宿主传入的结构体（EJSCoreHostAPI、EJSCoreHostOperationAPI、EJSCoreHostInvokeAPI
 * 等）都通过此函数进行公共头部校验。
 *
 * 校验顺序：
 *   1. 指针非空检查
 *   2. abi_version 必须等于 EJS_NATIVE_ABI_VERSION（当前为 1）
 *   3. struct_size 必须至少等于 minimum_struct_size（确保运行时所需的字段存在）
 *
 * @param value              指向待校验结构体的指针
 * @param minimum_struct_size 运行时要求的最小结构体大小（通常用 offsetof + sizeof
 *                           计算到最后一个必需字段，而非 sizeof 整个结构体，
 *                           以允许宿主传递更大的未来版本结构体）
 * @return 校验结果，EJS_NATIVE_VALIDATION_OK 表示通过
 */
EJSCoreNativeValidationResult ejs_native_validate_metadata(const void *value,
                                                       size_t     minimum_struct_size) {
    const EJSNativeABIMetadata *metadata = (const EJSNativeABIMetadata *)value;

    if (metadata == NULL) {
        return EJS_NATIVE_VALIDATION_NULL;
    }

    if (metadata->abi_version != EJS_NATIVE_ABI_VERSION) {
        return EJS_NATIVE_VALIDATION_ABI_VERSION;
    }

    if (metadata->struct_size < minimum_struct_size) {
        return EJS_NATIVE_VALIDATION_STRUCT_SIZE;
    }

    return EJS_NATIVE_VALIDATION_OK;
}

static bool ejs_native_validate_user_data_ref(EJSCoreUserData ref) {
    if (ref.value == NULL) {
        return ref.retain == NULL && ref.release == NULL;
    }
    return (ref.retain != NULL && ref.release != NULL) || (ref.retain == NULL && ref.release == NULL);
}

static bool ejs_native_reserved_fields_are_zero(uint64_t flags,
                                                void * const *reserved,
                                                size_t reserved_count) {
    if (flags != 0u) {
        return false;
    }

    for (size_t i = 0u; i < reserved_count; i++) {
        if (reserved[i] != NULL) {
            return false;
        }
    }

    return true;
}

/**
 * ejs_native_validate_operation_api — 校验操作管理 API 结构体
 *
 * 在元数据校验通过后，额外检查 cancel 和 release 两个必需回调是否非空。
 * 这两个回调是操作生命周期管理的关键路径：
 *   - cancel：JS 侧调用 AbortController.abort() 时触发，要求宿主中断操作
 *   - release：JS 侧 Promise 被 GC 或上下文销毁时触发，要求宿主释放引用
 *
 * @param api 指向 EJSCoreHostOperationAPI 的指针
 * @return 校验结果
 */
EJSCoreNativeValidationResult ejs_native_validate_operation_api(const EJSCoreHostOperationAPI *api) {
    EJSCoreNativeValidationResult result =
        ejs_native_validate_metadata(api, sizeof(EJSCoreHostOperationAPI));

    if (result != EJS_NATIVE_VALIDATION_OK) {
        return result;
    }

    if (!ejs_native_reserved_fields_are_zero(api->flags,
                                             api->reserved,
                                             sizeof(api->reserved) / sizeof(api->reserved[0]))) {
        return EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK;
    }

    if (api->cancel == NULL || api->release == NULL) {
        return EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK;
    }

    if (!ejs_native_validate_user_data_ref(api->user_data)) {
        return EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK;
    }

    return EJS_NATIVE_VALIDATION_OK;
}

static EJSCoreNativeValidationResult ejs_native_validate_sync_invoke_api(const EJSCoreHostSyncInvokeAPI *api,
                                                                         bool require_callback) {
    EJSCoreNativeValidationResult result =
        ejs_native_validate_metadata(api, sizeof(EJSCoreHostSyncInvokeAPI));

    if (result != EJS_NATIVE_VALIDATION_OK) {
        return result;
    }

    if (!ejs_native_reserved_fields_are_zero(api->flags,
                                             api->reserved,
                                             sizeof(api->reserved) / sizeof(api->reserved[0]))) {
        return EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK;
    }

    if (require_callback && api->invoke_sync == NULL) {
        return EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK;
    }

    if (!ejs_native_validate_user_data_ref(api->user_data)) {
        return EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK;
    }

    return EJS_NATIVE_VALIDATION_OK;
}

/**
 * ejs_native_validate_host_api — 校验完整的宿主 API 结构体
 *
 * 依次校验：
 *   1. EJSCoreHostAPI 本身的 ABI 版本与大小
 *   2. 内嵌 of EJSCoreHostOperationAPI（操作管理子结构体）
 *   3. 若 required_providers 包含 EJS_NATIVE_PROVIDER_INVOKE，
 *      还需校验 EJSCoreHostInvokeAPI（万能通道 invoke 子结构体），
 *      并检查 invoke 回调非空
 *
 * @param api                指向 EJSCoreHostAPI 的指针
 * @param required_providers 位掩码，指定必需的 provider 类型
 * @return 校验结果
 */
EJSCoreNativeValidationResult ejs_native_validate_host_api(const EJSCoreHostAPI *api,
                                                       uint32_t         required_providers) {
    EJSCoreNativeValidationResult result =
        ejs_native_validate_metadata(api, offsetof(EJSCoreHostAPI, invoke_api) + sizeof(api->invoke_api));

    if (result != EJS_NATIVE_VALIDATION_OK) {
        return result;
    }

    if (!ejs_native_reserved_fields_are_zero(api->flags,
                                             api->reserved,
                                             sizeof(api->reserved) / sizeof(api->reserved[0]))) {
        return EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK;
    }

    if (!ejs_native_validate_user_data_ref(api->user_data)) {
        return EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK;
    }

    result = ejs_native_validate_operation_api(&api->operations);

    if (result != EJS_NATIVE_VALIDATION_OK) {
        return result;
    }

    if ((required_providers & EJS_NATIVE_PROVIDER_INVOKE) != 0u) {
        result = ejs_native_validate_metadata(&api->invoke_api, sizeof(EJSCoreHostInvokeAPI));

        if (result != EJS_NATIVE_VALIDATION_OK) {
            return result;
        }

        if (!ejs_native_reserved_fields_are_zero(api->invoke_api.flags,
                                                 api->invoke_api.reserved,
                                                 sizeof(api->invoke_api.reserved) / sizeof(api->invoke_api.reserved[0]))) {
            return EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK;
        }

        if (api->invoke_api.invoke == NULL) {
            return EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK;
        }

        if (!ejs_native_validate_user_data_ref(api->invoke_api.user_data)) {
            return EJS_NATIVE_VALIDATION_REQUIRED_CALLBACK;
        }
    }

    size_t sync_api_start = offsetof(EJSCoreHostAPI, sync_invoke_api);
    size_t sync_api_end = sync_api_start + sizeof(api->sync_invoke_api);
    bool has_partial_sync_api = api->struct_size > sync_api_start && api->struct_size < sync_api_end;
    bool has_sync_api = api->struct_size >= sync_api_end;
    bool requires_sync_api = (required_providers & EJS_NATIVE_PROVIDER_SYNC_INVOKE) != 0u;

    if (has_partial_sync_api) {
        return EJS_NATIVE_VALIDATION_STRUCT_SIZE;
    }

    if (requires_sync_api && !has_sync_api) {
        return EJS_NATIVE_VALIDATION_STRUCT_SIZE;
    }

    if (has_sync_api) {
        result = ejs_native_validate_sync_invoke_api(&api->sync_invoke_api, requires_sync_api);

        if (result != EJS_NATIVE_VALIDATION_OK) {
            return result;
        }
    }

    return EJS_NATIVE_VALIDATION_OK;
}

/**
 * ejs_byte_buffer_init — 初始化字节缓冲区
 *
 * 将外部管理的内存区域包装为 EJSCoreByteBuffer，支持两种析构方式：
 *   - destroy：普通析构，直接释放内存
 *   - secure_destroy：安全析构，先擦除敏感数据再释放（适用于密钥材料等）
 *
 * 典型用途：
 *   - 宿主向 JS 传递网络响应体时，将响应 buffer 包装为 EJSCoreByteView
 *   - JS 向宿主传递 TypedArray 数据时，通过 EJSCoreByteBuffer 进行零拷贝传递
 *   - 加密操作中使用 secure_destroy 确保密钥材料被安全擦除
 *
 * @param buffer         待初始化的缓冲区结构体指针
 * @param data           数据指针（由调用方拥有，缓冲区不负责分配）
 * @param size           数据字节数
 * @param user_data      传递给 destroy/secure_destroy 的用户上下文，runtime 不单独释放
 * @param destroy        普通析构回调，可为 NULL（表示无需释放）
 * @param secure_destroy 安全析构回调，可为 NULL（回退到 ejs_secure_wipe + destroy）
 */
void ejs_byte_buffer_init(EJSCoreByteBuffer *buffer,
                          uint8_t *data,
                          size_t size,
                          void *user_data,
                          void (*destroy)(void *user_data, uint8_t *data, size_t size),
                          void (*secure_destroy)(void *user_data, uint8_t *data, size_t size)) {
    if (buffer == NULL) {
        return;
    }

    buffer->data = data;
    buffer->size = size;
    buffer->user_data = user_data;
    buffer->destroy = destroy;
    buffer->secure_destroy = secure_destroy;
}

/**
 * ejs_secure_wipe — 安全擦除内存区域
 *
 * 使用 volatile 指针逐字节写入零值，防止编译器将其优化为空操作。
 * 适用于清除包含敏感数据（如加密密钥、认证令牌）的内存区域。
 *
 * 注意：此函数不释放内存，仅擦除内容。对于栈上分配的缓冲区，
 * 编译器仍可能在某些优化级别下省略擦除；关键场景应使用
 * 平台特有的安全擦除 API（如 OpenSSL 的 OPENSSL_cleanse、
 * Windows 的 SecureZeroMemory）。
 *
 * @param data 待擦除的内存起始地址
 * @param size 待擦除的字节数
 */
void ejs_secure_wipe(void *data, size_t size) {
    if (data == NULL || size == 0u) {
        return;
    }

    volatile uint8_t *bytes = (volatile uint8_t *)data;

    while (size-- > 0u) {
        *bytes++ = 0u;
    }
}

/**
 * ejs_byte_buffer_destroy — 销毁字节缓冲区（普通模式）
 *
 * 如果注册了 destroy 回调，则调用它释放底层数据，然后将缓冲区
 * 所有字段置零/置空，防止悬挂指针。
 * 未注册 destroy 时不会释放 data 或 user_data，只清空 EJSCoreByteBuffer 字段。
 *
 * 适用于非敏感数据的释放场景（如普通网络响应体）。
 *
 * @param buffer 待销毁的缓冲区指针
 */
void ejs_byte_buffer_destroy(EJSCoreByteBuffer *buffer) {
    if (buffer == NULL) {
        return;
    }

    if ((buffer->data != NULL || buffer->size == 0u) && buffer->destroy != NULL) {
        buffer->destroy(buffer->user_data, buffer->data, buffer->size);
    }

    buffer->data = NULL;
    buffer->size = 0u;
    buffer->user_data = NULL;
    buffer->destroy = NULL;
    buffer->secure_destroy = NULL;
}

/**
 * ejs_byte_buffer_secure_destroy — 销毁字节缓冲区（安全模式）
 *
 * 优先使用宿主注册的 secure_destroy 回调；若未注册，则先用
 * ejs_secure_wipe 擦除数据内容，再用 destroy 回调释放内存。
 * user_data 只作为释放回调参数传回；没有释放回调时不会被 runtime 处理。
 *
 * 适用于包含敏感数据的释放场景（如加密密钥材料、认证凭证等）。
 * 确保数据在内存释放前被覆盖为零，降低内存残留泄漏风险。
 *
 * @param buffer 待安全销毁的缓冲区指针
 */
void ejs_byte_buffer_secure_destroy(EJSCoreByteBuffer *buffer) {
    if (buffer == NULL) {
        return;
    }

    if (buffer->data != NULL || buffer->size == 0u) {
        if (buffer->secure_destroy != NULL) {
            buffer->secure_destroy(buffer->user_data, buffer->data, buffer->size);
        } else if (buffer->data != NULL) {
            ejs_secure_wipe(buffer->data, buffer->size);

            if (buffer->destroy != NULL) {
                buffer->destroy(buffer->user_data, buffer->data, buffer->size);
            }
        } else if (buffer->destroy != NULL) {
            buffer->destroy(buffer->user_data, buffer->data, buffer->size);
        }
    }

    buffer->data = NULL;
    buffer->size = 0u;
    buffer->user_data = NULL;
    buffer->destroy = NULL;
    buffer->secure_destroy = NULL;
}

/**
 * ejs_native_operation_create — 创建一个新的宿主异步操作
 *
 * 操作创建后处于 PENDING 状态，引用计数初始化为 2：
 *   - 1 份引用归"调用方"（JS 侧），通过 release() 释放
 *   - 1 份引用归"完成方"（宿主侧），通过 complete() 释放
 *
 * 当双方都释放后，引用计数归零，触发 finalize 逻辑。
 * user_data 的资源释放必须写在 destroy 回调中；EJSCoreHostOperation 只保存该指针，
 * 并在 cancel/destroy 时原样传回。
 *
 * @param user_data 宿主自定义上下文，随 cancel/destroy 回调传回
 * @param cancel    取消回调，JS 侧请求取消时调用（可为 NULL）
 * @param destroy   销毁回调，操作终结时调用以释放宿主资源（可为 NULL）
 * @return 新创建的操作指针，内存不足时返回 NULL
 */
EJSCoreHostOperation * ejs_native_operation_create(void                              *user_data,
                                               EJSCoreNativeOperationCancelCallback  cancel,
                                               EJSCoreNativeOperationDestroyCallback destroy) {
    EJSCoreHostOperation *operation = (EJSCoreHostOperation *)calloc(1u, sizeof(EJSCoreHostOperation));

    if (operation == NULL) {
        return NULL;
    }

    atomic_init(&operation->state, EJS_NATIVE_OPERATION_PENDING);
    atomic_init(&operation->ref_count, 2);
    atomic_init(&operation->caller_released, false);
    atomic_init(&operation->completion_released, false);
    operation->user_data = user_data;
    operation->cancel = cancel;
    operation->destroy = destroy;
    return operation;
}

/**
 * ejs_native_operation_cancel — 请求取消一个正在进行的异步操作
 *
 * 仅当操作处于 PENDING 状态时才能成功转换到 CANCEL_REQUESTED。
 * 使用 atomic_compare_exchange_strong 确保状态转换的原子性：
 *   - 如果操作已经完成（COMPLETED）或已释放（RELEASED），
 *     则取消请求会被静默忽略，返回 0
 *   - 如果操作已被其他线程取消（CANCEL_REQUESTED），
 *     同样被忽略，返回 0
 *
 * 成功转换后调用宿主注册的 cancel 回调，由宿主决定如何中断操作
 * （如关闭网络连接、取消文件 I/O 等）。
 *
 * @param operation 待取消的操作指针
 * @return 宿主 cancel 回调的返回值（0 表示成功取消或无需取消）
 */
int ejs_native_operation_cancel(EJSCoreHostOperation *operation) {
    int expected = EJS_NATIVE_OPERATION_PENDING;

    if (operation == NULL) {
        return 0;
    }

    if (atomic_compare_exchange_strong(&operation->state, &expected,
                                       EJS_NATIVE_OPERATION_CANCEL_REQUESTED)) {
        if (operation->cancel != NULL) {
            return operation->cancel(operation->user_data);
        }
    }

    return 0;
}

/**
 * ejs_native_operation_release — 释放调用方对操作的引用
 *
 * JS 侧调用此函数表示不再关心操作结果。操作可能处于以下任一状态：
 *   - PENDING：操作仍在进行中，JS 侧主动放弃等待
 *   - CANCEL_REQUESTED：JS 已请求取消，现在释放引用
 *
 * 使用 atomic_compare_exchange_weak 循环尝试将状态转换到 RELEASED。
 * CAS 使用 weak 变体是因为在循环中重试是可接受的，而 weak 版本在
 * 某些架构（如 ARM LL/SC）上性能更优。
 *
 * 释放后将引用计数减 1。当引用计数归零时（即完成方也已释放），
 * 触发 finalize 销毁操作。
 *
 * 典型调用场景：
 *   - JS Promise 被 GC 回收时
 *   - 上下文销毁时批量释放所有挂起操作
 *
 * @param operation 待释放的操作指针
 */
void ejs_native_operation_release(EJSCoreHostOperation *operation) {
    int state = EJS_NATIVE_OPERATION_PENDING;

    if (operation == NULL) {
        return;
    }

    if (atomic_exchange(&operation->caller_released, true)) {
        return;
    }

    while (state == EJS_NATIVE_OPERATION_PENDING ||
           state == EJS_NATIVE_OPERATION_CANCEL_REQUESTED) {
        if (atomic_compare_exchange_weak(&operation->state, &state,
                                         EJS_NATIVE_OPERATION_RELEASED)) {
            break;
        }
    }
    ejs_native_operation_dec_ref(operation);
}

/**
 * ejs_native_operation_complete — 完成一个异步操作
 *
 * 宿主侧在操作执行完毕后调用此函数，将状态转换到 COMPLETED。
 * 仅当操作处于 PENDING 或 CANCEL_REQUESTED 时才能完成：
 *   - PENDING -> COMPLETED：正常完成
 *   - CANCEL_REQUESTED -> COMPLETED：操作已被请求取消但宿主仍然完成了它
 *     （宿主可能无法立即中断某些操作，如已发送的网络请求）
 *
 * 完成后立即触发 finalize，释放操作资源。注意：complete 与 cancel
 * 之间存在竞态关系——如果 cancel 先执行，操作进入 CANCEL_REQUESTED，
 * 此时 complete 仍然可以成功（因为 CANCEL_REQUESTED 是可完成状态），
 * 但宿主的 completion callback 应该根据操作是否实际被取消来决定
 * 返回成功还是中止错误。
 *
 * @param operation 待完成的操作指针
 * @return true 表示成功完成并销毁操作，false 表示操作已处于终态无法完成
 */
bool ejs_native_operation_complete(EJSCoreHostOperation *operation) {
    int state = EJS_NATIVE_OPERATION_PENDING;

    if (operation == NULL) {
        return false;
    }

    if (atomic_exchange(&operation->completion_released, true)) {
        return false;
    }

    while (state == EJS_NATIVE_OPERATION_PENDING ||
           state == EJS_NATIVE_OPERATION_CANCEL_REQUESTED) {
        if (atomic_compare_exchange_weak(&operation->state, &state,
                                         EJS_NATIVE_OPERATION_COMPLETED)) {
            ejs_native_operation_dec_ref(operation);
            return true;
        }
    }

    ejs_native_operation_dec_ref(operation);
    return false;
}

/**
 * ejs_native_operation_state — 查询操作当前状态
 *
 * @param operation 操作指针，可为 NULL
 * @return 操作状态；若 operation 为 NULL 则返回 EJS_NATIVE_OPERATION_RELEASED
 */
EJSCoreNativeOperationState ejs_native_operation_state(const EJSCoreHostOperation *operation) {
    if (operation == NULL) {
        return EJS_NATIVE_OPERATION_RELEASED;
    }

    return (EJSCoreNativeOperationState)atomic_load(&operation->state);
}

/**
 * ejs_native_operation_user_data — 获取操作关联的用户上下文
 *
 * @param operation 操作指针，可为 NULL
 * @return 用户上下文指针；若 operation 为 NULL 则返回 NULL
 */
void * ejs_native_operation_user_data(EJSCoreHostOperation *operation) {
    if (operation == NULL) {
        return NULL;
    }

    return operation->user_data;
}

/**
 * ejs_native_operation_api_cancel — 操作 API 的 cancel 适配器
 *
 * 将 EJSCoreHostOperationAPI.cancel 的签名适配到内部的
 * ejs_native_operation_cancel，忽略 user_data 参数。
 */
static int ejs_native_operation_api_cancel(EJSCoreUserData user_data, EJSCoreHostOperation *operation) {
    (void)user_data;
    return ejs_native_operation_cancel(operation);
}

/**
 * ejs_native_operation_api_release — 操作 API 的 release 适配器
 *
 * 将 EJSCoreHostOperationAPI.release 的签名适配到内部的
 * ejs_native_operation_release，忽略 user_data 参数。
 */
static void ejs_native_operation_api_release(EJSCoreUserData user_data, EJSCoreHostOperation *operation) {
    (void)user_data;
    ejs_native_operation_release(operation);
}

/**
 * ejs_native_operation_api — 构造一个默认的 EJSCoreHostOperationAPI 实例
 *
 * 返回一个使用内部实现填充的标准操作 API 结构体，宿主可直接将其
 * 赋值给 EJSCoreHostAPI.operations 字段，无需自行实现 cancel/release 逻辑。
 * 内部实现直接委托给 ejs_native_operation_cancel/release。
 *
 * @return 填充完毕的 EJSCoreHostOperationAPI 结构体（栈上值）
 */
EJSCoreHostOperationAPI ejs_native_operation_api(void) {
    EJSCoreHostOperationAPI api;

    api.abi_version = EJS_NATIVE_ABI_VERSION;
    api.struct_size = sizeof(EJSCoreHostOperationAPI);
    api.flags = 0u;

    for (size_t i = 0u; i < 4u; i++) {
        api.reserved[i] = NULL;
    }

    api.user_data = ejs_user_data_ref_null();
    api.cancel = ejs_native_operation_api_cancel;
    api.release = ejs_native_operation_api_release;
    return api;
}

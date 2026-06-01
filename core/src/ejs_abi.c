/**
 * ejs_abi.c — EJS ABI 兼容性校验的实现
 *
 * 本文件实现了对所有公共结构体的 ABI 版本和大小校验逻辑。
 * 校验策略遵循"最小必需字段"原则：
 *   - min_size 不使用 sizeof(整个结构体)，而是使用 offsetof 计算到最后一个
 *     必需字段的末尾，允许宿主传入更大的结构体（包含未来扩展字段）
 *   - abi_version 必须精确匹配，防止不同大版本之间的不兼容
 *
 * 校验流程：
 *   1. NULL 指针检查 → EJS_ABI_CHECK_NULL
 *   2. abi_version 匹配检查 → EJS_ABI_CHECK_VERSION
 *   3. struct_size >= min_size 检查 → EJS_ABI_CHECK_SIZE
 */

#include "ejs_abi.h"

/**
 * EJSABIPrefix — 所有公共 ABI 结构体的公共头部
 *
 * 约定：凡是需要 ABI 校验的结构体，前两个字段必须是 abi_version 和
 * struct_size，以便通过统一的 ejs_abi_check_public_struct 函数进行校验。
 */
typedef struct {
    uint32_t abi_version; /* ABI 版本号 */
    size_t struct_size;   /* 结构体实际大小（sizeof） */
} EJSABIPrefix;

/**
 * ejs_abi_check_public_struct — 通用的 ABI 结构体校验
 *
 * 通过将传入的指针强转为 EJSABIPrefix*，访问前两个字段进行校验。
 * struct_size 参数当前未使用（传入 sizeof 用于未来可能的额外校验），
 * 实际校验使用 ptr->struct_size 与 min_size 比较。
 *
 * @param ptr         指向待校验结构体的指针
 * @param abi_version 运行时要求的 ABI 版本号
 * @param struct_size 结构体的 sizeof（保留供未来使用）
 * @param min_size    运行时要求的最小结构体大小
 * @return 校验结果
 */
EJSABICheckResult ejs_abi_check_public_struct(const void *ptr,
                                              uint32_t   abi_version,
                                              size_t     struct_size,
                                              size_t     min_size) {
    const EJSABIPrefix *prefix = (const EJSABIPrefix *)ptr;

    (void)struct_size;

    if (ptr == NULL) {
        return EJS_ABI_CHECK_NULL;
    }

    if (prefix->abi_version != abi_version) {
        return EJS_ABI_CHECK_VERSION;
    }

    if (prefix->struct_size < min_size) {
        return EJS_ABI_CHECK_SIZE;
    }

    return EJS_ABI_CHECK_OK;
}

static bool ejs_abi_reserved_fields_are_zero(uint64_t flags,
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
 * ejs_abi_check_runtime_config — 校验 EJSCoreRuntimeConfig
 *
 * min_size 计算到 max_stack_size 字段的末尾：
 *   offsetof(EJSCoreRuntimeConfig, max_stack_size) + sizeof(uint32_t)
 * 这允许宿主传入包含额外扩展字段的更大结构体，只要前 6 个字段
 * （abi_version 到 max_stack_size）与当前版本兼容即可。
 *
 * @param config 指向 EJSCoreRuntimeConfig 的指针
 * @return true 表示校验通过
 */
bool ejs_abi_check_runtime_config(const EJSCoreRuntimeConfig *config) {
    if (ejs_abi_check_public_struct(config,
                                    EJS_RUNTIME_ABI_VERSION,
                                    sizeof(EJSCoreRuntimeConfig),
                                    offsetof(EJSCoreRuntimeConfig, max_stack_size) +
                                    sizeof(config->max_stack_size)) != EJS_ABI_CHECK_OK) {
        return false;
    }

    return ejs_abi_reserved_fields_are_zero(config->flags,
                                            config->reserved,
                                            sizeof(config->reserved) / sizeof(config->reserved[0]));
}

/**
 * ejs_abi_check_eval_options — 校验 EJSCoreEvalOptions
 *
 * min_size 计算到 kind 字段的末尾：
 *   offsetof(EJSCoreEvalOptions, kind) + sizeof(EJSCoreEvalKind)
 * kind 是当前版本中最后一个必需字段，specifier 和 source_url 为可选字段。
 *
 * @param options 指向 EJSCoreEvalOptions 的指针
 * @return true 表示校验通过
 */
bool ejs_abi_check_eval_options(const EJSCoreEvalOptions *options) {
    if (ejs_abi_check_public_struct(options,
                                    EJS_RUNTIME_ABI_VERSION,
                                    sizeof(EJSCoreEvalOptions),
                                    offsetof(EJSCoreEvalOptions, kind) +
                                    sizeof(options->kind)) != EJS_ABI_CHECK_OK) {
        return false;
    }

    return ejs_abi_reserved_fields_are_zero(options->flags,
                                            options->reserved,
                                            sizeof(options->reserved) / sizeof(options->reserved[0]));
}

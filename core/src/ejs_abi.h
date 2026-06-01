/**
 * ejs_abi.h — EJS ABI 兼容性校验接口
 *
 * 本头文件定义了运行时对所有公共结构体的 ABI 版本和大小校验机制。
 * EJS 采用"前向兼容"的 ABI 策略：
 *   - 运行时要求结构体至少包含当前版本的所有必需字段
 *   - 宿主可以传入更大的结构体（包含未来扩展字段），只要前几个字段匹配
 *   - abi_version 必须精确匹配，struct_size 必须 >= 运行时要求的最小值
 *
 * 所有公共结构体（EJSCoreRuntimeConfig、EJSCoreEvalOptions、EJSCoreHostAPI 等）
 * 都遵循相同的头部约定：前两个字段必须是 abi_version（uint32_t）和
 * struct_size（size_t），以便统一校验。
 *
 * 校验失败的处理：
 *   - 创建/注册等入口函数在校验失败时返回 NULL 或 EJS_STATUS_ERROR
 *   - 不会尝试降级兼容，避免未定义行为
 */

#ifndef EJS_ABI_H
#define EJS_ABI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "ejs_runtime.h"

/**
 * EJSABICheckResult — ABI 校验结果枚举
 *
 * EJS_ABI_CHECK_OK      — 校验通过，结构体版本和大小均符合要求
 * EJS_ABI_CHECK_NULL    — 传入的指针为 NULL
 * EJS_ABI_CHECK_VERSION — abi_version 不匹配（运行时要求与宿主提供的不一致）
 * EJS_ABI_CHECK_SIZE    — struct_size 小于运行时要求的最小值
 */
typedef enum {
    EJS_ABI_CHECK_OK = 0,
    EJS_ABI_CHECK_NULL,
    EJS_ABI_CHECK_VERSION,
    EJS_ABI_CHECK_SIZE
} EJSABICheckResult;

/**
 * ejs_abi_check_public_struct — 通用的 ABI 结构体校验函数
 *
 * 所有需要 ABI 校验的结构体都通过此函数进行校验。函数假设结构体的
 * 前两个字段分别是 abi_version（uint32_t）和 struct_size（size_t）。
 *
 * @param ptr            指向待校验结构体的指针
 * @param abi_version    运行时要求的 ABI 版本号（如 EJS_RUNTIME_ABI_VERSION）
 * @param struct_size    结构体的完整 sizeof（用于校验宿主是否正确设置）
 * @param min_size       运行时要求的最小结构体大小（通常是最后一个必需字段的
 *                       偏移 + 大小，允许宿主传入更大的结构体）
 * @return 校验结果枚举值
 */
EJSABICheckResult ejs_abi_check_public_struct(const void *ptr,
                                              uint32_t   abi_version,
                                              size_t     struct_size,
                                              size_t     min_size);

/**
 * ejs_abi_check_runtime_config — 校验 EJSCoreRuntimeConfig 结构体
 *
 * 检查 abi_version 是否等于 EJS_RUNTIME_ABI_VERSION，以及 struct_size
 * 是否至少覆盖到 max_stack_size 字段。
 *
 * @param config 指向 EJSCoreRuntimeConfig 的指针
 * @return true 表示校验通过
 */
bool ejs_abi_check_runtime_config(const EJSCoreRuntimeConfig *config);

/**
 * ejs_abi_check_eval_options — 校验 EJSCoreEvalOptions 结构体
 *
 * 检查 abi_version 是否等于 EJS_RUNTIME_ABI_VERSION，以及 struct_size
 * 是否至少覆盖到 kind 字段。
 *
 * @param options 指向 EJSCoreEvalOptions 的指针
 * @return true 表示校验通过
 */
bool ejs_abi_check_eval_options(const EJSCoreEvalOptions *options);

#endif /* ifndef EJS_ABI_H */

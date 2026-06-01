#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${repo_root}/build_xcode"
log_file="${build_dir}/test_js.log"
derived_data_dir="${build_dir}/DerivedData"

run_android_aar_build=0
run_android_aar_publish=0
android_engine="${EJS_ANDROID_ENGINE:-quickjs-ng}"
android_runtime_loop="${EJS_ANDROID_RUNTIME_LOOP:-libuv}"
run_apple_checks=1
skip_ctest=0
skip_network_tests=0

mkdir -p "${build_dir}"
: > "${log_file}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${log_file}"
}

usage() {
  cat <<'EOF'
Usage:
  ./test_js.sh [--android-aar] [--android-publish] [--android-only] [--no-android] [--skip-ctest] [--skip-network-tests] [--help]

Options:
  --android-aar       在主流程后执行 Android AAR assembleRelease 打包
  --android-publish   在 assembleRelease 之后执行本地 publish
  --android-only      只执行 Android AAR 打包，不执行 Apple/Xcode 验证链路
  --no-android        明确跳过 Android AAR 步骤
  --skip-ctest        跳过 ctest 执行（仅保留 build 阶段与 examples）
  --skip-network-tests 强制跳过所有依赖本地回环网络的测试（ejs_wintertc_apple_test / ejs_net_apple_test / ejs_xhr_apple_test）
  --help              显示帮助

Environment:
  EJS_ANDROID_ENGINE         传递给 Gradle 的 ejsAndroidEngine，默认 quickjs-ng
  EJS_ANDROID_RUNTIME_LOOP   传递给 Gradle 的 ejsAndroidRuntimeLoop，默认 libuv
  EJS_BUILD_ANDROID_AAR      置为 1 可默认开启 Android 打包
  EJS_PUBLISH_ANDROID_AAR    置为 1 可默认开启本地 publish
  EJS_SKIP_CTEST             置为 1 可默认跳过 ctest
  EJS_SKIP_NETWORK_TESTS     置为 1 可默认跳过依赖网络的测试
EOF
}

if [[ "${EJS_BUILD_ANDROID_AAR:-0}" == "1" ]]; then
  run_android_aar_build=1
fi

if [[ "${EJS_PUBLISH_ANDROID_AAR:-0}" == "1" ]]; then
  run_android_aar_build=1
  run_android_aar_publish=1
fi

if [[ "${EJS_SKIP_CTEST:-0}" == "1" ]]; then
  skip_ctest=1
fi

if [[ "${EJS_SKIP_NETWORK_TESTS:-0}" == "1" ]]; then
  skip_network_tests=1
fi

for arg in "$@"; do
  case "${arg}" in
    --android-aar)
      run_android_aar_build=1
      ;;
    --android-publish)
      run_android_aar_build=1
      run_android_aar_publish=1
      ;;
    --android-only)
      run_android_aar_build=1
      run_apple_checks=0
      ;;
    --no-android)
      run_android_aar_build=0
      run_android_aar_publish=0
      ;;
    --skip-ctest)
      skip_ctest=1
      ;;
    --skip-network-tests)
      skip_network_tests=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    "")
      ;;
    *)
      log "未识别参数: ${arg}"
      usage
      exit 1
      ;;
  esac
done

run_step() {
  local step_name="$1"
  shift

  log "=== 开始: ${step_name} ==="
  log "命令: $*"

  if ! "$@" 2>&1 | tee -a "${log_file}"; then
    local status=${PIPESTATUS[0]}
    log "=== 失败: ${step_name} (exit=${status}) ==="
    return "${status}"
  fi

  log "=== 完成: ${step_name} ==="
}

run_js_examples() {
  local cli="${build_dir}/tools/apple/Debug/ejs_apple_cli"
  local examples_dir="${repo_root}/tools/apple/examples"
  local example_status=0
  local passed=0
  local failed=0

  shopt -s nullglob
  local scripts=("${examples_dir}"/*.js)
  shopt -u nullglob

  if (( ${#scripts[@]} == 0 )); then
    log "未找到 JS example: ${examples_dir}/*.js"
    return 1
  fi

  cd "${repo_root}"

  for script in "${scripts[@]}"; do
    local relative_script="${script#${repo_root}/}"
    log "--- JS example 开始: ${relative_script} ---"

    if (( ${#api_check_env[@]} > 0 )); then
      if env "${api_check_env[@]}" "${cli}" --timeout 15 "${relative_script}" 2>&1 | tee -a "${log_file}"; then
        passed=$((passed + 1))
        log "--- JS example 完成: ${relative_script} ---"
      else
        local exit_code=${PIPESTATUS[0]}
        failed=$((failed + 1))
        example_status=${exit_code}
        log "--- JS example 失败: ${relative_script} (exit=${exit_code}) ---"
      fi
    else
      if "${cli}" --timeout 15 "${relative_script}" 2>&1 | tee -a "${log_file}"; then
        passed=$((passed + 1))
        log "--- JS example 完成: ${relative_script} ---"
      else
        local exit_code=${PIPESTATUS[0]}
        failed=$((failed + 1))
        example_status=${exit_code}
        log "--- JS example 失败: ${relative_script} (exit=${exit_code}) ---"
      fi
    fi
  done

  log "JS examples 汇总: passed=${passed}, failed=${failed}, total=${#scripts[@]}"
  return "${example_status}"
}

summarize_failures() {
  local issues=0

  log "=== 异常汇总 ==="

  for pattern in \
    "error:|ERROR:|\*\* BUILD FAILED \*\*|You don’t have permission|Operation not permitted|Could not compute dependency graph|Failed to compute dependency graph|Subprocess killed|Segmentation fault|Failed to execute|FAILURE:|Exception|fatal:|EXIT:137|failed to register ejs|Could not execute HTTPS fetch|Timed out waiting for fswatch event|server with the specified hostname could not be found"; do
    local matched
    matched="$(grep -nE "${pattern}" "${log_file}" | grep -v "RegisterExecutionPolicyException" || true)"
    if [[ -n "${matched}" ]]; then
      issues=$((issues + 1))
      log "【模式】${pattern}"
      printf '%s\n' "${matched}" | tee -a "${log_file}"
    fi
  done

  if (( issues == 0 )); then
    log "未发现已知异常模式。"
  fi
}

run_android_aar() {
  if (( run_android_aar_build == 0 )); then
    log "跳过 Android AAR 打包（默认关闭）。"
    return 0
  fi

  if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
    log "未检测到 ANDROID_HOME/ANDROID_SDK_ROOT，Android 打包可能失败。"
    return 1
  fi

  if ! command -v gradle >/dev/null 2>&1; then
    log "未检测到 gradle 命令，无法执行 Android 打包。"
    return 1
  fi

  run_step "Android AAR 打包 (assembleRelease)" \
    gradle -p "${repo_root}" \
    :ejs-android:assembleRelease \
    -PejsAndroidEngine="${android_engine}" \
    -PejsAndroidRuntimeLoop="${android_runtime_loop}"

  if (( run_android_aar_publish != 0 )); then
    run_step "Android AAR publishReleasePublicationToEjsLocalRepository" \
      gradle -p "${repo_root}" \
      :ejs-android:publishReleasePublicationToEjsLocalRepository
    log "Android AAR 已发布到本地仓库: ${repo_root}/platform/android/gradle/ejs-android/build/repo"
  else
    log "Android AAR 已生成，路径: ${repo_root}/platform/android/gradle/ejs-android/build/outputs/aar"
  fi
}

can_bind_local_host() {
  if ! command -v python3 >/dev/null 2>&1; then
    log "警告: 未检测到 python3，跳过本地回环端口权限探测。"
    return 0
  fi

  python3 - "$build_dir" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
  sock.bind(("127.0.0.1", 0))
  sock.listen(1)
  sys.exit(0)
except OSError:
  sys.exit(1)
finally:
  try:
    sock.close()
  except Exception:
    pass
PY
}

status=0
LOCAL_NETWORK_ENABLED=1

if (( skip_network_tests != 0 )); then
  LOCAL_NETWORK_ENABLED=0
  log "已通过参数/环境禁用网络测试: ejs_wintertc_apple_test / ejs_net_apple_test / ejs_xhr_apple_test"
else
  can_bind_local_host || { LOCAL_NETWORK_ENABLED=0; }
fi
if [[ "${LOCAL_NETWORK_ENABLED}" == "0" ]]; then
  log "检测到本地回环端口权限不可用，将跳过以下网络依赖测试: ejs_wintertc_apple_test / ejs_net_apple_test / ejs_xhr_apple_test"
  ctest_filter="-E"
  ctest_filter_pattern="ejs_wintertc_apple_test|ejs_net_apple_test|ejs_xhr_apple_test"
  api_check_env=(
    EJS_API_CHECK_SKIP_NETWORK=1
    EJS_API_CHECK_SKIP_FSWATCH=1
    EJS_API_CHECK_SKIP_HTTPS_FETCH=1
  )
else
  ctest_filter=""
  ctest_filter_pattern=""
  api_check_env=()
fi

if (( run_apple_checks != 0 )); then
  run_step "cmake 配置" cmake -DEJS_ENGINE=quickjs-ng -DEJS_RUNTIME_LOOP=libuv -DANDROID=OFF -DEJS_TEST=ON -G Xcode -B "${build_dir}" "${repo_root}" || status=$?
  run_step "cmake --build" \
    xcodebuild \
    -project "${build_dir}/ejs.xcodeproj" \
    -scheme ALL_BUILD \
    -configuration Debug \
    -derivedDataPath "${derived_data_dir}" \
    build || status=$?
  if (( skip_ctest == 0 )); then
    if [[ -n "${ctest_filter}" ]]; then
      run_step "ctest" ctest --test-dir "${build_dir}" -C Debug --output-on-failure ${ctest_filter} "${ctest_filter_pattern}" || status=$?
    else
      run_step "ctest" ctest --test-dir "${build_dir}" -C Debug --output-on-failure || status=$?
    fi
  else
    log "已跳过 ctest（--skip-ctest）"
  fi

  run_step "tools/apple/examples/*.js" run_js_examples || status=$?
fi

run_android_aar || status=$?

if (( status != 0 )); then
  summarize_failures
  log "test_js.sh 执行失败，日志文件: ${log_file}"
  exit ${status}
fi

summarize_failures
log "test_js.sh 执行成功。日志文件: ${log_file}"

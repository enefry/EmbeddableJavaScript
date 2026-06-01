#include <jni.h>
#include <string>
#include <vector>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <cstdlib>
#include <cstring>
#include <pthread.h>
#include <thread>
#include <condition_variable>
#include <atomic>
#include <chrono>
#include "ejs_runtime.h"
#include "ejs_native_api.h"

static JavaVM* g_vm = nullptr;

static jclass g_context_class = nullptr;
static jmethodID g_context_ctor = nullptr;

static jclass g_provider_class = nullptr;
static jmethodID g_provider_get_module_id = nullptr;
static jmethodID g_provider_invoke_method = nullptr;
static jmethodID g_provider_invoke_sync_method = nullptr;
static jmethodID g_provider_close_method = nullptr;

static jclass g_responder_class = nullptr;
static jmethodID g_responder_ctor = nullptr;

static jclass g_exception_class = nullptr;

static pthread_key_t g_detach_key;
static pthread_once_t g_detach_key_once = PTHREAD_ONCE_INIT;

static void detach_current_thread(void* env) {
    if (g_vm) {
        g_vm->DetachCurrentThread();
    }
}

static void make_detach_key() {
    pthread_key_create(&g_detach_key, detach_current_thread);
}

static JNIEnv* getEnv() {
    if (!g_vm) {
        return nullptr;
    }

    JNIEnv* env = nullptr;
    int getEnvStat = g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (getEnvStat == JNI_EDETACHED) {
#if defined(__ANDROID__)
        if (g_vm->AttachCurrentThread(&env, nullptr) != 0) {
#else
        if (g_vm->AttachCurrentThread(reinterpret_cast<void**>(&env), nullptr) != 0) {
#endif
            return nullptr;
        }
        pthread_once(&g_detach_key_once, make_detach_key);
        pthread_setspecific(g_detach_key, env);
    }
    return env;
}

static void throwException(JNIEnv* env, const char* message) {
    if (g_exception_class != nullptr) {
        env->ThrowNew(g_exception_class, message ? message : "Unknown error");
    }
}

static void ejs_android_close_provider(JNIEnv* env, jobject provider) {
    if (!env || !provider || !g_provider_close_method) {
        return;
    }
    env->CallVoidMethod(provider, g_provider_close_method);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
    }
}

static void ejs_android_close_and_delete_provider(JNIEnv* env, jobject provider) {
    if (!env || !provider) {
        return;
    }
    ejs_android_close_provider(env, provider);
    env->DeleteGlobalRef(provider);
}

class EJSAndroidContext;

class EJSAndroidRuntime {
public:
    EJSCoreRuntime* core_runtime;
    std::mutex lock;
    bool invalidated = false;
    bool destroy_delegated = false;
    std::unordered_map<std::string, std::string> context_defaults;
    std::unordered_set<EJSAndroidContext*> contexts;

    EJSAndroidRuntime(EJSCoreRuntime* runtime) : core_runtime(runtime) {}
    ~EJSAndroidRuntime() {
        if (!invalidated && core_runtime) {
            ejs_runtime_destroy(core_runtime);
        }
    }

    void registerContext(EJSAndroidContext* context) {
        std::lock_guard<std::mutex> guard(lock);
        if (context) {
            contexts.insert(context);
        }
    }

    void unregisterContext(EJSAndroidContext* context) {
        bool delete_self = false;
        EJSCoreRuntime* core_to_destroy = nullptr;
        {
            std::lock_guard<std::mutex> guard(lock);
            if (context) {
                contexts.erase(context);
            }
            if (invalidated && destroy_delegated && contexts.empty()) {
                core_to_destroy = core_runtime;
                core_runtime = nullptr;
                delete_self = true;
            }
        }
        if (core_to_destroy) {
            ejs_runtime_destroy(core_to_destroy);
        }
        if (delete_self) {
            delete this;
        }
    }
};

class EJSAndroidContext {
public:
    EJSCoreContext* core_context;
    EJSAndroidRuntime* runtime;
    
    std::mutex lock; // protecting providers map
    
    std::mutex state_lock; // protecting active_calls and invalidation
    std::condition_variable cv;
    int active_calls = 0;
    std::unordered_map<std::thread::id, int> active_calls_by_thread;
    bool invalidated = false;

    jweak java_context_weak_ref = nullptr; // Weak reference to avoid strong reference cycles
    std::unordered_map<std::string, jobject> providers;
    std::unordered_map<std::string, std::string> config_snapshot;
    bool deletion_delegated = false; // Indicates deletion task is delegated to endCall

    EJSAndroidContext(EJSCoreContext* context, EJSAndroidRuntime* rt) : core_context(context), runtime(rt) {}
    ~EJSAndroidContext() {
        if (runtime) {
            runtime->unregisterContext(this);
            runtime = nullptr;
        }
        JNIEnv* env = getEnv();
        if (env) {
            for (auto& pair : providers) {
                ejs_android_close_and_delete_provider(env, pair.second);
            }
            if (java_context_weak_ref) {
                env->DeleteWeakGlobalRef(java_context_weak_ref);
            }
        }
    }

    bool beginCall() {
        std::lock_guard<std::mutex> guard(state_lock);
        if (invalidated || !runtime) {
            return false;
        }
        {
            std::lock_guard<std::mutex> runtime_guard(runtime->lock);
            if (runtime->invalidated || runtime->core_runtime == nullptr) {
                return false;
            }
        }
        active_calls_by_thread[std::this_thread::get_id()]++;
        active_calls++;
        return true;
    }

    void endCall() {
        bool delete_self = false;
        EJSCoreContext* core_to_destroy = nullptr;
        {
            std::lock_guard<std::mutex> guard(state_lock);
            auto it = active_calls_by_thread.find(std::this_thread::get_id());
            if (it != active_calls_by_thread.end()) {
                it->second--;
                if (it->second == 0) {
                    active_calls_by_thread.erase(it);
                }
            }
            active_calls--;
            if (invalidated) {
                if (get_other_threads_active_calls() == 0) {
                    cv.notify_all();
                }
                if (active_calls == 0 && deletion_delegated) {
                    core_to_destroy = core_context;
                    core_context = nullptr;
                    delete_self = true;
                }
            }
        }
        if (core_to_destroy) {
            ejs_context_destroy(core_to_destroy);
        }
        if (delete_self) {
            delete this;
        }
    }

    int get_other_threads_active_calls() {
        int count = 0;
        std::thread::id cur_id = std::this_thread::get_id();
        for (auto& pair : active_calls_by_thread) {
            if (pair.first != cur_id) {
                count += pair.second;
            }
        }
        return count;
    }

    void clearJavaNativePtr(JNIEnv* env) {
        if (!env || !java_context_weak_ref || !g_context_class) {
            return;
        }
        jobject java_context = env->NewLocalRef(java_context_weak_ref);
        if (!java_context) {
            return;
        }
        jfieldID ptr_field = env->GetFieldID(g_context_class, "nativePtr", "J");
        if (ptr_field) {
            env->SetLongField(java_context, ptr_field, 0);
        }
        env->DeleteLocalRef(java_context);
    }
};

struct OperationBox {
    EJSCoreInvokeCompletion completion;
    void* completion_data;
    bool finished = false;
    bool core_operation_completed = false;
    std::mutex lock;
    std::atomic<int> refcount{2}; // 1 for native EJS operation wrapper, 1 for Java responder
    EJSCoreHostOperation* core_operation = nullptr;
    jobject java_operation_global_ref = nullptr; // Keeps a global reference to Java EJSProviderOperation

    OperationBox(EJSCoreInvokeCompletion comp, void* data) : completion(comp), completion_data(data) {}

    void decRef() {
        if (--refcount == 0) {
            delete this;
        }
    }

    EJSCoreHostOperation* takeCoreOperationForComplete() {
        std::lock_guard<std::mutex> guard(lock);
        if (core_operation_completed) {
            return nullptr;
        }
        core_operation_completed = true;
        return core_operation;
    }

    void completeCoreOperationOnce() {
        EJSCoreHostOperation* operation = takeCoreOperationForComplete();
        if (operation) {
            (void)ejs_native_operation_complete(operation);
        }
    }

    ~OperationBox() {
        JNIEnv* env = getEnv();
        if (env && java_operation_global_ref) {
            env->DeleteGlobalRef(java_operation_global_ref);
        }
    }
};

static constexpr auto kAndroidInvalidateWait = std::chrono::milliseconds(5000);

static EJSCoreContext* ejs_android_context_mark_invalidated(EJSAndroidContext* context,
                                                            bool* should_delete_context) {
    if (should_delete_context) {
        *should_delete_context = false;
    }
    if (!context) {
        return nullptr;
    }

    EJSCoreContext* core_to_destroy = nullptr;
    std::unique_lock<std::mutex> lock(context->state_lock);
    if (!context->invalidated) {
        context->invalidated = true;
    }

    bool drained = context->cv.wait_for(lock, kAndroidInvalidateWait, [context] {
        return context->get_other_threads_active_calls() == 0;
    });

    if (drained && context->active_calls == 0) {
        core_to_destroy = context->core_context;
        context->core_context = nullptr;
        if (should_delete_context) {
            *should_delete_context = true;
        }
    } else {
        context->deletion_delegated = true;
    }
    return core_to_destroy;
}

static void ejs_android_destroy_context_if_ready(EJSAndroidContext* context,
                                                 EJSCoreContext* core_to_destroy,
                                                 bool should_delete_context) {
    if (core_to_destroy) {
        ejs_context_destroy(core_to_destroy);
    }
    if (should_delete_context) {
        delete context;
    }
}

static int ejs_provider_operation_cancel(void* user_data) {
    OperationBox* box = static_cast<OperationBox*>(user_data);
    bool should_call_completion = false;
    {
        std::lock_guard<std::mutex> guard(box->lock);
        if (!box->finished) {
            box->finished = true;
            should_call_completion = true;
        }
    }

    JNIEnv* env = getEnv();
    if (env && box->java_operation_global_ref) {
        jclass opClass = env->GetObjectClass(box->java_operation_global_ref);
        jmethodID cancelMethod = env->GetMethodID(opClass, "cancel", "()V");
        env->CallVoidMethod(box->java_operation_global_ref, cancelMethod);
        if (env->ExceptionCheck()) {
            env->ExceptionClear(); // Clear cancellation exception
        }
        env->DeleteLocalRef(opClass);
    }
    if (should_call_completion) {
        EJSCoreHostError host_error = {};
        host_error.abi_version = EJS_NATIVE_ABI_VERSION;
        host_error.struct_size = sizeof(EJSCoreHostError);
        host_error.code = EJS_ERROR_ABORTED;
        host_error.message = "Android provider operation cancelled";

        EJSCoreByteView empty_view = {nullptr, 0};
        if (box->completion) {
            box->completion(box->completion_data, empty_view, &host_error);
        }
    }
    box->completeCoreOperationOnce();
    return 0;
}

static void ejs_provider_operation_destroy(void* user_data) {
    OperationBox* box = static_cast<OperationBox*>(user_data);
    box->decRef();
}

static EJSCoreHostOperation* ejs_context_dispatch_host_invoke(EJSCoreUserData user_data,
                                                             const char* module_id,
                                                             const char* method_id,
                                                             EJSCoreByteView payload,
                                                             EJSCoreByteView transfer_buffer,
                                                             EJSCoreInvokeCompletion completion,
                                                             void* completion_data) {
    EJSAndroidContext* context = reinterpret_cast<EJSAndroidContext*>(user_data.value);
    if (!context) return nullptr;
    if (!context->beginCall()) return nullptr;

    JNIEnv* env = getEnv();
    if (!env) {
        context->endCall();
        return nullptr;
    }

    jobject java_context = env->NewLocalRef(context->java_context_weak_ref);
    if (!java_context) {
        context->endCall();
        return nullptr;
    }

    OperationBox* state = new OperationBox(completion, completion_data);
    EJSCoreHostOperation* coreOperation = ejs_native_operation_create(state, ejs_provider_operation_cancel, ejs_provider_operation_destroy);
    if (!coreOperation) {
        delete state;
        env->DeleteLocalRef(java_context);
        context->endCall();
        return nullptr;
    }
    state->core_operation = coreOperation;

    std::string moduleIDStr = module_id ? module_id : "";
    std::string methodIDStr = method_id ? method_id : "";

    jobject provider = nullptr;
    {
        std::lock_guard<std::mutex> guard(context->lock);
        auto it = context->providers.find(moduleIDStr);
        if (it != context->providers.end()) {
            provider = env->NewLocalRef(it->second);
        }
    }

    if (!provider) {
        EJSCoreHostError host_error = {};
        host_error.abi_version = EJS_NATIVE_ABI_VERSION;
        host_error.struct_size = sizeof(EJSCoreHostError);
        host_error.code = EJS_ERROR_UNSUPPORTED;
        host_error.message = "Provider not found";

        EJSCoreByteView empty_view = {nullptr, 0};
        completion(completion_data, empty_view, &host_error);
        state->completeCoreOperationOnce();
        state->decRef();

        env->DeleteLocalRef(java_context);
        context->endCall();
        return coreOperation;
    }

    jstring jMethodId = env->NewStringUTF(methodIDStr.c_str());

    jbyteArray jPayload = nullptr;
    if (payload.data && payload.size > 0) {
        jPayload = env->NewByteArray(payload.size);
        env->SetByteArrayRegion(jPayload, 0, payload.size, reinterpret_cast<const jbyte*>(payload.data));
    } else {
        jPayload = env->NewByteArray(0);
    }

    jbyteArray jTransfer = nullptr;
    if (transfer_buffer.data && transfer_buffer.size > 0) {
        jTransfer = env->NewByteArray(transfer_buffer.size);
        env->SetByteArrayRegion(jTransfer, 0, transfer_buffer.size, reinterpret_cast<const jbyte*>(transfer_buffer.data));
    } else {
        jTransfer = env->NewByteArray(0);
    }

    jobject responder = env->NewObject(g_responder_class, g_responder_ctor, reinterpret_cast<jlong>(state));

    jobject operation = env->CallObjectMethod(provider, g_provider_invoke_method, jMethodId, jPayload, jTransfer, java_context, responder);

    bool failed = false;
    if (env->ExceptionCheck()) {
        failed = true;
        jthrowable ex = env->ExceptionOccurred();
        env->ExceptionClear();

        jclass exClass = env->GetObjectClass(ex);
        jmethodID getMessage = env->GetMethodID(exClass, "getMessage", "()Ljava/lang/String;");
        jstring msg = (jstring)env->CallObjectMethod(ex, getMessage);
        const char* c_msg = msg ? env->GetStringUTFChars(msg, nullptr) : "Java exception during invokeMethod";

        EJSCoreHostError host_error = {};
        host_error.abi_version = EJS_NATIVE_ABI_VERSION;
        host_error.struct_size = sizeof(EJSCoreHostError);
        host_error.code = EJS_ERROR_INTERNAL;
        host_error.message = strdup(c_msg);

        EJSCoreByteView empty_view = {nullptr, 0};
        completion(completion_data, empty_view, &host_error);
        free((void*)host_error.message);
        state->completeCoreOperationOnce();

        if (msg) {
            env->ReleaseStringUTFChars(msg, c_msg);
            env->DeleteLocalRef(msg);
        }
        env->DeleteLocalRef(ex);
        env->DeleteLocalRef(exClass);
    } else if (!operation) {
        failed = true;
        EJSCoreHostError host_error = {};
        host_error.abi_version = EJS_NATIVE_ABI_VERSION;
        host_error.struct_size = sizeof(EJSCoreHostError);
        host_error.code = EJS_ERROR_INTERNAL;
        host_error.message = "invokeMethod returned null";

        EJSCoreByteView empty_view = {nullptr, 0};
        completion(completion_data, empty_view, &host_error);
        state->completeCoreOperationOnce();
    }

    if (failed) {
        // Clear responder's nativePtr so that finalize() doesn't double destroy/decRef
        jfieldID ptrField = env->GetFieldID(g_responder_class, "nativePtr", "J");
        env->SetLongField(responder, ptrField, 0);

        state->decRef(); // Release ref count that would have been released by finishWithData
    } else {
        if (operation) {
            state->java_operation_global_ref = env->NewGlobalRef(operation);
            env->DeleteLocalRef(operation);
        }
    }

    env->DeleteLocalRef(jMethodId);
    env->DeleteLocalRef(jPayload);
    env->DeleteLocalRef(jTransfer);
    env->DeleteLocalRef(responder);
    env->DeleteLocalRef(provider);
    env->DeleteLocalRef(java_context);

    context->endCall();
    return coreOperation;
}

static int ejs_context_dispatch_host_invoke_sync(EJSCoreUserData user_data,
                                                 const char* module_id,
                                                 const char* method_id,
                                                 EJSCoreByteView payload,
                                                 EJSCoreByteView transfer_buffer,
                                                 EJSCoreByteBuffer* result_out,
                                                 EJSCoreHostError* error_out) {
    if (result_out != nullptr) {
        ejs_byte_buffer_init(result_out, nullptr, 0u, nullptr, nullptr, nullptr);
    }

    EJSAndroidContext* context = reinterpret_cast<EJSAndroidContext*>(user_data.value);
    if (!context) return -1;
    if (!context->beginCall()) return -1;

    JNIEnv* env = getEnv();
    if (!env) {
        context->endCall();
        return -1;
    }

    jobject java_context = env->NewLocalRef(context->java_context_weak_ref);
    if (!java_context) {
        context->endCall();
        return -1;
    }

    std::string moduleIDStr = module_id ? module_id : "";
    std::string methodIDStr = method_id ? method_id : "";

    jobject provider = nullptr;
    {
        std::lock_guard<std::mutex> guard(context->lock);
        auto it = context->providers.find(moduleIDStr);
        if (it != context->providers.end()) {
            provider = env->NewLocalRef(it->second);
        }
    }

    if (!provider) {
        if (error_out) {
            error_out->abi_version = EJS_NATIVE_ABI_VERSION;
            error_out->struct_size = sizeof(EJSCoreHostError);
            error_out->code = EJS_ERROR_UNSUPPORTED;
            error_out->message = strdup("Provider not found");
        }
        env->DeleteLocalRef(java_context);
        context->endCall();
        return -1;
    }

    jstring jMethodId = env->NewStringUTF(methodIDStr.c_str());

    jbyteArray jPayload = nullptr;
    if (payload.data && payload.size > 0) {
        jPayload = env->NewByteArray(payload.size);
        env->SetByteArrayRegion(jPayload, 0, payload.size, reinterpret_cast<const jbyte*>(payload.data));
    } else {
        jPayload = env->NewByteArray(0);
    }

    jbyteArray jTransfer = nullptr;
    if (transfer_buffer.data && transfer_buffer.size > 0) {
        jTransfer = env->NewByteArray(transfer_buffer.size);
        env->SetByteArrayRegion(jTransfer, 0, transfer_buffer.size, reinterpret_cast<const jbyte*>(transfer_buffer.data));
    } else {
        jTransfer = env->NewByteArray(0);
    }

    jobject resultObj = env->CallObjectMethod(provider, g_provider_invoke_sync_method, jMethodId, jPayload, jTransfer, java_context);

    if (env->ExceptionCheck()) {
        jthrowable ex = env->ExceptionOccurred();
        env->ExceptionClear();

        jclass exClass = env->GetObjectClass(ex);
        jmethodID getMessage = env->GetMethodID(exClass, "getMessage", "()Ljava/lang/String;");
        jstring msg = (jstring)env->CallObjectMethod(ex, getMessage);
        const char* c_msg = msg ? env->GetStringUTFChars(msg, nullptr) : "Java exception during invokeSyncMethod";

        if (error_out) {
            error_out->abi_version = EJS_NATIVE_ABI_VERSION;
            error_out->struct_size = sizeof(EJSCoreHostError);
            error_out->code = EJS_ERROR_INTERNAL;
            error_out->message = strdup(c_msg);
        }

        if (msg) {
            env->ReleaseStringUTFChars(msg, c_msg);
            env->DeleteLocalRef(msg);
        }
        env->DeleteLocalRef(ex);
        env->DeleteLocalRef(exClass);

        env->DeleteLocalRef(jMethodId);
        env->DeleteLocalRef(jPayload);
        env->DeleteLocalRef(jTransfer);
        env->DeleteLocalRef(provider);
        env->DeleteLocalRef(java_context);
        context->endCall();
        return -1;
    }

    if (resultObj && result_out) {
        jbyteArray jResult = static_cast<jbyteArray>(resultObj);
        jsize len = env->GetArrayLength(jResult);
        if (len > 0) {
            jbyte* bytes = env->GetByteArrayElements(jResult, nullptr);
            uint8_t* c_bytes = (uint8_t*)malloc(len);
            if (c_bytes) {
                memcpy(c_bytes, bytes, len);
                result_out->data = c_bytes;
                result_out->size = len;
                result_out->destroy = [](void*, uint8_t* data, size_t) { free(data); };
            }
            env->ReleaseByteArrayElements(jResult, bytes, JNI_ABORT);
        }
    }

    env->DeleteLocalRef(jMethodId);
    env->DeleteLocalRef(jPayload);
    env->DeleteLocalRef(jTransfer);
    if (resultObj) env->DeleteLocalRef(resultObj);
    env->DeleteLocalRef(provider);
    env->DeleteLocalRef(java_context);

    context->endCall();
    return 0;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_ejs_platform_EJSRuntime_nativeCreate(JNIEnv* env, jobject thiz, jobject config) {
    EJSCoreRuntimeConfig core_config = ejs_runtime_config_default_value();

    jstring jRuntimeName = nullptr;
    jstring jRuntimeVersion = nullptr;
    const char* cRuntimeName = nullptr;
    const char* cRuntimeVersion = nullptr;

    if (config) {
        jclass configClass = env->GetObjectClass(config);

        jmethodID getRuntimeName = env->GetMethodID(configClass, "getRuntimeName", "()Ljava/lang/String;");
        jmethodID getRuntimeVersion = env->GetMethodID(configClass, "getRuntimeVersion", "()Ljava/lang/String;");
        jmethodID getMemoryLimitBytes = env->GetMethodID(configClass, "getMemoryLimitBytes", "()J");
        jmethodID getMaxStackSize = env->GetMethodID(configClass, "getMaxStackSize", "()I");

        jRuntimeName = (jstring)env->CallObjectMethod(config, getRuntimeName);
        jRuntimeVersion = (jstring)env->CallObjectMethod(config, getRuntimeVersion);
        jlong memoryLimit = env->CallLongMethod(config, getMemoryLimitBytes);
        jint maxStack = env->CallIntMethod(config, getMaxStackSize);

        if (jRuntimeName) {
            cRuntimeName = env->GetStringUTFChars(jRuntimeName, nullptr);
            core_config.runtime_name = cRuntimeName;
        }
        if (jRuntimeVersion) {
            cRuntimeVersion = env->GetStringUTFChars(jRuntimeVersion, nullptr);
            core_config.runtime_version = cRuntimeVersion;
        }
        core_config.memory_limit_bytes = static_cast<size_t>(memoryLimit);
        core_config.max_stack_size = static_cast<uint32_t>(maxStack);

        env->DeleteLocalRef(configClass);
    }

    EJSCoreRuntime* runtime = ejs_runtime_create(&core_config);

    if (jRuntimeName && cRuntimeName) env->ReleaseStringUTFChars(jRuntimeName, cRuntimeName);
    if (jRuntimeVersion && cRuntimeVersion) env->ReleaseStringUTFChars(jRuntimeVersion, cRuntimeVersion);
    if (jRuntimeName) env->DeleteLocalRef(jRuntimeName);
    if (jRuntimeVersion) env->DeleteLocalRef(jRuntimeVersion);

    if (!runtime) {
        return 0;
    }

    EJSAndroidRuntime* runtime_obj = new EJSAndroidRuntime(runtime);

    // Extract contextDefaults from EJSRuntimeConfiguration
    if (config) {
        jclass configClass = env->GetObjectClass(config);
        jmethodID getContextDefaults = env->GetMethodID(configClass, "getContextDefaults", "()Ljava/util/Map;");
        jobject jMap = env->CallObjectMethod(config, getContextDefaults);
        if (jMap) {
            jclass mapClass = env->FindClass("java/util/Map");
            jmethodID entrySetMethod = env->GetMethodID(mapClass, "entrySet", "()Ljava/util/Set;");
            jobject jSet = env->CallObjectMethod(jMap, entrySetMethod);
            if (jSet) {
                jclass setClass = env->FindClass("java/util/Set");
                jmethodID iteratorMethod = env->GetMethodID(setClass, "iterator", "()Ljava/util/Iterator;");
                jobject jSetIterator = env->CallObjectMethod(jSet, iteratorMethod);
                if (jSetIterator) {
                    jclass iteratorClass = env->FindClass("java/util/Iterator");
                    jmethodID hasNextMethod = env->GetMethodID(iteratorClass, "hasNext", "()Z");
                    jmethodID nextMethod = env->GetMethodID(iteratorClass, "next", "()Ljava/lang/Object;");

                    jclass entryClass = env->FindClass("java/util/Map$Entry");
                    jmethodID getKeyMethod = env->GetMethodID(entryClass, "getKey", "()Ljava/lang/Object;");
                    jmethodID getValueMethod = env->GetMethodID(entryClass, "getValue", "()Ljava/lang/Object;");

                    while (env->CallBooleanMethod(jSetIterator, hasNextMethod)) {
                        jobject jEntry = env->CallObjectMethod(jSetIterator, nextMethod);
                        if (jEntry) {
                            jstring jKey = (jstring)env->CallObjectMethod(jEntry, getKeyMethod);
                            jstring jVal = (jstring)env->CallObjectMethod(jEntry, getValueMethod);

                            const char* cKey = env->GetStringUTFChars(jKey, nullptr);
                            const char* cVal = jVal ? env->GetStringUTFChars(jVal, nullptr) : "";

                            runtime_obj->context_defaults[cKey] = cVal;

                            env->ReleaseStringUTFChars(jKey, cKey);
                            if (jVal) env->ReleaseStringUTFChars(jVal, cVal);

                            env->DeleteLocalRef(jKey);
                            if (jVal) env->DeleteLocalRef(jVal);
                            env->DeleteLocalRef(jEntry);
                        }
                    }
                    env->DeleteLocalRef(jSetIterator);
                    env->DeleteLocalRef(entryClass);
                    env->DeleteLocalRef(iteratorClass);
                }
                env->DeleteLocalRef(jSet);
                env->DeleteLocalRef(setClass);
            }
            env->DeleteLocalRef(jMap);
            env->DeleteLocalRef(mapClass);
        }
        env->DeleteLocalRef(configClass);
    }

    return reinterpret_cast<jlong>(runtime_obj);
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_ejs_platform_EJSRuntime_nativeCreateContext(JNIEnv* env, jobject thiz, jlong nativePtr, jstring contextID, jobject config) {
    EJSAndroidRuntime* runtime = reinterpret_cast<EJSAndroidRuntime*>(nativePtr);
    if (!runtime || runtime->invalidated) return nullptr;

    std::lock_guard<std::mutex> guard(runtime->lock);
    if (runtime->invalidated || runtime->core_runtime == nullptr) {
        return nullptr;
    }

    EJSCoreContext* context = ejs_context_create(runtime->core_runtime);
    if (!context) return nullptr;

    EJSAndroidContext* android_context = new EJSAndroidContext(context, runtime);
    runtime->contexts.insert(android_context);

    jobject javaContext = env->NewObject(g_context_class, g_context_ctor, reinterpret_cast<jlong>(android_context), thiz, contextID);
    android_context->java_context_weak_ref = env->NewWeakGlobalRef(javaContext); // Change to NewWeakGlobalRef to prevent strong cycles

    // Context configuration inherits contextDefaults from the Runtime first
    android_context->config_snapshot = runtime->context_defaults;

    // Extract configurations from EJSContextConfiguration and override
    if (config) {
        jclass configClass = env->GetObjectClass(config);
        jmethodID getValuesMethod = env->GetMethodID(configClass, "getValues", "()Ljava/util/Map;");
        jobject jMap = env->CallObjectMethod(config, getValuesMethod);
        if (jMap) {
            jclass mapClass = env->FindClass("java/util/Map");
            jmethodID entrySetMethod = env->GetMethodID(mapClass, "entrySet", "()Ljava/util/Set;");
            jobject jSet = env->CallObjectMethod(jMap, entrySetMethod);
            if (jSet) {
                jclass setClass = env->FindClass("java/util/Set");
                jmethodID iteratorMethod = env->GetMethodID(setClass, "iterator", "()Ljava/util/Iterator;");
                jobject jSetIterator = env->CallObjectMethod(jSet, iteratorMethod);
                if (jSetIterator) {
                    jclass iteratorClass = env->FindClass("java/util/Iterator");
                    jmethodID hasNextMethod = env->GetMethodID(iteratorClass, "hasNext", "()Z");
                    jmethodID nextMethod = env->GetMethodID(iteratorClass, "next", "()Ljava/lang/Object;");

                    jclass entryClass = env->FindClass("java/util/Map$Entry");
                    jmethodID getKeyMethod = env->GetMethodID(entryClass, "getKey", "()Ljava/lang/Object;");
                    jmethodID getValueMethod = env->GetMethodID(entryClass, "getValue", "()Ljava/lang/Object;");

                    while (env->CallBooleanMethod(jSetIterator, hasNextMethod)) {
                        jobject jEntry = env->CallObjectMethod(jSetIterator, nextMethod);
                        if (jEntry) {
                            jstring jKey = (jstring)env->CallObjectMethod(jEntry, getKeyMethod);
                            jstring jVal = (jstring)env->CallObjectMethod(jEntry, getValueMethod);

                            const char* cKey = env->GetStringUTFChars(jKey, nullptr);
                            const char* cVal = jVal ? env->GetStringUTFChars(jVal, nullptr) : "";

                            android_context->config_snapshot[cKey] = cVal;

                            env->ReleaseStringUTFChars(jKey, cKey);
                            if (jVal) env->ReleaseStringUTFChars(jVal, cVal);

                            env->DeleteLocalRef(jKey);
                            if (jVal) env->DeleteLocalRef(jVal);
                            env->DeleteLocalRef(jEntry);
                        }
                    }
                    env->DeleteLocalRef(jSetIterator);
                    env->DeleteLocalRef(entryClass);
                    env->DeleteLocalRef(iteratorClass);
                }
                env->DeleteLocalRef(jSet);
                env->DeleteLocalRef(setClass);
            }
            env->DeleteLocalRef(jMap);
            env->DeleteLocalRef(mapClass);
        }
        env->DeleteLocalRef(configClass);
    }

    EJSCoreHostAPI hostAPI = ejs_host_api_default_value();
    hostAPI.invoke_api.user_data = ejs_user_data_ref_make(android_context, nullptr, nullptr);
    hostAPI.invoke_api.invoke = ejs_context_dispatch_host_invoke;
    hostAPI.sync_invoke_api.user_data = ejs_user_data_ref_make(android_context, nullptr, nullptr);
    hostAPI.sync_invoke_api.invoke_sync = ejs_context_dispatch_host_invoke_sync;

    ejs_context_register_host(context, &hostAPI);

    return javaContext;
}

extern "C" JNIEXPORT void JNICALL
Java_com_ejs_platform_EJSRuntime_requestInterrupt(JNIEnv* env, jobject thiz) {
    jclass clazz = env->GetObjectClass(thiz);
    jfieldID ptrField = env->GetFieldID(clazz, "nativePtr", "J");
    EJSAndroidRuntime* runtime = reinterpret_cast<EJSAndroidRuntime*>(env->GetLongField(thiz, ptrField));
    if (!runtime) {
        env->DeleteLocalRef(clazz);
        return;
    }

    {
        std::lock_guard<std::mutex> guard(runtime->lock);
        if (runtime->invalidated || !runtime->core_runtime) {
            env->DeleteLocalRef(clazz);
            return;
        }
        ejs_request_interrupt(runtime->core_runtime);
    }
    env->DeleteLocalRef(clazz);
}

extern "C" JNIEXPORT void JNICALL
Java_com_ejs_platform_EJSRuntime_nativeInvalidate(JNIEnv* env, jobject thiz) {
    jclass clazz = env->GetObjectClass(thiz);
    jfieldID ptrField = env->GetFieldID(clazz, "nativePtr", "J");
    EJSAndroidRuntime* runtime = reinterpret_cast<EJSAndroidRuntime*>(env->GetLongField(thiz, ptrField));
    if (runtime && !runtime->invalidated) {
        EJSCoreRuntime* coreRuntime = nullptr;
        std::vector<EJSAndroidContext*> contexts;
        bool should_delete_runtime = false;

        {
            std::lock_guard<std::mutex> guard(runtime->lock);
            if (runtime->invalidated) {
                env->DeleteLocalRef(clazz);
                return;
            }

            runtime->invalidated = true;
            runtime->destroy_delegated = false;
            coreRuntime = runtime->core_runtime;
            contexts.reserve(runtime->contexts.size());
            for (auto* context : runtime->contexts) {
                contexts.push_back(context);
            }
        }

        if (coreRuntime) {
            ejs_request_interrupt(coreRuntime);
        }

        for (EJSAndroidContext* context : contexts) {
            if (!context) {
                continue;
            }
            context->clearJavaNativePtr(env);
            bool delete_context = false;
            EJSCoreContext* core_context = ejs_android_context_mark_invalidated(context, &delete_context);
            ejs_android_destroy_context_if_ready(context, core_context, delete_context);
        }

        {
            std::lock_guard<std::mutex> guard(runtime->lock);
            if (runtime->contexts.empty()) {
                coreRuntime = runtime->core_runtime;
                runtime->core_runtime = nullptr;
                should_delete_runtime = true;
            } else {
                runtime->destroy_delegated = true;
                coreRuntime = nullptr;
            }
        }

        if (coreRuntime) {
            ejs_runtime_destroy(coreRuntime);
        }

        if (should_delete_runtime) {
            delete runtime;
        }
        env->SetLongField(thiz, ptrField, 0);
    }
    env->DeleteLocalRef(clazz);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_ejs_platform_EJSContext_nativeEvaluateScript(JNIEnv* env, jobject thiz, jstring source, jstring filename) {
    jclass clazz = env->GetObjectClass(thiz);
    jfieldID ptrField = env->GetFieldID(clazz, "nativePtr", "J");
    EJSAndroidContext* context = reinterpret_cast<EJSAndroidContext*>(env->GetLongField(thiz, ptrField));
    env->DeleteLocalRef(clazz);

    if (!context) return JNI_FALSE;
    if (!context->beginCall()) return JNI_FALSE;
    if (!source) {
        context->endCall();
        throwException(env, "Source is required");
        return JNI_FALSE;
    }

    const char* c_source = env->GetStringUTFChars(source, nullptr);
    const char* c_filename = filename ? env->GetStringUTFChars(filename, nullptr) : nullptr;
    if (!c_source) {
        if (filename && c_filename) {
            env->ReleaseStringUTFChars(filename, c_filename);
        }
        context->endCall();
        return JNI_FALSE;
    }

    EJSCoreResult result = ejs_eval_script(context->core_context, c_filename, c_source, env->GetStringUTFLength(source));

    env->ReleaseStringUTFChars(source, c_source);
    if (filename) env->ReleaseStringUTFChars(filename, c_filename);

    jboolean success = JNI_TRUE;
    if (result.status == EJS_STATUS_ERROR) {
        const char* msg = result.error ? ejs_error_message(result.error) : "Unknown runtime error";
        throwException(env, msg);
        if (result.error) ejs_error_destroy(result.error);
        success = JNI_FALSE;
    }

    context->endCall();
    return success;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_ejs_platform_EJSContext_nativeEvaluateModule(JNIEnv* env, jobject thiz, jstring source, jstring specifier, jstring sourceURL) {
    jclass clazz = env->GetObjectClass(thiz);
    jfieldID ptrField = env->GetFieldID(clazz, "nativePtr", "J");
    EJSAndroidContext* context = reinterpret_cast<EJSAndroidContext*>(env->GetLongField(thiz, ptrField));
    env->DeleteLocalRef(clazz);

    if (!context) return JNI_FALSE;
    if (!context->beginCall()) return JNI_FALSE;
    if (!source || !specifier) {
        context->endCall();
        throwException(env, "Source and specifier are required");
        return JNI_FALSE;
    }

    const char* c_source = env->GetStringUTFChars(source, nullptr);
    const char* c_specifier = specifier ? env->GetStringUTFChars(specifier, nullptr) : nullptr;
    const char* c_sourceURL = sourceURL ? env->GetStringUTFChars(sourceURL, nullptr) : nullptr;
    if (!c_source || !c_specifier) {
        if (c_source) {
            env->ReleaseStringUTFChars(source, c_source);
        }
        if (c_specifier) {
            env->ReleaseStringUTFChars(specifier, c_specifier);
        }
        if (c_sourceURL) {
            env->ReleaseStringUTFChars(sourceURL, c_sourceURL);
        }
        context->endCall();
        return JNI_FALSE;
    }

    EJSCoreEvalOptions options;
    options.abi_version = EJS_RUNTIME_ABI_VERSION;
    options.struct_size = sizeof(EJSCoreEvalOptions);
    options.flags = 0;
    options.reserved[0] = nullptr;
    options.reserved[1] = nullptr;
    options.reserved[2] = nullptr;
    options.reserved[3] = nullptr;
    options.specifier = c_specifier;
    options.source_url = c_sourceURL;
    options.kind = EJS_EVAL_KIND_MODULE;

    EJSCoreResult result = ejs_eval_module(context->core_context, &options, c_source, env->GetStringUTFLength(source));

    env->ReleaseStringUTFChars(source, c_source);
    if (specifier) env->ReleaseStringUTFChars(specifier, c_specifier);
    if (sourceURL) env->ReleaseStringUTFChars(sourceURL, c_sourceURL);

    jboolean success = JNI_TRUE;
    if (result.status == EJS_STATUS_ERROR) {
        const char* msg = result.error ? ejs_error_message(result.error) : "Unknown runtime error";
        throwException(env, msg);
        if (result.error) ejs_error_destroy(result.error);
        success = JNI_FALSE;
    }

    context->endCall();
    return success;
}

extern "C" JNIEXPORT void JNICALL
Java_com_ejs_platform_EJSContext_nativeInvalidate(JNIEnv* env, jobject thiz) {
    jclass clazz = env->GetObjectClass(thiz);
    jfieldID ptrField = env->GetFieldID(clazz, "nativePtr", "J");
    EJSAndroidContext* context = reinterpret_cast<EJSAndroidContext*>(env->GetLongField(thiz, ptrField));
    env->DeleteLocalRef(clazz);

    if (context) {
        EJSCoreRuntime* coreRuntime = nullptr;
        bool already_invalidated = false;
        EJSAndroidRuntime* runtime = nullptr;
        {
            std::lock_guard<std::mutex> lock(context->state_lock);
            if (context->invalidated) {
                already_invalidated = true;
            } else {
                context->invalidated = true;
                runtime = context->runtime;
            }
        }

        if (!already_invalidated && runtime) {
            std::lock_guard<std::mutex> runtime_guard(runtime->lock);
            coreRuntime = runtime->core_runtime;
        }
        if (!already_invalidated && coreRuntime) {
            ejs_request_interrupt(coreRuntime);
        }

        if (!already_invalidated) {
            bool delete_context = false;
            EJSCoreContext* core_context = ejs_android_context_mark_invalidated(context, &delete_context);
            ejs_android_destroy_context_if_ready(context, core_context, delete_context);
        }
        env->SetLongField(thiz, ptrField, 0);
    }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_ejs_platform_EJSContext_nativeRegisterProvider(JNIEnv* env, jobject thiz, jobject provider) {
    jclass clazz = env->GetObjectClass(thiz);
    jfieldID ptrField = env->GetFieldID(clazz, "nativePtr", "J");
    EJSAndroidContext* context = reinterpret_cast<EJSAndroidContext*>(env->GetLongField(thiz, ptrField));
    env->DeleteLocalRef(clazz);

    if (!context || !provider) return JNI_FALSE;
    if (!context->beginCall()) return JNI_FALSE;

    jstring jModuleID = (jstring)env->CallObjectMethod(provider, g_provider_get_module_id);
    if (!jModuleID) {
        context->endCall();
        return JNI_FALSE;
    }

    const char* cModuleID = env->GetStringUTFChars(jModuleID, nullptr);
    std::string moduleID(cModuleID);
    env->ReleaseStringUTFChars(jModuleID, cModuleID);
    env->DeleteLocalRef(jModuleID);

    jobject globalProvider = env->NewGlobalRef(provider);
    jobject replacedProvider = nullptr;
    {
        std::lock_guard<std::mutex> guard(context->lock);
        auto it = context->providers.find(moduleID);
        if (it != context->providers.end()) {
            replacedProvider = it->second;
        }
        context->providers[moduleID] = globalProvider;
    }
    if (replacedProvider) {
        ejs_android_close_and_delete_provider(env, replacedProvider);
    }

    context->endCall();
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_ejs_platform_EJSContext_nativeUnregisterProviderForModuleID(JNIEnv* env, jobject thiz, jstring moduleID) {
    jclass clazz = env->GetObjectClass(thiz);
    jfieldID ptrField = env->GetFieldID(clazz, "nativePtr", "J");
    EJSAndroidContext* context = reinterpret_cast<EJSAndroidContext*>(env->GetLongField(thiz, ptrField));
    env->DeleteLocalRef(clazz);

    if (!context || !moduleID) return;
    if (!context->beginCall()) return;

    const char* cModuleID = env->GetStringUTFChars(moduleID, nullptr);
    std::string moduleIDStr(cModuleID);
    env->ReleaseStringUTFChars(moduleID, cModuleID);

    jobject providerToClose = nullptr;
    {
        std::lock_guard<std::mutex> guard(context->lock);
        auto it = context->providers.find(moduleIDStr);
        if (it != context->providers.end()) {
            providerToClose = it->second;
            context->providers.erase(it);
        }
    }
    if (providerToClose) {
        ejs_android_close_and_delete_provider(env, providerToClose);
    }

    context->endCall();
}

extern "C" JNIEXPORT void JNICALL
Java_com_ejs_platform_EJSContext_nativeUnregisterAllProviders(JNIEnv* env, jobject thiz) {
    jclass clazz = env->GetObjectClass(thiz);
    jfieldID ptrField = env->GetFieldID(clazz, "nativePtr", "J");
    EJSAndroidContext* context = reinterpret_cast<EJSAndroidContext*>(env->GetLongField(thiz, ptrField));
    env->DeleteLocalRef(clazz);

    if (!context) return;
    if (!context->beginCall()) return;

    std::vector<jobject> providersToClose;
    {
        std::lock_guard<std::mutex> guard(context->lock);
        for (auto& pair : context->providers) {
            providersToClose.push_back(pair.second);
        }
        context->providers.clear();
    }
    for (jobject providerToClose : providersToClose) {
        ejs_android_close_and_delete_provider(env, providerToClose);
    }

    context->endCall();
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_ejs_platform_EJSContext_nativeConfigurationValueForKey(JNIEnv* env, jobject thiz, jstring key) {
    jclass clazz = env->GetObjectClass(thiz);
    jfieldID ptrField = env->GetFieldID(clazz, "nativePtr", "J");
    EJSAndroidContext* context = reinterpret_cast<EJSAndroidContext*>(env->GetLongField(thiz, ptrField));
    env->DeleteLocalRef(clazz);

    if (!context || !key) return nullptr;
    if (!context->beginCall()) return nullptr;

    const char* cKey = env->GetStringUTFChars(key, nullptr);
    std::string keyStr(cKey);
    env->ReleaseStringUTFChars(key, cKey);

    jstring result = nullptr;
    {
        std::lock_guard<std::mutex> guard(context->state_lock);
        auto it = context->config_snapshot.find(keyStr);
        if (it != context->config_snapshot.end()) {
            result = env->NewStringUTF(it->second.c_str());
        }
    }

    context->endCall();
    return result;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_ejs_platform_EJSProviderResponder_nativeFinishWithData(JNIEnv* env, jobject thiz, jbyteArray resultData, jobject error) {
    jclass clazz = env->GetObjectClass(thiz);
    jfieldID ptrField = env->GetFieldID(clazz, "nativePtr", "J");
    long ptr = env->GetLongField(thiz, ptrField);
    env->DeleteLocalRef(clazz);

    if (!ptr) return JNI_FALSE;

    OperationBox* state = reinterpret_cast<OperationBox*>(ptr);
    bool should_call_completion = false;
    {
        std::lock_guard<std::mutex> guard(state->lock);
        if (!state->finished) {
            state->finished = true;
            should_call_completion = true;
        }
    }

    if (should_call_completion) {
        EJSCoreHostError* host_error = nullptr;
        EJSCoreHostError host_error_struct = {};

        if (error) {
            jclass exClass = env->GetObjectClass(error);
            jmethodID getMessage = env->GetMethodID(exClass, "getMessage", "()Ljava/lang/String;");
            jstring msg = (jstring)env->CallObjectMethod(error, getMessage);
            const char* c_msg = msg ? env->GetStringUTFChars(msg, nullptr) : "Unknown Error";

            host_error_struct.abi_version = EJS_NATIVE_ABI_VERSION;
            host_error_struct.struct_size = sizeof(EJSCoreHostError);
            host_error_struct.code = EJS_ERROR_INTERNAL;
            host_error_struct.message = strdup(c_msg);
            host_error = &host_error_struct;

            if (msg) {
                env->ReleaseStringUTFChars(msg, c_msg);
                env->DeleteLocalRef(msg); // Fix local ref leak
            }
            env->DeleteLocalRef(exClass);
        }

        EJSCoreByteView view = {nullptr, 0};
        uint8_t* c_bytes = nullptr;
        if (resultData && !error) {
            jsize len = env->GetArrayLength(resultData);
            if (len > 0) {
                jbyte* bytes = env->GetByteArrayElements(resultData, nullptr);
                c_bytes = (uint8_t*)malloc(len);
                if (c_bytes) {
                    memcpy(c_bytes, bytes, len);
                    view.data = c_bytes;
                    view.size = len;
                }
                env->ReleaseByteArrayElements(resultData, bytes, JNI_ABORT);
            }
        }

        if (state->completion) {
            state->completion(state->completion_data, view, host_error);
        }
        state->completeCoreOperationOnce();

        if (c_bytes) free(c_bytes);
        if (host_error && host_error->message) free((void*)host_error->message);
    }

    env->SetLongField(thiz, ptrField, 0);
    state->decRef();
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_ejs_platform_EJSProviderResponder_nativeDestroy(JNIEnv* env, jclass clazz, jlong ptr) {
    if (ptr) {
        OperationBox* state = reinterpret_cast<OperationBox*>(ptr);
        bool should_call_completion = false;
        {
            std::lock_guard<std::mutex> guard(state->lock);
            if (!state->finished) {
                state->finished = true;
                should_call_completion = true;
            }
        }

        if (should_call_completion) {
            EJSCoreHostError host_error = {};
            host_error.abi_version = EJS_NATIVE_ABI_VERSION;
            host_error.struct_size = sizeof(EJSCoreHostError);
            host_error.code = EJS_ERROR_INTERNAL;
            host_error.message = strdup("Responder garbage collected without being completed");

            EJSCoreByteView empty_view = {nullptr, 0};
            if (state->completion) {
                state->completion(state->completion_data, empty_view, &host_error);
            }
            state->completeCoreOperationOnce();
            free((void*)host_error.message);
        }
        state->decRef();
    }
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    g_vm = vm;
    JNIEnv* env;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    jclass local_context = env->FindClass("com/ejs/platform/EJSContext");
    if (!local_context) return JNI_ERR;
    g_context_class = reinterpret_cast<jclass>(env->NewGlobalRef(local_context));
    g_context_ctor = env->GetMethodID(g_context_class, "<init>", "(JLcom/ejs/platform/EJSRuntime;Ljava/lang/String;)V");
    if (!g_context_ctor) return JNI_ERR;

    jclass local_provider = env->FindClass("com/ejs/platform/EJSProvider");
    if (!local_provider) return JNI_ERR;
    g_provider_class = reinterpret_cast<jclass>(env->NewGlobalRef(local_provider));
    g_provider_get_module_id = env->GetMethodID(g_provider_class, "getModuleID", "()Ljava/lang/String;");
    if (!g_provider_get_module_id) return JNI_ERR;
    g_provider_invoke_method = env->GetMethodID(g_provider_class, "invokeMethod", "(Ljava/lang/String;[B[BLcom/ejs/platform/EJSContext;Lcom/ejs/platform/EJSProviderResponder;)Lcom/ejs/platform/EJSProviderOperation;");
    if (!g_provider_invoke_method) return JNI_ERR;
    g_provider_invoke_sync_method = env->GetMethodID(g_provider_class, "invokeSyncMethod", "(Ljava/lang/String;[B[BLcom/ejs/platform/EJSContext;)[B");
    if (!g_provider_invoke_sync_method) return JNI_ERR;
    g_provider_close_method = env->GetMethodID(g_provider_class, "close", "()V");
    if (!g_provider_close_method) return JNI_ERR;

    jclass local_responder = env->FindClass("com/ejs/platform/EJSProviderResponder");
    if (!local_responder) return JNI_ERR;
    g_responder_class = reinterpret_cast<jclass>(env->NewGlobalRef(local_responder));
    g_responder_ctor = env->GetMethodID(g_responder_class, "<init>", "(J)V");
    if (!g_responder_ctor) return JNI_ERR;

    jclass local_exception = env->FindClass("java/lang/Exception");
    if (!local_exception) return JNI_ERR;
    g_exception_class = reinterpret_cast<jclass>(env->NewGlobalRef(local_exception));

    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL JNI_OnUnload(JavaVM* vm, void* reserved) {
    JNIEnv* env;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK) {
        if (g_context_class) env->DeleteGlobalRef(g_context_class);
        if (g_provider_class) env->DeleteGlobalRef(g_provider_class);
        if (g_responder_class) env->DeleteGlobalRef(g_responder_class);
        if (g_exception_class) env->DeleteGlobalRef(g_exception_class);
    }
}

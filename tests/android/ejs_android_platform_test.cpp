#include <jni.h>
#include <iostream>
#include <cassert>
#include <cstring>
#include <cstdarg>

extern "C" {
    JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved);
    JNIEXPORT void JNICALL JNI_OnUnload(JavaVM* vm, void* reserved);
    JNIEXPORT jlong JNICALL Java_com_ejs_platform_EJSRuntime_nativeCreate(JNIEnv* env, jobject thiz, jobject config);
    JNIEXPORT jobject JNICALL Java_com_ejs_platform_EJSRuntime_nativeCreateContext(JNIEnv* env, jobject thiz, jlong nativePtr, jstring contextID, jobject config);
    JNIEXPORT void JNICALL Java_com_ejs_platform_EJSRuntime_requestInterrupt(JNIEnv* env, jobject thiz);
    JNIEXPORT void JNICALL Java_com_ejs_platform_EJSRuntime_nativeInvalidate(JNIEnv* env, jobject thiz);
    JNIEXPORT jboolean JNICALL Java_com_ejs_platform_EJSContext_nativeEvaluateScript(JNIEnv* env, jobject thiz, jstring source, jstring filename);
    JNIEXPORT jboolean JNICALL Java_com_ejs_platform_EJSContext_nativeEvaluateModule(JNIEnv* env, jobject thiz, jstring source, jstring specifier, jstring sourceURL);
    JNIEXPORT void JNICALL Java_com_ejs_platform_EJSContext_nativeInvalidate(JNIEnv* env, jobject thiz);
}

static jlong g_nativePtr = 0;
static jlong g_createdContextPtr = 0;
static JNIEnv* g_env_ptr = nullptr;
static int g_throw_count = 0;
static const char* g_last_throw_message = nullptr;

static jclass JNICALL MockGetObjectClass(JNIEnv* env, jobject obj) {
    return (jclass)0x1234;
}

static jfieldID JNICALL MockGetFieldID(JNIEnv* env, jclass clazz, const char* name, const char* sig) {
    return (jfieldID)0x5678;
}

static jlong JNICALL MockGetLongField(JNIEnv* env, jobject obj, jfieldID fieldID) {
    return g_nativePtr;
}

static void JNICALL MockSetLongField(JNIEnv* env, jobject obj, jfieldID fieldID, jlong val) {
    g_nativePtr = val;
}

static jclass JNICALL MockFindClass(JNIEnv* env, const char* name) {
    return (jclass)0x1111;
}

static jmethodID JNICALL MockGetMethodID(JNIEnv* env, jclass clazz, const char* name, const char* sig) {
    return (jmethodID)0x2222;
}

static jobject JNICALL MockNewObject(JNIEnv* env, jclass clazz, jmethodID methodID, ...) {
    va_list args;
    va_start(args, methodID);
    g_createdContextPtr = va_arg(args, jlong);
    va_end(args);
    return (jobject)0x3333;
}

static jobject JNICALL MockNewObjectV(JNIEnv* env, jclass clazz, jmethodID methodID, va_list args) {
    g_createdContextPtr = va_arg(args, jlong);
    return (jobject)0x3333;
}

static jobject JNICALL MockNewGlobalRef(JNIEnv* env, jobject obj) {
    return obj;
}

static void JNICALL MockDeleteGlobalRef(JNIEnv* env, jobject obj) {
    // no-op
}

static void JNICALL MockDeleteLocalRef(JNIEnv* env, jobject obj) {
    // no-op
}

static jweak JNICALL MockNewWeakGlobalRef(JNIEnv* env, jobject obj) {
    return (jweak)obj;
}

static void JNICALL MockDeleteWeakGlobalRef(JNIEnv* env, jweak ref) {
    // no-op
}

static const char* JNICALL MockGetStringUTFChars(JNIEnv* env, jstring string, jboolean* isCopy) {
    if (isCopy) *isCopy = JNI_FALSE;
    return (const char*)string;
}

static jsize JNICALL MockGetStringUTFLength(JNIEnv* env, jstring string) {
    if (!string) return 0;
    return strlen((const char*)string);
}

static void JNICALL MockReleaseStringUTFChars(JNIEnv* env, jstring string, const char* utf) {
    // nothing
}

static jint JNICALL MockGetEnv(JavaVM* vm, void** env, jint version) {
    *env = g_env_ptr;
    return JNI_OK;
}

static jint JNICALL MockThrowNew(JNIEnv* env, jclass clazz, const char* message) {
    g_throw_count += 1;
    g_last_throw_message = message;
    return 0;
}

int main() {
    struct JNINativeInterface_ interface = {};
    interface.GetObjectClass = MockGetObjectClass;
    interface.GetFieldID = MockGetFieldID;
    interface.GetLongField = MockGetLongField;
    interface.SetLongField = MockSetLongField;
    interface.FindClass = MockFindClass;
    interface.GetMethodID = MockGetMethodID;
    interface.NewObject = MockNewObject;
    interface.NewObjectV = MockNewObjectV;
    interface.NewGlobalRef = MockNewGlobalRef;
    interface.DeleteGlobalRef = MockDeleteGlobalRef;
    interface.DeleteLocalRef = MockDeleteLocalRef;
    interface.NewWeakGlobalRef = MockNewWeakGlobalRef;
    interface.DeleteWeakGlobalRef = MockDeleteWeakGlobalRef;
    interface.GetStringUTFChars = MockGetStringUTFChars;
    interface.GetStringUTFLength = MockGetStringUTFLength;
    interface.ReleaseStringUTFChars = MockReleaseStringUTFChars;
    interface.ThrowNew = MockThrowNew;

    JNIEnv_ env_struct;
    env_struct.functions = &interface;
    JNIEnv* env = &env_struct;
    g_env_ptr = env;

    struct JNIInvokeInterface_ vm_interface = {};
    vm_interface.GetEnv = MockGetEnv;
    
    JavaVM_ vm_struct;
    vm_struct.functions = &vm_interface;
    JavaVM* vm = &vm_struct;

    std::cout << "Initializing JNI_OnLoad..." << std::endl;
    jint load_res = JNI_OnLoad(vm, nullptr);
    assert(load_res == JNI_VERSION_1_6);
    std::cout << "JNI_OnLoad successful." << std::endl;

    jobject dummyConfig = (jobject)0x1;
    jobject dummyRuntimeThis = (jobject)0x2;
    jobject dummyContextThis = (jobject)0x3;

    std::cout << "Testing Android Platform EJSRuntime and EJSContext" << std::endl;

    jlong runtimePtr = Java_com_ejs_platform_EJSRuntime_nativeCreate(env, dummyRuntimeThis, nullptr);
    assert(runtimePtr != 0);
    std::cout << "Runtime created." << std::endl;

    jstring contextID = (jstring)"app://test/context";
    jobject javaContext = Java_com_ejs_platform_EJSRuntime_nativeCreateContext(env, dummyRuntimeThis, runtimePtr, contextID, nullptr);
    assert(javaContext != nullptr);
    std::cout << "Context created." << std::endl;

    jlong contextPtr = g_createdContextPtr;

    g_nativePtr = contextPtr;
    jstring scriptSource = (jstring)"var a = 1 + 1;";
    jstring scriptFilename = (jstring)"test.js";
    jboolean evalRes = Java_com_ejs_platform_EJSContext_nativeEvaluateScript(env, dummyContextThis, scriptSource, scriptFilename);
    assert(evalRes == JNI_FALSE);
    assert(g_throw_count == 1);
    assert(g_last_throw_message != nullptr);
    std::cout << "Script evaluation rejected by stub engine." << std::endl;

    g_nativePtr = contextPtr;
    jstring moduleSource = (jstring)"export const b = 2;";
    jstring moduleSpecifier = (jstring)"test_module";
    jstring moduleURL = (jstring)"test_module.js";
    jboolean evalModRes = Java_com_ejs_platform_EJSContext_nativeEvaluateModule(env, dummyContextThis, moduleSource, moduleSpecifier, moduleURL);
    assert(evalModRes == JNI_FALSE);
    assert(g_throw_count == 2);
    assert(g_last_throw_message != nullptr);
    std::cout << "Module evaluation rejected by stub engine." << std::endl;

    g_nativePtr = runtimePtr;
    Java_com_ejs_platform_EJSRuntime_requestInterrupt(env, dummyRuntimeThis);
    std::cout << "Interrupt requested." << std::endl;

    g_nativePtr = contextPtr;
    Java_com_ejs_platform_EJSContext_nativeInvalidate(env, dummyContextThis);
    std::cout << "Context invalidated." << std::endl;
    
    g_nativePtr = runtimePtr;
    Java_com_ejs_platform_EJSRuntime_nativeInvalidate(env, dummyRuntimeThis);
    std::cout << "Runtime invalidated." << std::endl;

    std::cout << "All basic execution tests passed!" << std::endl;
    
    JNI_OnUnload(vm, nullptr);
    return 0;
}

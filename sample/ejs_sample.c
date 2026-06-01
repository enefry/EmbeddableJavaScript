#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include "ejs_runtime.h"

// ANSI color escape codes for premium terminal output
#define COLOR_RESET   "\033[0m"
#define COLOR_RED     "\033[1;31m"
#define COLOR_GREEN   "\033[1;32m"
#define COLOR_YELLOW  "\033[1;33m"
#define COLOR_BLUE    "\033[1;34m"
#define COLOR_MAGENTA "\033[1;35m"
#define COLOR_CYAN    "\033[1;36m"

struct EJSCoreHostOperation {
    int dummy;
};

// Sample Host state
typedef struct {
    atomic_int ref_count;
    int received_count;
} SampleHost;

static void sample_host_retain(void *user_data) {
    SampleHost *host = (SampleHost *)user_data;
    if (host != NULL) {
        atomic_fetch_add(&host->ref_count, 1);
    }
}

static void sample_host_release_ref(void *user_data) {
    SampleHost *host = (SampleHost *)user_data;
    if (host != NULL && atomic_fetch_sub(&host->ref_count, 1) == 1) {
        free(host);
    }
}

// Custom Host Operations
static int sample_host_cancel(EJSCoreUserData user_data, EJSCoreHostOperation *operation) {
    (void)user_data;
    (void)operation;
    return 0;
}

static void sample_host_release(EJSCoreUserData user_data, EJSCoreHostOperation *operation) {
    (void)user_data;
    if (operation) {
        free(operation);
    }
}

// Custom Host Invoke Callback
static EJSCoreHostOperation *sample_host_invoke(EJSCoreUserData user_data,
                                            const char *module_id,
                                            const char *method_id,
                                            EJSCoreByteView payload,
                                            EJSCoreByteView transfer_buffer,
                                            EJSCoreInvokeCompletion completion,
                                            void *completion_data) {
    SampleHost *host = (SampleHost *)user_data.value;
    host->received_count++;

    // Format highly premium terminal print
    printf("\n" COLOR_CYAN "┌─────────────────── EJS NATIVE HOST ───────────────────┐" COLOR_RESET "\n");
    printf(COLOR_CYAN "│" COLOR_RESET " " COLOR_GREEN "[SUCCESS]" COLOR_RESET " Received call from JS runtime!               " COLOR_CYAN "│" COLOR_RESET "\n");
    printf(COLOR_CYAN "│" COLOR_RESET " - " COLOR_YELLOW "Module ID:" COLOR_RESET " %-40s " COLOR_CYAN "│" COLOR_RESET "\n", module_id ? module_id : "NULL");
    printf(COLOR_CYAN "│" COLOR_RESET " - " COLOR_YELLOW "Method ID:" COLOR_RESET " %-40s " COLOR_CYAN "│" COLOR_RESET "\n", method_id ? method_id : "NULL");
    
    if (payload.data && payload.size > 0) {
        // Safe printing of payload
        char *payload_str = malloc(payload.size + 1);
        memcpy(payload_str, payload.data, payload.size);
        payload_str[payload.size] = '\0';
        printf(COLOR_CYAN "│" COLOR_RESET " - " COLOR_MAGENTA "Payload:" COLOR_RESET " %-42s " COLOR_CYAN "│" COLOR_RESET "\n", payload_str);
        free(payload_str);
    } else {
        printf(COLOR_CYAN "│" COLOR_RESET " - " COLOR_MAGENTA "Payload:" COLOR_RESET " EMPTY                                    " COLOR_CYAN "│" COLOR_RESET "\n");
    }
    
    printf(COLOR_CYAN "└───────────────────────────────────────────────────────┘" COLOR_RESET "\n\n");

    // Complete synchronously with a success payload response
    EJSCoreByteView result;
    result.data = (const uint8_t *)"\"OK\"";
    result.size = 4;
    completion(completion_data, result, NULL);

    // Return a dummy operation
    EJSCoreHostOperation *op = calloc(1, sizeof(EJSCoreHostOperation));
    return op;
}

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;

    printf(COLOR_GREEN "🚀 Starting EJS Pure Core Microkernel Demonstration..." COLOR_RESET "\n");

    // 1. Setup Runtime Config
    EJSCoreRuntimeConfig config = ejs_runtime_config_default_value();
    config.runtime_name = "ejs_sample_runtime";
    config.runtime_version = "1.0.0";
    config.memory_limit_bytes = 1024 * 1024 * 16; // 16MB
    config.max_stack_size = 1024 * 256;          // 256KB

    // 2. Create Runtime and Context
    EJSCoreRuntime *runtime = ejs_runtime_create(&config);
    if (!runtime) {
        fprintf(stderr, COLOR_RED "❌ Failed to create EJSCoreRuntime" COLOR_RESET "\n");
        return EXIT_FAILURE;
    }

    EJSCoreContext *context = ejs_context_create(runtime);
    if (!context) {
        fprintf(stderr, COLOR_RED "❌ Failed to create EJSCoreContext" COLOR_RESET "\n");
        ejs_runtime_destroy(runtime);
        return EXIT_FAILURE;
    }

    // 3. Register Custom Native Host API
    SampleHost *sample_host = (SampleHost *)calloc(1u, sizeof(SampleHost));
    if (sample_host == NULL) {
        fprintf(stderr, COLOR_RED "❌ Failed to allocate sample host state" COLOR_RESET "\n");
        ejs_context_destroy(context);
        ejs_runtime_destroy(runtime);
        return EXIT_FAILURE;
    }
    atomic_init(&sample_host->ref_count, 1);
    EJSCoreHostAPI host_api = ejs_host_api_default_value();
    host_api.user_data = ejs_user_data_ref_make(sample_host, sample_host_retain, sample_host_release_ref);

    host_api.operations.user_data = ejs_user_data_ref_make(sample_host, sample_host_retain, sample_host_release_ref);
    host_api.operations.cancel = sample_host_cancel;
    host_api.operations.release = sample_host_release;

    host_api.invoke_api.user_data = ejs_user_data_ref_make(sample_host, sample_host_retain, sample_host_release_ref);
    host_api.invoke_api.invoke = sample_host_invoke;

    ejs_context_register_host(context, &host_api);

    // 4. Evaluate JavaScript code through the core native invoke channel.
    const char *js_code = 
        "__ejs_native__.invoke(\"test\", \"report\", \"Hello from EJS Core Sample JS environment!\");\n";
    
    printf(COLOR_BLUE "📖 Evaluating JavaScript Code..." COLOR_RESET "\n");
    EJSCoreResult res = ejs_eval_script(context, "sample.js", js_code, strlen(js_code));
    if (res.status != EJS_STATUS_OK) {
        if (res.error) {
            fprintf(stderr, COLOR_RED "❌ JS Evaluation Error: %s" COLOR_RESET "\n", ejs_error_message(res.error));
            ejs_error_destroy(res.error);
        }
        ejs_context_destroy(context);
        ejs_runtime_destroy(runtime);
        sample_host_release_ref(sample_host);
        return EXIT_FAILURE;
    }


    // 7. Cleanup and Destroy
    printf(COLOR_GREEN "🧹 Cleaning up and terminating gracefully..." COLOR_RESET "\n");
    ejs_context_destroy(context);
    ejs_runtime_destroy(runtime);
    sample_host_release_ref(sample_host);

    printf(COLOR_GREEN "🎉 EJS Demonstration successfully completed!" COLOR_RESET "\n");
    return EXIT_SUCCESS;
}

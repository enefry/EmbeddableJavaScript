#import "EJSAppleCLISupport.h"

int main(int argc, const char *argv[]) {
    EJSCLIRunOptions *options = [[EJSCLIRunOptions alloc] init];
    options.runtimeName = @"ejs_apple_cli";
    options.contextID = @"app://tools/ejs_apple_cli";
    options.timeoutSeconds = 5.0;
    return EJSCLIRunMain(argc, argv, options);
}

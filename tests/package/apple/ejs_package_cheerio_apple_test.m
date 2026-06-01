#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <stdlib.h>

#import "EJSApplePlatform.h"
#import "EJSPackageApple.h"

@interface TestReportProvider : NSObject <EJSProvider>
@property (nonatomic, copy) NSString *moduleID;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, copy) NSString *lastMessage;
@end

@implementation TestReportProvider

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _moduleID = @"test";
        _semaphore = dispatch_semaphore_create(0);
        _lastMessage = @"";
    }
    return self;
}

- (id<EJSProviderOperation>)invokeMethod:(NSString *)methodID
                                 payload:(NSData *)payload
                          transferBuffer:(NSData *)transferBuffer
                                 context:(EJSContext *)context
                               responder:(EJSProviderResponder *)responder {
    (void)transferBuffer;
    (void)context;

    if (![methodID isEqualToString:@"report"]) {
        [responder finishWithData:nil error:EJSProviderMakeError(EJSProviderErrorCodeUnsupported, @"Unsupported report method")];
        return [[EJSImmediateOperation alloc] init];
    }

    NSString *message = payload != nil ? [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] : @"";
    self.lastMessage = message ?: @"";
    dispatch_semaphore_signal(self.semaphore);
    [responder finishWithData:nil error:nil];
    return [[EJSImmediateOperation alloc] init];
}

@end

static BOOL wait_for_report(TestReportProvider *provider, NSString *expected) {
    long result = dispatch_semaphore_wait(provider.semaphore,
                                          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
    if (result != 0) {
        fprintf(stderr, "timed out waiting for cheerio report: expected=%s last=%s\n",
                expected.UTF8String,
                provider.lastMessage.UTF8String);
        return NO;
    }
    if (![provider.lastMessage isEqualToString:expected]) {
        fprintf(stderr, "unexpected cheerio report: expected=%s actual=%s\n",
                expected.UTF8String,
                provider.lastMessage.UTF8String);
        return NO;
    }
    return YES;
}

static NSDictionary<NSString *, id> * read_manifest(NSURL *packageURL, NSError **error) {
    NSURL *manifestURL = [packageURL URLByAppendingPathComponent:@"ejs-package.json" isDirectory:NO];
    NSData *data = [NSData dataWithContentsOfURL:manifestURL options:0 error:error];
    if (data == nil) {
        return nil;
    }
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![root isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return root;
}

int main(void) {
    @autoreleasepool {
        const char *packagePath = getenv("EJS_CHEERIO_EJSPKG_PATH");
        if (packagePath == NULL || packagePath[0] == '\0') {
            fprintf(stdout, "ejs_package_cheerio_apple_test: SKIP EJS_CHEERIO_EJSPKG_PATH is not set\n");
            return 77;
        }

        NSError *error = nil;
        NSString *packagePathString = [NSString stringWithUTF8String:packagePath];
        NSURL *packageURL = [NSURL fileURLWithPath:packagePathString isDirectory:YES];
        NSDictionary<NSString *, id> *manifest = read_manifest(packageURL, &error);
        if (manifest == nil) {
            fprintf(stderr, "failed to read cheerio manifest: %s\n", error.localizedDescription.UTF8String);
            return EXIT_FAILURE;
        }

        NSString *entry = [manifest[@"entry"] isKindOfClass:[NSString class]] ? manifest[@"entry"] : nil;
        NSString *packageID = [manifest[@"packageId"] isKindOfClass:[NSString class]] ? manifest[@"packageId"] : nil;
        NSString *packageSHA256 = [manifest[@"packageSha256"] isKindOfClass:[NSString class]] ? manifest[@"packageSha256"] : nil;
        NSDictionary *dependencies = [manifest[@"dependencies"] isKindOfClass:[NSDictionary class]] ? manifest[@"dependencies"] : nil;
        if (entry.length == 0 ||
            packageSHA256.length == 0 ||
            (![packageID hasPrefix:@"npm:cheerio@"] &&
             ![dependencies[@"cheerio"] isKindOfClass:[NSDictionary class]])) {
            fprintf(stderr, "cheerio manifest does not look like a converted cheerio package\n");
            return EXIT_FAILURE;
        }

        EJSRuntimeConfiguration *configuration = [[EJSRuntimeConfiguration alloc] init];
        configuration.runtimeName = @"ejs_package_cheerio_apple_test";
        EJSRuntime *runtime = [[EJSRuntime alloc] initWithConfiguration:configuration];
        EJSContext *context = [runtime createContextWithID:@"app://tests/package/cheerio" error:&error];
        if (context == nil) {
            fprintf(stderr, "failed to create cheerio context: %s\n", error.localizedDescription.UTF8String);
            return EXIT_FAILURE;
        }

        TestReportProvider *reportProvider = [[TestReportProvider alloc] init];
        if (![context registerProvider:reportProvider error:&error]) {
            fprintf(stderr, "failed to register cheerio report provider: %s\n", error.localizedDescription.UTF8String);
            return EXIT_FAILURE;
        }

        EJSPackageInstallOptions *options = [[EJSPackageInstallOptions alloc] init];
        options.approvedPackageSHA256Values = [NSSet setWithObject:packageSHA256];
        if (!EJSPackageInstallIntoContext(context, packageURL, options, &error)) {
            fprintf(stderr, "failed to install cheerio package: %s\n", error.localizedDescription.UTF8String);
            return EXIT_FAILURE;
        }

        NSString *source = [NSString stringWithFormat:
            @"import { load } from '%@';"
             "const $ = load('<main><h1>Hello</h1><a href=\"/x\">Link</a></main>');"
             "const result = $('h1').text() + ':' + $('a').attr('href') + ':' + $('main').children().length;"
             "__ejs_native__.invoke('test', 'report', result);",
            entry];

        if (![context evaluateModule:source
                           specifier:@"cheerio_runtime_test"
                           sourceURL:@"app://tests/package/cheerio.mjs"
                               error:&error] ||
            !wait_for_report(reportProvider, @"Hello:/x:2")) {
            fprintf(stderr, "cheerio runtime verification failed: %s\n", error.localizedDescription.UTF8String);
            return EXIT_FAILURE;
        }

        return EXIT_SUCCESS;
    }
}

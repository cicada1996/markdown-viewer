// One-shot helper: makes the given app the system default for Markdown files.
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

int main(int argc, const char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: set_default /path/to/App.app\n");
        return 1;
    }
    NSURL *appURL = [NSURL fileURLWithPath:@(argv[1])];
    UTType *markdown = [UTType typeWithIdentifier:@"net.daringfireball.markdown"];
    if (!markdown) {
        fprintf(stderr, "markdown UTType unavailable\n");
        return 1;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int status = 0;
    [[NSWorkspace sharedWorkspace] setDefaultApplicationAtURL:appURL
                                            toOpenContentType:markdown
                                            completionHandler:^(NSError *error) {
        if (error) {
            fprintf(stderr, "could not set default handler: %s\n",
                    error.localizedDescription.UTF8String);
            status = 1;
        } else {
            printf("default .md handler set\n");
        }
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return status;
}

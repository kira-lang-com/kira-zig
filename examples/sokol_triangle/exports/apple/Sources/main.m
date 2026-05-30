#import <Foundation/Foundation.h>

// Unified Kira Runner Entry: identical for macOS, iOS, iPadOS, tvOS and visionOS.
// The KiraRunner.toml `mode` field selects standalone playback vs. live reload.
extern int kira_live_runner_entry(const char *manifest_path);

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
#if defined(KIRA_TARGET_UNAVAILABLE)
    @autoreleasepool {
        NSLog(@"Kira: this platform target has no native backend build yet.");
    }
    return 0;
#else
    @autoreleasepool {
        NSString *path = [[NSBundle mainBundle] pathForResource:@"KiraRunner" ofType:@"toml"];
        return kira_live_runner_entry([path UTF8String]);
    }
#endif
}

#import <UIKit/UIKit.h>
#import <NodeMobile/NodeMobile.h>
#include <unistd.h>
#include <vector>
#include <string>

@interface ProbeApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) NSString *resultPath;
@end
@implementation ProbeApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *screen = [UIViewController new];
    screen.view.backgroundColor = UIColor.systemBackgroundColor;
    self.label = [UILabel new];
    self.label.textColor = UIColor.labelColor;
    self.label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.label.numberOfLines = 0;
    self.label.text = @"Starting native Node capability test…";
    self.label.frame = CGRectInset(self.window.bounds, 24, 90);
    self.label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [screen.view addSubview:self.label];
    self.window.rootViewController = screen;
    [self.window makeKeyAndVisible];
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    self.resultPath = [documents stringByAppendingPathComponent:@"result.json"];
    NSString *run = NSProcessInfo.processInfo.environment[@"OPERATOR_PROBE_RUN"];
    if (!run.length) run = NSUUID.UUID.UUIDString;
    setenv("OPERATOR_PROBE_RUN", run.UTF8String, 1);
    setenv("OPERATOR_PROBE_DIRECTORY", documents.UTF8String, 1);
    chdir(documents.UTF8String);
    NSString *script = [NSBundle.mainBundle pathForResource:@"capabilities" ofType:@"mjs"];
    NSLog(@"[native-node] starting bundled capability test run=%@", run);
    [NSThread detachNewThreadWithBlock:^{
        @autoreleasepool {
            std::string joined = std::string("node") + '\0' + script.UTF8String + '\0';
            std::vector<char> bytes(joined.begin(), joined.end());
            char *args[] = {bytes.data(), bytes.data() + 5};
            int code = node_start(2, args);
            NSLog(@"[native-node] engine returned code=%d", code);
        }
    }];
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    return YES;
}
- (void)refresh {
    NSData *data = [NSData dataWithContentsOfFile:self.resultPath];
    if (!data) return;
    NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!result) return;
    self.label.text = [NSString stringWithFormat:@"Native Node test\n\nStatus: %@\nNode: %@\nPlatform: %@\nChecks: %@\nTime: %@ ms\n%@", result[@"status"], result[@"node"], result[@"platform"], [result[@"checks"] componentsJoinedByString:@", "], result[@"elapsedMs"], result[@"error"] ?: @""];
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeApp.class));}
}

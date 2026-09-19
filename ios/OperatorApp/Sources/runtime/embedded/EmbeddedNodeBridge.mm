#import "EmbeddedNodeBridge.h"
#import <NodeMobile/NodeMobile.h>
#import <os/log.h>
#include <string>
#include <vector>

@implementation EmbeddedNodeBridge
+ (BOOL)startEntry:(NSString *)entry state:(NSString *)state runID:(NSString *)runID
             token:(NSString *)token statusPath:(NSString *)statusPath gatewayPort:(uint16_t)gatewayPort {
    static BOOL started = NO;
    @synchronized(self) {
        if (started) return NO;
        started = YES;
        if (setenv("OPERATOR_GATEWAY_TOKEN", token.UTF8String, 1) ||
            setenv("OPERATOR_RUNTIME_STATE_DIR", state.UTF8String, 1) ||
            setenv("OPERATOR_RUNTIME_RUN_ID", runID.UTF8String, 1) ||
            setenv("OPERATOR_RUNTIME_STATUS_PATH", statusPath.UTF8String, 1)) return NO;
        std::string gatewayPortString = std::to_string(gatewayPort);
        if (setenv("OPERATOR_RUNTIME_GATEWAY_PORT", gatewayPortString.c_str(), 1)) return NO;
        [NSThread detachNewThreadWithBlock:^{
            @autoreleasepool {
                // Node requires all argument strings in one contiguous allocation.
                std::string joined = std::string("node") + '\0' + entry.UTF8String + '\0';
                std::vector<char> bytes(joined.begin(), joined.end());
                char *args[] = {bytes.data(), bytes.data() + 5};
                os_log(OS_LOG_DEFAULT, "[embedded-runtime] engine entering run=%{public}@", runID);
                int code = node_start(2, args);
                os_log_error(OS_LOG_DEFAULT, "[embedded-runtime] engine returned run=%{public}@ code=%d", runID, code);
                NSDictionary *result = @{ @"runID": runID, @"status": @"failed" };
                NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
                [data writeToFile:statusPath options:NSDataWritingAtomic error:nil];
            }
        }];
        return YES;
    }
}
@end

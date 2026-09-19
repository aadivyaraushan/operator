#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN
@interface EmbeddedNodeBridge : NSObject
+ (BOOL)startEntry:(NSString *)entry state:(NSString *)state runID:(NSString *)runID
             token:(NSString *)token statusPath:(NSString *)statusPath gatewayPort:(uint16_t)gatewayPort
    NS_SWIFT_NAME(start(entry:state:runID:token:statusPath:gatewayPort:));
@end
NS_ASSUME_NONNULL_END

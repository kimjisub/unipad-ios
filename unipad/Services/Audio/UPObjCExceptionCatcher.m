#import "UPObjCExceptionCatcher.h"

NSException *_Nullable UPRunCatchingObjCException(void(NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}

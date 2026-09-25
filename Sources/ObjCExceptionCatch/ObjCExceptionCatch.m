#import "ObjCExceptionCatch.h"

BOOL ObjCExceptionCatchTryRun(void (NS_NOESCAPE ^block)(void),
                               NSException *_Nullable *_Nullable outException) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (outException) {
            *outException = exception;
        }
        return NO;
    }
}

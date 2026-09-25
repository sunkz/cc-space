#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL ObjCExceptionCatchTryRun(void (NS_NOESCAPE ^block)(void),
                                                 NSException *_Nullable *_Nullable outException);

NS_ASSUME_NONNULL_END

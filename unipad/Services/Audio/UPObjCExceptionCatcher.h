#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs @c block and returns the Objective-C exception it raised, or nil when it returned normally.
///
/// Swift has no @c \@catch. AVFoundation raises NSException from @c AVAudioPlayerNode.play() when the
/// node's engine is not rendering ("player did not see an IO cycle"), and that kills the process even
/// though the app could carry on with one missed pad. Only the audio hot path uses this.
NSException *_Nullable UPRunCatchingObjCException(void(NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END

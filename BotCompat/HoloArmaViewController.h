#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Native local import workspace for the Holograma Arma asset workflow.
/// It keeps the selected asset, dumps, and Path ID metadata together so the
/// package can be inspected or handed to a future local Unity serializer.
@interface HoloArmaViewController : UIViewController
- (instancetype)initWithAssetURL:(nullable NSURL *)assetURL;
@end

NS_ASSUME_NONNULL_END
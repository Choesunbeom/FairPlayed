#import <UIKit/UIKit.h>
#import <objc/runtime.h>
FOUNDATION_EXPORT BOOL YTKACEFeatureEnabled(NSString *key);
FOUNDATION_EXPORT BOOL YTKACEInstallInstanceHook(NSString *cls, NSString *selector, IMP replacement, IMP *original);
#define YTKACEDebugLog(...) ((void)0)

// Standalone Duo features and YouTube Tweaks settings; no YTKACE runtime dependency.
// Derived from YTKACE MIT-licensed iPhone Duo implementation.
#import "DuoSoloShim.h"
#import "DuoKit.h"
#import <objc/message.h>
#import <objc/runtime.h>

extern void YTKACEInstallDuoDeskPlayerHooks(void);
extern void YTKACEInstallDuoStatusBarHooks(void);
extern void YTKACEDuoDeskControlsLayout(UIView *);

static NSString *const kDesk=@"YTKACE.Preference.Player.DuoDeskSplit";
static NSString *const kStatus=@"YTKACE.Preference.Player.DuoStatusBarHidden";
static IMP origOverlay=NULL, origSettingsModern=NULL, origSettingsLegacy=NULL;
static BOOL deskInstalled=NO, statusInstalled=NO, overlayInstalled=NO, settingsModernInstalled=NO, settingsLegacyInstalled=NO;

BOOL YTKACEFeatureEnabled(NSString *key) {
    id value=[NSUserDefaults.standardUserDefaults objectForKey:key];
    return value==nil ? YES : [value boolValue];
}

BOOL YTKACEInstallInstanceHook(NSString *className, NSString *selName, IMP replace, IMP *old) {
    Class cls=NSClassFromString(className);
    SEL sel=NSSelectorFromString(selName);
    if (cls==Nil || sel==NULL) return NO;
    Method method=class_getInstanceMethod(cls,sel);
    if (method==NULL) return NO;
    IMP original=method_getImplementation(method);
    if (original==replace) return YES;
    const char *types=method_getTypeEncoding(method);
    if (!class_addMethod(cls,sel,replace,types)) method_setImplementation(method,replace);
    if (old!=NULL) *old=original;
    return YES;
}
static void overlayLayout(UIView *view, SEL sel) {
    if (origOverlay) ((void (*)(id,SEL))origOverlay)(view,sel);
    YTKACEDuoDeskControlsLayout(view);
}

static void refreshPlayerLayouts(void) {
    Class player=NSClassFromString(@"YTPlayerView");
    Class overlay=NSClassFromString(@"YTMainAppControlsOverlayView");
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        UIView *root=window.rootViewController.view;
        if (!root) continue;
        NSMutableArray<UIView *> *stack=[NSMutableArray arrayWithObject:root];
        while (stack.count) {
            UIView *v=stack.lastObject;
            [stack removeLastObject];
            if ((player && [v isKindOfClass:player]) || (overlay && [v isKindOfClass:overlay])) {
                [v setNeedsLayout];
            }
            [stack addObjectsFromArray:v.subviews];
        }
        [window.rootViewController setNeedsStatusBarAppearanceUpdate];
    }
}
@interface DuoSoloSwitches : UITableViewController
@end
@implementation DuoSoloSwitches
- (instancetype)init {
    if ((self=[super initWithStyle:UITableViewStyleInsetGrouped])) self.title=@"iPhone Duo";
    return self;
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    (void)table; (void)section; return 2;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
    (void)table;
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    BOOL desk=index.row==0;
    cell.textLabel.text=desk ? @"노트북 레이아웃 + 반사 효과" : @"동영상 위 상태 표시줄 숨기기";
    cell.detailTextLabel.text=desk
      ? @"플렉스 모드: 위쪽 영상, 아래쪽 컨트롤 및 블러 반사"
      : @"영상과 겹치는 상태 표시줄을 자동으로 숨김";
    cell.detailTextLabel.numberOfLines=2;
    UISwitch *toggle=[UISwitch new];
    toggle.tag=desk?2601:2602;
    toggle.on=YTKACEFeatureEnabled(desk?kDesk:kStatus);
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView=toggle;
    cell.selectionStyle=UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)toggleChanged:(UISwitch *)toggle {
    [NSUserDefaults.standardUserDefaults setBool:toggle.isOn
        forKey:(toggle.tag==2601?kDesk:kStatus)];
    refreshPlayerLayouts();
}
@end

static BOOL isTweaksSection(NSArray *items,id title) {
    if ([title isKindOfClass:NSString.class] &&
        [(NSString *)title rangeOfString:@"tweak" options:NSCaseInsensitiveSearch].location!=NSNotFound) return YES;
    for (id item in items) {
        @try {
            NSString *value=[item valueForKey:@"title"];
            if ([value isKindOfClass:NSString.class] &&
                ([value containsString:@"PleaseDontStopTheMusic"] ||
                 [value containsString:@"Gonerino"] ||
                 [value containsString:@"YouPiP"])) return YES;
        } @catch (__unused NSException *exception) {}
    }
    return NO;
}
static NSArray *addEntry(NSArray *items,id title,id controller) {
    if (!isTweaksSection(items,title)) return items;
    for (id item in items) {
        @try {
            if ([[item valueForKey:@"accessibilityIdentifier"] isEqual:@"DuoSoloEntry"]) return items;
        } @catch (__unused NSException *exception) {}
    }
    Class cls=NSClassFromString(@"YTSettingsSectionItem");
    SEL make=NSSelectorFromString(@"itemWithTitle:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if (!cls || ![cls respondsToSelector:make]) return items;
    __weak id weakController=controller;
    BOOL (^selection)(id,NSUInteger)=^BOOL(__unused id cell,__unused NSUInteger index) {
        id owner=weakController;
        UIViewController *page=[DuoSoloSwitches new];
        SEL push=NSSelectorFromString(@"pushViewController:");
        if ([owner respondsToSelector:push]) {
            ((void (*)(id,SEL,id))objc_msgSend)(owner,push,page);
            return YES;
        }
        UINavigationController *nav=[owner isKindOfClass:UIViewController.class] ?
            ((UIViewController *)owner).navigationController : nil;
        if (nav) { [nav pushViewController:page animated:YES]; return YES; }
        return NO;
    };
    id entry=((id (*)(id,SEL,id,id,id,id))objc_msgSend)(cls,make,
        @"iPhone Duo", @"DuoSoloEntry", nil, [selection copy]);
    if (!entry) return items;
    NSMutableArray *updated=[items mutableCopy] ?: [NSMutableArray array];
    [updated addObject:entry];
    return updated;
}
static void settingsModern(id ctrl,SEL cmd,NSArray *items,NSUInteger category,id title,id icon,id desc,BOOL hidden) {
    NSArray *adjusted=addEntry(items,title,ctrl);
    if (origSettingsModern)
      ((void (*)(id,SEL,id,NSUInteger,id,id,id,BOOL))origSettingsModern)
       (ctrl,cmd,adjusted,category,title,icon,desc,hidden);
}
static void settingsLegacy(id ctrl,SEL cmd,NSArray *items,NSUInteger category,id title,id desc,BOOL hidden) {
    NSArray *adjusted=addEntry(items,title,ctrl);
    if (origSettingsLegacy)
      ((void (*)(id,SEL,id,NSUInteger,id,id,BOOL))origSettingsLegacy)
       (ctrl,cmd,adjusted,category,title,desc,hidden);
}

static void installOnce(void) {
    if (!DUOIsDuo()) return;
    if (!deskInstalled && NSClassFromString(@"YTPlayerView")) {
        YTKACEInstallDuoDeskPlayerHooks();
        deskInstalled=YES;
    }
    if (!statusInstalled && NSClassFromString(@"YTWatchLayerViewController")) {
        YTKACEInstallDuoStatusBarHooks();
        statusInstalled=YES;
    }
    if (!overlayInstalled) overlayInstalled=YTKACEInstallInstanceHook(
        @"YTMainAppControlsOverlayView",@"layoutSubviews",(IMP)overlayLayout,&origOverlay);
    if (!settingsModernInstalled) settingsModernInstalled=YTKACEInstallInstanceHook(
        @"YTSettingsViewController",
        @"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:",
        (IMP)settingsModern,&origSettingsModern);
    if (!settingsLegacyInstalled) settingsLegacyInstalled=YTKACEInstallInstanceHook(
        @"YTSettingsViewController",
        @"setSectionItems:forCategory:title:titleDescription:headerHidden:",
        (IMP)settingsLegacy,&origSettingsLegacy);
}

__attribute__((constructor)) static void start(void) {
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults registerDefaults:@{ kDesk:@YES,kStatus:@YES }];
        dispatch_async(dispatch_get_main_queue(), ^{
            installOnce();
            for (NSInteger i=1;i<=15;i++) dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW,(int64_t)i*NSEC_PER_SEC),
              dispatch_get_main_queue(), ^{ installOnce(); });
        });
    }
}

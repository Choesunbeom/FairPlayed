// FairPlayed IPA Packer — iPhone-only archive packager.
// No FairPlay decryption, network calls, account access, or signing.
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "../FairPlayed/FairPlayed/zipio.h"

static NSString *FPDocuments(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}
static NSString *FPSafeName(NSString *s) {
    if (!s.length || [s hasPrefix:@"/"] || [s containsString:@"\\"] || [s containsString:@"\0"]) return nil;
    for (NSString *p in [s componentsSeparatedByString:@"/"]) {
        if (!p.length || [p isEqualToString:@"."] || [p isEqualToString:@".."]) return nil;
    }
    return s;
}
static NSString *FPSingleApp(NSString *payload, NSError **error) {
    NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:payload error:error];
    NSMutableArray *apps = NSMutableArray.array;
    for (NSString *name in entries) {
        if (![name hasSuffix:@".app"]) continue;
        BOOL dir = NO;
        NSString *path = [payload stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&dir] && dir) [apps addObject:name];
    }
    if (apps.count == 1) return apps.firstObject;
    if (error) *error = [NSError errorWithDomain:@"FairPlayedPacker" code:1 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Payload 폴더에 .app이 1개 있어야 합니다. 발견: %lu개", (unsigned long)apps.count]}];
    return nil;
}
static BOOL FPReplicateSINF(NSString *embedded, NSString **message, NSError **error) {
    NSString *manifest = [embedded stringByAppendingPathComponent:@"SC_Info/Manifest.plist"];
    if (![NSFileManager.defaultManager fileExistsAtPath:manifest]) {
        if (message) *message = @"SC_Info/Manifest.plist 없음 (복호화 실패 가능)";
        return YES;
    }
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:manifest];
    NSArray *sinfs = plist[@"SinfPaths"];
    NSArray *destinations = plist[@"SinfReplicationPaths"];
    if (![sinfs isKindOfClass:NSArray.class] || sinfs.count == 0 || ![sinfs.firstObject isKindOfClass:NSString.class]) {
        if (message) *message = @"Manifest에 SinfPaths 없음";
        return YES;
    }
    NSString *source = FPSafeName(sinfs.firstObject);
    if (!source) return NO;
    NSString *sourceFile = [embedded stringByAppendingPathComponent:source];
    if (![NSFileManager.defaultManager fileExistsAtPath:sourceFile]) {
        if (message) *message = @"앱의 FairPlay SINF 파일 없음 (복호화 불가능할 수 있음)";
        return YES;
    }
    NSUInteger count = 0;
    if ([destinations isKindOfClass:NSArray.class]) {
        for (id obj in destinations) {
            if (![obj isKindOfClass:NSString.class]) continue;
            NSString *rel = FPSafeName(obj);
            if (!rel || [rel hasPrefix:@"Watch/"]) continue;
            NSString *dst = [embedded stringByAppendingPathComponent:rel];
            if ([NSFileManager.defaultManager fileExistsAtPath:dst]) continue;
            NSString *parent = dst.stringByDeletingLastPathComponent;
            if (![NSFileManager.defaultManager createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
            if (![NSFileManager.defaultManager copyItemAtPath:sourceFile toPath:dst error:error]) return NO;
            count++;
        }
    }
    if (message) *message = [NSString stringWithFormat:@"SINF 추가 경로 %lu개 복사", (unsigned long)count];
    return YES;
}
static NSString *FPPack(NSString *base, NSString *target, NSString **details, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID UUIDString]];
    NSString *baseDir = [scratch stringByAppendingPathComponent:@"Base"];
    NSString *appDir = [scratch stringByAppendingPathComponent:@"Target"];
    NSString *output = [FPDocuments() stringByAppendingPathComponent:@"FairPlayed-target-unsigned.ipa"];
    NSString *partial = [scratch stringByAppendingPathComponent:@"Result.ipa"];
    char zerr[1024] = {0};
    NSString *fail = nil;
    do {
        if (![fm createDirectoryAtPath:baseDir withIntermediateDirectories:YES attributes:nil error:error] ||
            ![fm createDirectoryAtPath:appDir withIntermediateDirectories:YES attributes:nil error:error]) break;
        if (zip_extract_all(base.fileSystemRepresentation, baseDir.fileSystemRepresentation, zerr, sizeof(zerr)) != 0) {
            fail = [NSString stringWithFormat:@"FairPlayed ZIP 오류: %s", zerr]; break;
        }
        if (zip_extract_all(target.fileSystemRepresentation, appDir.fileSystemRepresentation, zerr, sizeof(zerr)) != 0) {
            fail = [NSString stringWithFormat:@"대상 IPA ZIP 오류: %s", zerr]; break;
        }
        NSString *basePayload = [baseDir stringByAppendingPathComponent:@"Payload"];
        NSString *targetPayload = [appDir stringByAppendingPathComponent:@"Payload"];
        NSString *baseName = FPSingleApp(basePayload, error);
        NSString *targetName = FPSingleApp(targetPayload, error);
        if (!baseName || !targetName) break;
        if (![baseName isEqualToString:@"FairPlayed.app"]) {
            fail = @"기본 파일로 FairPlayed-base-unsigned.ipa를 선택하세요."; break;
        }
        NSString *host = [basePayload stringByAppendingPathComponent:baseName];
        NSDictionary *hostInfo = [NSDictionary dictionaryWithContentsOfFile:[host stringByAppendingPathComponent:@"Info.plist"]];
        NSString *binary = hostInfo[@"CFBundleExecutable"];
        if (!binary.length || ![fm fileExistsAtPath:[host stringByAppendingPathComponent:binary]]) {
            fail = @"기본 FairPlayed IPA의 실행 파일을 찾을 수 없습니다."; break;
        }
        NSString *src = [targetPayload stringByAppendingPathComponent:targetName];
        NSDictionary *targetInfo = [NSDictionary dictionaryWithContentsOfFile:[src stringByAppendingPathComponent:@"Info.plist"]];
        if (!targetInfo[@"CFBundleExecutable"]) {
            fail = @"대상 IPA의 앱 정보(Info.plist)가 올바르지 않습니다."; break;
        }
        NSString *embedRoot = [host stringByAppendingPathComponent:@"EmbeddedPayload"];
        [fm removeItemAtPath:embedRoot error:nil];
        if (![fm createDirectoryAtPath:embedRoot withIntermediateDirectories:YES attributes:nil error:error]) break;
        NSString *label = [targetName stringByDeletingPathExtension];
        NSString *dst = [embedRoot stringByAppendingPathComponent:label];
        if (![fm moveItemAtPath:src toPath:dst error:error]) break;
        [fm removeItemAtPath:[dst stringByAppendingPathComponent:@"Watch"] error:nil];
        // The helper is intentionally unsigned; leave the target signatures and license assets as data.
        [fm removeItemAtPath:[host stringByAppendingPathComponent:@"_CodeSignature"] error:nil];
        [fm removeItemAtPath:[host stringByAppendingPathComponent:@"embedded.mobileprovision"] error:nil];
        NSString *sinf = nil;
        if (!FPReplicateSINF(dst, &sinf, error)) break;
        if (zip_create_from_dir(baseDir.fileSystemRepresentation, partial.fileSystemRepresentation, zerr, sizeof(zerr)) != 0) {
            fail = [NSString stringWithFormat:@"IPA 생성 실패: %s", zerr]; break;
        }
        [fm removeItemAtPath:output error:nil];
        if (![fm moveItemAtPath:partial toPath:output error:error]) break;
        if (details) *details = [NSString stringWithFormat:@"완료: %@ · %@ · 서명 전 IPA", label, sinf ?: @"SINF 확인됨"];
        [fm removeItemAtPath:scratch error:nil];
        return output;
    } while (NO);
    [fm removeItemAtPath:scratch error:nil];
    if (fail && error) *error = [NSError errorWithDomain:@"FairPlayedPacker" code:2 userInfo:@{NSLocalizedDescriptionKey:fail}];
    return nil;
}

@interface PackerController : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic,strong) UILabel *baseLabel;
@property(nonatomic,strong) UILabel *targetLabel;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIButton *packageButton;
@property(nonatomic,strong) UIButton *shareButton;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) NSString *basePath;
@property(nonatomic,strong) NSString *targetPath;
@property(nonatomic,strong) NSString *resultPath;
@property(nonatomic,assign) NSInteger selecting;
@property(nonatomic,assign) BOOL copyInProgress;
@end
@implementation PackerController
- (UILabel *)caption:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
    UILabel *v = UILabel.new;
    v.text = text;
    v.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    v.textColor = UIColor.labelColor;
    v.numberOfLines = 0;
    return v;
}
- (UIButton *)action:(NSString *)title selector:(SEL)sel prominent:(BOOL)prominent {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *c = prominent ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.tintedButtonConfiguration;
    c.title = title;
    c.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    c.contentInsets = NSDirectionalEdgeInsetsMake(16, 14, 16, 14);
    b.configuration = c;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIScrollView *scroll = UIScrollView.new;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]]];
    UIStackView *stack = UIStackView.new;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.layoutMargins = UIEdgeInsetsMake(24, 22, 24, 22);
    stack.layoutMarginsRelativeArrangement = YES;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]]];
    [stack addArrangedSubview:[self caption:@"IPA 재패키징" size:30 bold:YES]];
    [stack addArrangedSubview:[self caption:@"암호화된 앱 IPA와 FairPlayed 기본 IPA를 선택하면, SideStore에서 서명할 수 있는 IPA를 만듭니다. 이 앱은 복호화나 서명을 수행하지 않습니다." size:15 bold:NO]];
    [stack addArrangedSubview:[self caption:@"1. FairPlayed 기본 IPA" size:18 bold:YES]];
    [stack addArrangedSubview:[self action:@"FairPlayed IPA 선택" selector:@selector(selectBase) prominent:NO]];
    self.baseLabel = [self caption:@"선택되지 않음" size:14 bold:NO];
    [stack addArrangedSubview:self.baseLabel];
    [stack addArrangedSubview:[self caption:@"2. 암호화된 앱 IPA" size:18 bold:YES]];
    [stack addArrangedSubview:[self action:@"대상 IPA 선택" selector:@selector(selectTarget) prominent:NO]];
    self.targetLabel = [self caption:@"선택되지 않음" size:14 bold:NO];
    [stack addArrangedSubview:self.targetLabel];
    [stack addArrangedSubview:[self caption:@"3. 패키징 및 내보내기" size:18 bold:YES]];
    self.packageButton = [self action:@"서명용 IPA 만들기" selector:@selector(packageNow) prominent:YES];
    [stack addArrangedSubview:self.packageButton];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [stack addArrangedSubview:self.spinner];
    self.status = [self caption:@"파일 두 개를 선택하세요." size:14 bold:NO];
    [stack addArrangedSubview:self.status];
    self.shareButton = [self action:@"IPA 공유 · SideStore로 보내기" selector:@selector(share) prominent:NO];
    self.shareButton.enabled = NO;
    [stack addArrangedSubview:self.shareButton];
    [stack addArrangedSubview:[self caption:@"주의: FairPlayed는 앱을 설치 전에 포함해야 합니다. 생성된 파일을 SideStore로 서명·설치한 뒤 FairPlayed의 ‘복호화’를 실행하세요. iOS 27.2.1에서 실제 복호화 성공은 검증되지 않았습니다." size:13 bold:NO]];
}
- (void)selectBase { [self choose:1]; }
- (void)selectTarget { [self choose:2]; }
- (void)choose:(NSInteger)kind {
    if (self.copyInProgress) return;
    self.selecting = kind;
    UTType *ipa = [UTType typeWithIdentifier:@"com.apple.itunes.ipa"];
    NSArray *types = ipa ? @[ipa, UTTypeZIP, UTTypeData] : @[UTTypeZIP, UTTypeData];
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url || self.copyInProgress) return;
    NSInteger kind = self.selecting;
    self.copyInProgress = YES;
    self.packageButton.enabled = NO;
    self.shareButton.enabled = NO;
    self.resultPath = nil;
    self.status.text = @"선택한 IPA를 가져오는 중… 파일 크기에 따라 시간이 걸릴 수 있습니다.";
    [self.spinner startAnimating];
    NSString *dst = [FPDocuments() stringByAppendingPathComponent:kind == 1 ? @"FairPlayed-input.ipa" : @"App-input.ipa"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL access = [url startAccessingSecurityScopedResource];
        NSString *temporary = [dst stringByAppendingString:@".importing"];
        NSError *error = nil;
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:temporary error:nil];
        BOOL copied = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:temporary] error:&error];
        if (access) [url stopAccessingSecurityScopedResource];
        if (copied) {
            [fm removeItemAtPath:dst error:nil];
            copied = [fm moveItemAtPath:temporary toPath:dst error:&error];
        }
        if (!copied) [fm removeItemAtPath:temporary error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.copyInProgress = NO;
            [self.spinner stopAnimating];
            self.packageButton.enabled = YES;
            if (!copied) {
                self.status.text = [NSString stringWithFormat:@"IPA 가져오기 실패: %@", error.localizedDescription ?: @"파일 복사 오류"];
                return;
            }
            if (kind == 1) {
                self.basePath = dst;
                self.baseLabel.text = [NSString stringWithFormat:@"✓ %@", url.lastPathComponent];
            } else {
                self.targetPath = dst;
                self.targetLabel.text = [NSString stringWithFormat:@"✓ %@", url.lastPathComponent];
            }
            self.status.text = self.basePath && self.targetPath ? @"준비 완료. IPA를 만들 수 있습니다." : @"다른 IPA도 선택하세요.";
        });
    });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { self.selecting = 0; }
- (void)packageNow {
    if (self.copyInProgress) return;
    if (!self.basePath || !self.targetPath) { self.status.text = @"IPA 두 개를 모두 선택하세요."; return; }
    self.packageButton.enabled = NO; self.shareButton.enabled = NO; self.status.text = @"압축 해제와 재패키징 중… 앱을 닫지 마세요.";
    [self.spinner startAnimating];
    NSString *base = self.basePath, *target = self.targetPath;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *details = nil;
        NSString *output = FPPack(base, target, &details, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.packageButton.enabled = YES;
            self.resultPath = output;
            self.shareButton.enabled = output != nil;
            self.status.text = output ? details : [NSString stringWithFormat:@"오류: %@", error.localizedDescription ?: @"알 수 없는 오류"];
        });
    });
}
- (void)share {
    if (!self.resultPath || ![NSFileManager.defaultManager fileExistsAtPath:self.resultPath]) return;
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:self.resultPath]] applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = self.shareButton;
    [self presentViewController:sheet animated:YES completion:nil];
}
@end

@interface PackerScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation PackerScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = PackerController.new;
    [self.window makeKeyAndVisible];
}
@end
@interface PackerApp : UIResponder <UIApplicationDelegate>
@end
@implementation PackerApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(PackerApp.class)); }
}

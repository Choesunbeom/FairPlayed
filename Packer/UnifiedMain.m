// FairPlayed — FairPlay decryption research tool.
// Runs mremap_encrypted experiments from a regular sandboxed (sideloaded) app.
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include "fpcore.h"
#include "zipio.h"
// The packaging helpers below are shared with PackerMain.m; keep both paths aligned.

#pragma mark - logging

static NSFileHandle *gLogFile;
static void (^gUILog)(NSString *);

static void FPLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void FPLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", s.UTF8String); fflush(stdout);
    @synchronized ([NSFileHandle class]) {
        [gLogFile writeData:[[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    }
    if (gUILog) gUILog(s);
}

static void core_log(void *ctx, const char *msg) { FPLog(@"%s", msg); }

static NSString *DocsDir(void) { return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject; }
static NSString *WorkDir(void) {
    return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"fpwork"];
}

#pragma mark - runner

@interface FPRunner : NSObject
+ (void)runEnvironment;
+ (void)probeInstalledAppsMatching:(NSString *)filter export:(BOOL)export;
+ (NSString *)processIPA:(NSString *)ipaPath;
+ (void)processAllDocumentsIPAs;
+ (void)embeddedExperiment;
+ (void)embeddedExport;
+ (void)copyTree:(NSString *)src to:(NSString *)dst skipped:(NSMutableArray *)skipped;
@end

@implementation FPRunner

+ (NSArray<NSString *> *)machOsUnder:(NSString *)root {
    NSMutableArray *out = [NSMutableArray array];
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:root];
    for (NSString *rel in en) {
        NSString *p = [root stringByAppendingPathComponent:rel];
        NSDictionary *a = en.fileAttributes;
        if (![a.fileType isEqualToString:NSFileTypeRegular] || a.fileSize < 4096) continue;
        if (fp_is_macho(p.fileSystemRepresentation)) [out addObject:rel];
    }
    return out;
}

+ (void)logEnvironment {
    struct utsname u; uname(&u);
    FPLog(@"== FairPlayed %@ | %s | iOS %@ | pid %d | uid %d",
          NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"], u.machine,
          UIDevice.currentDevice.systemVersion, getpid(), getuid());
    FPLog(@"bundle: %@", NSBundle.mainBundle.bundlePath);
    FPLog(@"docs:   %@", DocsDir());
    for (NSString *d in @[@"/private/var/containers/Bundle/Application", @"/var/containers/Bundle/Application",
                          NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent]) {
        DIR *dir = opendir(d.fileSystemRepresentation);
        if (!dir) { FPLog(@"opendir(%@): %s", d, strerror(errno)); continue; }
        int n = 0; struct dirent *de; while ((de = readdir(dir))) n++;
        closedir(dir);
        FPLog(@"opendir(%@): OK, %d entries", d, n);
    }
}

// --- Installed apps (via LaunchServices private SPI) -------------------------------------------

+ (NSArray<NSDictionary *> *)installedApps {
    NSMutableArray *res = [NSMutableArray array];
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    id w = [ws respondsToSelector:@selector(defaultWorkspace)] ? [ws performSelector:@selector(defaultWorkspace)] : nil;
    NSArray *proxies = nil;
    for (NSString *sel in @[@"allInstalledApplications", @"allApplications"]) {
        if ([w respondsToSelector:NSSelectorFromString(sel)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            proxies = [w performSelector:NSSelectorFromString(sel)];
#pragma clang diagnostic pop
            FPLog(@"LSApplicationWorkspace.%@ -> %lu proxies", sel, (unsigned long)proxies.count);
            if (proxies.count) break;
        }
    }
    for (id p in proxies) {
        @try {
            NSString *bid = [p valueForKey:@"bundleIdentifier"];
            NSURL *url = [p valueForKey:@"bundleURL"];
            NSString *exe = [p valueForKey:@"bundleExecutable"];
            NSString *type = [p valueForKey:@"applicationType"];
            if (bid && url && exe) [res addObject:@{@"id": bid, @"path": url.path, @"exe": exe, @"type": type ?: @"?"}];
        } @catch (NSException *e) {}
    }
    // Enumeration is denied to unentitled apps on iOS 27; resolve explicitly named bundle IDs instead.
    NSString *targets = NSProcessInfo.processInfo.environment[@"FPD_TARGETS"];
    for (NSString *bid in [targets componentsSeparatedByString:@","]) {
        if (!bid.length) continue;
        NSDictionary *d = [self resolveBundleID:bid];
        if (d) [res addObject:d];
    }
    // Explicit installed .app paths (e.g. from `devicectl device install app` output).
    NSString *paths = NSProcessInfo.processInfo.environment[@"FPD_PATHS"];
    for (NSString *raw in [paths componentsSeparatedByString:@","]) {
        NSString *p = [raw stringByStandardizingPath];
        if (!p.length) continue;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Info.plist"]];
        NSString *exe = info[@"CFBundleExecutable"] ?: p.lastPathComponent.stringByDeletingPathExtension;
        NSError *lsErr = nil;
        NSArray *ls = [NSFileManager.defaultManager contentsOfDirectoryAtPath:[p stringByAppendingPathComponent:@"SC_Info"] error:&lsErr];
        FPLog(@"FPD_PATHS %@: Info.plist readable=%d exe=%@ SC_Info=%@", p, info != nil, exe,
              ls ? [ls componentsJoinedByString:@","] : lsErr.localizedDescription);
        [res addObject:@{@"id": info[@"CFBundleIdentifier"] ?: p.lastPathComponent, @"path": p, @"exe": exe, @"type": @"Target"}];
    }
    return res;
}

+ (NSDictionary *)resolveBundleID:(NSString *)bid {
    NSString *path = nil, *exe = nil, *type = nil;
    Class proxyCls = NSClassFromString(@"LSApplicationProxy");
    if ([proxyCls respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        @try {
            id p = [proxyCls performSelector:@selector(applicationProxyForIdentifier:) withObject:bid];
            path = [[p valueForKey:@"bundleURL"] path];
            exe = [p valueForKey:@"bundleExecutable"];
            type = [p valueForKey:@"applicationType"];
            FPLog(@"LSApplicationProxy(%@): url=%@ exe=%@ type=%@ installed=%@", bid, path, exe, type,
                  [p respondsToSelector:NSSelectorFromString(@"isInstalled")] ? [p valueForKey:@"isInstalled"] : @"?");
        } @catch (NSException *e) { FPLog(@"LSApplicationProxy(%@): %@", bid, e.reason); }
    }
    Class recCls = NSClassFromString(@"LSApplicationRecord");
    SEL initSel = NSSelectorFromString(@"initWithBundleIdentifier:allowPlaceholder:error:");
    if (recCls && [recCls instancesRespondToSelector:initSel]) {
        @try {
            NSError *err = nil;
            // init consumes self and returns +1; spell that out so ARC does not over-release when it returns nil.
            typedef id (*LSRecInitFn)(__attribute__((ns_consumed)) id, SEL, NSString *, BOOL, NSError * __autoreleasing *)
                __attribute__((ns_returns_retained));
            LSRecInitFn initFn = (LSRecInitFn)[recCls instanceMethodForSelector:initSel];
            id r = initFn([recCls alloc], initSel, bid, NO, &err);
            NSURL *u = r ? [r valueForKey:@"URL"] : nil;
            NSURL *x = nil;
            @try { x = r ? [r valueForKey:@"executableURL"] : nil; } @catch (NSException *e) {}
            FPLog(@"LSApplicationRecord(%@): url=%@ exe=%@ err=%@", bid, u.path, x.path, err.localizedDescription);
            if (!path && u) path = u.path;
            if (!exe && x) exe = x.lastPathComponent;
        } @catch (NSException *e) { FPLog(@"LSApplicationRecord(%@): %@", bid, e.reason); }
    }
    if (path && !exe) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
        exe = info[@"CFBundleExecutable"];
        FPLog(@"  Info.plist readable=%d", info != nil);
    }
    if (!path || !exe) return nil;
    return @{@"id": bid, @"path": path, @"exe": exe, @"type": @"Target"};
}

+ (void)probeInstalledAppsMatching:(NSString *)filter export:(BOOL)export {
    FPLog(@"=== installed-app probe (filter=%@) ===", filter ?: @"<user apps>");
    NSArray *apps = [self installedApps];
    int readable = 0, encrypted = 0, decrypted = 0;
    for (NSDictionary *a in apps) {
        BOOL wanted = [a[@"type"] isEqualToString:@"Target"] ||
                      (filter.length ? [a[@"id"] containsString:filter] : [a[@"type"] isEqualToString:@"User"]);
        if (!wanted) continue;
        if ([a[@"id"] isEqualToString:NSBundle.mainBundle.bundleIdentifier]) continue;
        NSString *exe = [a[@"path"] stringByAppendingPathComponent:a[@"exe"]];
        int fd = open(exe.fileSystemRepresentation, O_RDONLY);
        int e = errno;
        FPLog(@"[%@] %@ type=%@ open=%s", a[@"id"], exe, a[@"type"], fd >= 0 ? "OK" : strerror(e));
        if (fd < 0) continue;
        close(fd); readable++;
        fp_slice_t sl[FP_MAX_SLICES]; int n = 0; char err[256];
        if (fp_parse(exe.fileSystemRepresentation, sl, FP_MAX_SLICES, &n, err, sizeof err) != 0 || n == 0) { FPLog(@"  parse: %s", err); continue; }
        if (!(sl[0].has_enc && sl[0].cryptid)) { FPLog(@"  not encrypted (cryptid=%u)", sl[0].cryptid); continue; }
        encrypted++;
        int modes[] = { FP_MODE_R_CID2, FP_MODE_RX_CID1, FP_MODE_R_CID1 };
        int ok = fp_probe_file(exe.fileSystemRepresentation, modes, 3, core_log, NULL);
        if (ok > 0) {
            decrypted++;
            if (export) [self exportInstalledApp:a];
        }
    }
    FPLog(@"=== installed-app probe done: %lu apps listed, %d readable, %d encrypted, %d decrypted ===",
          (unsigned long)apps.count, readable, encrypted, decrypted);
}

+ (void)exportInstalledApp:(NSDictionary *)a {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *work = [WorkDir() stringByAppendingPathComponent:a[@"id"]];
    [fm removeItemAtPath:work error:nil];
    NSString *appName = [a[@"path"] lastPathComponent];
    NSString *dst = [[work stringByAppendingPathComponent:@"Payload"] stringByAppendingPathComponent:appName];
    [fm createDirectoryAtPath:dst.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *err;
    if (![fm copyItemAtPath:a[@"path"] toPath:dst error:&err]) { FPLog(@"  copy bundle failed: %@", err); return; }
    int fails = 0;
    for (NSString *rel in [self machOsUnder:dst]) {
        NSString *src = [a[@"path"] stringByAppendingPathComponent:rel];
        NSString *out = [dst stringByAppendingPathComponent:rel];
        int r = fp_decrypt_file(src.fileSystemRepresentation, out.fileSystemRepresentation, core_log, NULL);
        FPLog(@"  %@: %s", rel, r == 0 ? "decrypted" : r == 1 ? "not encrypted" : "FAILED");
        if (r < 0) fails++;
    }
    NSString *ipa = [[DocsDir() stringByAppendingPathComponent:@"Decrypted"] stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@%@.ipa", a[@"id"], fails ? @"-PARTIAL" : @"-decrypted"]];
    [fm createDirectoryAtPath:ipa.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    char zerr[512] = {0};
    if (zip_create_from_dir(work.fileSystemRepresentation, ipa.fileSystemRepresentation, zerr, sizeof zerr) == 0)
        FPLog(@"  wrote %@", ipa);
    else
        FPLog(@"  zip failed: %s", zerr);
}

// --- IPA files ----------------------------------------------------------------------------------

+ (void)pathVariantExperiment:(NSString *)exe appDir:(NSString *)appDir {
    // Does decryption depend on where the binary lives / on SC_Info being next to it?
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = [WorkDir() stringByAppendingPathComponent:@"variants"];
    [fm removeItemAtPath:base error:nil];
    NSString *exeName = exe.lastPathComponent;
    NSString *lone = [[base stringByAppendingPathComponent:@"lone"] stringByAppendingPathComponent:exeName];
    NSString *tmpApp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"fpvariant/X.app"];
    [fm removeItemAtPath:tmpApp.stringByDeletingLastPathComponent error:nil];
    [fm createDirectoryAtPath:lone.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:tmpApp withIntermediateDirectories:YES attributes:nil error:nil];
    [fm copyItemAtPath:exe toPath:lone error:nil];
    [fm copyItemAtPath:exe toPath:[tmpApp stringByAppendingPathComponent:exeName] error:nil];
    NSString *sc = [appDir stringByAppendingPathComponent:@"SC_Info"];
    if ([fm fileExistsAtPath:sc]) [fm copyItemAtPath:sc toPath:[tmpApp stringByAppendingPathComponent:@"SC_Info"] error:nil];
    // C: X.app without SC_Info; D: plain (non-.app) directory with SC_Info; E: SC_Info with .sinf only.
    NSString *appNoSC = [base stringByAppendingPathComponent:@"C/Y.app"];
    NSString *plainSC = [base stringByAppendingPathComponent:@"D/plain"];
    NSString *sinfOnly = [base stringByAppendingPathComponent:@"E/Z.app"];
    for (NSString *d in @[appNoSC, plainSC, sinfOnly]) {
        [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
        [fm copyItemAtPath:exe toPath:[d stringByAppendingPathComponent:exeName] error:nil];
    }
    if ([fm fileExistsAtPath:sc]) {
        [fm copyItemAtPath:sc toPath:[plainSC stringByAppendingPathComponent:@"SC_Info"] error:nil];
        NSString *e = [sinfOnly stringByAppendingPathComponent:@"SC_Info"];
        [fm createDirectoryAtPath:e withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *sinf = [exeName stringByAppendingPathExtension:@"sinf"];
        [fm copyItemAtPath:[sc stringByAppendingPathComponent:sinf] toPath:[e stringByAppendingPathComponent:sinf] error:nil];
    }
    int modes[] = { FP_MODE_R_CID2 };
    NSArray *variants = @[
        @[@"A: binary alone, no SC_Info", lone],
        @[@"B: tmp/X.app + full SC_Info", [tmpApp stringByAppendingPathComponent:exeName]],
        @[@"C: Y.app without SC_Info", [appNoSC stringByAppendingPathComponent:exeName]],
        @[@"D: plain dir (no .app) + full SC_Info", [plainSC stringByAppendingPathComponent:exeName]],
        @[@"E: Z.app + SC_Info with .sinf only", [sinfOnly stringByAppendingPathComponent:exeName]],
    ];
    for (NSArray *v in variants) {
        FPLog(@"-- variant %@: %@", v[0], v[1]);
        fp_probe_file([v[1] fileSystemRepresentation], modes, 1, core_log, NULL);
    }
}

+ (NSString *)processIPA:(NSString *)ipaPath {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *name = ipaPath.lastPathComponent.stringByDeletingPathExtension;
    FPLog(@"=== IPA: %@ (%.1f MB) ===", ipaPath.lastPathComponent,
          [[fm attributesOfItemAtPath:ipaPath error:nil] fileSize] / 1048576.0);
    NSString *work = [WorkDir() stringByAppendingPathComponent:name];
    [fm removeItemAtPath:work error:nil];
    [fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
    char err[512] = {0};
    if (zip_extract_all(ipaPath.fileSystemRepresentation, work.fileSystemRepresentation, err, sizeof err) != 0) {
        FPLog(@"extract failed: %s", err); return nil;
    }
    NSString *payload = [work stringByAppendingPathComponent:@"Payload"];
    NSString *app = nil;
    for (NSString *f in [fm contentsOfDirectoryAtPath:payload error:nil]) if ([f.pathExtension isEqualToString:@"app"]) app = f;
    if (!app) { FPLog(@"no Payload/*.app"); return nil; }
    NSString *appDir = [payload stringByAppendingPathComponent:app];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appDir stringByAppendingPathComponent:@"Info.plist"]];
    NSString *mainExe = [appDir stringByAppendingPathComponent:info[@"CFBundleExecutable"] ?: app.stringByDeletingPathExtension];
    FPLog(@"app: %@ id=%@ ver=%@ SC_Info=%@", app, info[@"CFBundleIdentifier"], info[@"CFBundleShortVersionString"],
          [fm contentsOfDirectoryAtPath:[appDir stringByAppendingPathComponent:@"SC_Info"] error:nil]);

    FPLog(@"-- main executable, all modes, in extracted bundle:");
    int modes[] = { FP_MODE_R_CID2, FP_MODE_RX_CID1, FP_MODE_R_CID1 };
    int ok = fp_probe_file(mainExe.fileSystemRepresentation, modes, 3, core_log, NULL);
    if (NSProcessInfo.processInfo.environment[@"FPD_VARIANTS"]) [self pathVariantExperiment:mainExe appDir:appDir];
    if (ok <= 0) { FPLog(@"=== main executable NOT decrypted; not exporting ==="); return nil; }

    int fails = 0, done = 0;
    for (NSString *rel in [self machOsUnder:appDir]) {
        NSString *p = [appDir stringByAppendingPathComponent:rel];
        NSString *tmp = [p stringByAppendingString:@".fpdec"];
        int r = fp_decrypt_file(p.fileSystemRepresentation, tmp.fileSystemRepresentation, core_log, NULL);
        if (r == 0) { rename(tmp.fileSystemRepresentation, p.fileSystemRepresentation); done++; }
        else unlink(tmp.fileSystemRepresentation);
        if (r < 0) fails++;
        FPLog(@"  %@: %s", rel, r == 0 ? "decrypted" : r == 1 ? "not encrypted" : "FAILED");
    }
    NSString *outDir = [DocsDir() stringByAppendingPathComponent:@"Decrypted"];
    [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *ipa = [outDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@.ipa", name, fails ? @"-PARTIAL" : @"-decrypted"]];
    if (zip_create_from_dir(work.fileSystemRepresentation, ipa.fileSystemRepresentation, err, sizeof err) != 0) {
        FPLog(@"zip failed: %s", err); return nil;
    }
    [fm removeItemAtPath:work error:nil];
    FPLog(@"=== wrote %@ (%d binaries decrypted, %d failed) ===", ipa.lastPathComponent, done, fails);
    return ipa;
}

// fairplayd reads <dir of binary>/SC_Info/<exe>.sinf, and System Policy denies it access to app data
// containers. Test locations fairplayd can read: our own (installed) bundle, reached directly or via symlinks.
+ (NSString *)embeddedRoot {
    return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"EmbeddedPayload"];
}

+ (void)embeddedExperiment {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [self embeddedRoot];
    NSArray *names = [fm contentsOfDirectoryAtPath:root error:nil];
    FPLog(@"=== embedded-payload experiment: %@ (%lu entries) ===", root, (unsigned long)names.count);
    int modes3[] = { FP_MODE_R_CID2, FP_MODE_RX_CID1, FP_MODE_R_CID1 };
    int modes1[] = { FP_MODE_R_CID2 };
    NSString *outDir = [DocsDir() stringByAppendingPathComponent:@"Decrypted"];
    [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in names) {
        NSString *dir = [root stringByAppendingPathComponent:name];
        NSDictionary *pinfo = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"Info.plist"]];
        NSString *exeName = pinfo[@"CFBundleExecutable"] ?: name;
        NSString *exe = [dir stringByAppendingPathComponent:exeName];
        NSString *sc = [dir stringByAppendingPathComponent:@"SC_Info"];
        BOOL haveExe = [fm fileExistsAtPath:exe], haveSC = [fm fileExistsAtPath:sc];
        FPLog(@"[%@] exe=%d SC_Info=%@", name, haveExe, [[fm contentsOfDirectoryAtPath:sc error:nil] componentsJoinedByString:@","]);
        if (!haveExe) continue;
        NSMutableArray *decryptedFrom = [NSMutableArray array];

        FPLog(@"-- J: binary + SC_Info inside own app bundle: %@", exe);
        if (fp_probe_file(exe.fileSystemRepresentation, modes3, 3, core_log, NULL) > 0) [decryptedFrom addObject:exe];

        NSString *base = [WorkDir() stringByAppendingPathComponent:[@"embedded-" stringByAppendingString:name]];
        [fm removeItemAtPath:base error:nil];
        NSMutableArray *variants = [NSMutableArray array];
        if (haveSC) {
            NSString *h = [base stringByAppendingPathComponent:@"H"];
            [fm createDirectoryAtPath:h withIntermediateDirectories:YES attributes:nil error:nil];
            [fm copyItemAtPath:exe toPath:[h stringByAppendingPathComponent:exeName] error:nil];
            symlink(sc.fileSystemRepresentation, [h stringByAppendingPathComponent:@"SC_Info"].fileSystemRepresentation);
            [variants addObject:@[@"H: container binary, SC_Info -> symlink to bundle SC_Info", h]];

            NSString *i = [base stringByAppendingPathComponent:@"I"];
            NSString *isc = [i stringByAppendingPathComponent:@"SC_Info"];
            [fm createDirectoryAtPath:isc withIntermediateDirectories:YES attributes:nil error:nil];
            [fm copyItemAtPath:exe toPath:[i stringByAppendingPathComponent:exeName] error:nil];
            for (NSString *f in [fm contentsOfDirectoryAtPath:sc error:nil])
                symlink([sc stringByAppendingPathComponent:f].fileSystemRepresentation, [isc stringByAppendingPathComponent:f].fileSystemRepresentation);
            [variants addObject:@[@"I: container binary, SC_Info/* -> per-file symlinks into bundle", i]];
        }
        NSString *ext = NSProcessInfo.processInfo.environment[@"FPD_SCLINK"];
        if (ext.length) {
            NSString *f = [base stringByAppendingPathComponent:@"F"];
            [fm createDirectoryAtPath:f withIntermediateDirectories:YES attributes:nil error:nil];
            [fm copyItemAtPath:exe toPath:[f stringByAppendingPathComponent:exeName] error:nil];
            symlink(ext.fileSystemRepresentation, [f stringByAppendingPathComponent:@"SC_Info"].fileSystemRepresentation);
            [variants addObject:@[[@"F: container binary, SC_Info -> symlink to " stringByAppendingString:ext], f]];
        }
        for (NSArray *v in variants) {
            NSString *bin = [v[1] stringByAppendingPathComponent:exeName];
            FPLog(@"-- %@: %@", v[0], bin);
            if (fp_probe_file(bin.fileSystemRepresentation, modes1, 1, core_log, NULL) > 0) [decryptedFrom addObject:bin];
        }
        if (decryptedFrom.count) {
            NSString *out = [outDir stringByAppendingPathComponent:[exeName stringByAppendingString:@".decrypted"]];
            int r = fp_decrypt_file([decryptedFrom.firstObject fileSystemRepresentation], out.fileSystemRepresentation, core_log, NULL);
            FPLog(@"=== %@: decrypted via %lu variant(s); wrote %@ (rc=%d) ===", name, (unsigned long)decryptedFrom.count, out, r);
        } else {
            FPLog(@"=== %@: no variant decrypted ===", name);
        }
    }
}

+ (void)copyTree:(NSString *)src to:(NSString *)dst skipped:(NSMutableArray *)skipped {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:src];
    for (NSString *rel in en) {
        NSString *type = en.fileAttributes.fileType;
        NSString *s = [src stringByAppendingPathComponent:rel], *d = [dst stringByAppendingPathComponent:rel];
        if ([rel.lastPathComponent isEqualToString:@"SC_Info"]) { [en skipDescendants]; [skipped addObject:rel]; continue; }
        if ([type isEqualToString:NSFileTypeDirectory]) {
            [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
        } else if ([type isEqualToString:NSFileTypeSymbolicLink]) {
            NSString *t = [fm destinationOfSymbolicLinkAtPath:s error:nil];
            if (!t || ![fm createSymbolicLinkAtPath:d withDestinationPath:t error:nil]) [skipped addObject:rel];
        } else if (![fm copyItemAtPath:s toPath:d error:nil]) {
            [skipped addObject:rel];
        }
    }
}

// Full export: EmbeddedPayload/<name>/ holds a complete copy of <name>.app (placed there by embed_ipa.sh).
// Every encrypted Mach-O is decrypted from its in-bundle path (where fairplayd can read it and its SC_Info),
// written into a container copy of the app, and the result is zipped into Documents/Decrypted/<name>-decrypted.ipa.
+ (void)embeddedExport {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [self embeddedRoot];
    for (NSString *name in [fm contentsOfDirectoryAtPath:root error:nil]) @autoreleasepool {
        NSString *src = [root stringByAppendingPathComponent:name];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[src stringByAppendingPathComponent:@"Info.plist"]];
        if (!info) { FPLog(@"[%@] no Info.plist; not a full app copy, skipping export", name); continue; }
        FPLog(@"=== export %@ (%@ %@) ===", name, info[@"CFBundleIdentifier"], info[@"CFBundleShortVersionString"]);
        NSString *work = [WorkDir() stringByAppendingPathComponent:[@"export-" stringByAppendingString:name]];
        NSString *appDst = [[work stringByAppendingPathComponent:@"Payload"] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"app"]];
        [fm removeItemAtPath:work error:nil];
        // The app sandbox denies reading SC_Info contents even inside our own bundle (only fairplayd needs them),
        // and a decrypted IPA does not need them either: copy everything else, tolerating unreadable files.
        NSMutableArray *skipped = [NSMutableArray array];
        [self copyTree:src to:appDst skipped:skipped];
        FPLog(@"copied bundle; skipped %lu item(s): %@", (unsigned long)skipped.count, [skipped componentsJoinedByString:@", "]);
        int dec = 0, plain = 0, fail = 0;
        NSMutableArray *failed = [NSMutableArray array];
        for (NSString *rel in [self machOsUnder:src]) @autoreleasepool {
            int r = fp_decrypt_file([src stringByAppendingPathComponent:rel].fileSystemRepresentation,
                                    [appDst stringByAppendingPathComponent:rel].fileSystemRepresentation, core_log, NULL);
            if (r == 0) dec++; else if (r == 1) plain++; else { fail++; [failed addObject:rel]; }
            FPLog(@"  %@ %@", r == 0 ? @"[DECRYPTED]" : r == 1 ? @"[plain]    " : @"[FAILED]   ", rel);
        }
        NSString *outDir = [DocsDir() stringByAppendingPathComponent:@"Decrypted"];
        [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *ipa = [outDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@.ipa", name, fail ? @"-PARTIAL" : @"-decrypted"]];
        [fm removeItemAtPath:ipa error:nil];
        char zerr[512] = {0};
        int zr = zip_create_from_dir(work.fileSystemRepresentation, ipa.fileSystemRepresentation, zerr, sizeof zerr);
        [fm removeItemAtPath:work error:nil];
        FPLog(@"=== %@: %d decrypted, %d not encrypted, %d failed%@; %@ ===", name, dec, plain, fail,
              fail ? [NSString stringWithFormat:@" (%@)", [failed componentsJoinedByString:@", "]] : @"",
              zr == 0 ? [@"wrote " stringByAppendingString:ipa.lastPathComponent] : [NSString stringWithFormat:@"zip failed: %s", zerr]);
    }
}

+ (void)processAllDocumentsIPAs {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *ipas = [NSMutableArray array];
    for (NSString *dir in @[DocsDir(), [DocsDir() stringByAppendingPathComponent:@"Inbox"]])
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil])
            if ([f.pathExtension.lowercaseString isEqualToString:@"ipa"]) [ipas addObject:[dir stringByAppendingPathComponent:f]];
    if (!ipas.count) FPLog(@"no .ipa files in Documents/");
    for (NSString *p in ipas) @autoreleasepool { [self processIPA:p]; }
}

+ (void)runEnvironment {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSString *mode = env[@"FPD_AUTORUN"];
    if (!mode) return;
    [self logEnvironment];
    if ([mode isEqualToString:@"installed"] || [mode isEqualToString:@"all"])
        [self probeInstalledAppsMatching:env[@"FPD_FILTER"] export:env[@"FPD_EXPORT"] != nil];
    if ([mode isEqualToString:@"embedded"] || [mode isEqualToString:@"all"])
        [self embeddedExperiment];
    if ([mode isEqualToString:@"export"])
        [self embeddedExport];
    if ([mode isEqualToString:@"ipa"] || [mode isEqualToString:@"all"])
        [self processAllDocumentsIPAs];
    FPLog(@"== autorun finished ==");
    if (env[@"FPD_EXIT"]) exit(0);
}

@end

#pragma mark - packaging helpers
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
        if (![baseName isEqualToString:@"FairPlayedPacker.app"]) {
            fail = @"내장 FairPlayed 기본 IPA 형식이 올바르지 않습니다."; break;
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
        // Keep a clean base template inside every repackaged app: the user can
        // select a different target later without installing a second helper.
        NSString *templateCopy = [host stringByAppendingPathComponent:@"FairPlayed-base-template.ipa"];
        if (![fm fileExistsAtPath:templateCopy] &&
            ![fm copyItemAtPath:base toPath:templateCopy error:error]) break;
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


#pragma mark - Unified on-device interface

@interface FPViewController : UIViewController <UIDocumentPickerDelegate>
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIButton *packButton;
@property (nonatomic, strong) UIButton *decryptButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSString *lastIPA;
@property (nonatomic, strong) NSString *resultIPA;
@property (nonatomic, assign) BOOL busy;
@end

@implementation FPViewController
- (UIButton *)makeButton:(NSString *)title tag:(NSInteger)tag {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = (tag == 1) ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.tintedButtonConfiguration;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.title = title;
    config.contentInsets = NSDirectionalEdgeInsetsMake(13, 12, 13, 12);
    button.configuration = config;
    button.tag = tag;
    [button addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (UILabel *)label:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
    UILabel *v = UILabel.new;
    v.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    v.text = text;
    v.textColor = UIColor.labelColor;
    v.numberOfLines = 0;
    return v;
}
- (BOOL)hasEmbeddedTarget {
    NSString *root = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"EmbeddedPayload"];
    NSArray<NSString *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    for (NSString *name in items) {
        if (![[NSDictionary dictionaryWithContentsOfFile:[[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Info.plist"]] isKindOfClass:NSDictionary.class]) continue;
        return YES;
    }
    return NO;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UIScrollView *scroll = UIScrollView.new;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor]]];

    UIStackView *stack = UIStackView.new;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.layoutMargins = UIEdgeInsetsMake(22, 18, 22, 18);
    stack.layoutMarginsRelativeArrangement = YES;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]]];

    [stack addArrangedSubview:[self label:@"FairPlayed 통합 패커" size:28 bold:YES]];
    [stack addArrangedSubview:[self label:@"FairPlayed 복호화 엔진과 기본 IPA가 내장되어 있습니다. 암호화된 IPA만 선택하세요." size:14 bold:NO]];
    self.stateLabel = [self label:@"상태 확인 중…" size:14 bold:YES];
    [stack addArrangedSubview:self.stateLabel];

    [stack addArrangedSubview:[self makeButton:@"① 암호화된 IPA 선택" tag:0]];
    self.packButton = [self makeButton:@"② 서명용 IPA 만들기" tag:1];
    [stack addArrangedSubview:self.packButton];
    self.decryptButton = [self makeButton:@"③ 내장 앱 복호화" tag:2];
    [stack addArrangedSubview:self.decryptButton];
    self.shareButton = [self makeButton:@"④ IPA · 결과 파일 공유" tag:3];
    [stack addArrangedSubview:self.shareButton];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [stack addArrangedSubview:self.spinner];
    [stack addArrangedSubview:[self label:@"복호화는 재패키징된 IPA를 SideStore로 서명·재설치한 뒤 가능합니다. 현재 설치된 앱의 데이터 폴더에 IPA를 넣는 것만으로는 복호화되지 않습니다." size:13 bold:NO]];
    [stack addArrangedSubview:[self label:@"실행 기록" size:17 bold:YES]];
    self.textView = UITextView.new;
    self.textView.editable = NO;
    self.textView.scrollEnabled = YES;
    self.textView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.textView.layer.cornerRadius = 12;
    self.textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.textView.heightAnchor constraintEqualToConstant:240].active = YES;
    [stack addArrangedSubview:self.textView];

    __weak typeof(self) weakSelf = self;
    gUILog = ^(NSString *line) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UITextView *tv = weakSelf.textView;
            if (!tv) return;
            tv.text = [tv.text stringByAppendingFormat:@"%@\n", line];
            if (tv.text.length > 100000) tv.text = [tv.text substringFromIndex:tv.text.length - 70000];
            [tv scrollRangeToVisible:NSMakeRange(tv.text.length, 0)];
        });
    };
    NSString *target = [DocsDir() stringByAppendingPathComponent:@"Encrypted-input.ipa"];
    if ([NSFileManager.defaultManager fileExistsAtPath:target]) self.lastIPA = target;
    NSString *result = [DocsDir() stringByAppendingPathComponent:@"FairPlayed-target-unsigned.ipa"];
    if ([NSFileManager.defaultManager fileExistsAtPath:result]) self.resultIPA = result;
    [self refreshState];
    FPLog(@"FairPlayed 통합 패커 실행. 복호화 엔진: 원본 FairPlayed.");
    FPLog(@"내장 페이로드 상태: %@", [self hasEmbeddedTarget] ? @"있음 — 복호화 가능성 검사" : @"없음 — 먼저 IPA 생성/재서명/재설치 필요");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [FPRunner runEnvironment]; });
}
- (void)refreshState {
    BOOL hasEmbedded = [self hasEmbeddedTarget];
    self.stateLabel.text = hasEmbedded
        ? @"내장 대상 앱 발견: '③ 내장 앱 복호화'를 눌러 시험하세요."
        : @"기본 패커 모드: 암호화된 IPA를 선택하고 재서명용 파일을 만드세요.";
    self.packButton.enabled = !self.busy && self.lastIPA != nil;
    self.decryptButton.enabled = !self.busy && hasEmbedded;
    self.shareButton.enabled = !self.busy;
}
- (void)setBusyUI:(BOOL)busy {
    self.busy = busy;
    if (busy) [self.spinner startAnimating]; else [self.spinner stopAnimating];
    [self refreshState];
}
- (void)background:(dispatch_block_t)block {
    [self setBusyUI:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        block();
        dispatch_async(dispatch_get_main_queue(), ^{ [self setBusyUI:NO]; });
    });
}
- (void)tap:(UIButton *)b {
    switch (b.tag) {
        case 0: {
            if (self.busy) return;
            UTType *ipa = [UTType typeWithIdentifier:@"com.apple.itunes.ipa"];
            NSArray *types = ipa ? @[ipa, UTTypeZIP, UTTypeData] : @[UTTypeZIP, UTTypeData];
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
            picker.delegate = self;
            [self presentViewController:picker animated:YES completion:nil];
            break;
        }
        case 1: {
            if (!self.lastIPA || self.busy) return;
            NSString *target = self.lastIPA;
            NSString *base = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"FairPlayed-base-template.ipa"];
            if (![NSFileManager.defaultManager fileExistsAtPath:base]) {
                FPLog(@"오류: 기본 FairPlayed IPA가 내장되지 않았습니다. 통합 버전 IPA를 설치하세요.");
                return;
            }
            [self background:^{
                FPLog(@"대상 IPA 패키징 시작: %@", target.lastPathComponent);
                NSError *error = nil;
                NSString *details = nil;
                NSString *output = FPPack(base, target, &details, &error);
                if (output) {
                    FPLog(@"%@\n서명 후 같은 앱을 재설치해야 복호화할 수 있습니다.", details);
                    dispatch_async(dispatch_get_main_queue(), ^{ self.resultIPA = output; });
                } else FPLog(@"패키징 실패: %@", error.localizedDescription ?: @"원인 불명");
            }];
            break;
        }
        case 2: {
            if (self.busy || ![self hasEmbeddedTarget]) return;
            [self background:^{
                FPLog(@"내장 앱 복호화 시작 (iOS 27.2.1에서는 실험적)");
                [FPRunner logEnvironment];
                [FPRunner embeddedExport];
                FPLog(@"복호화 결과는 파일 앱의 FairPlayed 패커 / Decrypted에서 확인하세요.");
            }];
            break;
        }
        case 3: {
            if (self.busy) return;
            NSMutableArray *items = NSMutableArray.array;
            if (self.resultIPA && [NSFileManager.defaultManager fileExistsAtPath:self.resultIPA])
                [items addObject:[NSURL fileURLWithPath:self.resultIPA]];
            NSString *dir = [DocsDir() stringByAppendingPathComponent:@"Decrypted"];
            for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
                if ([file.pathExtension.lowercaseString isEqualToString:@"ipa"])
                    [items addObject:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:file]]];
            NSString *logPath = [DocsDir() stringByAppendingPathComponent:@"fairplayed.log"];
            if ([NSFileManager.defaultManager fileExistsAtPath:logPath]) [items addObject:[NSURL fileURLWithPath:logPath]];
            if (!items.count) { FPLog(@"아직 공유할 출력 파일이 없습니다."); return; }
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
            share.popoverPresentationController.sourceView = b;
            [self presentViewController:share animated:YES completion:nil];
            break;
        }
    }
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url || self.busy) return;
    [self setBusyUI:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scope = [url startAccessingSecurityScopedResource];
        NSString *dst = [DocsDir() stringByAppendingPathComponent:@"Encrypted-input.ipa"];
        NSString *tmp = [dst stringByAppendingString:@".incoming"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:tmp error:nil];
        NSError *error = nil;
        BOOL copied = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp] error:&error];
        if (scope) [url stopAccessingSecurityScopedResource];
        if (copied) {
            [fm removeItemAtPath:dst error:nil];
            copied = [fm moveItemAtPath:tmp toPath:dst error:&error];
        }
        if (!copied) [fm removeItemAtPath:tmp error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (copied) {
                self.lastIPA = dst;
                FPLog(@"암호화 IPA 등록: %@ (%.1f MB)", url.lastPathComponent,
                      [[fm attributesOfItemAtPath:dst error:nil] fileSize] / 1048576.0);
            } else FPLog(@"IPA 가져오기 실패: %@", error.localizedDescription ?: @"파일 복사 실패");
            [self setBusyUI:NO];
        });
    });
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [FPViewController new];
    [self.window makeKeyAndVisible];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    NSString *logPath = [DocsDir() stringByAppendingPathComponent:@"fairplayed.log"];
    if (![NSFileManager.defaultManager fileExistsAtPath:logPath]) [NSData.data writeToFile:logPath atomically:NO];
    gLogFile = [NSFileHandle fileHandleForWritingAtPath:logPath];
    [gLogFile seekToEndOfFile];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}

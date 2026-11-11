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
    // The kernel FairPlay service cannot read a guest app under LiveContainer's
    // data container, regardless of whether the embedded app's SINF exists.
    NSString *bundle = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    if ([bundle containsString:@"/Documents/Applications/"]) {
        FPLog(@"[환경 오류] FairPlayed가 LiveContainer 안에서 실행 중입니다.");
        FPLog(@"암호화된 IPA를 포함한 FairPlayed-target-unsigned.ipa를 SideStore로 *독립 설치*한 뒤 홈 화면에서 실행하세요.");
        FPLog(@"현재 경로: %@", bundle);
        FPLog(@"LiveContainer 내부에서는 FairPlay 접근이 불가능하여 복호화 대신 PARTIAL 파일만 생성됩니다. 작업을 중단합니다.");
        return;
    }
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
        fp_reset_tiny_stub_count();
        NSMutableArray *failed = [NSMutableArray array];
        for (NSString *rel in [self machOsUnder:src]) @autoreleasepool {
            int r = fp_decrypt_file([src stringByAppendingPathComponent:rel].fileSystemRepresentation,
                                    [appDst stringByAppendingPathComponent:rel].fileSystemRepresentation, core_log, NULL);
            if (r == 0) dec++; else if (r == 1) plain++; else { fail++; [failed addObject:rel]; }
            FPLog(@"  %@ %@", r == 0 ? @"[DECRYPTED]" : r == 1 ? @"[plain]    " : @"[FAILED]   ", rel);
        }
        NSString *outDir = [DocsDir() stringByAppendingPathComponent:@"Decrypted"];
        [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
        unsigned tentative = fp_tiny_stub_count();
        NSString *suffix = fail ? @"-PARTIAL" : tentative ? @"-EXPERIMENTAL" : @"-decrypted";
        NSString *ipa = [outDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@.ipa", name, suffix]];
        if (tentative) FPLog(@"[주의] 저코드 1페이지 프레임워크 %u개는 실험 판정입니다. 복호화 완료로 검증된 것이 아닙니다.", tentative);
        [fm removeItemAtPath:ipa error:nil];
        char zerr[512] = {0};
        int zr = zip_create_from_dir(work.fileSystemRepresentation, ipa.fileSystemRepresentation, zerr, sizeof zerr);
        [fm removeItemAtPath:work error:nil];
        FPLog(@"=== %@: %d decrypted, %d not encrypted, %d failed, %u experimental%@; %@ ===", name, dec, plain, fail, tentative,
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


// FairPlayed's FairPlay service lookup requires a genuinely installed app bundle.
// LiveContainer runs guest apps from Documents/Applications inside its own data container.
static BOOL FPRunningAsLiveContainerGuest(void) {
    NSString *bundle = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    return [bundle containsString:@"/Documents/Applications/"];
}



#pragma mark - IPA browser inside daru sandbox (no Files provider dependency)

// Presents IPAs from the app's own shared Documents directory.
// Unlike UIDocumentPickerViewController this never invokes the system Recents
// File Provider interface that stalls on the reported iOS 27.2.1 setup.
@interface DaruLocalIPABrowser : UITableViewController
@property(nonatomic,copy) void (^onIPASelected)(NSURL *);
@property(nonatomic,strong) NSArray<NSDictionary *> *items;
@property(nonatomic,strong) UILabel *emptyLabel;
@end

@implementation DaruLocalIPABrowser

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"daru · IPA 선택";
    self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight=72;
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"닫기"
                                                                         style:UIBarButtonItemStylePlain
                                                                        target:self
                                                                        action:@selector(closeBrowser)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                         target:self
                                                                                         action:@selector(reloadIPAList)];
    UIRefreshControl *refresh=UIRefreshControl.new;
    [refresh addTarget:self action:@selector(reloadIPAList) forControlEvents:UIControlEventValueChanged];
    self.refreshControl=refresh;

    UILabel *info=UILabel.new;
    info.numberOfLines=0;
    info.textAlignment=NSTextAlignmentLeft;
    info.font=[UIFont systemFontOfSize:14];
    info.textColor=UIColor.secondaryLabelColor;
    info.text=@"① 파일 앱을 열어 IPA를 '나의 iPhone → daru' 폴더에 복사하세요.\n② daru로 돌아와 파일 이름을 누르면 됩니다.\n파일이 안 보이면 오른쪽 위 새로고침을 누르세요.";
    UIView *header=UIView.new;
    header.backgroundColor=UIColor.clearColor;
    [header addSubview:info];
    info.translatesAutoresizingMaskIntoConstraints=NO;
    [NSLayoutConstraint activateConstraints:@[
        [info.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [info.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [info.topAnchor constraintEqualToAnchor:header.topAnchor constant:15],
        [info.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-15]
    ]];
    header.frame=CGRectMake(0,0,1,120);
    self.tableView.tableHeaderView=header;

    self.emptyLabel=UILabel.new;
    self.emptyLabel.text=@"daru 폴더에 IPA가 없습니다.\n파일 앱에서 IPA를 복사한 뒤 새로고침해 주세요.";
    self.emptyLabel.numberOfLines=0;
    self.emptyLabel.textAlignment=NSTextAlignmentCenter;
    self.emptyLabel.textColor=UIColor.secondaryLabelColor;
    self.emptyLabel.font=[UIFont systemFontOfSize:15];
    self.items=@[];
    [self reloadIPAList];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadIPAList];
}
- (void)closeBrowser {
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)reloadIPAList {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSMutableArray<NSDictionary *> *items=NSMutableArray.array;
        NSFileManager *fm=NSFileManager.defaultManager;
        NSString *docs=DocsDir();
        for (NSString *folder in @[docs,[docs stringByAppendingPathComponent:@"Inbox"]]) {
            NSArray<NSString *> *names=[fm contentsOfDirectoryAtPath:folder error:nil];
            for (NSString *name in names) {
                if (![[name.pathExtension lowercaseString] isEqualToString:@"ipa"]) continue;
                if ([name isEqualToString:@"FairPlayed-target-unsigned.ipa"]) continue;
                NSString *file=[folder stringByAppendingPathComponent:name];
                BOOL isDirectory=NO;
                if (![fm fileExistsAtPath:file isDirectory:&isDirectory] || isDirectory) continue;
                NSDictionary *attributes=[fm attributesOfItemAtPath:file error:nil];
                NSDate *when=attributes[NSFileModificationDate] ?: [NSDate distantPast];
                [items addObject:@{
                    @"url":[NSURL fileURLWithPath:file],
                    @"name":name,
                    @"length":attributes[NSFileSize] ?: @0,
                    @"date":when
                }];
            }
        }
        [items sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
            return [b[@"date"] compare:a[@"date"]];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.items=[items copy];
            self.tableView.backgroundView=items.count ? nil : self.emptyLabel;
            [self.tableView reloadData];
            [self.refreshControl endRefreshing];
        });
    });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.items.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse=@"DaruLocalIPA";
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    NSDictionary *item=self.items[indexPath.row];
    cell.textLabel.text=item[@"name"];
    cell.textLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;
    cell.textLabel.numberOfLines=2;
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%.1f MB · daru 내부 파일", [item[@"length"] doubleValue]/1048576.0];
    cell.imageView.image=[UIImage systemImageNamed:@"doc.zipper"];
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= self.items.count) return;
    NSURL *url=self.items[indexPath.row][@"url"];
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onIPASelected) self.onIPASelected(url);
    }];
}
@end

#pragma mark - Native Liquid Glass workspace (iOS 26+)

@interface FPWorkspace : UITabBarController <UIDocumentPickerDelegate>
- (void)importIPAAtURL:(NSURL *)source;
@property(nonatomic,strong) UILabel *inputLabel;
@property(nonatomic,strong) UILabel *packageStatus;
@property(nonatomic,strong) UILabel *decryptStatus;
@property(nonatomic,strong) UILabel *logSummary;
@property(nonatomic,strong) UIButton *generateButton;
@property(nonatomic,strong) UIButton *sharePackageButton;
@property(nonatomic,strong) UIButton *decryptButton;
@property(nonatomic,strong) UISwitch *stubModeSwitch;
@property(nonatomic,strong) UIButton *shareResultButton;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) UITextView *inlineLog;
@property(nonatomic,strong) UITextView *fullLog;
@property(nonatomic,strong) NSMutableString *displayLog;
@property(nonatomic,strong) NSString *lastIPA;
@property(nonatomic,strong) NSString *resultIPA;
@property(nonatomic,assign) BOOL busy;
@end

@implementation FPWorkspace

- (UILabel *)label:(NSString *)s size:(CGFloat)sz strong:(BOOL)strong {
    UILabel *v=UILabel.new;
    v.text=s;
    v.numberOfLines=0;
    v.textColor=UIColor.labelColor;
    v.font=strong ? [UIFont boldSystemFontOfSize:sz] : [UIFont systemFontOfSize:sz];
    return v;
}
- (UIButton *)button:(NSString *)title symbol:(NSString *)symbol tag:(NSInteger)tag primary:(BOOL)primary {
    UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config=primary ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.tintedButtonConfiguration;
    config.title=title;
    config.cornerStyle=UIButtonConfigurationCornerStyleLarge;
    config.contentInsets=NSDirectionalEdgeInsetsMake(14,12,14,12);
    if (symbol.length) config.image=[UIImage systemImageNamed:symbol];
    config.imagePadding=8;
    b.configuration=config;
    b.tag=tag;
    [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (UIStackView *)stack {
    UIStackView *v=UIStackView.new;
    v.axis=UILayoutConstraintAxisVertical;
    v.alignment=UIStackViewAlignmentFill;
    v.spacing=10;
    return v;
}
- (UIStackView *)card {
    UIStackView *v=[self stack];
    v.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;
    v.layer.cornerRadius=20;
    v.layer.cornerCurve=kCACornerCurveContinuous;
    v.layoutMargins=UIEdgeInsetsMake(18,17,18,17);
    v.layoutMarginsRelativeArrangement=YES;
    return v;
}
- (UIStackView *)page:(UIViewController *)c {
    UIScrollView *scroll=UIScrollView.new;
    scroll.translatesAutoresizingMaskIntoConstraints=NO;
    scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    scroll.alwaysBounceVertical=YES;
    c.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
    [c.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:c.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:c.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:c.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:c.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    UIStackView *s=[self stack];
    s.spacing=16;
    s.layoutMargins=UIEdgeInsetsMake(20,16,32,16);
    s.layoutMarginsRelativeArrangement=YES;
    s.translatesAutoresizingMaskIntoConstraints=NO;
    [scroll addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [s.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [s.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [s.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [s.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];
    return s;
}
- (UIView *)glassTitle:(NSString *)title subtitle:(NSString *)subtitle {
    UIVisualEffect *effect=nil;
    if (@available(iOS 26.0, *)) {
        effect=[UIGlassEffect new];
    } else {
        effect=[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    }
    UIVisualEffectView *glass=[[UIVisualEffectView alloc] initWithEffect:effect];
    glass.layer.cornerRadius=24;
    glass.layer.cornerCurve=kCACornerCurveContinuous;
    glass.clipsToBounds=YES;
    UIStackView *inner=[self stack];
    inner.spacing=4;
    inner.layoutMargins=UIEdgeInsetsMake(18,20,18,20);
    inner.layoutMarginsRelativeArrangement=YES;
    inner.translatesAutoresizingMaskIntoConstraints=NO;
    [inner addArrangedSubview:[self label:title size:23 strong:YES]];
    [inner addArrangedSubview:[self label:subtitle size:13 strong:NO]];
    [glass.contentView addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor],
        [inner.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor],
        [inner.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor],
        [inner.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor]
    ]];
    return glass;
}
- (UIView *)divider {
    UIView *v=UIView.new;
    v.backgroundColor=UIColor.separatorColor;
    v.translatesAutoresizingMaskIntoConstraints=NO;
    [v.heightAnchor constraintEqualToConstant:0.5].active=YES;
    return v;
}
- (UITextView *)logView:(CGFloat)height {
    UITextView *v=UITextView.new;
    v.editable=NO;
    v.selectable=YES;
    v.scrollEnabled=YES;
    v.textColor=UIColor.secondaryLabelColor;
    v.backgroundColor=UIColor.tertiarySystemGroupedBackgroundColor;
    v.layer.cornerRadius=12;
    v.layer.cornerCurve=kCACornerCurveContinuous;
    v.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    v.translatesAutoresizingMaskIntoConstraints=NO;
    [v.heightAnchor constraintEqualToConstant:height].active=YES;
    return v;
}
- (BOOL)hasEmbeddedTarget {
    NSString *root=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"EmbeddedPayload"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) {
        NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Info.plist"]];
        if ([info isKindOfClass:NSDictionary.class]) return YES;
    }
    return NO;
}
- (BOOL)hasCompleteResult {
    NSString *dir=[DocsDir() stringByAppendingPathComponent:@"Decrypted"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        if ([[name lowercaseString] hasSuffix:@"-decrypted.ipa"] && ![[name lowercaseString] containsString:@"partial"]) return YES;
    }
    return NO;
}
- (NSArray<NSURL *> *)resultFiles {
    NSString *dir=[DocsDir() stringByAppendingPathComponent:@"Decrypted"];
    NSMutableArray<NSURL *> *results=NSMutableArray.array;
    for (NSString *name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        if ([[name.pathExtension lowercaseString] isEqualToString:@"ipa"])
            [results addObject:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]]];
    }
    return results;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    // Native iOS 26+ UITabBar receives Liquid Glass automatically when built
    // with a current SDK. Unlike a simulated blur, it uses the system material.
    UIViewController *packing=UIViewController.new;
    UIViewController *decrypting=UIViewController.new;
    UIViewController *logging=UIViewController.new;
    packing.tabBarItem=[[UITabBarItem alloc] initWithTitle:@"패키징" image:[UIImage systemImageNamed:@"shippingbox.fill"] tag:0];
    decrypting.tabBarItem=[[UITabBarItem alloc] initWithTitle:@"복호화" image:[UIImage systemImageNamed:@"lock.open.fill"] tag:1];
    logging.tabBarItem=[[UITabBarItem alloc] initWithTitle:@"로그" image:[UIImage systemImageNamed:@"text.alignleft"] tag:2];
    self.viewControllers=@[packing,decrypting,logging];
    self.selectedIndex=0;

    // The action and compact log live in one progress area but use separate
    // subpanels, as requested.
    UIStackView *pack=[self page:packing];
    [pack addArrangedSubview:[self glassTitle:@"daru" subtitle:@"FairPlayed 엔진 내장 · IPA 서명 전 패키징"]];
    UIStackView *fileCard=[self card];
    [fileCard addArrangedSubview:[self label:@"① 암호화 IPA 선택" size:19 strong:YES]];
    [fileCard addArrangedSubview:[self label:@"iPadn에서 다운로드한 본인 보유 앱의 IPA를 선택하세요." size:14 strong:NO]];
    [fileCard addArrangedSubview:[self button:@"IPA 선택 (daru 파일 목록)" symbol:@"doc.text.magnifyingglass" tag:10 primary:YES]];
    [fileCard addArrangedSubview:[self button:@"iOS 파일 앱에서 직접 찾아보기 (보조)" symbol:@"folder" tag:17 primary:NO]];
    [fileCard addArrangedSubview:[self label:@"기본 선택은 iOS의 '최근 항목' 화면을 열지 않습니다. 파일 앱에서 '나의 iPhone → daru'에 IPA를 복사한 다음 위 버튼에서 선택하세요. 보조 버튼은 iOS 파일 선택기가 정상 작동할 때만 이용하세요." size:12 strong:NO]];
    self.inputLabel=[self label:@"선택된 파일 없음" size:13 strong:NO];
    self.inputLabel.textColor=UIColor.secondaryLabelColor;
    [fileCard addArrangedSubview:self.inputLabel];
    [pack addArrangedSubview:fileCard];

    UIStackView *working=[self stack];
    working.spacing=8;
    [working addArrangedSubview:[self label:@"작업 진행" size:20 strong:YES]];
    UIStackView *generateCard=[self card];
    [generateCard addArrangedSubview:[self label:@"② SideStore 서명용 IPA 생성" size:17 strong:YES]];
    [generateCard addArrangedSubview:[self label:@"내장된 FairPlayed 템플릿과 선택한 IPA를 재패키징합니다." size:13 strong:NO]];
    self.generateButton=[self button:@"서명용 IPA 만들기" symbol:@"shippingbox" tag:11 primary:YES];
    [generateCard addArrangedSubview:self.generateButton];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped=YES;
    [generateCard addArrangedSubview:self.spinner];
    self.packageStatus=[self label:@"IPA를 선택하면 생성할 수 있습니다." size:13 strong:NO];
    [generateCard addArrangedSubview:self.packageStatus];
    [working addArrangedSubview:generateCard];

    UIStackView *compactCard=[self card];
    [compactCard addArrangedSubview:[self label:@"실시간 작업 로그" size:16 strong:YES]];
    self.inlineLog=[self logView:154];
    [compactCard addArrangedSubview:self.inlineLog];
    [compactCard addArrangedSubview:[self button:@"전체 로그 보기" symbol:@"list.bullet.rectangle" tag:15 primary:NO]];
    [working addArrangedSubview:compactCard];
    [pack addArrangedSubview:working];

    UIStackView *shareCard=[self card];
    [shareCard addArrangedSubview:[self label:@"③ IPA 공유 · SideStore 재설치" size:17 strong:YES]];
    [shareCard addArrangedSubview:[self label:@"생성된 IPA를 SideStore로 서명·재설치한 뒤, 메뉴바의 ‘복호화’로 이동하세요." size:14 strong:NO]];
    self.sharePackageButton=[self button:@"IPA 내보내기 / SideStore 공유" symbol:@"square.and.arrow.up" tag:12 primary:NO];
    [shareCard addArrangedSubview:self.sharePackageButton];
    [pack addArrangedSubview:shareCard];

    UIStackView *dec=[self page:decrypting];
    [dec addArrangedSubview:[self glassTitle:@"복호화" subtitle:@"생성한 FairPlayed IPA를 SideStore에 독립 설치한 다음 진행"]];
    UIStackView *decryptCard=[self card];
    [decryptCard addArrangedSubview:[self label:@"④ 내장된 앱 복호화" size:19 strong:YES]];
    self.decryptStatus=[self label:@"재설치한 앱의 내장 페이로드를 확인합니다." size:14 strong:NO];
    [decryptCard addArrangedSubview:self.decryptStatus];
    UIView *line=[self divider];
    [decryptCard addArrangedSubview:line];
    UIStackView *tinyRow=[self stack];
    tinyRow.axis=UILayoutConstraintAxisHorizontal;
    tinyRow.alignment=UIStackViewAlignmentCenter;
    tinyRow.distribution=UIStackViewDistributionFill;
    UILabel *tinyLabel=[self label:@"초소형 프레임워크 실험 모드" size:14 strong:YES];
    [tinyRow addArrangedSubview:tinyLabel];
    self.stubModeSwitch=UISwitch.new;
    self.stubModeSwitch.on=NO;
    [tinyRow addArrangedSubview:self.stubModeSwitch];
    [decryptCard addArrangedSubview:tinyRow];
    [decryptCard addArrangedSubview:[self label:@"기본값은 꺼짐. 1페이지 복호화 결과가 거의 0일 때만 제한적으로 허용하며, 결과는 EXPERIMENTAL IPA로 표시됩니다. 실행 성공을 보장하지 않습니다." size:12 strong:NO]];
    self.decryptButton=[self button:@"복호화 실행" symbol:@"lock.open" tag:13 primary:YES];
    [decryptCard addArrangedSubview:self.decryptButton];
    [dec addArrangedSubview:decryptCard];

    UIStackView *resultCard=[self card];
    [resultCard addArrangedSubview:[self label:@"⑤ 복호화 결과 확인 및 공유" size:18 strong:YES]];
    [resultCard addArrangedSubview:[self label:@"실패한 프레임워크가 있는 PARTIAL IPA는 LiveContainer에서 실행할 수 없습니다. 로그에서 실패 개수를 먼저 확인하세요." size:13 strong:NO]];
    self.shareResultButton=[self button:@"복호화 결과 IPA 내보내기" symbol:@"square.and.arrow.up" tag:14 primary:NO];
    [resultCard addArrangedSubview:self.shareResultButton];
    [dec addArrangedSubview:resultCard];

    UIStackView *logs=[self page:logging];
    [logs addArrangedSubview:[self glassTitle:@"진단 로그" subtitle:@"암호화 해제 진행과 실패한 프레임워크 확인"]];
    UIStackView *logCard=[self card];
    [logCard addArrangedSubview:[self label:@"전체 실행 로그" size:18 strong:YES]];
    self.fullLog=[self logView:460];
    [logCard addArrangedSubview:self.fullLog];
    [logCard addArrangedSubview:[self button:@"로그 파일 공유" symbol:@"square.and.arrow.up" tag:16 primary:NO]];
    [logs addArrangedSubview:logCard];

    self.displayLog=[NSMutableString string];
    NSString *record=[DocsDir() stringByAppendingPathComponent:@"fairplayed.log"];
    NSString *previous=[NSString stringWithContentsOfFile:record encoding:NSUTF8StringEncoding error:nil];
    if (previous.length) {
        [self.displayLog appendString:previous.length > 50000 ? [previous substringFromIndex:previous.length-50000] : previous];
        self.inlineLog.text=self.displayLog;
        self.fullLog.text=self.displayLog;
    }
    __weak typeof(self) weakSelf=self;
    gUILog=^(NSString *line) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FPWorkspace *s=weakSelf;
            if (!s) return;
            [s.displayLog appendFormat:@"%@\n",line];
            if (s.displayLog.length > 90000)
                [s.displayLog deleteCharactersInRange:NSMakeRange(0,s.displayLog.length-65000)];
            NSString *shortText=s.displayLog.length > 7000 ? [s.displayLog substringFromIndex:s.displayLog.length-7000] : s.displayLog;
            s.inlineLog.text=shortText;
            s.fullLog.text=s.displayLog;
            [s.inlineLog scrollRangeToVisible:NSMakeRange(s.inlineLog.text.length,0)];
            [s.fullLog scrollRangeToVisible:NSMakeRange(s.fullLog.text.length,0)];
        });
    };

    NSString *input=[DocsDir() stringByAppendingPathComponent:@"Encrypted-input.ipa"];
    if ([NSFileManager.defaultManager fileExistsAtPath:input]) self.lastIPA=input;
    NSString *generated=[DocsDir() stringByAppendingPathComponent:@"FairPlayed-target-unsigned.ipa"];
    if ([NSFileManager.defaultManager fileExistsAtPath:generated]) self.resultIPA=generated;
    [self refresh];
    NSString *readme=[DocsDir() stringByAppendingPathComponent:@"IPA를 이 폴더에 복사하세요.txt"];
    if (![NSFileManager.defaultManager fileExistsAtPath:readme])
        [@"파일 앱 → 나의 iPhone → daru 폴더에 .ipa 파일을 복사하세요. daru 앱의 'daru 폴더의 IPA 선택' 버튼으로 가져올 수 있습니다.\n" writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:nil];
    FPLog(@"daru 2.5 · 기본 IPA 선택기는 daru 자체 목록을 사용합니다 (iOS 최근 항목 우회).");
    if (FPRunningAsLiveContainerGuest())
        FPLog(@"[환경 주의] LiveContainer 안에서는 FairPlay 복호화가 불가능합니다. SideStore 직접 설치하세요.");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{[FPRunner runEnvironment];});
}
- (void)refresh {
    BOOL guest=FPRunningAsLiveContainerGuest();
    BOOL embedded=[self hasEmbeddedTarget];
    self.generateButton.enabled=!self.busy && self.lastIPA.length>0;
    self.sharePackageButton.enabled=!self.busy && self.resultIPA.length>0 && [NSFileManager.defaultManager fileExistsAtPath:self.resultIPA];
    self.decryptButton.enabled=!self.busy && embedded && !guest;
    self.shareResultButton.enabled=!self.busy && [self resultFiles].count>0;
    self.inputLabel.text=self.lastIPA ? [NSString stringWithFormat:@"✓ %@ (%.1f MB)",self.lastIPA.lastPathComponent,[[NSFileManager.defaultManager attributesOfItemAtPath:self.lastIPA error:nil] fileSize]/1048576.0] : @"선택된 IPA 없음";
    if (guest) self.decryptStatus.text=@"LiveContainer 내부 실행 중: 복호화 불가. SideStore로 독립 설치하세요.";
    else if (embedded) self.decryptStatus.text=@"설치된 앱에 암호화 대상이 포함되어 있습니다. 아래 버튼으로 복호화를 시도하세요.";
    else self.decryptStatus.text=@"내장된 대상 앱 없음. 패키징 → 공유 → SideStore 재설치 후 돌아오세요.";
}
- (void)working:(dispatch_block_t)work {
    self.busy=YES;
    [self.spinner startAnimating];
    [self refresh];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        work();
        dispatch_async(dispatch_get_main_queue(),^{
            self.busy=NO;
            [self.spinner stopAnimating];
            [self refresh];
        });
    });
}
- (void)sharePaths:(NSArray<NSURL *> *)urls from:(UIView *)sender {
    if (!urls.count) { FPLog(@"공유할 파일이 없습니다."); return; }
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
    share.popoverPresentationController.sourceView=sender;
    [self.selectedViewController presentViewController:share animated:YES completion:nil];
}
- (void)tap:(UIButton *)sender {
    switch (sender.tag) {
        case 10: {
            if (self.busy) return;
            DaruLocalIPABrowser *browser=[[DaruLocalIPABrowser alloc] initWithStyle:UITableViewStyleInsetGrouped];
            __weak typeof(self) weakSelf=self;
            browser.onIPASelected=^(NSURL *file) {
                FPLog(@"[IPA 목록] 사용자 선택: %@",file.lastPathComponent);
                [weakSelf importIPAAtURL:file];
            };
            UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:browser];
            navigation.modalPresentationStyle=UIModalPresentationFullScreen;
            [self presentViewController:navigation animated:YES completion:nil];
            break;
        }
        case 17: {
            if (self.busy) return;
            // The optional Files path uses the original pre-glass configuration:
            // 'asCopy:YES', permissive file types and presentation by the root
            // controller, rather than the Glass tab's selected child.
            UTType *ipa=[UTType typeWithIdentifier:@"com.apple.itunes.ipa"];
            NSArray<UTType *> *types=ipa ? @[ipa,UTTypeZIP,UTTypeData] : @[UTTypeZIP,UTTypeData];
            UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
            picker.delegate=self;
            picker.allowsMultipleSelection=NO;
            picker.modalPresentationStyle=UIModalPresentationPageSheet;
            FPLog(@"[iOS 보조 선택기] 이전 버전의 복사 모드로 호출. 최근 항목 화면이 멈추면 daru 목록을 이용하세요.");
            [self presentViewController:picker animated:YES completion:nil];
            break;
        }
        case 11: {
            if (self.busy || !self.lastIPA) return;
            NSString *base=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"FairPlayed-base-template.ipa"];
            if (![NSFileManager.defaultManager fileExistsAtPath:base]) {
                self.packageStatus.text=@"오류: 내장된 FairPlayed 기본 IPA를 찾을 수 없습니다.";
                FPLog(@"기본 IPA 템플릿 없음: %@",base);
                return;
            }
            NSString *target=self.lastIPA;
            self.packageStatus.text=@"IPA 압축 해제 및 재패키징 중… 앱을 종료하지 마세요.";
            [self working:^{
                NSError *error=nil;
                NSString *detail=nil;
                FPLog(@"[패키징] 시작: %@",target.lastPathComponent);
                NSString *output=FPPack(base,target,&detail,&error);
                if (output) {
                    FPLog(@"[패키징] %@ — 다음 단계: ③ 공유 → SideStore 재설치 → 복호화 탭",detail);
                    dispatch_async(dispatch_get_main_queue(),^{
                        self.resultIPA=output;
                        self.packageStatus.text=@"생성 완료. 아래 ‘③ IPA 공유’에서 SideStore로 내보내세요.";
                    });
                } else {
                    FPLog(@"[패키징 오류] %@",error.localizedDescription ?: @"알 수 없는 오류");
                    dispatch_async(dispatch_get_main_queue(),^{
                        self.packageStatus.text=[NSString stringWithFormat:@"생성 실패: %@",error.localizedDescription ?: @"원인 불명"];
                    });
                }
            }];
            break;
        }
        case 12: {
            if (self.resultIPA.length && [NSFileManager.defaultManager fileExistsAtPath:self.resultIPA])
                [self sharePaths:@[[NSURL fileURLWithPath:self.resultIPA]] from:sender];
            break;
        }
        case 13: {
            if (self.busy) return;
            if (FPRunningAsLiveContainerGuest()) {
                FPLog(@"[복호화 차단] LiveContainer 내부 실행. SideStore로 직접 설치해야 합니다.");
                self.selectedIndex=2;
                return;
            }
            if (![self hasEmbeddedTarget]) {
                FPLog(@"[복호화 차단] 내장된 대상 앱 없음. ①~③ 순서로 재패키징 및 SideStore 재설치하세요.");
                return;
            }
            BOOL experimental=self.stubModeSwitch.isOn;
            self.decryptStatus.text=@"복호화 중입니다. 완료 후 실패 수 및 EXPERIMENTAL 여부를 확인하세요.";
            [self working:^{
                fp_set_tiny_stub_mode(experimental);
                FPLog(@"[복호화 모드] %@", experimental ? @"1페이지 실험 허용 (EXPERIMENTAL 결과 가능)" : @"표준 검증");
                [FPRunner logEnvironment];
                [FPRunner embeddedExport];
                fp_set_tiny_stub_mode(false);
                NSArray *results=[self resultFiles];
                BOOL complete=[self hasCompleteResult];
                FPLog(complete ? @"[복호화] 결과 IPA 발견. 로그를 검토하세요." :
                      @"[복호화 경고] 완전 복호화된 IPA가 없습니다. PARTIAL IPA는 설치하지 마세요.");
                dispatch_async(dispatch_get_main_queue(),^{
                    self.decryptStatus.text=complete ? @"완료된 IPA가 있습니다. 로그 검증 후 ⑤에서 공유하세요." :
                                                     @"완전 복호화 실패: 로그에서 실패한 프레임워크를 확인하세요.";
                    self.shareResultButton.enabled=results.count>0;
                });
            }];
            break;
        }
        case 14: {
            NSArray<NSURL *> *result=[self resultFiles];
            if (!result.count) { FPLog(@"아직 복호화 결과 IPA가 없습니다."); return; }
            if (![self hasCompleteResult]) {
                UIAlertController *warning=[UIAlertController alertControllerWithTitle:@"부분 복호화 파일" message:@"이 파일은 PARTIAL 또는 EXPERIMENTAL 상태로, 완전한 복호화가 검증되지 않았습니다. LiveContainer 실행에 실패할 수 있습니다. 진단 목적으로 공유하시겠습니까?" preferredStyle:UIAlertControllerStyleAlert];
                [warning addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
                [warning addAction:[UIAlertAction actionWithTitle:@"파일 공유" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self sharePaths:result from:sender];}]];
                [self.selectedViewController presentViewController:warning animated:YES completion:nil];
            } else [self sharePaths:result from:sender];
            break;
        }
        case 15: self.selectedIndex=2; break;
        case 16: {
            NSString *path=[DocsDir() stringByAppendingPathComponent:@"fairplayed.log"];
            if ([NSFileManager.defaultManager fileExistsAtPath:path])
                [self sharePaths:@[[NSURL fileURLWithPath:path]] from:sender];
            break;
        }
    }
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    FPLog(@"[iOS 보조 선택기] 파일 선택 완료: %@", urls.firstObject.lastPathComponent ?: @"없음");
    [self importIPAAtURL:urls.firstObject];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)picker {
    FPLog(@"[iOS 보조 선택기] 취소됨");
}
- (void)importIPAAtURL:(NSURL *)source {
    if (!source || self.busy) return;
    NSString *extension=source.pathExtension.lowercaseString;
    if (![extension isEqualToString:@"ipa"]) {
        self.packageStatus.text=@"IPA 파일만 등록할 수 있습니다. (.ipa 확장자 확인)";
        FPLog(@"[입력 거부] IPA가 아닌 파일: %@",source.lastPathComponent);
        return;
    }
    self.busy=YES;
    [self.spinner startAnimating];
    [self refresh];
    self.packageStatus.text=@"선택한 IPA를 가져오는 중…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        BOOL access=[source startAccessingSecurityScopedResource];
        NSString *dest=[DocsDir() stringByAppendingPathComponent:@"Encrypted-input.ipa"];
        NSString *temporary=[dest stringByAppendingString:@".incoming"];
        NSFileManager *fm=NSFileManager.defaultManager;
        [fm removeItemAtPath:temporary error:nil];
        NSError *error=nil;
        BOOL sameFile=[source.URLByStandardizingPath.path isEqualToString:[NSURL fileURLWithPath:dest].URLByStandardizingPath.path];
        BOOL ok=sameFile || [fm copyItemAtURL:source toURL:[NSURL fileURLWithPath:temporary] error:&error];
        if (access) [source stopAccessingSecurityScopedResource];
        if (ok && !sameFile) {
            [fm removeItemAtPath:dest error:nil];
            ok=[fm moveItemAtPath:temporary toPath:dest error:&error];
        }
        if (!ok) [fm removeItemAtPath:temporary error:nil];
        dispatch_async(dispatch_get_main_queue(),^{
            self.busy=NO;
            [self.spinner stopAnimating];
            if (ok) {
                self.lastIPA=dest;
                self.resultIPA=nil;
                self.packageStatus.text=@"IPA 등록 완료. ② 서명용 IPA 만들기를 실행하세요.";
                FPLog(@"[입력 완료] %@ (%.1f MB)",source.lastPathComponent,
                       [[fm attributesOfItemAtPath:dest error:nil] fileSize]/1048576.0);
            } else {
                self.packageStatus.text=[NSString stringWithFormat:@"IPA 복사 실패: %@",error.localizedDescription ?: @"파일 오류"];
                FPLog(@"[입력 오류] %@",error.localizedDescription ?: @"파일 복사 실패");
            }
            [self refresh];
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
    FPWorkspace *app=[FPWorkspace new];
    self.window.rootViewController = app;
    [self.window makeKeyAndVisible];
    // Opening an IPA using Files -> Share -> Open in daru also works if
    // the Files document picker extension freezes.
    for (UIOpenURLContext *ctx in opts.URLContexts) {
        if (ctx.URL.isFileURL) [app importIPAAtURL:ctx.URL];
    }
}
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    FPWorkspace *app=(FPWorkspace *)self.window.rootViewController;
    for (UIOpenURLContext *ctx in URLContexts)
        if (ctx.URL.isFileURL) [app importIPAAtURL:ctx.URL];
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

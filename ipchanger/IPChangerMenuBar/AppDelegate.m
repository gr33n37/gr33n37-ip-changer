//
//  AppDelegate.m — menu bar: flag PNG from flagcdn (same as pref pane), then emoji raster fallback.
//

#import "AppDelegate.h"
#import "IPCTorRotationEngine.h"
#import <AppKit/AppKit.h>

static NSString *IPCMBSharedExitIdentityPath(void)
{
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IPChanger"];
    return [dir stringByAppendingPathComponent:@"exit-identity.plist"];
}

/// ISO 3166-1 alpha-2 → regional-indicator flag string (empty if invalid).
static NSString *IPCMBFlagEmojiFromCountryCode(NSString *cc)
{
    if (cc.length != 2) return @"";
    unichar a = (unichar)toupper([cc characterAtIndex:0]);
    unichar b = (unichar)toupper([cc characterAtIndex:1]);
    if (a < 'A' || a > 'Z' || b < 'A' || b > 'Z') return @"";
    unichar r0 = (unichar)(0x1F1E6 + (a - 'A'));
    unichar r1 = (unichar)(0x1F1E6 + (b - 'A'));
    return [NSString stringWithCharacters:(unichar[]){ r0, r1 } length:2];
}

/// Same URL as ipchanger.m `curlSOCKSData:…flagcdn.com…`.
static NSData *IPCMBFetchFlagPNGData(NSString *cc)
{
    if (cc.length != 2) return nil;
    NSString *url = [NSString stringWithFormat:@"https://flagcdn.com/w80/%@.png", cc.lowercaseString];
    NSArray *args = @[ @"-s", @"--connect-timeout", @"6", @"-m", @"12", url ];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/curl"];
    task.arguments = args;
    task.standardError = [NSFileHandle fileHandleForWritingAtPath:@"/dev/null"];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    @try {
        [task launch];
    } @catch (__unused NSException *ex) {
        return nil;
    }
    [task waitUntilExit];
    return [[out fileHandleForReading] readDataToEndOfFile];
}

/// Mirrors `ipchanger` `ipc_imageFromFlagEmoji:` (34pt Apple Color Emoji, flipped:NO), then scales for the status item.
static NSImage *IPCMBImageFromFlagEmojiLikePrefPane(NSString *emoji)
{
    NSString *s = emoji.length ? emoji : @"🌐";
    NSFont *font = [NSFont fontWithName:@"Apple Color Emoji" size:34.0];
    if (!font) {
        font = [NSFont systemFontOfSize:34.0];
    }
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.alignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSParagraphStyleAttributeName: para,
    };
    NSStringDrawingOptions drawOpts = NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesDeviceMetrics;
    NSSize maxHint = NSMakeSize(120.0, 90.0);
    NSRect br = [s boundingRectWithSize:maxHint options:drawOpts attributes:attrs];
    CGFloat tw = MAX(32.0, ceil(NSWidth(br)));
    CGFloat th = MAX(28.0, ceil(NSHeight(br)));
    NSSize sz = NSMakeSize(tw + 12.0, th + 12.0);

    NSImage *image = [NSImage imageWithSize:sz flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
        [[NSColor clearColor] setFill];
        NSRectFill(rect);
        CGFloat x = floor((NSWidth(rect) - tw) * 0.5);
        CGFloat y = floor((NSHeight(rect) - th) * 0.5);
        NSRect drawR = NSMakeRect(x, y, tw, th);
        [s drawWithRect:drawR options:drawOpts attributes:attrs context:nil];
        return YES;
    }];
    image.template = NO;
    [image setSize:NSMakeSize(22.0, 18.0)];
    return image;
}

/// Same logic as `ipc_setFlagImageFromPNGData:countryCode:` — PNG first, then emoji raster.
static NSImage *IPCMBStatusFlagImageFromCountryCode(NSString *cc)
{
    NSData *png = IPCMBFetchFlagPNGData(cc);
    if (png.length > 24) {
        NSImage *img = [[NSImage alloc] initWithData:png];
        if (img && img.size.width > 4.0 && img.size.height > 2.0) {
            img.template = NO;
            [img setSize:NSMakeSize(22.0, 18.0)];
            return img;
        }
    }
    NSString *emoji = IPCMBFlagEmojiFromCountryCode(cc);
    if (!emoji.length) {
        emoji = @"🌐";
    }
    return IPCMBImageFromFlagEmojiLikePrefPane(emoji);
}

@interface AppDelegate () <NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSMenuItem *ipMenuItem;
@property (nonatomic, strong) NSMenuItem *detailMenuItem;
@property (nonatomic, strong) NSMenuItem *stopRotationMenuItem;
/// Avoid refetching flagcdn for the same country on every timer tick.
@property (nonatomic, copy) NSString *resolvedFlagCountryCode;
@property (nonatomic, strong) NSImage *resolvedFlagImage;
@property (nonatomic, copy) NSString *flagFetchPendingCC;
@property (nonatomic, assign) NSInteger flagFetchGeneration;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSButton *btn = self.statusItem.button;
    btn.image = IPCMBImageFromFlagEmojiLikePrefPane(@"🌐");
    btn.imagePosition = NSImageOnly;
    btn.title = @"";

    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;

    self.ipMenuItem = [[NSMenuItem alloc] initWithTitle:@"IP: —" action:NULL keyEquivalent:@""];
    self.ipMenuItem.enabled = NO;

    self.detailMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];
    self.detailMenuItem.enabled = NO;
    self.detailMenuItem.hidden = YES;

    [menu addItem:self.ipMenuItem];
    [menu addItem:self.detailMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *m;
    m = [menu addItemWithTitle:@"Reload from IP Changer" action:@selector(reloadFromSharedState) keyEquivalent:@"r"];
    m.target = self;

    m = [menu addItemWithTitle:@"Open IP Changer Settings…" action:@selector(openSystemSettingsForIPChanger) keyEquivalent:@"s"];
    m.target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    self.stopRotationMenuItem = [menu addItemWithTitle:@"Stop rotation" action:@selector(stopRotationFromMenu:) keyEquivalent:@""];
    self.stopRotationMenuItem.target = self;
    self.stopRotationMenuItem.enabled = NO;

    m = [menu addItemWithTitle:@"Quit IP Changer Menu" action:@selector(quit) keyEquivalent:@"q"];
    m.target = self;

    self.statusItem.menu = menu;

    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    [dnc addObserver:self selector:@selector(reloadFromSharedState) name:@"com.philodi.ipchanger.ExitIdentityChanged" object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [dnc addObserver:self selector:@selector(ipc_handleRotationStart:) name:IPCRotationStartNotification object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [dnc addObserver:self selector:@selector(ipc_handleRotationStop:) name:IPCRotationStopNotification object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

    [self reloadFromSharedState];
    __weak typeof(self) wself = self;
    self.pollTimer = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        [wself reloadFromSharedState];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)dealloc
{
    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    [dnc removeObserver:self name:@"com.philodi.ipchanger.ExitIdentityChanged" object:nil];
    [dnc removeObserver:self name:IPCRotationStartNotification object:nil];
    [dnc removeObserver:self name:IPCRotationStopNotification object:nil];
}

- (void)menuWillOpen:(NSMenu *)menu
{
    [self reloadFromSharedState];
}

/// Reads shared plist; flag matches pref pane: flagcdn PNG, else same emoji raster as `ipc_imageFromFlagEmoji:`.
- (void)reloadFromSharedState
{
    NSString *path = IPCMBSharedExitIdentityPath();
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];

    NSString *ip = @"";
    NSString *cc = @"";
    NSString *country = @"";
    NSString *city = @"";
    BOOL ok = NO;

    if ([plist isKindOfClass:[NSDictionary class]]) {
        ok = [plist[@"ok"] boolValue];
        id q = plist[@"query"];
        ip = ([q isKindOfClass:[NSString class]]) ? (NSString *)q : @"";
        id c = plist[@"countryCode"];
        cc = ([c isKindOfClass:[NSString class]]) ? (NSString *)c : @"";
        id co = plist[@"country"];
        country = ([co isKindOfClass:[NSString class]]) ? (NSString *)co : @"";
        id ci = plist[@"city"];
        city = ([ci isKindOfClass:[NSString class]]) ? (NSString *)ci : @"";
    }

    NSButton *barBtn = self.statusItem.button;
    barBtn.imagePosition = NSImageOnly;
    barBtn.title = @"";

    NSString *ccNorm = (cc.length == 2) ? cc.uppercaseString : @"";
    if (ok && ccNorm.length == 2) {
        if ([self.resolvedFlagCountryCode isEqualToString:ccNorm] && self.resolvedFlagImage) {
            barBtn.image = self.resolvedFlagImage;
        } else if ([self.flagFetchPendingCC isEqualToString:ccNorm]) {
            // PNG fetch in flight for this country; keep interim image.
        } else {
            NSString *ccUpper = ccNorm;
            self.flagFetchPendingCC = ccUpper;
            NSInteger gen = ++self.flagFetchGeneration;
            NSString *emojiNow = IPCMBFlagEmojiFromCountryCode(ccUpper);
            if (!emojiNow.length) {
                emojiNow = @"🌐";
            }
            barBtn.image = IPCMBImageFromFlagEmojiLikePrefPane(emojiNow);

            __weak typeof(self) wself = self;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSImage *img = IPCMBStatusFlagImageFromCountryCode(ccUpper);
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(wself) s = wself;
                    if (!s) return;
                    if (gen != s.flagFetchGeneration) return;
                    s.resolvedFlagCountryCode = ccUpper;
                    s.resolvedFlagImage = img;
                    s.flagFetchPendingCC = nil;
                    s.statusItem.button.image = img;
                });
            });
        }
    } else {
        self.resolvedFlagCountryCode = nil;
        self.resolvedFlagImage = nil;
        self.flagFetchPendingCC = nil;
        self.flagFetchGeneration += 1;
        barBtn.image = IPCMBImageFromFlagEmojiLikePrefPane(@"🌐");
    }

    self.ipMenuItem.title = ip.length ? [NSString stringWithFormat:@"IP: %@", ip] : @"IP: —";

    NSMutableString *detail = [NSMutableString string];
    if (city.length && country.length) {
        [detail appendFormat:@"%@, %@", city, country];
    } else if (country.length) {
        [detail appendString:country];
    } else if (!ok && ip.length) {
        [detail appendString:@"Geo unavailable (check Tor SOCKS in IP Changer)"];
    }
    if (detail.length) {
        self.detailMenuItem.title = [detail copy];
        self.detailMenuItem.hidden = NO;
    } else {
        self.detailMenuItem.title = @"";
        self.detailMenuItem.hidden = YES;
    }

    NSMutableString *tip = [NSMutableString string];
    if (ip.length) [tip appendFormat:@"IP: %@", ip];
    if (ok && country.length) {
        if (tip.length) [tip appendString:@"\n"];
        [tip appendString:country];
        if (city.length) [tip appendFormat:@" — %@", city];
    } else if (ip.length && !ok) {
        if (tip.length) [tip appendString:@"\n"];
        [tip appendString:@"Open IP Changer for Tor exit details."];
    }
    if (!tip.length) {
        [tip appendString:@"Open IP Changer in System Settings — exit identity appears after the pane refreshes."];
    }
    self.statusItem.button.toolTip = [tip copy];

    if (self.stopRotationMenuItem) {
        self.stopRotationMenuItem.enabled = IPCRotationStateReadActive();
    }
}

- (void)ipc_handleRotationStart:(NSNotification *)notification
{
    NSDictionary *info = notification.userInfo;
    NSInteger interval = [info[@"interval"] integerValue];
    NSInteger times = [info[@"times"] integerValue];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [[IPCTorRotationEngine sharedEngine] runBackgroundRotationIntervalSeconds:interval times:times];
    });
}

- (void)ipc_handleRotationStop:(NSNotification *)notification
{
    (void)notification;
    [[IPCTorRotationEngine sharedEngine] requestStop];
}

- (void)stopRotationFromMenu:(id)sender
{
    (void)sender;
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:IPCRotationStopNotification object:nil userInfo:nil deliverImmediately:YES];
}

- (void)openSystemSettingsForIPChanger
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *homePP = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/PreferencePanes/ipchanger.prefPane"];
    NSString *sysPP = @"/Library/PreferencePanes/ipchanger.prefPane";
    NSURL *paneURL = nil;
    if ([fm fileExistsAtPath:homePP]) {
        paneURL = [NSURL fileURLWithPath:homePP isDirectory:YES];
    } else if ([fm fileExistsAtPath:sysPP]) {
        paneURL = [NSURL fileURLWithPath:sysPP isDirectory:YES];
    }

    if (paneURL && [[NSWorkspace sharedWorkspace] openURL:paneURL]) {
        return;
    }

    NSURL *scheme = [NSURL URLWithString:@"x-apple.systempreferences:com.philodi.ipchanger"];
    if ([[NSWorkspace sharedWorkspace] openURL:scheme]) {
        return;
    }

    NSURL *settingsApp = [NSURL fileURLWithPath:@"/System/Applications/System Settings.app" isDirectory:YES];
    [[NSWorkspace sharedWorkspace] openURL:settingsApp];
}

- (void)quit
{
    [NSApp terminate:nil];
}

@end

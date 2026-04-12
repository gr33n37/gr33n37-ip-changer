//
//  ipchanger.m
//  ipchanger
//
//  Tor IP rotation — mirrors ip-changer.sh / README usage on macOS.
//

#import "ipchanger.h"
#import "IPCTorRotationEngine.h"
#import <AppKit/AppKit.h>
#import <Network/Network.h>

static NSString * const kTorSOCKSHost = @"127.0.0.1";
static const in_port_t kTorSOCKSPort = 9050;

@interface ipchanger ()
@property (nonatomic, strong) NSStackView *rootStack;
@property (nonatomic, strong) NSTextField *intervalField;
@property (nonatomic, strong) NSTextField *timesField;
@property (nonatomic, strong) NSButton *startButton;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSTextField *ipCaptionLabel;
@property (nonatomic, strong) NSTextField *ipValueField;
@property (nonatomic, strong) NSTextField *countryNameField;
@property (nonatomic, strong) NSTextField *regionNameField;
@property (nonatomic, strong) NSTextField *cityNameField;
@property (nonatomic, strong) NSTextField *ispNameField;
@property (nonatomic, strong) NSTextField *torCircuitField;
@property (nonatomic, strong) NSImageView *flagImageView;
@property (nonatomic, strong) NSTextField *statInternetVal;
@property (nonatomic, strong) NSTextField *statTorVal;
@property (nonatomic, strong) NSTextField *statSOCKSVal;
@property (nonatomic, strong) NSTextField *statRotationVal;
@property (nonatomic, strong) NSTextField *hintField;

@property (nonatomic, assign) BOOL didBuildPreferencesUI;
@property (nonatomic, assign) NSInteger uiNilMainViewRetries;

@property (nonatomic, assign) nw_path_monitor_t pathMonitor;
@property (atomic, assign) BOOL internetPathSatisfied;

@property (nonatomic, strong) NSTimer *logPurgeTimer;
@end

static void IPCRunOnBackground(dispatch_block_t block);
static void IPCRunOnMain(dispatch_block_t block);

@implementation ipchanger

#pragma mark - Lifecycle

- (instancetype)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    return self;
}

- (NSView *)loadMainView
{
    NSView *root = [super loadMainView];
    [self layoutRootStackInMainView];
    return root;
}

- (void)mainViewDidLoad
{
    [super mainViewDidLoad];
    [self buildPreferencesUIIfNeeded];
    [self layoutRootStackInMainView];
    [self scheduleStatsRefresh];
    [self ipc_startTorLogPurgeTimerIfNeeded];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(ipc_rotationStateExternallyChanged:) name:IPCRotationStateChangedNotification object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
}

- (void)ipc_rotationStateExternallyChanged:(NSNotification *)notification
{
    IPCRunOnMain(^{
        [self refreshConnectivityStats];
    });
}

/// Ensures the menu bar agent is running so it can receive rotation start/stop notifications.
- (void)ipc_launchMenuBarIfNeeded
{
    NSString *bid = @"com.philodi.ipchanger.menubar";
    NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bid];
    if (!url) {
        NSString *u = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/IPChangerMenuBar.app"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:u]) {
            url = [NSURL fileURLWithPath:u isDirectory:YES];
        }
    }
    if (!url && [[NSFileManager defaultManager] fileExistsAtPath:@"/Applications/IPChangerMenuBar.app"]) {
        url = [NSURL fileURLWithPath:@"/Applications/IPChangerMenuBar.app" isDirectory:YES];
    }
    if (url) {
        NSWorkspaceOpenConfiguration *cfg = [[NSWorkspaceOpenConfiguration alloc] init];
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:url configuration:cfg completionHandler:nil];
    }
}

- (void)willSelect
{
    [super willSelect];
    [self buildPreferencesUIIfNeeded];
    [self layoutRootStackInMainView];
    [self scheduleStatsRefresh];
}

- (void)didSelect
{
    [super didSelect];
    [self layoutRootStackInMainView];
    [self scheduleStatsRefresh];
}

/// Builds controls once. Uses Auto Layout from `mainView` so NSStackView / grids get a real width and lay out
/// vertically (frame-only layout + NSBox broke intrinsic heights and caused overlapping views).
- (void)buildPreferencesUIIfNeeded
{
    if (self.didBuildPreferencesUI) return;

    NSView *v = self.mainView;
    if (!v) {
        if (self.uiNilMainViewRetries < 30) {
            self.uiNilMainViewRetries += 1;
            dispatch_async(dispatch_get_main_queue(), ^{ [self buildPreferencesUIIfNeeded]; });
        }
        return;
    }
    self.uiNilMainViewRetries = 0;
    self.didBuildPreferencesUI = YES;

    v.autoresizesSubviews = YES;

    self.intervalField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.intervalField.translatesAutoresizingMaskIntoConstraints = NO;

    self.timesField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.timesField.placeholderString = @"0";
    self.timesField.translatesAutoresizingMaskIntoConstraints = NO;

    self.startButton = [NSButton buttonWithTitle:@"Start" target:self action:@selector(startRotation:)];
    self.startButton.bezelStyle = NSBezelStyleRounded;
    self.startButton.controlSize = NSControlSizeLarge;
    self.startButton.keyEquivalent = @"\r";

    self.stopButton = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopRotation:)];
    self.stopButton.bezelStyle = NSBezelStyleRounded;
    self.stopButton.controlSize = NSControlSizeLarge;
    self.stopButton.enabled = NO;

    NSStackView *buttonRow = [NSStackView stackViewWithViews:@[ self.startButton, self.stopButton ]];
    buttonRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttonRow.spacing = 14.0;
    buttonRow.alignment = NSLayoutAttributeCenterY;

    NSStackView *rotationInner = [NSStackView stackViewWithViews:@[
        [self intervalRow],
        [self timesRow],
        buttonRow,
    ]];
    rotationInner.orientation = NSUserInterfaceLayoutOrientationVertical;
    rotationInner.alignment = NSLayoutAttributeLeading;
    rotationInner.spacing = 14.0;
    NSView *rotSection = [self ipc_sectionStackTitle:@"Rotation" content:rotationInner];

    self.ipCaptionLabel = [NSTextField labelWithString:@"Exit IP address"];
    self.ipCaptionLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    self.ipCaptionLabel.textColor = [NSColor secondaryLabelColor];

    self.ipValueField = [NSTextField labelWithString:@"—"];
    self.ipValueField.font = [NSFont monospacedSystemFontOfSize:17.0 weight:NSFontWeightSemibold];
    self.ipValueField.textColor = [NSColor labelColor];

    self.flagImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.flagImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.flagImageView.imageAlignment = NSImageAlignCenter;
    self.flagImageView.editable = NO;
    [self ipc_setFlagEmoji:@"🌐"];

    self.countryNameField = [NSTextField labelWithString:@"—"];
    self.countryNameField.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightMedium];
    self.countryNameField.textColor = [NSColor labelColor];

    NSTextField *countryHdr = [NSTextField labelWithString:@"Country"];
    countryHdr.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    countryHdr.textColor = [NSColor secondaryLabelColor];

    self.regionNameField = [NSTextField labelWithString:@"—"];
    self.regionNameField.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightMedium];
    self.regionNameField.textColor = [NSColor labelColor];
    NSTextField *regionHdr = [NSTextField labelWithString:@"Region"];
    regionHdr.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    regionHdr.textColor = [NSColor secondaryLabelColor];

    self.cityNameField = [NSTextField labelWithString:@"—"];
    self.cityNameField.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightMedium];
    self.cityNameField.textColor = [NSColor labelColor];
    NSTextField *cityHdr = [NSTextField labelWithString:@"City"];
    cityHdr.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    cityHdr.textColor = [NSColor secondaryLabelColor];

    self.ispNameField = [NSTextField wrappingLabelWithString:@"—"];
    self.ispNameField.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular];
    self.ispNameField.textColor = [NSColor labelColor];
    self.ispNameField.preferredMaxLayoutWidth = 380.0;
    NSTextField *ispHdr = [NSTextField labelWithString:@"ISP"];
    ispHdr.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    ispHdr.textColor = [NSColor secondaryLabelColor];

    NSStackView *flagTextCol = [NSStackView stackViewWithViews:@[
        countryHdr, self.countryNameField,
        regionHdr, self.regionNameField,
        cityHdr, self.cityNameField,
        ispHdr, self.ispNameField,
    ]];
    flagTextCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    flagTextCol.spacing = 2.0;
    flagTextCol.alignment = NSLayoutAttributeLeading;

    NSStackView *flagRow = [NSStackView stackViewWithViews:@[ self.flagImageView, flagTextCol ]];
    flagRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    flagRow.spacing = 18.0;
    flagRow.alignment = NSLayoutAttributeTop;

    [self.flagImageView.widthAnchor constraintEqualToConstant:56.0].active = YES;
    [self.flagImageView.heightAnchor constraintEqualToConstant:40.0].active = YES;

    NSTextField *torCircuitHdr = [NSTextField labelWithString:@"Tor circuit (guard → middle → exit)"];
    torCircuitHdr.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    torCircuitHdr.textColor = [NSColor secondaryLabelColor];

    self.torCircuitField = [NSTextField wrappingLabelWithString:@"—"];
    self.torCircuitField.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    self.torCircuitField.textColor = [NSColor labelColor];
    self.torCircuitField.preferredMaxLayoutWidth = 480.0;
    [self.torCircuitField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

    NSStackView *exitInner = [NSStackView stackViewWithViews:@[
        self.ipCaptionLabel,
        self.ipValueField,
        flagRow,
        torCircuitHdr,
        self.torCircuitField,
    ]];
    exitInner.orientation = NSUserInterfaceLayoutOrientationVertical;
    exitInner.alignment = NSLayoutAttributeLeading;
    exitInner.spacing = 10.0;
    NSView *exitSection = [self ipc_sectionStackTitle:@"Exit identity" content:exitInner];

    self.statInternetVal = [self ipc_statValueField];
    self.statTorVal = [self ipc_statValueField];
    self.statSOCKSVal = [self ipc_statValueField];
    self.statRotationVal = [self ipc_statValueField];
    NSGridView *statusGrid = [self ipc_statusGrid];
    NSView *statusSection = [self ipc_sectionStackTitle:@"Connection status" content:statusGrid];

    NSTextField *info = [NSTextField wrappingLabelWithString:@"Traffic must use the Tor SOCKS proxy at 127.0.0.1:9050. Turn off VPNs and iCloud Private Relay to match the exit IP shown here. Tor can be installed with Homebrew when prompted."];
    info.font = [NSFont systemFontOfSize:11.0];
    info.textColor = [NSColor secondaryLabelColor];
    info.preferredMaxLayoutWidth = 480.0;
    [info setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

    self.hintField = [NSTextField wrappingLabelWithString:@""];
    self.hintField.font = [NSFont systemFontOfSize:11.0];
    self.hintField.textColor = [NSColor systemOrangeColor];
    self.hintField.preferredMaxLayoutWidth = 480.0;

    NSBox *sep1 = [self ipc_separatorLine];
    NSBox *sep2 = [self ipc_separatorLine];
    NSBox *sep3 = [self ipc_separatorLine];

    NSStackView *form = [NSStackView stackViewWithViews:@[
        rotSection,
        sep1,
        exitSection,
        sep2,
        statusSection,
        sep3,
        info,
        self.hintField,
    ]];
    form.orientation = NSUserInterfaceLayoutOrientationVertical;
    form.alignment = NSLayoutAttributeLeading;
    form.spacing = 22.0;
    form.edgeInsets = NSEdgeInsetsMake(4, 0, 8, 0);
    form.translatesAutoresizingMaskIntoConstraints = NO;
    [form setCustomSpacing:28.0 afterView:rotSection];
    [form setCustomSpacing:28.0 afterView:exitSection];
    [form setCustomSpacing:28.0 afterView:statusSection];

    [v addSubview:form];
    self.rootStack = form;

    static const CGFloat kSide = 26.0;
    static const CGFloat kVert = 22.0;
    [NSLayoutConstraint activateConstraints:@[
        [form.topAnchor constraintEqualToAnchor:v.topAnchor constant:kVert],
        [form.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:kSide],
        [form.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-kSide],
    ]];
    NSLayoutConstraint *bottomPin = [form.bottomAnchor constraintLessThanOrEqualToAnchor:v.bottomAnchor constant:-kVert];
    bottomPin.priority = NSLayoutPriorityDefaultHigh;
    bottomPin.active = YES;

    [self startInternetPathMonitorIfNeeded];
}

/// Clears files under canonical Tor *log* folders every few seconds (Homebrew paths). Does not touch Tor data/state dirs.
- (void)ipc_startTorLogPurgeTimerIfNeeded
{
    if (self.logPurgeTimer) {
        return;
    }
    static const NSTimeInterval kIPCLogPurgeIntervalSeconds = 5.0;
    __weak typeof(self) weakSelf = self;
    self.logPurgeTimer = [NSTimer timerWithTimeInterval:kIPCLogPurgeIntervalSeconds repeats:YES block:^(NSTimer *timer) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self) {
                [self ipc_purgeTorInstallLogFiles];
            }
        });
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.logPurgeTimer forMode:NSRunLoopCommonModes];
}

- (void)ipc_purgeTorInstallLogFiles
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *dirs = @[
        @"/opt/homebrew/var/log/tor",
        @"/usr/local/var/log/tor",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Tor"],
    ];
    for (NSString *dir in dirs) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
            continue;
        }
        NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in entries) {
            if ([name hasPrefix:@"."]) {
                continue;
            }
            NSString *path = [dir stringByAppendingPathComponent:name];
            BOOL isSubdir = NO;
            if (![fm fileExistsAtPath:path isDirectory:&isSubdir]) {
                continue;
            }
            if (isSubdir) {
                continue;
            }
            NSError *err = nil;
            if (![fm removeItemAtPath:path error:&err]) {
                [[NSData data] writeToFile:path options:NSDataWritingAtomic error:nil];
            }
        }
    }
}

- (void)dealloc
{
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self name:IPCRotationStateChangedNotification object:nil];
    [self.logPurgeTimer invalidate];
    self.logPurgeTimer = nil;
    if (_pathMonitor) {
        nw_path_monitor_cancel(_pathMonitor);
        _pathMonitor = NULL;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)startInternetPathMonitorIfNeeded
{
    if (self.pathMonitor) return;

    nw_path_monitor_t mon = nw_path_monitor_create();
    nw_path_monitor_set_queue(mon, dispatch_get_main_queue());
    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_update_handler(mon, ^(nw_path_t path) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.internetPathSatisfied = (nw_path_get_status(path) == nw_path_status_satisfied);
        [self refreshConnectivityStats];
    });
    nw_path_monitor_start(mon);
    self.pathMonitor = mon;
}

- (void)layoutRootStackInMainView
{
    NSView *v = self.mainView;
    if (!v) return;
    [v setNeedsLayout:YES];
    [v layoutSubtreeIfNeeded];
}

#pragma mark - UI builders

- (NSView *)intervalRow
{
    NSTextField *lab = [NSTextField wrappingLabelWithString:@"Interval in seconds (0 = no wait):"];
    lab.alignment = NSTextAlignmentRight;
    lab.font = [NSFont systemFontOfSize:12.0];
    lab.preferredMaxLayoutWidth = 228.0;
    [lab setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.intervalField.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
    self.intervalField.placeholderString = @"0";
    NSStackView *row = [NSStackView stackViewWithViews:@[ lab, self.intervalField ]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 12.0;
    row.alignment = NSLayoutAttributeCenterY;
    row.distribution = NSStackViewDistributionFill;
    [lab.widthAnchor constraintEqualToConstant:232.0].active = YES;
    [self.intervalField.widthAnchor constraintEqualToConstant:88.0].active = YES;
    [self.intervalField setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return row;
}

- (NSView *)timesRow
{
    NSTextField *lab = [NSTextField wrappingLabelWithString:@"Times to change IP (0 = unlimited):"];
    lab.alignment = NSTextAlignmentRight;
    lab.font = [NSFont systemFontOfSize:12.0];
    lab.preferredMaxLayoutWidth = 220.0;
    [lab setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *row = [NSStackView stackViewWithViews:@[ lab, self.timesField ]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 12.0;
    row.alignment = NSLayoutAttributeCenterY;
    row.distribution = NSStackViewDistributionFill;
    [lab.widthAnchor constraintEqualToConstant:232.0].active = YES;
    [self.timesField.widthAnchor constraintEqualToConstant:88.0].active = YES;
    self.timesField.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
    [self.timesField setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return row;
}

- (NSImageView *)ipc_symbolView:(NSString *)symbolName
{
    NSImage *img = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
    iv.image = img;
    iv.imageScaling = NSImageScaleProportionallyDown;
    if (@available(macOS 11.0, *)) {
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightSemibold];
        iv.symbolConfiguration = cfg;
    }
    iv.contentTintColor = [NSColor secondaryLabelColor];
    [iv.widthAnchor constraintEqualToConstant:22.0].active = YES;
    [iv.heightAnchor constraintEqualToConstant:20.0].active = YES;
    return iv;
}

- (NSTextField *)ipc_mutedLabel:(NSString *)text
{
    NSTextField *t = [NSTextField labelWithString:text];
    t.font = [NSFont systemFontOfSize:12.0];
    t.textColor = [NSColor secondaryLabelColor];
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    return t;
}

- (NSTextField *)ipc_statValueField
{
    NSTextField *f = [NSTextField labelWithString:@"—"];
    f.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    f.textColor = [NSColor labelColor];
    f.alignment = NSTextAlignmentRight;
    f.lineBreakMode = NSLineBreakByTruncatingTail;
    [f setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [f.widthAnchor constraintGreaterThanOrEqualToConstant:112.0].active = YES;
    return f;
}

- (NSStackView *)ipc_sectionStackTitle:(NSString *)title content:(NSView *)content
{
    NSTextField *head = [NSTextField labelWithString:title];
    head.font = [NSFont boldSystemFontOfSize:13.0];
    head.textColor = [NSColor labelColor];
    NSStackView *stack = [NSStackView stackViewWithViews:@[ head, content ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 12.0;
    stack.alignment = NSLayoutAttributeLeading;
    stack.edgeInsets = NSEdgeInsetsMake(2, 0, 4, 0);
    return stack;
}

- (NSBox *)ipc_separatorLine
{
    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;
    return sep;
}

- (NSGridView *)ipc_statusGrid
{
    NSGridView *g = [NSGridView gridViewWithViews:@[
        @[ [self ipc_symbolView:@"network"], [self ipc_mutedLabel:@"Internet"], self.statInternetVal ],
        @[ [self ipc_symbolView:@"lock.shield"], [self ipc_mutedLabel:@"Tor process"], self.statTorVal ],
        @[ [self ipc_symbolView:@"cable.connector"], [self ipc_mutedLabel:@"SOCKS port 9050"], self.statSOCKSVal ],
        @[ [self ipc_symbolView:@"arrow.triangle.2.circlepath"], [self ipc_mutedLabel:@"IP rotation"], self.statRotationVal ],
    ]];
    g.rowSpacing = 12.0;
    g.columnSpacing = 14.0;
    for (NSInteger row = 0; row < 4; row++) {
        for (NSInteger col = 0; col < 3; col++) {
            NSGridCell *cell = [g cellAtColumnIndex:col rowIndex:row];
            cell.yPlacement = NSGridCellPlacementCenter;
            cell.xPlacement = (col == 2) ? NSGridCellPlacementTrailing : NSGridCellPlacementLeading;
        }
    }
    return g;
}

- (void)ipc_setFlagEmoji:(NSString *)emoji
{
    self.flagImageView.image = [self ipc_imageFromFlagEmoji:emoji];
}

/// Loads a country flag bitmap over Tor (pref panes often render regional-indicator emoji as a blank/globe).
- (void)ipc_setFlagImageFromPNGData:(nullable NSData *)png countryCode:(NSString *)cc
{
    if (png.length > 24) {
        NSImage *img = [[NSImage alloc] initWithData:png];
        if (img && img.size.width > 4.0 && img.size.height > 2.0) {
            img.template = NO;
            self.flagImageView.image = img;
            return;
        }
    }
    [self ipc_setFlagEmoji:[self flagEmojiForISO:cc]];
}

/// Rasterizes emoji for NSImageView. Uses boundingRect + drawWithRect so regional-indicator flags size correctly.
- (NSImage *)ipc_imageFromFlagEmoji:(NSString *)emoji
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

    // flipped:NO matches normal AppKit text coordinates; flipped:YES often clips emoji to “empty” / white in small views.
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
    return image;
}

#pragma mark - Actions

- (void)startRotation:(id)sender
{
    self.hintField.stringValue = @"";

    if (IPCRotationStateReadActive()) {
        self.hintField.stringValue = @"Rotation is already running in the background. Use Stop to end.";
        return;
    }

    NSInteger intervalSeconds = [self.intervalField.stringValue integerValue];
    NSInteger times = [self.timesField.stringValue integerValue];
    if (intervalSeconds < 0) {
        self.hintField.stringValue = @"Interval cannot be negative. Use 0 for no pause between changes.";
        return;
    }
    if (times < 0) {
        self.hintField.stringValue = @"Times cannot be negative. Use 0 for unlimited rotations.";
        return;
    }

    NSString *brew = [[IPCTorRotationEngine sharedEngine] brewPath];
    if (!brew) {
        self.hintField.stringValue = @"Homebrew not found. Install from https://brew.sh/ then reopen System Settings.";
        return;
    }

    [self ipc_launchMenuBarIfNeeded];
    NSDictionary *info = @{ @"interval": @(intervalSeconds), @"times": @(times) };
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:IPCRotationStartNotification object:nil userInfo:info deliverImmediately:YES];

    self.hintField.stringValue = @"Rotation runs in IP Changer (menu bar). Closing System Settings does not stop it — use Stop here or in the menu bar.";
    [self refreshConnectivityStats];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshConnectivityStats];
    });
}

- (void)stopRotation:(id)sender
{
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:IPCRotationStopNotification object:nil userInfo:nil deliverImmediately:YES];
    self.hintField.stringValue = @"";
    [self refreshConnectivityStats];
}

- (void)ipc_applyExitIdentitySnapshot:(NSDictionary *)snap
{
    NSDictionary *s = snap ?: @{};

    id tcirc = s[@"torCircuit"];
    if ([tcirc isKindOfClass:[NSString class]] && [(NSString *)tcirc length]) {
        self.torCircuitField.stringValue = (NSString *)tcirc;
    }

    if ([s[@"ok"] boolValue]) {
        NSString *q = s[@"query"];
        self.ipValueField.stringValue = ([q isKindOfClass:[NSString class]] && q.length) ? q : @"—";
        NSString *country = s[@"country"];
        self.countryNameField.stringValue = ([country isKindOfClass:[NSString class]] && country.length) ? country : @"—";
        NSString *region = s[@"region"];
        self.regionNameField.stringValue = ([region isKindOfClass:[NSString class]] && region.length) ? region : @"—";
        NSString *city = s[@"city"];
        self.cityNameField.stringValue = ([city isKindOfClass:[NSString class]] && city.length) ? city : @"—";
        NSString *isp = s[@"isp"];
        self.ispNameField.stringValue = ([isp isKindOfClass:[NSString class]] && isp.length) ? isp : @"—";
        NSString *cc = [s[@"countryCode"] isKindOfClass:[NSString class]] ? s[@"countryCode"] : @"";
        NSData *png = [s[@"flagPNG"] isKindOfClass:[NSData class]] ? s[@"flagPNG"] : nil;
        [self ipc_setFlagImageFromPNGData:png countryCode:cc];
    } else {
        NSString *ip = [s[@"query"] isKindOfClass:[NSString class]] ? s[@"query"] : nil;
        if (ip.length) {
            self.ipValueField.stringValue = ip;
            self.countryNameField.stringValue = @"(Geo lookup failed — is Tor SOCKS up?)";
            self.regionNameField.stringValue = @"—";
            self.cityNameField.stringValue = @"—";
            self.ispNameField.stringValue = @"—";
        } else {
            self.ipValueField.stringValue = @"—";
            self.countryNameField.stringValue = @"—";
            self.regionNameField.stringValue = @"—";
            self.cityNameField.stringValue = @"—";
            self.ispNameField.stringValue = @"—";
        }
        [self ipc_setFlagEmoji:@"🌐"];
    }

    IPCWriteSharedExitIdentity(s);
}

- (void)refreshExitIdentity
{
    __weak typeof(self) weakSelf = self;
    IPCRunOnBackground(^{
        NSDictionary *snap = [[IPCTorRotationEngine sharedEngine] captureExitIdentitySnapshot];
        IPCRunOnMain(^{
            [weakSelf ipc_applyExitIdentitySnapshot:snap];
        });
    });
}

- (NSString *)flagEmojiForISO:(NSString *)iso
{
    if (iso.length < 2) return @"🌐";
    NSString *two = [[iso substringToIndex:2] uppercaseString];
    unichar a = [two characterAtIndex:0];
    unichar b = [two characterAtIndex:1];
    if (a < 'A' || a > 'Z' || b < 'A' || b > 'Z') return @"🌐";
    return [NSString stringWithFormat:@"%C%C",
        (unichar)(0x1F1E6 + (a - 'A')),
        (unichar)(0x1F1E6 + (b - 'A'))];
}

#pragma mark - Connectivity

- (void)scheduleStatsRefresh
{
    __weak typeof(self) weakSelf = self;
    IPCRunOnBackground(^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        __block NSString *circuitPath = nil;
        __block NSDictionary *snap = nil;
        dispatch_group_t grp = dispatch_group_create();
        dispatch_group_enter(grp);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            circuitPath = IPCTorControlCircuitPathDisplayString();
            dispatch_group_leave(grp);
        });
        dispatch_group_enter(grp);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            snap = [[IPCTorRotationEngine sharedEngine] captureExitIdentitySnapshot];
            dispatch_group_leave(grp);
        });
        dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);

        IPCRunOnMain(^{
            if (!self) return;
            self.torCircuitField.stringValue = circuitPath.length ? circuitPath : @"—";
            [self ipc_applyExitIdentitySnapshot:snap ?: @{}];
            [self refreshConnectivityStats];
        });
    });
}

- (void)refreshConnectivityStats
{
    BOOL inet = [self isInternetReachable];
    IPCTorRotationEngine *eng = [IPCTorRotationEngine sharedEngine];
    BOOL sock = [eng isPortOpen:kTorSOCKSHost port:kTorSOCKSPort];
    BOOL tor = [eng isTorProcessRunning];
    BOOL rotating = IPCRotationStateReadActive();

    self.statInternetVal.stringValue = inet ? @"Reachable" : @"Offline";
    self.statInternetVal.textColor = inet ? [NSColor systemGreenColor] : [NSColor systemRedColor];

    self.statTorVal.stringValue = tor ? @"Running" : @"Stopped";
    self.statTorVal.textColor = tor ? [NSColor systemGreenColor] : [NSColor systemOrangeColor];

    self.statSOCKSVal.stringValue = sock ? @"Reachable" : @"Closed";
    self.statSOCKSVal.textColor = sock ? [NSColor systemGreenColor] : [NSColor systemRedColor];

    if (rotating && !(tor && sock)) {
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:IPCRotationStopNotification object:nil userInfo:nil deliverImmediately:YES];
        rotating = NO;
        if (!self.hintField.stringValue.length) {
            self.hintField.stringValue = @"Tor or SOCKS went down during rotation; background loop was stopped. Start Tor, then press Start.";
        }
    }

    if (self.didBuildPreferencesUI) {
        self.startButton.enabled = !rotating;
        self.stopButton.enabled = rotating;
    }

    self.statRotationVal.stringValue = rotating ? @"Active" : @"Idle";
    self.statRotationVal.textColor = rotating ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor];

    [self.statInternetVal invalidateIntrinsicContentSize];
    [self.statTorVal invalidateIntrinsicContentSize];
    [self.statSOCKSVal invalidateIntrinsicContentSize];
    [self.statRotationVal invalidateIntrinsicContentSize];
    [self.rootStack invalidateIntrinsicContentSize];
    [self.mainView setNeedsLayout:YES];
    [self layoutRootStackInMainView];
}

- (BOOL)isInternetReachable
{
    return self.internetPathSatisfied;
}

#pragma mark - Utils

static void IPCRunOnBackground(dispatch_block_t block)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), block);
}

static void IPCRunOnMain(dispatch_block_t block)
{
    dispatch_async(dispatch_get_main_queue(), block);
}

@end

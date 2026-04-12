//
//  IPCTorRotationEngine.m
//  Shared Tor rotation + geo (menu bar runs loop; pref pane uses API).
//

#import "IPCTorRotationEngine.h"
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

NSString * const IPCRotationStartNotification = @"com.philodi.ipchanger.RotationStart";
NSString * const IPCRotationStopNotification = @"com.philodi.ipchanger.RotationStop";
NSString * const IPCRotationStateChangedNotification = @"com.philodi.ipchanger.RotationStateChanged";

static NSString * const kTorSOCKSHost = @"127.0.0.1";
static const in_port_t kTorSOCKSPort = 9050;
static const in_port_t kTorControlPort = 9051;

static NSString *IPCHexEncodeData(NSData *data)
{
    if (data.length == 0) return @"";
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *b = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02x", b[i]];
    }
    return hex;
}

static NSMutableString *IPCTorControlPayloadWithAuth(void)
{
    NSArray<NSString *> *cookiePaths = @[
        @"/opt/homebrew/var/lib/tor/control_auth_cookie",
        @"/usr/local/var/lib/tor/control_auth_cookie",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tor/control_auth_cookie"],
    ];

    NSData *cookie = nil;
    for (NSString *p in cookiePaths) {
        if ([[NSFileManager defaultManager] isReadableFileAtPath:p]) {
            cookie = [NSData dataWithContentsOfFile:p];
            if (cookie.length > 0) break;
        }
    }

    NSMutableString *payload = [NSMutableString string];
    if (cookie.length > 0) {
        [payload appendFormat:@"AUTHENTICATE %@\r\n", IPCHexEncodeData(cookie)];
    } else {
        [payload appendString:@"AUTHENTICATE \"\"\r\n"];
    }
    return payload;
}

/// Sends a full control script (must include AUTH) and returns the ASCII reply after Tor closes the connection.
static NSString *IPCTorControlExchange(NSString *payload, NSError **outError)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"ipchanger" code:100 userInfo:@{ NSLocalizedDescriptionKey: @"Could not open socket for Tor control port." }];
        }
        return nil;
    }

    struct timeval tv = { .tv_sec = 8, .tv_usec = 0 };
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, (socklen_t)sizeof(tv));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kTorControlPort);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        if (outError) {
            *outError = [NSError errorWithDomain:@"ipchanger" code:101 userInfo:@{ NSLocalizedDescriptionKey: @"Tor control port not reachable (127.0.0.1:9051). Enable ControlPort in torrc, or rotation will fall back to restarting the service." }];
        }
        return nil;
    }

    const char *bytes = payload.UTF8String;
    size_t len = strlen(bytes);
    if (send(fd, bytes, len, 0) < 0) {
        close(fd);
        if (outError) {
            *outError = [NSError errorWithDomain:@"ipchanger" code:102 userInfo:@{ NSLocalizedDescriptionKey: @"Failed to write to Tor control port." }];
        }
        return nil;
    }

    NSMutableData *accum = [NSMutableData data];
    char rbuf[8192];
    ssize_t n;
    while ((n = recv(fd, rbuf, (int)sizeof(rbuf), 0)) > 0) {
        [accum appendBytes:rbuf length:(NSUInteger)n];
    }
    close(fd);

    return [[NSString alloc] initWithData:accum encoding:NSUTF8StringEncoding] ?: @"";
}

/// Guard → middle → exit style names from a `GETINFO circuit-status` reply (first GENERAL circuit, else first BUILT).
static NSString *IPCParseCircuitPathFromTorReply(NSString *all)
{
    if (all.length == 0) return nil;
    NSArray<NSString *> *lines = [all componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSString *chosen = nil;
    for (NSString *line in lines) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([t containsString:@" BUILT "] && [t containsString:@"purpose=GENERAL"]) {
            chosen = t;
        }
    }
    if (!chosen) {
        for (NSString *line in lines) {
            NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([t containsString:@" BUILT "]) {
                chosen = t;
                break;
            }
        }
    }
    if (!chosen) return nil;

    NSArray<NSString *> *parts = [chosen componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *p in parts) {
        if (p.length) [tokens addObject:p];
    }

    BOOL pastBuilt = NO;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *tok in tokens) {
        if (!pastBuilt) {
            if ([tok isEqualToString:@"BUILT"]) pastBuilt = YES;
            continue;
        }
        if ([tok hasPrefix:@"purpose="] || [tok hasPrefix:@"TIME_CREATED="] || [tok hasPrefix:@"REASON="]) {
            break;
        }
        // Later KEY=value metadata without $ (avoid eating unknown pairs)
        NSRange eq = [tok rangeOfString:@"="];
        if (eq.location != NSNotFound && ![tok hasPrefix:@"$"] && [tok rangeOfString:@"~"].location == NSNotFound) {
            break;
        }

        NSString *disp = tok;
        NSRange tilde = [tok rangeOfString:@"~"];
        if (eq.location != NSNotFound && eq.location + 1 < tok.length) {
            disp = [tok substringFromIndex:eq.location + 1];
        } else if (tilde.location != NSNotFound && tilde.location + 1 < tok.length) {
            disp = [tok substringFromIndex:tilde.location + 1];
        } else if ([tok hasPrefix:@"$"] && tok.length > 8) {
            disp = [[[tok substringToIndex:MIN((NSUInteger)13, tok.length)] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"$"]] stringByAppendingString:@"…"];
        }
        if (disp.length) [names addObject:disp];
    }
    if (names.count == 0) return nil;
    return [names componentsJoinedByString:@" → "];
}

NSString *IPCTorControlCircuitPathDisplayString(void)
{
    NSMutableString *payload = IPCTorControlPayloadWithAuth();
    [payload appendString:@"GETINFO circuit-status\r\nQUIT\r\n"];
    NSError *err = nil;
    NSString *all = IPCTorControlExchange([payload copy], &err);
    if (all.length == 0) return nil;
    if ([all containsString:@"515 Authentication failed"] || [all containsString:@"514 Authentication required"]) {
        return nil;
    }
    return IPCParseCircuitPathFromTorReply(all);
}

/// Asks Tor for a new circuit without `brew services restart` (no full process stop). Requires ControlPort + cookie in torrc.
static BOOL IPCSendTorNewnym(NSError **outError)
{
    NSMutableString *payload = IPCTorControlPayloadWithAuth();
    [payload appendString:@"SIGNAL NEWNYM\r\nQUIT\r\n"];

    NSString *all = IPCTorControlExchange([payload copy], outError);
    if (!all) return NO;

    if ([all containsString:@"515 Authentication failed"] || [all containsString:@"514 Authentication required"]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"ipchanger" code:103 userInfo:@{ NSLocalizedDescriptionKey: @"Tor control port rejected AUTHENTICATE (check cookie or ControlPort settings in torrc)." }];
        }
        return NO;
    }
    if ([all containsString:@"553"]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"ipchanger" code:105 userInfo:@{ NSLocalizedDescriptionKey: @"Tor rate-limits NEWNYM; wait a bit or use a longer interval." }];
        }
        return NO;
    }
    if ([all containsString:@"552"] || [all containsString:@"Unrecognized signal"]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"ipchanger" code:104 userInfo:@{ NSLocalizedDescriptionKey: @"Tor rejected SIGNAL NEWNYM on this build." }];
        }
        return NO;
    }

    NSUInteger pos = 0;
    NSInteger okCount = 0;
    while (pos < all.length) {
        NSRange r = [all rangeOfString:@"250 OK" options:0 range:NSMakeRange(pos, all.length - pos)];
        if (r.location == NSNotFound) break;
        okCount += 1;
        pos = r.location + r.length;
    }
    if (okCount >= 2) {
        return YES;
    }

    if (outError) {
        *outError = [NSError errorWithDomain:@"ipchanger" code:106 userInfo:@{ NSLocalizedDescriptionKey: all.length ? all : @"No usable reply from Tor control port." }];
    }
    return NO;
}
static NSFileHandle *IPCNullOutput(void)
{
    static NSFileHandle *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = [NSFileHandle fileHandleForWritingAtPath:@"/dev/null"];
    });
    return handle;
}

NSString *IPCSharedExitIdentityPath(void)
{
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IPChanger"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"exit-identity.plist"];
}

void IPCWriteSharedExitIdentity(NSDictionary *snap)
{
    NSDictionary *s = snap ?: @{};
    NSMutableDictionary *plist = [NSMutableDictionary dictionary];
    plist[@"ok"] = @([s[@"ok"] boolValue]);
    for (NSString *k in @[ @"query", @"countryCode", @"country", @"region", @"city", @"isp" ]) {
        id v = s[k];
        plist[k] = ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) ? v : @"";
    }
    id tc = s[@"torCircuit"];
    if ([tc isKindOfClass:[NSString class]] && [(NSString *)tc length]) {
        plist[@"torCircuit"] = tc;
    }
    plist[@"updated"] = [NSDate date];
    NSString *path = IPCSharedExitIdentityPath();
    (void)[plist writeToURL:[NSURL fileURLWithPath:path isDirectory:NO] atomically:YES];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.philodi.ipchanger.ExitIdentityChanged" object:nil userInfo:nil deliverImmediately:YES];
}

NSString *IPCRotationStatePath(void)
{
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IPChanger"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"rotation-state.plist"];
}

BOOL IPCRotationStateReadActive(void)
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:IPCRotationStatePath()];
    return d != nil && [d[@"active"] boolValue];
}

void IPCRotationStateWrite(BOOL active, NSString * _Nullable circuit)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"active"] = @(active);
    if (circuit.length) {
        d[@"circuit"] = [circuit copy];
    }
    d[@"updated"] = [NSDate date];
    (void)[d writeToURL:[NSURL fileURLWithPath:IPCRotationStatePath() isDirectory:NO] atomically:YES];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:IPCRotationStateChangedNotification object:nil userInfo:nil deliverImmediately:YES];
}

@interface IPCTorRotationEngine ()
@property (atomic, assign) BOOL backgroundLoopRunning;
@end

@implementation IPCTorRotationEngine

+ (instancetype)sharedEngine
{
    static IPCTorRotationEngine *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[IPCTorRotationEngine alloc] init]; });
    return s;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _workerShouldStop = YES;
    }
    return self;
}

- (void)runBackgroundRotationIntervalSeconds:(NSInteger)intervalSeconds times:(NSInteger)times
{
    if (self.backgroundLoopRunning) {
        return;
    }
    self.backgroundLoopRunning = YES;

    NSError *err = nil;
    if (![self ensureTorInstalled:&err]) {
        IPCRotationStateWrite(NO, nil);
        self.backgroundLoopRunning = NO;
        return;
    }
    if (![self startTorIfNeeded:&err]) {
        IPCRotationStateWrite(NO, nil);
        self.backgroundLoopRunning = NO;
        return;
    }

    NSInteger remaining = times;
    BOOL unlimited = (times == 0);

    self.workerShouldStop = NO;
    IPCRotationStateWrite(YES, nil);

    while (!self.workerShouldStop) {
        if (![self rotateTorCircuit:&err]) {
            (void)[self startTorIfNeeded:&err];
            if (self.workerShouldStop) {
                break;
            }
            [self interruptibleSleep:2];
        }

        [self interruptibleSleep:1];

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
            snap = [self captureExitIdentitySnapshot];
            dispatch_group_leave(grp);
        });
        dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);

        NSMutableDictionary *merged = [(snap ?: @{}) mutableCopy];
        if (circuitPath.length) {
            merged[@"torCircuit"] = circuitPath;
        }
        IPCWriteSharedExitIdentity([merged copy]);
        IPCRotationStateWrite(YES, circuitPath.length ? circuitPath : nil);

        if (!unlimited) {
            remaining -= 1;
            if (remaining <= 0 || self.workerShouldStop) {
                break;
            }
        }

        NSInteger sleepSec = intervalSeconds;
        if (sleepSec > 0) {
            [self interruptibleSleep:sleepSec];
        }
        if (self.workerShouldStop) {
            break;
        }
    }

    self.workerShouldStop = YES;
    IPCRotationStateWrite(NO, nil);
    self.backgroundLoopRunning = NO;
}

- (void)requestStop
{
    self.workerShouldStop = YES;
    IPCRotationStateWrite(NO, nil);
}

- (nullable NSString *)brewPath
{
    NSArray<NSString *> *candidates = @[
        @"/opt/homebrew/bin/brew",
        @"/usr/local/bin/brew",
    ];
    for (NSString *p in candidates) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

- (BOOL)ensureTorInstalled:(NSError **)outError
{
    NSString *brew = [self brewPath];
    NSString *check = [NSString stringWithFormat:@"\"%@\" list --formula | /usr/bin/grep -q '^tor$'", brew];
    int code = [self runBashReturnCode:check];
    if (code == 0) return YES;

    NSString *install = [NSString stringWithFormat:@"\"%@\" install tor", brew];
    NSError *err = nil;
    (void)[self runBash:install error:&err];
    if (err || ![self runBashReturnCode:check]) {
        if (outError) *outError = [NSError errorWithDomain:@"ipchanger" code:2 userInfo:@{ NSLocalizedDescriptionKey: @"Installing Tor via brew failed. Run `brew install tor` in Terminal." }];
        return NO;
    }
    return YES;
}

- (BOOL)startTorIfNeeded:(NSError **)outError
{
    if ([self isTorProcessRunning]) return YES;

    NSString *brew = [self brewPath];
    NSString *cmd = [NSString stringWithFormat:@"\"%@\" services start tor", brew];
    NSError *err = nil;
    (void)[self runBash:cmd error:&err];
    [self interruptibleSleep:3];
    if (![self isTorProcessRunning]) {
        if (outError) *outError = [NSError errorWithDomain:@"ipchanger" code:3 userInfo:@{ NSLocalizedDescriptionKey: @"Tor did not start. Try: brew services start tor" }];
        return NO;
    }
    return YES;
}

- (BOOL)rotateTorCircuit:(NSError **)outError
{
    // Prefer Tor control port NEWNYM: new exit IP without stopping the whole daemon (faster, no SOCKS drop).
    NSError *ctrlErr = nil;
    if (IPCSendTorNewnym(&ctrlErr)) {
        return YES;
    }

    NSString *brew = [self brewPath];
    if (!brew) {
        if (outError) *outError = ctrlErr;
        return NO;
    }
    NSString *cmd = [NSString stringWithFormat:@"\"%@\" services restart tor", brew];
    NSError *err = nil;
    (void)[self runBash:cmd error:&err];
    if (err) {
        if (outError) {
            NSString *msg = [NSString stringWithFormat:@"%@ (Falling back after control port: %@)", err.localizedDescription, ctrlErr.localizedDescription ?: @"n/a"];
            *outError = [NSError errorWithDomain:err.domain code:err.code userInfo:@{ NSLocalizedDescriptionKey: msg }];
        }
        return NO;
    }
    return YES;
}

- (BOOL)isTorProcessRunning
{
    NSString *out = [self runBash:@"/usr/bin/pgrep -x tor || true" error:NULL];
    return out.length > 0;
}

- (nullable NSString *)runBash:(NSString *)command error:(NSError **)outError
{
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    task.arguments = @[ @"-lc", command ];

    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"PATH"] = @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    task.environment = env;

    @try {
        [task launch];
    } @catch (NSException *ex) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"ipchanger" code:1 userInfo:@{ NSLocalizedDescriptionKey: ex.reason ?: @"task failed" }];
        }
        return nil;
    }

    [task waitUntilExit];

    NSData *so = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    NSData *se = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
    NSString *sout = [[NSString alloc] initWithData:so encoding:NSUTF8StringEncoding] ?: @"";
    if (task.terminationStatus != 0 && outError) {
        NSString *serr = [[NSString alloc] initWithData:se encoding:NSUTF8StringEncoding] ?: @"";
        *outError = [NSError errorWithDomain:@"ipchanger" code:(int)task.terminationStatus userInfo:@{ NSLocalizedDescriptionKey: serr.length ? serr : sout }];
    }
    return sout;
}

- (int)runBashReturnCode:(NSString *)command
{
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    task.arguments = @[ @"-lc", command ];
    task.standardOutput = IPCNullOutput();
    task.standardError = IPCNullOutput();

    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"PATH"] = @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    task.environment = env;

    @try {
        [task launch];
        [task waitUntilExit];
        return (int)task.terminationStatus;
    } @catch (NSException *ex) {
        return -1;
    }
}

#pragma mark - Curl / geo

- (nullable NSString *)curlSOCKS:(NSString *)url UTF8:(BOOL)utf8
{
    NSMutableArray *args = [NSMutableArray arrayWithObjects:
        @"-s", @"--connect-timeout", @"6", @"-m", @"10",
        @"--socks5-hostname", [NSString stringWithFormat:@"%@:%u", kTorSOCKSHost, kTorSOCKSPort],
        url,
        nil];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/curl"];
    task.arguments = args;

    NSPipe *stdoutPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = IPCNullOutput();

    @try {
        [task launch];
    } @catch (NSException *ex) {
        return nil;
    }
    [task waitUntilExit];
    NSData *data = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    if (utf8) {
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
}

- (nullable NSData *)curlSOCKSData:(NSString *)url
{
    NSMutableArray *args = [NSMutableArray arrayWithObjects:
        @"-s", @"--connect-timeout", @"6", @"-m", @"12",
        @"--socks5-hostname", [NSString stringWithFormat:@"%@:%u", kTorSOCKSHost, kTorSOCKSPort],
        url,
        nil];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/curl"];
    task.arguments = args;

    NSPipe *stdoutPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = IPCNullOutput();

    @try {
        [task launch];
    } @catch (NSException *ex) {
        return nil;
    }
    [task waitUntilExit];
    return [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
}

/// Runs on a worker thread: geo JSON + flag PNG (parallel-friendly when called with circuit fetch).
- (NSDictionary *)captureExitIdentitySnapshot
{
    NSString *json = [self curlSOCKS:@"http://ip-api.com/json/?fields=status,message,query,country,countryCode,city,regionName,isp" UTF8:YES];
    if (json.length) {
        NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([dict isKindOfClass:[NSDictionary class]] && [dict[@"status"] isEqualToString:@"success"]) {
            NSString *cc = [dict[@"countryCode"] isKindOfClass:[NSString class]] ? dict[@"countryCode"] : @"";
            NSMutableDictionary *snap = [NSMutableDictionary dictionary];
            snap[@"query"] = dict[@"query"] ?: @"";
            snap[@"country"] = dict[@"country"] ?: @"";
            snap[@"region"] = [dict[@"regionName"] isKindOfClass:[NSString class]] ? dict[@"regionName"] : @"";
            snap[@"city"] = [dict[@"city"] isKindOfClass:[NSString class]] ? dict[@"city"] : @"";
            snap[@"isp"] = [dict[@"isp"] isKindOfClass:[NSString class]] ? dict[@"isp"] : @"";
            snap[@"countryCode"] = cc;
            if (cc.length == 2) {
                NSData *png = [self curlSOCKSData:[NSString stringWithFormat:@"https://flagcdn.com/w80/%@.png", cc.lowercaseString]];
                if (png.length > 24) snap[@"flagPNG"] = png;
            }
            snap[@"ok"] = @YES;
            return snap;
        }
    }

    NSMutableDictionary *snap = [NSMutableDictionary dictionary];
    snap[@"ok"] = @NO;
    NSString *plain = [self curlSOCKS:@"https://checkip.amazonaws.com" UTF8:YES];
    NSString *ip = [[plain stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    if (ip.length) snap[@"query"] = ip;
    return snap;
}

- (BOOL)isPortOpen:(NSString *)host port:(in_port_t)port
{
    NSString *p = [NSString stringWithFormat:@"%u", port];
    NSString *cmd = [NSString stringWithFormat:@"/usr/bin/nc -z -G 1 %@ %@ >/dev/null 2>&1", host, p];
    return [self runBashReturnCode:cmd] == 0;
}

- (void)interruptibleSleep:(NSInteger)seconds
{
    for (NSInteger i = 0; i < seconds && !self.workerShouldStop; i++) {
        usleep(1000000);
    }
}

@end

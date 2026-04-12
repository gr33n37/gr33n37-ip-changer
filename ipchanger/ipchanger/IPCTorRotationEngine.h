//
//  IPCTorRotationEngine.h
//  Shared Tor rotation (background worker runs in IPChangerMenuBar; pref pane sends start/stop).
//

#import <Foundation/Foundation.h>

extern NSString * const IPCRotationStartNotification;
extern NSString * const IPCRotationStopNotification;
extern NSString * const IPCRotationStateChangedNotification;

FOUNDATION_EXPORT NSString *IPCSharedExitIdentityPath(void);
FOUNDATION_EXPORT void IPCWriteSharedExitIdentity(NSDictionary *snap);
FOUNDATION_EXPORT NSString *IPCRotationStatePath(void);
FOUNDATION_EXPORT BOOL IPCRotationStateReadActive(void);
FOUNDATION_EXPORT void IPCRotationStateWrite(BOOL active, NSString * _Nullable circuit);

/// Tor circuit line for the pref pane stats refresh (same GETINFO path as the engine).
FOUNDATION_EXPORT NSString * _Nullable IPCTorControlCircuitPathDisplayString(void);

@interface IPCTorRotationEngine : NSObject

+ (instancetype)sharedEngine;

@property (atomic, assign) BOOL workerShouldStop;

/// Block until the loop finishes; call only from a private background queue.
- (void)runBackgroundRotationIntervalSeconds:(NSInteger)intervalSeconds times:(NSInteger)times;

- (void)requestStop;

- (nullable NSString *)brewPath;
- (BOOL)ensureTorInstalled:(NSError **)outError;
- (BOOL)startTorIfNeeded:(NSError **)outError;
- (BOOL)rotateTorCircuit:(NSError **)outError;
- (BOOL)isTorProcessRunning;
- (nullable NSString *)runBash:(NSString *)command error:(NSError **)outError;
- (int)runBashReturnCode:(NSString *)command;
- (nullable NSString *)curlSOCKS:(NSString *)url UTF8:(BOOL)utf8;
- (nullable NSData *)curlSOCKSData:(NSString *)url;
- (NSDictionary *)captureExitIdentitySnapshot;
- (void)interruptibleSleep:(NSInteger)seconds;
- (BOOL)isPortOpen:(NSString *)host port:(uint16_t)port;

@end

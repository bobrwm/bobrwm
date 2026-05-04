#import "shim.h"
#import <AppKit/AppKit.h>

// ---------------------------------------------------------------------------
// KVO context tokens.
// ---------------------------------------------------------------------------
static void *kBWFinishedLaunchingCtx = &kBWFinishedLaunchingCtx;
static void *kBWActivationPolicyCtx  = &kBWActivationPolicyCtx;

// ---------------------------------------------------------------------------
// Per-app KVO helper that defers the app-launched event until the process
// is both finished launching AND has a Regular activation policy.
//
// Electron apps (VS Code, Slack, Discord) fire
// NSWorkspaceDidLaunchApplicationNotification before their accessibility
// server is ready. Some Electron helper processes also start as
// NSApplicationActivationPolicyProhibited and transition to Regular later.
// Gating on both conditions avoids wasting retry budget on premature AX
// observer registration and catches late policy transitions.
// ---------------------------------------------------------------------------
@class BWLaunchGate;

/// Active launch gates kept alive until both KVO conditions are met.
/// Access is main-thread-only (NSWorkspace notifications are delivered there).
static NSMutableDictionary<NSNumber *, BWLaunchGate *> *sLaunchGates;

@interface BWLaunchGate : NSObject
@property (strong) NSRunningApplication *app;
@property (assign) BOOL observingLaunch;
@property (assign) BOOL observingPolicy;
@end

@implementation BWLaunchGate

- (instancetype)initWithApp:(NSRunningApplication *)app
           needsLaunchGate:(BOOL)needsLaunchGate
           needsPolicyGate:(BOOL)needsPolicyGate {
  self = [super init];
  if (self) {
    _app = app;
    if (needsLaunchGate) {
      _observingLaunch = YES;
      [app addObserver:self
            forKeyPath:@"isFinishedLaunching"
               options:NSKeyValueObservingOptionNew
               context:kBWFinishedLaunchingCtx];
    }
    if (needsPolicyGate) {
      _observingPolicy = YES;
      [app addObserver:self
            forKeyPath:@"activationPolicy"
               options:NSKeyValueObservingOptionNew
               context:kBWActivationPolicyCtx];
    }
  }
  return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
  if (context == kBWFinishedLaunchingCtx) {
    // isFinishedLaunching transitioned — check if both conditions are met.
  } else if (context == kBWActivationPolicyCtx) {
    // activationPolicy transitioned — check if both conditions are met.
  } else {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    return;
  }

  NSRunningApplication *app = (NSRunningApplication *)object;
  if (!app.isFinishedLaunching) return;
  if (app.activationPolicy != NSApplicationActivationPolicyRegular) return;

  pid_t pid = app.processIdentifier;
  bw_workspace_app_launched(pid);

  // Both conditions met — remove KVO and drop the dictionary entry.
  [self removeAllObservers];
  [sLaunchGates removeObjectForKey:@(pid)];
}

- (void)removeAllObservers {
  if (_observingLaunch) {
    [_app removeObserver:self forKeyPath:@"isFinishedLaunching" context:kBWFinishedLaunchingCtx];
    _observingLaunch = NO;
  }
  if (_observingPolicy) {
    [_app removeObserver:self forKeyPath:@"activationPolicy" context:kBWActivationPolicyCtx];
    _observingPolicy = NO;
  }
}

- (void)dealloc {
  [self removeAllObservers];
}

@end

// NSWorkspace observer
@interface BWObserver : NSObject
@end

@implementation BWObserver

- (void)appLaunched:(NSNotification *)note {
  NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
  pid_t pid = app.processIdentifier;

  BOOL launched = app.isFinishedLaunching;
  BOOL regular  = app.activationPolicy == NSApplicationActivationPolicyRegular;

  if (launched && regular) {
    bw_workspace_app_launched(pid);
    return;
  }

  // One or both conditions not met — install KVO gate(s).
  if (!sLaunchGates) {
    sLaunchGates = [NSMutableDictionary new];
  }
  NSNumber *key = @(pid);
  if (sLaunchGates[key]) return; // already waiting
  BWLaunchGate *gate = [[BWLaunchGate alloc] initWithApp:app
                                        needsLaunchGate:!launched
                                        needsPolicyGate:!regular];
  sLaunchGates[key] = gate;
}

- (void)appTerminated:(NSNotification *)note {
  NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
  pid_t pid = app.processIdentifier;

  // Discard any pending launch gate for this process.
  [sLaunchGates removeObjectForKey:@(pid)];

  bw_workspace_app_terminated(pid);
}

- (void)spaceChanged:(NSNotification *)note {
  (void)note;
  bw_workspace_space_changed();
}

- (void)displayChanged:(NSNotification *)note {
  (void)note;
  bw_workspace_display_changed();
}

- (void)activeAppChanged:(NSNotification *)note {
  NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
  if (app) {
    bw_workspace_active_app_changed(app.processIdentifier);
  }
}

@end

// Status bar

@interface BWStatusBarDelegate : NSObject
- (void)retile:(id)sender;
- (void)quit:(id)sender;
@end

@implementation BWStatusBarDelegate

- (void)retile:(id)sender {
  (void)sender;
  bw_retile();
}

- (void)quit:(id)sender {
  (void)sender;
  bw_will_quit();
  [NSApp terminate:nil];
}

@end

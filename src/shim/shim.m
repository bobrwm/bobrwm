#import "shim.h"
#import <AppKit/AppKit.h>

// ---------------------------------------------------------------------------
// KVO context token for isFinishedLaunching observation.
// ---------------------------------------------------------------------------
static void *kBWFinishedLaunchingCtx = &kBWFinishedLaunchingCtx;

// ---------------------------------------------------------------------------
// Per-app KVO helper that waits for isFinishedLaunching == YES before
// emitting the app-launched event.  Electron apps (VS Code, Slack, Discord)
// fire NSWorkspaceDidLaunchApplicationNotification well before their
// accessibility server is ready.  Gating on isFinishedLaunching avoids
// wasting retry budget on premature AX observer registration attempts.
// ---------------------------------------------------------------------------
@class BWLaunchGate;

/// Active launch gates kept alive until the KVO fires.
/// Access is main-thread-only (NSWorkspace notifications are delivered there).
static NSMutableDictionary<NSNumber *, BWLaunchGate *> *sLaunchGates;

@interface BWLaunchGate : NSObject
@property (strong) NSRunningApplication *app;
@end

@implementation BWLaunchGate

- (instancetype)initWithApp:(NSRunningApplication *)app {
  self = [super init];
  if (self) {
    _app = app;
    [app addObserver:self
          forKeyPath:@"isFinishedLaunching"
             options:NSKeyValueObservingOptionNew
             context:kBWFinishedLaunchingCtx];
  }
  return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
  if (context != kBWFinishedLaunchingCtx) {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    return;
  }

  NSRunningApplication *app = (NSRunningApplication *)object;
  if (!app.isFinishedLaunching) return;

  pid_t pid = app.processIdentifier;
  bw_workspace_app_launched(pid);

  // One-shot: remove KVO and drop the dictionary entry that kept us alive.
  [app removeObserver:self forKeyPath:@"isFinishedLaunching" context:kBWFinishedLaunchingCtx];
  [sLaunchGates removeObjectForKey:@(pid)];
}

- (void)dealloc {
  // Safety: if the gate is deallocated before the app finishes launching
  // (e.g. app crashed during startup), remove the KVO to avoid a dangling
  // observer.  removeObserver:forKeyPath:context: is idempotent when the
  // observer is already removed.
  @try {
    [_app removeObserver:self forKeyPath:@"isFinishedLaunching" context:kBWFinishedLaunchingCtx];
  } @catch (NSException *) {
    // Already removed — nothing to do.
  }
}

@end

// NSWorkspace observer
@interface BWObserver : NSObject
@end

@implementation BWObserver

- (void)appLaunched:(NSNotification *)note {
  NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
  pid_t pid = app.processIdentifier;

  if (app.isFinishedLaunching) {
    bw_workspace_app_launched(pid);
    return;
  }

  // App is not ready yet — install a KVO gate.
  if (!sLaunchGates) {
    sLaunchGates = [NSMutableDictionary new];
  }
  NSNumber *key = @(pid);
  if (sLaunchGates[key]) return; // already waiting
  BWLaunchGate *gate = [[BWLaunchGate alloc] initWithApp:app];
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

#import <AppKit/AppKit.h>
#import "shim.h"

// ---------------------------------------------------------------------------
// Accessibility
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// NSWorkspace observer
// ---------------------------------------------------------------------------

@interface BWObserver : NSObject
@end

@implementation BWObserver

- (void)appLaunched:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    pid_t pid = app.processIdentifier;
    bw_workspace_app_launched(pid);
}

- (void)appTerminated:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    bw_workspace_app_terminated(app.processIdentifier);
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

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

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

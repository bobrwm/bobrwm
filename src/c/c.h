// Aggregated C headers translated by build.zig (b.addTranslateC) and
// imported as `@import("c")`.
//
// We deliberately exclude the ApplicationServices/CoreGraphics umbrella
// headers because Aro (the new translate-c backend in Zig 0.16) cannot
// parse Apple's blocks syntax (`void (^Foo)(...)`) used in CGPath.h,
// CGPDF*.h, CGImage-adjacent headers, and several CoreServices
// sub-frameworks (Metadata, ATS, xpc).
//
// Symbols only declared in CGEvent.h / CGWindow.h (and therefore not
// translatable) are hand-written in `src/c/cg_extra.zig` and imported
// separately as `@import("cg_extra")`.

// Suppress umbrella and heavyweight CG headers by pre-defining their
// include guards. Aro fails on several sub-frameworks (ATS, ColorSync,
// Metadata, CGPath/CGImage blocks, xpc nullability, etc.) and we don't
// need their content. Each guard short-circuits a transitive include
// path that would otherwise drag those headers in.
#define __APPLICATIONSERVICES__
#define __CORESERVICES__
#define __CARBON__
#define __ATS__
#define __COLORSYNC__
#define __HISERVICES__
// CGRemoteOperation -> CGDirectDisplay -> CGContext -> CGImage -> CGPath.
// Killing CGDirectDisplay breaks that chain without losing the
// CGEventTapProxy/CGEventTapLocation typedefs we actually use.
#define CGDIRECTDISPLAY_H_
#define CGCONTEXT_H_
#define CGIMAGE_H_
#define CGPATH_H_
#define CGCOLORSPACE_H_
#define CGCOLOR_H_
#define CGGRADIENT_H_
#define CGPATTERN_H_
#define CGFONT_H_
#define CGDATAPROVIDER_H_
#define CGAFFINETRANSFORM_H_
// CFPlugInCOM, CFAttributedString etc. drag in unused CG bits via
// CFPlugIn. Block CFPlugIn entirely; we don't use it.
#define __COREFOUNDATION_CFPLUGIN__
#define __COREFOUNDATION_CFPLUGINCOM__
// mach/message.h has bit-field structs that Aro demotes to opaque,
// then C11 `_Static_assert` calls on their sizes are translated into
// `comptime { if (@sizeOf(opaque) != N) @compileError(...) }` which
// fail unconditionally. We don't reference any of these types from
// Zig, so neutralize the static assertions.
#define _Static_assert(...)

#include <CoreFoundation/CoreFoundation.h>

// CoreGraphics: include only sub-headers that Aro can fully parse.
#include <CoreGraphics/CGGeometry.h>
#include <CoreGraphics/CGError.h>
#include <CoreGraphics/CGEventTypes.h>
#include <CoreGraphics/CGWindowLevel.h>

// HIServices subframework of ApplicationServices: Accessibility (AX) APIs.
// Order matters because we suppress the ApplicationServices umbrella
// header above; each AX header would normally pick up its dependencies
// from the umbrella. AXError must be declared before AXUIElement.
#include <HIServices/AXError.h>
#include <HIServices/AXValue.h>
#include <HIServices/AXActionConstants.h>
#include <HIServices/AXAttributeConstants.h>
#include <HIServices/AXNotificationConstants.h>
#include <HIServices/AXRoleConstants.h>
#include <HIServices/AXUIElement.h>

#include <dispatch/dispatch.h>
#include <pthread.h>
#include <os/lock.h>
#include <unistd.h>

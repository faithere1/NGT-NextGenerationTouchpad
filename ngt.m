// NGT - Next Generation Touchpad
// Absolute trackpad mode: the trackpad surface maps to the whole screen,
// like a graphics tablet. Touch a spot -> cursor jumps to that spot.

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <os/lock.h>

// ---- Private MultitouchSupport.framework types (loaded at runtime) ----
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
    int frame;
    double timestamp;
    int identifier, state, fingerId, handId;
    MTVector normalized;   // 0..1, origin bottom-left
    float size;
    int zero1;
    float angle, majorAxis, minorAxis;
    MTVector mm;
    int zero2[2];
    float unk2;
} MTTouch;
typedef void *MTDeviceRef;
typedef int (*MTFrameCallback)(MTDeviceRef, MTTouch *, int, double, int);

// ---- Settings ----
static const double kEdgeMargin = 0.03;   // trackpad edges that map to screen edges
static const double kClickGrace = 0.35;   // seconds after lift to still pin clicks (tap-to-click)

// ---- Shared state (touch thread <-> event tap) ----
static _Atomic bool   gEnabled = true;
static _Atomic bool   gTouching = false;
static _Atomic double gX = 0, gY = 0;
static _Atomic double gLastTouch = 0;
static CGRect gBounds;                       // target screen, guarded by gBoundsLock
static os_unfair_lock gBoundsLock = OS_UNFAIR_LOCK_INIT;
static CFMachPortRef gTap;

static void setBounds(CGRect r) {
    os_unfair_lock_lock(&gBoundsLock);
    gBounds = r;
    os_unfair_lock_unlock(&gBoundsLock);
}

static CGRect getBounds(void) {
    os_unfair_lock_lock(&gBoundsLock);
    CGRect r = gBounds;
    os_unfair_lock_unlock(&gBoundsLock);
    return r;
}

static double remap(double v) {
    v = (v - kEdgeMargin) / (1.0 - 2.0 * kEdgeMargin);
    return v < 0 ? 0 : (v > 1 ? 1 : v);
}

static int onFrame(MTDeviceRef dev, MTTouch *t, int n, double ts, int frame) {
    // Only one finger positions the cursor; 2+ fingers = normal scroll/gestures.
    // State 3 = making touch, 4 = touching.
    if (!atomic_load(&gEnabled) || n != 1 || t[0].state < 3 || t[0].state > 4) {
        atomic_store(&gTouching, false);
        return 0;
    }
    CGRect b = getBounds();
    double x = b.origin.x + remap(t[0].normalized.pos.x) * (b.size.width - 1);
    double y = b.origin.y + (1.0 - remap(t[0].normalized.pos.y)) * (b.size.height - 1);

    double ox = atomic_load(&gX), oy = atomic_load(&gY);
    atomic_store(&gX, x);
    atomic_store(&gY, y);
    atomic_store(&gLastTouch, CFAbsoluteTimeGetCurrent());
    bool wasTouching = atomic_exchange(&gTouching, true);

    // Skip sub-pixel jitter to save work.
    if (wasTouching && fabs(x - ox) < 0.5 && fabs(y - oy) < 0.5) return 0;

    bool down = CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft);
    CGEventRef e = CGEventCreateMouseEvent(NULL, down ? kCGEventLeftMouseDragged : kCGEventMouseMoved,
                                           CGPointMake(x, y), kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    return 0;
}

// Pins every mouse event (from the trackpad's own relative motion) to the absolute point.
static CGEventRef onEvent(CGEventTapProxy p, CGEventType type, CGEventRef e, void *ctx) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(gTap, true);
        return e;
    }
    if (!atomic_load(&gEnabled)) return e;
    if (atomic_load(&gTouching) ||
        CFAbsoluteTimeGetCurrent() - atomic_load(&gLastTouch) < kClickGrace) {
        CGEventSetLocation(e, CGPointMake(atomic_load(&gX), atomic_load(&gY)));
    }
    return e;
}

static bool startMultitouch(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!h) return false;
    CFArrayRef (*createList)(void) = dlsym(h, "MTDeviceCreateList");
    void (*registerCb)(MTDeviceRef, MTFrameCallback) = dlsym(h, "MTRegisterContactFrameCallback");
    void (*start)(MTDeviceRef, int) = dlsym(h, "MTDeviceStart");
    if (!createList || !registerCb || !start) return false;

    CFArrayRef devs = createList();
    if (!devs || CFArrayGetCount(devs) == 0) return false;
    for (CFIndex i = 0; i < CFArrayGetCount(devs); i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(devs, i);
        registerCb(d, onFrame);
        start(d, 0);
    }
    return true;   // devs intentionally kept alive for app lifetime
}

static bool startEventTap(void) {
    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) |
                       CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
                       CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
                       CGEventMaskBit(kCGEventRightMouseDragged);
    gTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                            mask, onEvent, NULL);
    if (!gTap) return false;
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, gTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    CGEventTapEnable(gTap, true);
    return true;
}

// ---- Screen-switch banner (AirPods-style popup, top-right) ----
@interface Banner : NSObject
@property (strong) NSPanel *panel;
@property (strong) NSTextField *label;
@property (strong) NSTimer *hideTimer;
@end

@implementation Banner
- (instancetype)init {
    self = [super init];
    NSRect frame = NSMakeRect(0, 0, 300, 64);
    _panel = [[NSPanel alloc] initWithContentRect:frame
                                        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                          backing:NSBackingStoreBuffered defer:YES];
    _panel.level = NSStatusWindowLevel;
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = YES;
    _panel.ignoresMouseEvents = YES;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:frame];
    bg.material = NSVisualEffectMaterialPopover;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.state = NSVisualEffectStateActive;
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 16;
    bg.layer.masksToBounds = YES;
    _panel.contentView = bg;

    NSImageView *icon = [NSImageView imageViewWithImage:
        [NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:nil]];
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:26 weight:NSFontWeightRegular];
    icon.frame = NSMakeRect(16, 14, 36, 36);
    [bg addSubview:icon];

    _label = [NSTextField labelWithString:@""];
    _label.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    _label.frame = NSMakeRect(62, 22, 224, 20);
    [bg addSubview:_label];
    return self;
}

- (void)show:(NSString *)text onScreen:(NSScreen *)screen {
    self.label.stringValue = text;
    NSRect vf = screen.visibleFrame;
    NSSize s = self.panel.frame.size;
    [self.panel setFrameOrigin:NSMakePoint(NSMaxX(vf) - s.width - 12, NSMaxY(vf) - s.height - 12)];
    if (!self.panel.visible) self.panel.alphaValue = 0;
    [self.panel orderFrontRegardless];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
        c.duration = 0.15;
        self.panel.animator.alphaValue = 1;
    }];
    [self.hideTimer invalidate];
    self.hideTimer = [NSTimer scheduledTimerWithTimeInterval:1.8 target:self selector:@selector(hide)
                                                    userInfo:nil repeats:NO];
}

- (void)hide {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
        c.duration = 0.3;
        self.panel.animator.alphaValue = 0;
    } completionHandler:^{
        if (self.panel.alphaValue == 0) [self.panel orderOut:nil];   // not re-shown meanwhile
    }];
}
@end

// ---- Menu bar UI ----
static CGDirectDisplayID displayID(NSScreen *s) {
    return [s.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
}

@interface App : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *item;
@property (strong) NSMenuItem *toggle;
@property (strong) Banner *banner;
@property CGDirectDisplayID target;
- (void)cycleScreen:(int)dir;
@end

// Global hotkeys ⌃⌥→ / ⌃⌥← (Carbon: no extra permission, zero cost while idle).
static OSStatus onHotKey(EventHandlerCallRef h, EventRef e, void *ctx) {
    EventHotKeyID hk;
    GetEventParameter(e, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hk), NULL, &hk);
    [(__bridge App *)ctx cycleScreen:(hk.id == 1 ? 1 : -1)];
    return noErr;
}

@implementation App
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.banner = [Banner new];
    [self screensChanged];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screensChanged)
        name:NSApplicationDidChangeScreenParametersNotification object:nil];

    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(onHotKey, 1, &spec, (__bridge void *)self, NULL);
    EventHotKeyRef ref;
    RegisterEventHotKey(kVK_RightArrow, controlKey | optionKey, (EventHotKeyID){'NGT ', 1},
                        GetApplicationEventTarget(), 0, &ref);
    RegisterEventHotKey(kVK_LeftArrow, controlKey | optionKey, (EventHotKeyID){'NGT ', 2},
                        GetApplicationEventTarget(), 0, &ref);

    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.toggle = [[NSMenuItem alloc] initWithTitle:@"Tablet Mode" action:@selector(toggleMode) keyEquivalent:@""];
    self.toggle.target = self;
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;   // built lazily in menuNeedsUpdate:
    self.item.menu = menu;

    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    bool trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);

    if (!trusted || !startEventTap()) {
        [self fail:@"Grant Accessibility access to NGT (System Settings → Privacy & Security → Accessibility), then relaunch."];
        return;
    }
    if (!startMultitouch()) {
        [self fail:@"Could not access the trackpad."];
        return;
    }
    [self refresh];
}

- (void)menuNeedsUpdate:(NSMenu *)m {
    [m removeAllItems];
    [m addItem:self.toggle];
    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *hdr = [m addItemWithTitle:@"Screen" action:nil keyEquivalent:@""];
    hdr.enabled = NO;
    NSArray<NSScreen *> *screens = NSScreen.screens;
    for (NSUInteger i = 0; i < screens.count; i++) {
        NSMenuItem *it = [m addItemWithTitle:screens[i].localizedName action:@selector(pickScreen:) keyEquivalent:@""];
        it.target = self;
        it.tag = i;
        it.indentationLevel = 1;
        it.state = displayID(screens[i]) == self.target ? NSControlStateValueOn : NSControlStateValueOff;
    }
    NSString *right = [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
    NSMenuItem *next = [m addItemWithTitle:@"Next Screen" action:@selector(nextScreen) keyEquivalent:right];
    next.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    next.target = self;

    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:@"Quit NGT" action:@selector(terminate:) keyEquivalent:@"q"];
}

// Restore the saved screen (by ID, then by name); fall back to the main screen
// without overwriting the saved choice, so it comes back when re-plugged.
- (void)screensChanged {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    CGDirectDisplayID savedID = (CGDirectDisplayID)[d integerForKey:@"screenID"];
    NSString *savedName = [d stringForKey:@"screenName"];
    NSArray<NSScreen *> *screens = NSScreen.screens;

    NSScreen *pick = nil;
    for (NSScreen *s in screens) if (displayID(s) == savedID) { pick = s; break; }
    if (!pick && savedName)
        for (NSScreen *s in screens) if ([s.localizedName isEqualToString:savedName]) { pick = s; break; }
    if (!pick) pick = screens.firstObject;   // primary display
    if (!pick) return;

    bool changed = self.target != 0 && displayID(pick) != self.target;
    [self applyScreen:pick save:NO notify:changed];
}

- (void)applyScreen:(NSScreen *)s save:(bool)save notify:(bool)notify {
    self.target = displayID(s);
    setBounds(CGDisplayBounds(self.target));
    if (save) {
        [NSUserDefaults.standardUserDefaults setInteger:self.target forKey:@"screenID"];
        [NSUserDefaults.standardUserDefaults setObject:s.localizedName forKey:@"screenName"];
    }
    if (notify) [self.banner show:[@"Screen: " stringByAppendingString:s.localizedName] onScreen:s];
}

- (void)pickScreen:(NSMenuItem *)it {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if ((NSUInteger)it.tag < screens.count) [self applyScreen:screens[it.tag] save:YES notify:YES];
}

- (void)nextScreen { [self cycleScreen:1]; }

- (void)cycleScreen:(int)dir {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    NSInteger n = screens.count, cur = 0;
    if (n == 0) return;
    for (NSInteger i = 0; i < n; i++) if (displayID(screens[i]) == self.target) { cur = i; break; }
    [self applyScreen:screens[((cur + dir) % n + n) % n] save:YES notify:YES];
}

- (void)fail:(NSString *)msg {
    atomic_store(&gEnabled, false);
    self.item.button.title = @"NGT ⚠";
    self.toggle.title = msg;
    self.toggle.enabled = NO;
    self.toggle.action = nil;
}

- (void)toggleMode {
    atomic_store(&gEnabled, !atomic_load(&gEnabled));
    [self refresh];
}

- (void)refresh {
    bool on = atomic_load(&gEnabled);
    self.toggle.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    self.item.button.title = on ? @"NGT ●" : @"NGT ○";
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;   // no Dock icon
        App *d = [App new];
        app.delegate = d;
        [app run];
    }
    return 0;
}

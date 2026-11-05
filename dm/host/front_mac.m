// Mac front end: with DM_WINDOW=1 open a window (CAMetalLayer, for the graphics backend to present frames) + keyboard and controllers → dm_input; the guest runs on a large-stack thread instead and the main thread belongs to AppKit.
// Without DM_WINDOW: the guest runs directly on the current thread, behaving the same as with no front end (windowless tests use this).
// The window is fullscreen-capable (the green button and ⌃⌘F); DM_FULLSCREEN=1 starts it that way. ⌘Q quits; the left mouse button is the touchscreen.
// Key map (Nintendo layout): 1 = performance overlay mode, 2 = settings panel, WASD left stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR, F=press left stick G=press right stick, Return=+ Tab=−, Space=shake the controller.
// Controllers: face buttons as on the iPhone, by position (right A, bottom B, top X, left Y) or on a Nintendo pad by its labels (pad_apple.h), shoulders L R, triggers ZL ZR, Menu + Options −, both sticks and their presses.
// Each controller is a player of its own (local co-op): the first one connected is player 1, together with the keyboard, the next player 2, and so on up to 8 (pad_slots.h);
// DM_PAD_MERGE=1 merges every controller into player 1 instead, DM_KBD_PLAYER=own makes the keyboard player 1 on its own, with the controllers from player 2 on.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <GameController/GameController.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "hle.h"
#include "pad_slots.h"
#include "haptics_apple.h"
#include "motion_apple.h"
#include "motion_pro_mac.h"
#include "pad_apple.h"
#include <signal.h>
#include <math.h>
#include <sys/resource.h>
#include <mach/mach.h>

static CAMetalLayer *g_layer;
static uint64_t g_btn;
static int g_w, g_a, g_s, g_d;
static int g_input_on = 1;   // main thread: the game window is key, so its keyboard, mouse and controllers reach the game (input_release / input_resume)

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
static _Atomic int g_screen_fps;   // the window's screen's maximumFramesPerSecond, kept up to date when the window moves to another screen
int front_screen_max_fps(void) { return g_screen_fps; }
static _Atomic int g_fullscreen;   // the window is in fullscreen (set when it has entered and when it has left)
int front_fullscreen(void) { return g_fullscreen; }   // nvn_mtl.m link_latency: frame latency 2 in fullscreen
// The screen's refresh rate matched to the game's frame rate in fullscreen (front_screen_match, from PR #79; DM_SCREEN_MATCH=0 turns it off). 60 fps on a 144 Hz screen cannot be paced
// evenly: the display link counts a tick on the refresh nearest each 1/60 s slot (nvn_mtl.m link_range), so frames stay up 2 and 3 refreshes in turn (13.9 / 20.8 ms) and Apple's HUD shows
// the frame interval jumping between them. In fullscreen, a screen whose rate is not a multiple of the game's switches to the mode of the same size with the highest rate that is (144 → 120 Hz
// for 60 and 30 fps), for this app only: macOS switches it back when the host quits, crashes included, and leaving fullscreen or that screen switches it back at once. A window keeps the
// screen's rate, because the switch changes the whole screen for every app and most external screens go black for a second or more. A screen with no such mode keeps the virtual ticks
static NSWindow *g_win; static _Atomic int g_match_want;   // the game's window; the frame rate to match (0 = not known yet), written by the present thread only
static CGDirectDisplayID g_match_id; static CGDisplayModeRef g_match_orig;   // main thread: the screen this host switched and its own mode (NULL = none switched)
static double mode_hz(CGDisplayModeRef m) { double hz = CGDisplayModeGetRefreshRate(m); return hz > 0 ? hz : 0; }   // 0 = not known (older built-in screens report none)
static int hz_multiple(double hz, int fps) { double k = round(hz / fps); return k >= 1 && fabs(hz / fps - k) < 0.01; }   // 59.94 Hz counts as 60
static CGError screen_set_mode(CGDirectDisplayID id, CGDisplayModeRef m) {   // for this app only (kCGConfigureForAppOnly)
    CGDisplayConfigRef cfg; CGError r = CGBeginDisplayConfiguration(&cfg);
    if (r != kCGErrorSuccess) return r;
    r = CGConfigureDisplayWithDisplayMode(cfg, id, m, NULL);
    if (r != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return r; }
    return CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
}
static void screen_match_restore(int on_it) {   // main thread: the screen this host switched gets its own mode again; on_it: the window is on that screen
    double hz = mode_hz(g_match_orig); CGError r = screen_set_mode(g_match_id, g_match_orig);
    LOG("front end: screen %s %.0f Hz", r == kCGErrorSuccess ? "back at" : "could not be switched back to", hz);
    if (r == kCGErrorSuccess && on_it && hz > 0) g_screen_fps = (int)round(hz);
    CGDisplayModeRelease(g_match_orig); g_match_orig = NULL;
}
static void screen_match_apply(void) {   // main thread: on a new frame rate, on entering and leaving fullscreen and on a move to another screen
    static int off = -1; if (off < 0) { const char *e = getenv("DM_SCREEN_MATCH"); off = e && !strcmp(e, "0"); if (off) LOG("front end: the screen keeps its refresh rate in fullscreen too (DM_SCREEN_MATCH=0)"); }
    NSScreen *scr = g_win.screen; int want = g_match_want, full = (g_win.styleMask & NSWindowStyleMaskFullScreen) != 0;
    CGDirectDisplayID id = scr ? [scr.deviceDescription[@"NSScreenNumber"] unsignedIntValue] : kCGNullDirectDisplay;
    if (g_match_orig && (!full || id != g_match_id)) screen_match_restore(id == g_match_id);
    if (off || !full || want <= 0 || !scr) return;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(id);
    if (!cur) return;
    double hz = mode_hz(cur);
    if (hz <= 0 || hz_multiple(hz, want)) {   // already a multiple, or not known
        if (g_match_orig && hz > 0) g_screen_fps = (int)round(hz);   // the screen this host switched: its rate from the mode, which maximumFramesPerSecond (the screen observer) may not show yet
        CGDisplayModeRelease(cur); return;
    }
    size_t w = CGDisplayModeGetWidth(cur), h = CGDisplayModeGetHeight(cur), pw = CGDisplayModeGetPixelWidth(cur), ph = CGDisplayModeGetPixelHeight(cur);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(id, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES});
    CGDisplayModeRef pick = NULL; double pick_hz = 0;
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i); double r = mode_hz(m);
        if (CGDisplayModeGetWidth(m) != w || CGDisplayModeGetHeight(m) != h || CGDisplayModeGetPixelWidth(m) != pw || CGDisplayModeGetPixelHeight(m) != ph || !CGDisplayModeIsUsableForDesktopGUI(m)) continue;
        if (hz_multiple(r, want) && r > pick_hz) { pick = m; pick_hz = r; }
    }
    if (!pick) LOG("front end: screen at %.0f Hz has no mode of this size at a multiple of %d Hz: frames are paced on the nearest refreshes", hz, want);
    else {
        CGError r = screen_set_mode(id, pick);
        LOG("front end: screen at %.0f Hz %s %.0f Hz for %d fps in fullscreen (DM_SCREEN_MATCH=0 keeps it)", hz, r == kCGErrorSuccess ? "switched to" : "could not be switched to", pick_hz, want);
        if (r == kCGErrorSuccess) { if (!g_match_orig) { g_match_orig = CGDisplayModeRetain(cur); g_match_id = id; } g_screen_fps = (int)round(pick_hz); }
    }
    if (modes) CFRelease(modes);
    CGDisplayModeRelease(cur);
}
void front_screen_match(int fps) {
    if (!g_layer || g_match_want == fps) return;   // no window (a windowless run's main thread runs the guest), or the rate as before
    g_match_want = fps; dispatch_async(dispatch_get_main_queue(), ^{ screen_match_apply(); });
}
static void push(void) {
    int32_t lx = (g_d - g_a) * 32767, ly = (g_w - g_s) * 32767;
    dm_input_set(g_btn, lx, ly, 0, 0);
}
static int key_bit(unsigned short code) {
    switch (code) {
        case 38: return 0;  case 40: return 1;  case 32: return 2;  case 34: return 3;    // J K U I → A B X Y
        case 3: return 4;   case 5: return 5;                                            // F G → press stick
        case 12: return 6;  case 14: return 7;  case 6: return 8;   case 8: return 9;    // Q E Z C → L R ZL ZR
        case 36: return 10; case 48: return 11;                                          // Return Tab → + −
        case 123: return 12; case 126: return 13; case 124: return 14; case 125: return 15; // ← ↑ → ↓
    }
    return -1;
}
static void on_key(NSEvent *e, int down) {
    if (!g_input_on) return;
    unsigned short c = e.keyCode;
    switch (c) { case 13: g_w = down; break; case 0: g_a = down; break; case 1: g_s = down; break; case 2: g_d = down; break; }
    int b = key_bit(c);
    uint64_t m = b >= 0 ? 1ull << b : c == 49 ? DM_BTN_SHAKE : 0;   // Space: shaken while held
    g_btn = down ? (g_btn | m) : (g_btn & ~m);
    push();
}

// Physical controllers (GameController) go to dm_pad_set_player, mapped as the iPhone's (DmGamepad.m read_pad, same layout); player 1's is ORed with the keyboard, a stick takes
// whichever is deflected more (hle_hid.c). DM_KEYS uses player 1's path, so player 1's controller touched during a script takes it over.
// Players: every controller with an extended gamepad profile holds a slot (pad_slots.h: player 1 first, a reconnected controller gets its player back), and hle_hid.c reports
// player n on its own npad while the slot is held (dm_pad_players). A one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c).
// With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins; when the last one goes away its buttons and sticks are released)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge, g_kbd_own;
static int32_t pad_axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * DM_STICK_MAX); }
static void pad_read(GCExtendedGamepad *g) {
    if (!g_input_on) return;
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    uint64_t m = dm_pad_face(g);   // by position, a Nintendo pad by its labels
    #define K(btn, bit) if (btn.isPressed) m |= bit
    K(g.leftShoulder, DM_BTN_L); K(g.rightShoulder, DM_BTN_R); K(g.leftTrigger, DM_BTN_ZL); K(g.rightTrigger, DM_BTN_ZR);
    K(g.buttonMenu, DM_BTN_PLUS); K(g.buttonOptions, DM_BTN_MINUS); K(g.leftThumbstickButton, DM_BTN_LS); K(g.rightThumbstickButton, DM_BTN_RS);   // nil on pads without them: not pressed
    K(g.dpad.left, DM_BTN_LEFT); K(g.dpad.up, DM_BTN_UP); K(g.dpad.right, DM_BTN_RIGHT); K(g.dpad.down, DM_BTN_DOWN);
    #undef K
    dm_pad_set_player(p, m, pad_axis(g.leftThumbstick.xAxis.value), pad_axis(g.leftThumbstick.yAxis.value), pad_axis(g.rightThumbstick.xAxis.value), pad_axis(g.rightThumbstick.yAxis.value));
}
// Home and Capture: without this macOS takes them as system gestures (Home opens the Games app); the host gives them no function
static void pad_keep_system_buttons(GCController *c) { for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled; }
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static void pro_players_changed(GCController *gone) {
    int count = 0, player = -1;
    for (GCController *c in GCController.controllers) if (c != gone && c.extendedGamepad && [c.productCategory isEqualToString:@"Switch Pro Controller"]) {
        count++; player = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)c);
    }
    dm_motion_pro_players(count, player);
}
static void pro_devices_changed(void) { pro_players_changed(nil); }
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil on a connect)
static void pads_changed(GCController *gone) {
    if (g_merge) {
        int any = 0;
        for (GCController *c in GCController.controllers) if (c.extendedGamepad && c != gone) {
            any = 1; pad_keep_system_buttons(c); c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; pad_read(g); };
            dm_motion_attach(c, 0);   // every controller is player 1: the last one moved drives its six-axis sensor
            pad_read(c.extendedGamepad);
        }
        if (gone) dm_motion_detach(gone, 0);
        if (!any) { dm_pad_set(0, 0, 0, 0, 0); dm_haptics_apple_controller(0, nil); }
        pro_players_changed(gone);
        return;
    }
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        dm_motion_detach(g_held[p], p);
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_keep_system_buttons(c);
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; pad_read(g); };
        dm_motion_attach(c, p);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        pad_read(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
    pro_players_changed(gone);
}
// Focus: a window that is no longer key sees no key-up, mouse-up or controller release, so whatever is held when it loses focus (another app, the text box, minimized) would
// stay pressed in the game. The front end releases only what it pressed itself: scripted buttons and sticks have their own path, and the touch is also DM_KEYS / DM_CTL's (hle_hid.c).
// Out of focus a controller's changes are ignored, so back in focus each controller is read as it is now (a button still held, a stick still deflected)
static int g_mouse_down;   // the mouse holds the touch (DmGameView)
static void input_release(void) {
    g_input_on = 0;
    dm_motion_pro_active(0);
    g_btn = 0; g_w = g_a = g_s = g_d = 0; push();
    if (g_mouse_down) { g_mouse_down = 0; dm_touch_set(NULL, 0); }
    if (g_merge) { for (GCController *c in GCController.controllers) if (c.extendedGamepad) { dm_pad_set(0, 0, 0, 0, 0); break; } }
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
static void input_resume(void) {
    g_input_on = 1;
    dm_motion_pro_active(1);
    if (g_merge) { for (GCController *c in GCController.controllers) if (c.extendedGamepad) pad_read(c.extendedGamepad); }
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p].extendedGamepad) pad_read(g_held[p].extendedGamepad);
}
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    e = getenv("DM_KBD_PLAYER"); g_kbd_own = !g_merge && e && !strcmp(e, "own");
    static const char kbd = 0;
    if (g_kbd_own) pad_slot_take(&g_slots, &kbd, "keyboard");   // holds player 1 for good
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : g_kbd_own ? "the keyboard is player 1, each controller a player of its own from player 2 on (DM_KBD_PLAYER=own)"
                                                                           : "each controller is a player of its own, the keyboard plays with player 1");
    pads_changed(nil);
    dm_motion_pro_start(pro_devices_changed);
}

// Mouse as a single-point touchscreen (front.h dm_touch_set): left button down / drag = finger 0, release = lifted. The content view takes the clicks,
// not a window-wide event monitor, so clicks on the title bar, the window buttons and the resize edges still reach AppKit.
@interface DmGameView : NSView @end
@implementation DmGameView
- (void)mouseDown:(NSEvent *)e { [self mouseDragged:e]; }
- (void)mouseDragged:(NSEvent *)e {
    if (!g_input_on) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil]; NSSize b = self.bounds.size;
    double w = b.width, h = b.height;
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;   // the centered 16:9 picture the present fits into the view, as on the iPhone (DmGamepad.m)
    double x0 = (b.width - w) / 2, y0 = (b.height - h) / 2;
    dm_touch t = {0, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax(1 - (p.y - y0) / h, 0), 0.999)};   // The AppKit view origin is at bottom left, the touchscreen origin is at top left
    dm_touch_set(&t, 1); g_mouse_down = 1;
}
- (void)mouseUp:(NSEvent *)e { (void)e; if (g_mouse_down) { g_mouse_down = 0; dm_touch_set(NULL, 0); } }
// The drawable follows the view in pixels: a layer assigned to a layer-backed view kept the drawable at the first window's 1280x720 in fullscreen too, so the game picture was
// scaled down to it and up again by the compositor
- (void)fitDrawable {
    CAMetalLayer *l = (CAMetalLayer *)self.layer; if (![l isKindOfClass:CAMetalLayer.class] || !self.window) return;
    l.contentsScale = self.window.backingScaleFactor;
    NSSize px = [self convertSizeToBacking:self.bounds.size]; if (px.width < 1 || px.height < 1 || CGSizeEqualToSize(l.drawableSize, px)) return;
    l.drawableSize = px; LOG("front end: drawable %.0fx%.0f", px.width, px.height);
}
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self fitDrawable]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self fitDrawable]; }
@end

// Performance overlay: a small box in the window's top-right corner, refreshed twice a second. Key 1 cycles it: compact (frame rate + the game's resolution) → detailed (the frame-rate
// graph, frame time, GPU, CPU, memory, the game's pacing, the window's output size) → off → compact. DM_OVERLAY=compact | detailed | off picks the mode at start (default compact; the settings window writes it)
uint64_t mtl_cur_frame(void); double mtl_gpu_ms(uint64_t f); int nvn_game_fps(void); void nvn_game_size(int *w, int *h);
#define OV_N 60   // graph samples: 30 s
static int g_ov_mode = 1;   // 0 off, 1 compact, 2 detailed
@interface DmOverlay : NSView
@property(strong) NSTextField *label;
@end
@implementation DmOverlay {
    float _fps[OV_N]; int _n; uint64_t _f0; double _t0, _cpu0; NSString *_lines; double _fpsNow, _gpu;
}
- (instancetype)initWithFrame:(NSRect)r {
    if (!(self = [super initWithFrame:r])) return nil;
    self.wantsLayer = YES; self.layer.backgroundColor = [NSColor colorWithWhite:0.04 alpha:0.72].CGColor; self.layer.cornerRadius = 7;
    self.layer.borderWidth = 1; self.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.14].CGColor;
    self.label = [NSTextField labelWithString:@""]; self.label.maximumNumberOfLines = 0; [self addSubview:self.label];
    _t0 = CACurrentMediaTime(); _f0 = mtl_cur_frame(); _gpu = -1;
    __weak DmOverlay *w = self; [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { (void)t; [w tick]; }];
    return self;
}
- (NSView *)hitTest:(NSPoint)p { (void)p; return nil; }   // clicks go through to the game (the touchscreen)
static double cpu_seconds(void) { struct rusage u; getrusage(RUSAGE_SELF, &u); return u.ru_utime.tv_sec + u.ru_stime.tv_sec + (u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6; }
static double footprint_gb(void) { task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT; return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) == KERN_SUCCESS ? vi.phys_footprint / 1073741824.0 : 0; }
- (void)tick {
    double t = CACurrentMediaTime(), dt = t - _t0, cpu = cpu_seconds(); uint64_t f = mtl_cur_frame();
    if (dt <= 0) return;
    _fpsNow = f >= _f0 ? (f - _f0) / dt : 0;
    double g = 0; int gn = 0;   // GPU busy time per frame: the frames of the last half second that have completed
    for (uint64_t k = f > 3 ? f - 3 : 0; k > _f0 && gn < 30; k--) { double v = mtl_gpu_ms(k); if (v >= 0) { g += v; gn++; } }
    if (gn) _gpu = g / gn;
    double cpuPct = _cpu0 > 0 ? (cpu - _cpu0) / dt * 100 : 0;
    _t0 = t; _f0 = f; _cpu0 = cpu;
    if (_n < OV_N) _fps[_n++] = (float)_fpsNow; else { memmove(_fps, _fps + 1, (OV_N - 1) * sizeof *_fps); _fps[OV_N - 1] = (float)_fpsNow; }
    [self refreshWithCPU:cpuPct];
}
// The engine this app was built with (S2M_ENGINE, baked in by switch2mac.py: "switch2mac", or "nxnative-84dea6983541" for another engine's build):
// its name, and the commit's first 8 characters when it has one. tools/engine/s2m_ui.m in switch2mac has the same for the other engines.
static void engine_name(NSString **name, NSString **version) {
    const char *e = getenv("S2M_ENGINE"); NSString *s = e && *e ? @(e) : @"";
    NSRange dash = [s rangeOfString:@"-" options:NSBackwardsSearch]; NSString *tail = dash.location != NSNotFound ? [s substringFromIndex:dash.location + 1] : @"";
    BOOL hex = tail.length >= 7 && [tail rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
    *name = hex ? [s substringToIndex:dash.location] : s; *version = hex ? [tail substringToIndex:MIN(8u, tail.length)] : @"";
}
- (void)refreshWithCPU:(double)cpuPct {
    self.hidden = g_ov_mode == 0; if (!g_ov_mode) return;
    NSFont *mono = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    NSColor *green = [NSColor colorWithCalibratedRed:80/255.0 green:1 blue:120/255.0 alpha:1], *yellow = [NSColor colorWithCalibratedRed:1 green:230/255.0 blue:40/255.0 alpha:1],
            *red = [NSColor colorWithCalibratedRed:1 green:90/255.0 blue:80/255.0 alpha:1], *grey = [NSColor colorWithWhite:0.72 alpha:1];
    NSColor *fc = _fpsNow >= 55 ? green : _fpsNow >= 30 ? yellow : red;
    NSMutableAttributedString *a = [NSMutableAttributedString new];
    void (^line)(NSString *, NSColor *) = ^(NSString *s, NSColor *c) { [a appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: c}]]; };
    NSString *gpu = _gpu >= 0 ? [NSString stringWithFormat:@"%.1f ms", _gpu] : @"--";
    int gw0, gh0; nvn_game_size(&gw0, &gh0);
    NSString *eng, *engVer; engine_name(&eng, &engVer);
    NSString *fpsText = [NSString stringWithFormat:@"FPS %.0f", _fpsNow];
    line(fpsText, fc);
    if (eng.length) {   // the engine, dimmed, at the right of the FPS line (the font is monospaced: pad to the hint line's width)
        NSInteger pad = MAX(2, 21 - (NSInteger)fpsText.length - (NSInteger)eng.length);
        line([[@"" stringByPaddingToLength:pad withString:@" " startingAtIndex:0] stringByAppendingString:eng], [NSColor colorWithWhite:0.6 alpha:1]);
    }
    line(gw0 > 0 ? [NSString stringWithFormat:@"\n%dx%d", gw0, gh0] : @"\n--", green);
    if (g_ov_mode == 2) {
        line([NSString stringWithFormat:@"\nGPU %@", gpu], _gpu > 16.7 ? yellow : green);
        line([NSString stringWithFormat:@"\nFrame %.1f ms", _fpsNow > 0 ? 1000 / _fpsNow : 0], green);
        line([NSString stringWithFormat:@"\nCPU %.0f%%", cpuPct], green);
        double mem = footprint_gb(); line([NSString stringWithFormat:@"\nMemory %.1f GB", mem], mem > 16 ? yellow : green);
        line([NSString stringWithFormat:@"\nGame pacing %d fps", nvn_game_fps()], grey);
        NSSize px = g_layer.drawableSize; line([NSString stringWithFormat:@"\nOutput %.0fx%.0f", px.width, px.height], grey);
        if (eng.length) line([NSString stringWithFormat:@"\nEngine %@%@%@", eng, engVer.length ? @" " : @"", engVer], grey);
    }
    line(g_ov_mode == 2 ? @"\n1: hide · 2: settings" : @"\n1: more · 2: settings", grey);
    self.label.attributedStringValue = a;
    NSSize z = [self.label sizeThatFits:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGFloat gw = g_ov_mode == 2 ? 220 : 0, gh = g_ov_mode == 2 ? 74 : 0, cw = fmax(ceil(z.width), gw), m = 10;
    CGFloat w = cw + 16, h = ceil(z.height) + gh + 10; NSSize b = self.superview.bounds.size;
    self.frame = NSMakeRect(floor(b.width - w - m), floor(b.height - h - m), w, h);
    self.label.frame = NSMakeRect(8, gh + 5, ceil(z.width), ceil(z.height));
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)d {   // detailed mode: the frame rate of the last 30 s, with lines at 30 and 60
    (void)d; if (g_ov_mode != 2 || !_n) return;
    float lo = _fps[0], hi = _fps[0]; for (int i = 0; i < _n; i++) { lo = fminf(lo, _fps[i]); hi = fmaxf(hi, _fps[i]); }
    NSDictionary *st = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightMedium], NSForegroundColorAttributeName: [NSColor colorWithWhite:0.88 alpha:1]};
    [[NSString stringWithFormat:@"min %.0f   max %.0f   (30 s)", lo, hi] drawAtPoint:NSMakePoint(8, 60) withAttributes:st];
    NSRect p = NSMakeRect(30, 8, self.bounds.size.width - 38, 46); double top = fmax(60, ceil(hi * 1.1 / 30) * 30);
    NSDictionary *ax = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightRegular], NSForegroundColorAttributeName: [NSColor colorWithWhite:0.75 alpha:0.8]};
    for (int v = 30; v <= 60; v += 30) {
        CGFloat y = NSMinY(p) + v / top * p.size.height;
        NSBezierPath *g = [NSBezierPath bezierPath]; [g moveToPoint:NSMakePoint(NSMinX(p), y)]; [g lineToPoint:NSMakePoint(NSMaxX(p), y)];
        [[NSColor colorWithWhite:0.75 alpha:0.2] setStroke]; [g stroke];
        [[NSString stringWithFormat:@"%d", v] drawAtPoint:NSMakePoint(8, y - 5) withAttributes:ax];
    }
    NSBezierPath *c = [NSBezierPath bezierPath]; c.lineWidth = 1.5;
    for (int i = 0; i < _n; i++) {
        NSPoint q = NSMakePoint(NSMinX(p) + (OV_N > 1 ? (CGFloat)(OV_N - _n + i) / (OV_N - 1) : 0) * p.size.width, NSMinY(p) + fmin(_fps[i] / top, 1) * p.size.height);
        if (i) [c lineToPoint:q]; else [c moveToPoint:q];
    }
    [[NSColor colorWithCalibratedRed:80/255.0 green:1 blue:120/255.0 alpha:1] setStroke]; [c stroke];
}
@end
// Settings panel (key 2, Esc closes): the app's settings list (Resources/dm/launcher.json, the same rows the launcher window has) over the game, dark cards as in the launcher.
// A change is saved where the launcher reads it (launcher.<VAR> in the app's preferences, removed at the default) for the next start; the overlay and fullscreen apply at once.
// While it is open the keyboard and mouse do not reach the game
static NSUserDefaults *settings_store(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bid hasPrefix:@"org.nxnative."] ? NSUserDefaults.standardUserDefaults : nil;   // the host inside the app: its bundle's domain, as the launcher's
}
static NSColor *ui_accent(void) { return [NSColor colorWithCalibratedRed:80/255.0 green:1 blue:120/255.0 alpha:1]; }
@interface DmPanelRow : NSObject
@property(copy) NSDictionary *s; @property(strong) NSTextField *note;
@end
@implementation DmPanelRow @end
@interface DmPanel : NSView
@property(strong) NSMutableArray<DmPanelRow *> *rows;
@end
static DmPanel *g_panel;
static void overlay_set(int mode);
@implementation DmPanel
static NSTextField *panel_label(NSString *t, CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *l = [NSTextField wrappingLabelWithString:t]; l.font = [NSFont systemFontOfSize:size weight:w]; l.textColor = c; l.drawsBackground = NO; return l;
}
static NSString *setting_value(NSDictionary *s) {
    const char *e = getenv([s[@"env"] UTF8String]); return e ? @(e) : s[@"default"];
}
- (instancetype)initWithFrame:(NSRect)r {
    if (!(self = [super initWithFrame:r])) return nil;
    self.wantsLayer = YES; self.layer.backgroundColor = [NSColor colorWithWhite:0.07 alpha:0.94].CGColor; self.layer.cornerRadius = 12;
    self.layer.borderWidth = 1; self.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.14].CGColor;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.rows = [NSMutableArray array];
    const char *fd = getenv("DM_FONT_DIR"); NSArray *list = nil;
    if (fd) { NSData *d = [NSData dataWithContentsOfFile:[[@(fd) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"launcher.json"]];
              if (d) list = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil][@"settings"]; }
    NSStackView *st = [NSStackView stackViewWithViews:@[]]; st.orientation = NSUserInterfaceLayoutOrientationVertical; st.alignment = NSLayoutAttributeLeading; st.spacing = 8;
    st.edgeInsets = NSEdgeInsetsMake(18, 20, 18, 20);
    NSTextField *title = panel_label(@"Settings", 20, NSFontWeightBold, NSColor.whiteColor);
    NSTextField *sub = panel_label(@"2 or Esc closes · the overlay and display mode change at once, the rest at the next launch", 11, NSFontWeightMedium, ui_accent());
    [st addArrangedSubview:title]; [st addArrangedSubview:sub];
    NSString *sec = nil;
    for (NSDictionary *s in list) {
        NSString *sc = [s[@"section"] isEqual:@"Game"] ? @"DISPLAY" : [s[@"section"] uppercaseString];
        if (![sc isEqual:sec]) { sec = sc; NSTextField *h = panel_label(sc, 11, NSFontWeightBold, [NSColor colorWithWhite:0.6 alpha:1]); [st addArrangedSubview:h]; [st setCustomSpacing:4 afterView:h]; }
        [st addArrangedSubview:[self card:s]];
    }
    if (!list.count) [st addArrangedSubview:panel_label(@"No settings list in this app (Resources/dm/launcher.json).", 12, NSFontWeightRegular, NSColor.whiteColor)];
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:self.bounds]; sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    sv.drawsBackground = NO; sv.hasVerticalScroller = YES;
    NSView *doc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, r.size.width, 10)]; [doc addSubview:st]; st.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[[st.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor], [st.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor], [st.topAnchor constraintEqualToAnchor:doc.topAnchor]]];
    doc.frame = NSMakeRect(0, 0, r.size.width - 16, st.fittingSize.height); sv.documentView = doc; [self addSubview:sv];
    [doc scrollPoint:NSMakePoint(0, doc.isFlipped ? 0 : doc.bounds.size.height)];
    return self;
}
- (BOOL)isFlipped { return YES; }
- (NSView *)card:(NSDictionary *)s {
    NSView *c = [NSView new]; c.wantsLayer = YES; c.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.06].CGColor; c.layer.cornerRadius = 9;
    c.layer.borderWidth = 1; c.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.12].CGColor; c.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *l = panel_label(s[@"label"], 13, NSFontWeightSemibold, NSColor.whiteColor);
    DmPanelRow *row = [DmPanelRow new]; row.s = s; [self.rows addObject:row];
    NSString *v = setting_value(s); NSControl *ctl;
    if ([s[@"kind"] isEqual:@"choice"]) {
        NSPopUpButton *p = [NSPopUpButton new]; for (NSArray *o in s[@"options"]) { [p addItemWithTitle:o[1]]; p.lastItem.representedObject = o[0]; if ([o[0] isEqual:v]) [p selectItem:p.lastItem]; }
        ctl = p;
    } else if ([s[@"kind"] isEqual:@"range"]) {
        NSSlider *sl = [NSSlider sliderWithValue:v.doubleValue minValue:[s[@"min"] doubleValue] maxValue:[s[@"max"] doubleValue] target:nil action:nil]; sl.continuous = NO;
        [sl.widthAnchor constraintEqualToConstant:150].active = YES; ctl = sl;
    } else { NSSwitch *w = [NSSwitch new]; w.state = [v isEqual:s[@"on"] ?: @"1"] ? NSControlStateValueOn : NSControlStateValueOff; ctl = w; }
    ctl.target = self; ctl.action = @selector(changed:); ctl.tag = (NSInteger)self.rows.count - 1;
    NSString *n = s[@"note"]; row.note = panel_label(n ?: @"", 11, NSFontWeightRegular, [NSColor colorWithWhite:0.65 alpha:1]); row.note.hidden = !n.length;
    for (NSView *x in @[l, row.note, ctl]) { x.translatesAutoresizingMaskIntoConstraints = NO; [c addSubview:x]; }
    [NSLayoutConstraint activateConstraints:@[
        [c.widthAnchor constraintEqualToConstant:self.bounds.size.width - 56],
        [l.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:12], [l.topAnchor constraintEqualToAnchor:c.topAnchor constant:9],
        [l.trailingAnchor constraintLessThanOrEqualToAnchor:ctl.leadingAnchor constant:-10],
        [row.note.leadingAnchor constraintEqualToAnchor:l.leadingAnchor], [row.note.topAnchor constraintEqualToAnchor:l.bottomAnchor constant:2],
        [row.note.trailingAnchor constraintLessThanOrEqualToAnchor:ctl.leadingAnchor constant:-10],
        [row.note.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-9],
        [ctl.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-12], [ctl.centerYAnchor constraintEqualToAnchor:c.centerYAnchor]]];
    [row.note setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    return c;
}
- (void)changed:(NSControl *)ctl {
    NSDictionary *s = self.rows[(NSUInteger)ctl.tag].s; NSString *v;
    if ([ctl isKindOfClass:NSPopUpButton.class]) v = ((NSPopUpButton *)ctl).selectedItem.representedObject;
    else if ([ctl isKindOfClass:NSSlider.class]) v = [NSString stringWithFormat:@"%.2f", ctl.doubleValue];
    else v = ((NSSwitch *)ctl).state == NSControlStateValueOn ? (s[@"on"] ?: @"1") : (s[@"off"] ?: @"0");
    NSString *env = s[@"env"]; NSUserDefaults *u = settings_store(); NSString *key = [@"launcher." stringByAppendingString:env];
    if ([v isEqual:s[@"default"]]) [u removeObjectForKey:key]; else [u setObject:v forKey:key];
    LOG("front end: setting %s = %s (%s)", env.UTF8String, v.UTF8String, u ? "saved for the next launch" : "not saved: no app preferences");
    if ([env isEqual:@"DM_OVERLAY"]) overlay_set([v isEqual:@"off"] ? 0 : [v isEqual:@"detailed"] ? 2 : 1);
    if ([env isEqual:@"DM_FULLSCREEN"] && ([v isEqual:@"1"] != ((g_win.styleMask & NSWindowStyleMaskFullScreen) != 0))) [g_win toggleFullScreen:nil];
}
- (void)mouseDown:(NSEvent *)e { (void)e; }   // clicks on the panel's background do not reach the game
@end
static void panel_toggle(void) {
    NSView *cv = g_win.contentView;
    if (g_panel) { [g_panel removeFromSuperview]; g_panel = nil; input_resume(); LOG("front end: settings panel closed"); return; }
    input_release();
    CGFloat w = fmin(500, cv.bounds.size.width - 40), h = fmin(560, cv.bounds.size.height - 40);
    g_panel = [[DmPanel alloc] initWithFrame:NSMakeRect(floor((cv.bounds.size.width - w) / 2), floor((cv.bounds.size.height - h) / 2), w, h)];
    g_panel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    [cv addSubview:g_panel positioned:NSWindowAbove relativeTo:nil]; LOG("front end: settings panel open (key 2)");
}

static DmOverlay *g_ov;
static void overlay_set(int mode) { g_ov_mode = mode; [g_ov refreshWithCPU:0]; }
static void overlay_cycle(void) {
    g_ov_mode = g_ov_mode == 1 ? 2 : g_ov_mode == 2 ? 0 : 1;
    LOG("front end: overlay %s (key 1)", g_ov_mode == 0 ? "off" : g_ov_mode == 1 ? "compact" : "detailed");
    [g_ov refreshWithCPU:0];
}

typedef struct { void (*fn)(void); } guest_arg;
static void *guest_tramp(void *p) {
    static char alt[65536];                       // The signal alternate stack is per thread; crash printing must also work on the guest thread
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    ((guest_arg *)p)->fn(); LOG("guest thread finished"); exit(0);
}

// Metal reads MTL_HUD_ENABLED when the process makes its first device, which can be before the window: set from DM_METAL_HUD before main (set in front_run, the HUD did not show)
__attribute__((constructor)) static void hud_env(void) { front_hud_env(); }
void front_run(void (*guest)(void)) {
    // A game: tell macOS its work is latency-critical, so the system does not trade its frame time for power while the frame rate is capped
    static id activity; activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical reason:@"game"];
    if (!getenv("DM_WINDOW")) { guest(); return; }
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect r = NSMakeRect(0, 0, 1280, 720);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:r
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @DM_GAME_NAME;   // the game profile's name (game name label)
        // Fullscreen: without FullScreenPrimary the green button only zooms the window. The present path already scales
        // the game picture to fit the drawable with black bars around it, so fullscreen keeps the game's aspect ratio.
        win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        NSView *v = win.contentView = [[DmGameView alloc] initWithFrame:r];
        v.wantsLayer = YES;
        g_layer = [CAMetalLayer layer];
        g_layer.device = MTLCreateSystemDefaultDevice();
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.contentsScale = win.backingScaleFactor;
        if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) { g_layer.developerHUDProperties = @{@"mode": @"default"}; LOG("front end: Metal performance HUD on (DM_METAL_HUD)"); }   // Apple's HUD over the game: frame rate, frame and GPU time, memory
        v.layer = g_layer; [(DmGameView *)v fitDrawable];
        const char *ov = getenv("DM_OVERLAY"); g_ov_mode = ov && !strcmp(ov, "off") ? 0 : ov && !strcmp(ov, "detailed") ? 2 : 1;
        g_ov = [[DmOverlay alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)]; [v addSubview:g_ov]; [g_ov refreshWithCPU:0];
        void s2m_share_attach(NSWindow *win); s2m_share_attach(win);   // the shared shader list: contribution file and the offer to send it, when the game closes (s2m_share.m)
        [win center];
        [win makeKeyAndOrderFront:nil];
        g_screen_fps = (int)(win.screen ?: NSScreen.mainScreen).maximumFramesPerSecond;
        g_win = win;
        [NSApp activateIgnoringOtherApps:YES];
        // A host another process starts (scripts/regress.py) is not activated (its focus state stays 2), so its window opened wherever it landed in the window order, and behind
        // another app's window macOS fires its display link about once a second: Breath of the Wild stepped up to 3 vsyncs at boot and never came back (20 fps runs).
        // DM_WINDOW_TOP=1 orders it in front without activation and keeps it above other apps' windows; the log names every change of the window's visibility either way
        if (getenv("DM_WINDOW_TOP") && atoi(getenv("DM_WINDOW_TOP"))) { win.level = NSFloatingWindowLevel; [win orderFrontRegardless]; LOG("front end: window kept in front (DM_WINDOW_TOP)"); }
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidChangeOcclusionStateNotification object:win queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; static int vis = -1; int v = (win.occlusionState & NSWindowOcclusionStateVisible) != 0; if (v == vis) return; vis = v;
            if (v) LOG("front end: window visible"); else LOG("front end: window covered (its display link fires about once a second: frame times measure nothing)"); }];
        // Main menu: AppKit runs ⌘ shortcuts only through menu items, so ⌘Q quits and ⌃⌘F toggles fullscreen from here (AppKit shows the item as Globe-F and keeps ⌃⌘F as a hidden twin)
        NSMenu *bar = [NSMenu new], *app = [NSMenu new], *wm = [[NSMenu alloc] initWithTitle:@"Window"];
        [[bar addItemWithTitle:@"" action:nil keyEquivalent:@""] setSubmenu:app];
        [app addItemWithTitle:@"Quit " DM_GAME_NAME action:@selector(terminate:) keyEquivalent:@"q"];
        [[bar addItemWithTitle:@"Window" action:nil keyEquivalent:@""] setSubmenu:wm];
        [wm addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"].keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
        NSApp.mainMenu = bar;
        const char *fs = getenv("DM_FULLSCREEN");   // 1 (or any value but 0): start in fullscreen; 0, the settings window's Window, or unset: a window
        if (fs && strcmp(fs, "0")) dispatch_async(dispatch_get_main_queue(), ^{ [win toggleFullScreen:nil]; });
        for (NSNotificationName nm in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:nm object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                GCController *c = n.object; int conn = n.name == GCControllerDidConnectNotification;
                if (!c.extendedGamepad || g_merge) LOG("controller %s: %s%s", conn ? "connected" : "disconnected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
                pads_changed(conn ? nil : c); }];
        dm_haptics_apple_init();
        pads_start();
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;   // Only swallow keys for the game window; other windows such as the software keyboard input box receive typing as usual
            if (e.type == NSEventTypeKeyDown && (e.modifierFlags & NSEventModifierFlagCommand)) return e;   // ⌘ shortcuts go to the menu; a key released while ⌘ is held still reaches the game, or it would stay pressed
            if (e.keyCode == 18) { if (e.type == NSEventTypeKeyDown && !e.isARepeat) overlay_cycle(); return nil; }   // key 1: the overlay's next mode (not a game button)
            if (e.keyCode == 19 || (e.keyCode == 53 && g_panel)) { if (e.type == NSEventTypeKeyDown && !e.isARepeat) panel_toggle(); return nil; }   // key 2 (or Esc while it is open): the settings panel
            if (g_panel) return nil;   // the panel is open: no keys reach the game
            if (!e.isARepeat) on_key(e, e.type == NSEventTypeKeyDown);
            return nil;   // Swallow it to avoid the system beep
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:win queue:nil
                                                      usingBlock:^(NSNotification *n) { (void)n; exit(0); }];
        // Lifecycle (hle.h / dm.h): focus lost → 2, focus regained → 1; minimized → 3 + audio paused + GPU suspended, restored → resume (followed by focus regained → 1).
        // Input is released when the window stops being key (and when it is minimized) and taken up again when it is key again
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSWindowDidChangeScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; if (win.screen) { g_screen_fps = (int)win.screen.maximumFramesPerSecond; g_layer.contentsScale = win.backingScaleFactor; } screen_match_apply(); }];
        // Entering and leaving fullscreen: the layer is layer-backed, so its frame (and with it the drawable) follows the
        // content view by itself; only the scale factor has to be carried over to the screen the window ended up on. The screen's rate is matched in fullscreen only (screen_match_apply)
        [nc addObserverForName:NSWindowDidEnterFullScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_fullscreen = 1; g_layer.contentsScale = win.backingScaleFactor; screen_match_apply(); }];
        [nc addObserverForName:NSWindowDidExitFullScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_fullscreen = 0; g_layer.contentsScale = win.backingScaleFactor; screen_match_apply(); }];
        [nc addObserverForName:NSWindowDidResignKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; input_release(); if (!win.miniaturized) dm_focus_set(2); }];
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; input_resume(); dm_focus_set(1); }];
        [nc addObserverForName:NSWindowDidMiniaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; input_release(); dm_focus_set(3); dm_audio_suspend(1); dm_gfx_suspend(1); }];
        [nc addObserverForName:NSWindowDidDeminiaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_gfx_suspend(0); dm_audio_suspend(0); dm_focus_set(2); }];
        // Guest thread: 64 MiB stack (the Switch main thread stack is specified by npdm; the host gives plenty)
        static guest_arg ga; ga.fn = guest;
        pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);
        pthread_t th; if (pthread_create(&th, &a, guest_tramp, &ga)) die("pthread_create guest");
        [NSApp run];
    }
}

// Progress screen of the prepare step (front.h front_progress): a dark view over the game's, the title, a bar and a count, centered; AppKit views, so it draws while the game's thread waits
static NSView *g_prog; static NSTextField *g_prog_title, *g_prog_count; static NSProgressIndicator *g_prog_bar;
static NSTextField *prog_label(NSRect r, CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *t = [NSTextField labelWithString:@""]; t.frame = r; t.alignment = NSTextAlignmentCenter; t.textColor = c;
    t.font = [NSFont monospacedDigitSystemFontOfSize:size weight:w]; return t;
}
void front_progress(const char *title, long done, long total) {
    if (!g_layer) return;
    NSString *tt = title ? @(title) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!tt) { [g_prog removeFromSuperview]; g_prog = nil; return; }
        if (!g_prog) {
            NSView *cv = g_win.contentView;
            g_prog = [[NSView alloc] initWithFrame:cv.bounds]; g_prog.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            g_prog.wantsLayer = YES; g_prog.layer.backgroundColor = [NSColor colorWithWhite:0.06 alpha:0.94].CGColor;
            NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(floor((cv.bounds.size.width - 400) / 2), floor((cv.bounds.size.height - 96) / 2), 400, 96)];
            box.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
            g_prog_title = prog_label(NSMakeRect(0, 62, 400, 30), 20, NSFontWeightSemibold, NSColor.whiteColor);
            g_prog_bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 36, 360, 20)];
            g_prog_bar.style = NSProgressIndicatorStyleBar; g_prog_bar.indeterminate = NO; g_prog_bar.minValue = 0;
            g_prog_count = prog_label(NSMakeRect(0, 4, 400, 22), 13, NSFontWeightRegular, [NSColor colorWithWhite:0.72 alpha:1]);
            [box addSubview:g_prog_title]; [box addSubview:g_prog_bar]; [box addSubview:g_prog_count]; [g_prog addSubview:box];
            [cv addSubview:g_prog];
        }
        g_prog_title.stringValue = tt; g_prog_bar.maxValue = total > 0 ? (double)total : 1; g_prog_bar.doubleValue = (double)done;
        g_prog_count.stringValue = [NSString stringWithFormat:@"%@ of %@", [NSNumberFormatter localizedStringFromNumber:@(done) numberStyle:NSNumberFormatterDecimalStyle],
                                    [NSNumberFormatter localizedStringFromNumber:@(total) numberStyle:NSNumberFormatterDecimalStyle]];
    });
}

// Software keyboard input box (front.h): the main thread shows an NSAlert + text field and the guest thread waits synchronously for the result. Not shown in windowless mode (returns -1, the caller treats it as cancel)
extern int g_swkbd_min_chars;   // hle_swkbd.c: this input's minimum length from ShowKeyboardArg; the applet keeps OK disabled until the text is long enough
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    if (!g_layer) return -1;
    __block int r = 0;
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        // The box takes the keyboard and the mouse, so the game window never sees the key-up of the button or the touch-up of the click that opened it: nothing may stay pressed
        // while it is up, or the game reads the stuck button / touch the moment the box closes (Stardew Valley's character creation re-opened the keyboard endlessly)
        g_btn = 0; g_w = g_a = g_s = g_d = 0; push();
        dm_touch_set(NULL, 0);
        int min_chars = g_swkbd_min_chars > 0 ? g_swkbd_min_chars : 0;
        NSString *info = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
        for (;;) {
            NSAlert *a = [NSAlert new];
            a.messageText = title && *title ? @(title) : @"Input";
            a.informativeText = info;
            [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
            NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
            f.stringValue = text ?: (initial ? @(initial) : @"");
            if (guide && *guide) f.placeholderString = @(guide);
            a.accessoryView = f; a.window.initialFirstResponder = f;
            r = [a runModal] == NSAlertFirstButtonReturn;
            text = f.stringValue;
            if (!r || (int)text.length >= min_chars) break;
            // On hardware the applet would not have accepted the shorter text (OK stayed disabled); a game that rejects it re-opens the keyboard for ever, so the box comes back with the rule instead
            info = [info stringByAppendingFormat:@"\nAt least %d characters are needed here.", min_chars];
        }
    });
    if (!r) return 0;
    (void)max_chars;                              // Truncation is done uniformly in hle_swkbd.c in UTF-16 units
    snprintf(out, out_cap, "%s", text.UTF8String);
    return 1;
}

// The shared shader list's contribution file and the offer to send it (switch2mac; the way MacNativeGames does it for Tears of the Kingdom), for every engine
// switch2mac builds with: this engine's front_mac.m calls s2m_share_attach, and tools/engine/patch.py copies this file into the others (their s2m_ui.m calls it).
// When the game closes, the rows the app built (pso_user.tsv beside the save folder, or DM_PSO_USER) that the list it shipped (pso_manifest.tsv beside DM_NVN_SHMAP) lacks
// and that were not sent before (.shader-list-contribution.txt.done) are written to shader-list-contribution.txt in the same folder, under a header naming the game's
// title ID and its engine (S2M_ENGINE, baked into the app), so the game's list in the repository only ever takes rows from its own build.
// Each time 100 new rows have built up (S2M_SHARE_EVERY), a dialog asks: Send opens the "Shader list" issue form (S2M_SHARE_REPO, default switch2mac's) and shows a copy
// of the file in Finder to drag in, then marks its rows as sent; Remind me later asks again after 100 more; Stop reminding (s2m.share.never in the app's preferences)
// or S2M_SHARE=0 never asks. The app uploads nothing itself. Only rows of hex keys and numbers are read or written: no game data, no paths, no names.
#import <Cocoa/Cocoa.h>
#include "dm.h"
#include <regex.h>

static NSWindow *s_win;
// The dialog's "?" button: what is sent, in plain words (the README's "Is sending safe?"); it leaves the dialog open
@interface S2MShareHelp : NSObject <NSAlertDelegate> @end
@implementation S2MShareHelp
- (BOOL)alertShowHelp:(NSAlert *)a { (void)a; [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/azmasm/switch2mac#is-sending-safe"]]; return YES; }
@end
static NSArray<NSString *> *list_rows(NSString *path) {
    NSString *t = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil; if (!t) return @[];
    static regex_t re; static int ok = -1;
    if (ok < 0) ok = !regcomp(&re, "^(S\t[0-9a-f]{16}_[a-z0-9]+\t[0-9]+|C\t[0-9a-f]{16}_[a-z0-9]+|R\t[0-9a-f]+)$", REG_EXTENDED | REG_NOSUB);   // tools/shader_list.py ROW
    NSMutableOrderedSet *o = [NSMutableOrderedSet orderedSet];
    for (NSString *l in [t componentsSeparatedByString:@"\n"]) if (ok && l.length < 8192 && !regexec(&re, l.UTF8String, 0, NULL, 0)) [o addObject:l];
    return o.array;
}
static void write_rows(NSString *path, NSString *head, NSArray<NSString *> *rows) {
    NSMutableString *t = [head mutableCopy]; for (NSString *r in rows) [t appendFormat:@"%@\n", r];
    [t writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void share_at_close(void) {
    static int done; if (done++) return;
    const char *pu = getenv("DM_PSO_USER"), *save = getenv("DM_SAVE"), *shmap = getenv("DM_NVN_SHMAP"), *eng = getenv("S2M_ENGINE");
    NSString *user = pu && *pu ? @(pu) : save && *save ? [[@(save) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"pso_user.tsv"] : nil;
    if (!user || !shmap) return;
    NSString *dir = user.stringByDeletingLastPathComponent, *tid = dir.lastPathComponent, *game = @(DM_GAME_NAME), *engine = eng && *eng ? @(eng) : @"unknown";
    NSString *contrib = [dir stringByAppendingPathComponent:@"shader-list-contribution.txt"], *sent = [dir stringByAppendingPathComponent:@".shader-list-contribution.txt.done"];
    NSMutableSet *have = [NSMutableSet setWithArray:list_rows([@(shmap).stringByDeletingLastPathComponent stringByAppendingPathComponent:@"pso_manifest.tsv"])];
    [have addObjectsFromArray:list_rows(sent)];
    NSMutableArray *rows = [NSMutableArray array]; for (NSString *r in list_rows(user)) if (![have containsObject:r]) [rows addObject:r];
    NSString *head = [NSString stringWithFormat:@"# switch2mac shader list contribution\tgame=%@\tengine=%@\n# %@: shaders and pipelines this Mac built that the app's shared list lacks. Identifiers only, no game data.\n", tid, engine, game];
    write_rows(contrib, head, rows);
    LOG("front end: shader list contribution: %lu rows (%s)", (unsigned long)rows.count, contrib.fileSystemRepresentation);
    const char *off = getenv("S2M_SHARE"); if (off && !strcmp(off, "0")) return;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @""; if (![bid hasPrefix:@"org.nxnative."]) return;   // asked from the app only, not from a build folder run
    NSUserDefaults *u = NSUserDefaults.standardUserDefaults; if ([u boolForKey:@"s2m.share.never"]) return;
    const char *ev = getenv("S2M_SHARE_EVERY"); NSInteger every = ev && atoi(ev) > 0 ? atoi(ev) : 100, next = [u integerForKey:@"s2m.share.next"]; if (next <= 0) next = every;
    if ((NSInteger)rows.count < next) return;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"Help others play %@ without stutters?", game];
    a.informativeText = [NSString stringWithFormat:@"Your Mac prepared %lu shaders the shared list doesn't have yet. Send opens a GitHub form and shows the file: drag it in and press Create.\n\n"
                         "The file is only a list of shader IDs: no game files, no saves, nothing about you. (? explains more.)", (unsigned long)rows.count];
    [a addButtonWithTitle:@"Send"]; [a addButtonWithTitle:@"Remind me later"]; [a addButtonWithTitle:@"Stop reminding"];
    static S2MShareHelp *help; if (!help) help = [S2MShareHelp new];
    a.showsHelp = YES; a.delegate = help;
    if (s_win.styleMask & NSWindowStyleMaskFullScreen) [s_win toggleFullScreen:nil];
    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse r = [a runModal];
    if (r == NSAlertThirdButtonReturn) { [u setBool:YES forKey:@"s2m.share.never"]; LOG("front end: shader list: stop reminding"); return; }
    if (r != NSAlertFirstButtonReturn) { [u setInteger:(NSInteger)rows.count + every forKey:@"s2m.share.next"]; LOG("front end: shader list: remind later"); return; }
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyyMMdd-HHmm"; df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *out = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"shader-list-%@-%@.txt", tid, [df stringFromDate:NSDate.date]]];
    write_rows(out, head, rows);
    NSMutableArray *all = [list_rows(sent) mutableCopy]; [all addObjectsFromArray:rows]; write_rows(sent, @"", all);   // sent: never offered again
    write_rows(contrib, head, @[]); [u setInteger:every forKey:@"s2m.share.next"];
    const char *rp = getenv("S2M_SHARE_REPO"); NSString *repo = rp && *rp ? @(rp) : @"https://github.com/azmasm/switch2mac";
    NSMutableCharacterSet *cs = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy]; [cs removeCharactersInString:@"+&=?/#"];
    NSString *title = [NSString stringWithFormat:@"[Shader list] %@: %lu rows", game, (unsigned long)rows.count];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/issues/new?template=shader-list.yml&title=%@&game=%@", repo,
                                       [title stringByAddingPercentEncodingWithAllowedCharacters:cs], [[NSString stringWithFormat:@"%@ (%@)", game, tid] stringByAddingPercentEncodingWithAllowedCharacters:cs]]];
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:out]]];
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
    LOG("front end: shader list: %lu rows to send in %s", (unsigned long)rows.count, out.fileSystemRepresentation);
}
void s2m_share_attach(NSWindow *win) {   // before front_mac.m's own close handler (exit(0)), and for ⌘Q: observers run in the order they were added
    s_win = win;
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; share_at_close(); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; share_at_close(); }];
}

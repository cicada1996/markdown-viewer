// Markdown Viewer — a minimal .md viewer for macOS.
// Renders with marked.js inside a WKWebView, live-reloads when the file
// changes, and offers a plain-text edit mode plus a light/dark toggle.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const kAppearanceKey = @"appearanceOverride";
static NSString * const kAppearanceChanged = @"MarkdownViewerAppearanceChanged";

static NSString *bundleResource(NSString *name, NSString *ext) {
    NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:ext];
    NSString *s = url ? [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (!s) {
        NSLog(@"Missing bundle resource: %@.%@", name, ext);
        exit(1);
    }
    return s;
}

static NSString *htmlPage(NSString *markdown) {
    static NSString *template_;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        template_ = [bundleResource(@"template", @"html")
            stringByReplacingOccurrencesOfString:@"__MARKED_JS__"
                                      withString:bundleResource(@"marked.min", @"js")];
    });
    NSData *json = [NSJSONSerialization dataWithJSONObject:markdown
                                                   options:NSJSONWritingFragmentsAllowed
                                                     error:NULL];
    NSString *encoded = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]
                             : @"\"(could not encode file)\"";
    return [template_ stringByReplacingOccurrencesOfString:@"__MARKDOWN_JSON__" withString:encoded];
}

static BOOL isMarkdownURL(NSURL *url) {
    NSString *ext = url.pathExtension.lowercaseString;
    return [@[@"md", @"markdown", @"mdown", @"mkd"] containsObject:ext];
}

static BOOL appIsDark(void) {
    NSAppearance *appearance = NSApp.appearance ?: NSApp.effectiveAppearance;
    NSString *match = [appearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

static NSButton *titlebarButton(NSString *symbol, NSString *tooltip, id target, SEL action) {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tooltip];
    NSButton *button = [NSButton buttonWithImage:image target:target action:action];
    button.bezelStyle = NSBezelStyleTexturedRounded;
    button.toolTip = tooltip;
    return button;
}

#pragma mark - Viewer window

@class AppDelegate;

@interface ViewerController : NSObject <NSWindowDelegate, WKNavigationDelegate, NSTextViewDelegate>
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSScrollView *editorScroll;
@property (nonatomic, strong) NSTextView *textView;
@property (nonatomic, strong) NSButton *editButton;
@property (nonatomic, strong) NSButton *appearanceButton;
@property (nonatomic, assign) BOOL editing;
@property (nonatomic, strong) dispatch_source_t monitor;
@property (nonatomic, assign) double pendingScrollY;
@property (nonatomic, copy) void (^onClose)(void);
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
- (void)openFile:(NSURL *)url;
@end

@implementation ViewerController

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    self = [super init];
    _fileURL = fileURL;

    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    // Allow the rendered page to load images that sit next to the .md file.
    [config.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
    [config setValue:@YES forKey:@"allowUniversalAccessFromFileURLs"];
    _webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    _webView.navigationDelegate = self;
    _webView.allowsMagnification = YES;

    _window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 760, 860)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    // We hold the window in a strong property, so ARC owns it. Left at the
    // default (YES), closing the window makes AppKit release it too — a
    // double-free that later crashes while AppKit tears down its window list.
    _window.releasedWhenClosed = NO;
    _window.contentView = _webView;
    _window.title = fileURL.lastPathComponent;
    _window.subtitle = [fileURL.URLByDeletingLastPathComponent.path
        stringByReplacingOccurrencesOfString:NSHomeDirectory() withString:@"~"];
    _window.representedURL = fileURL;
    _window.delegate = self;
    _window.tabbingMode = NSWindowTabbingModePreferred;
    [_window setFrameAutosaveName:@"MarkdownViewerWindow"];

    [self setupTitlebarButtons];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshAppearanceIcon)
                                                 name:kAppearanceChanged
                                               object:nil];

    [self render];
    [self startWatching];
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:fileURL];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupTitlebarButtons {
    _editButton = titlebarButton(@"pencil", @"Edit (⌘E)", self, @selector(toggleEdit:));
    _appearanceButton = titlebarButton(appIsDark() ? @"sun.max" : @"moon",
                                       @"Light/dark mode (⇧⌘D)", self, @selector(toggleAppearance:));
    // Titlebar accessories are frame-based — lay the buttons out manually.
    _editButton.frame = NSMakeRect(0, 0, 36, 22);
    _appearanceButton.frame = NSMakeRect(40, 0, 36, 22);
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 84, 22)];
    [container addSubview:_editButton];
    [container addSubview:_appearanceButton];
    NSTitlebarAccessoryViewController *accessory = [NSTitlebarAccessoryViewController new];
    accessory.view = container;
    accessory.layoutAttribute = NSLayoutAttributeTrailing;
    [_window addTitlebarAccessoryViewController:accessory];
}

#pragma mark Rendering

- (NSString *)fileContents {
    return [NSString stringWithContentsOfURL:self.fileURL encoding:NSUTF8StringEncoding error:NULL];
}

- (void)render {
    __weak ViewerController *weakSelf = self;
    [self.webView evaluateJavaScript:@"window.scrollY" completionHandler:^(id value, NSError *error) {
        ViewerController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.pendingScrollY = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0;
        NSString *markdown = [strongSelf fileContents];
        if (!markdown) markdown = [NSString stringWithFormat:@"*Could not read %@*", strongSelf.fileURL.path];
        [strongSelf.webView loadHTMLString:htmlPage(markdown)
                                   baseURL:strongSelf.fileURL.URLByDeletingLastPathComponent];
    }];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (self.pendingScrollY > 0) {
        NSString *js = [NSString stringWithFormat:@"window.scrollTo(0, %f)", self.pendingScrollY];
        [webView evaluateJavaScript:js completionHandler:nil];
    }
}

// Open web links in the browser and other .md links in a new viewer window.
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    if (navigationAction.navigationType != WKNavigationTypeLinkActivated || !url) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    decisionHandler(WKNavigationActionPolicyCancel);
    if (url.isFileURL && isMarkdownURL(url)) {
        [(AppDelegate *)NSApp.delegate openFile:url];
    } else {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

#pragma mark Edit mode

- (void)setupEditor {
    NSRect frame = ((NSView *)self.window.contentView).frame;
    _editorScroll = [[NSScrollView alloc] initWithFrame:frame];
    _editorScroll.hasVerticalScroller = YES;
    NSSize contentSize = _editorScroll.contentSize;

    _textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    _textView.richText = NO;
    _textView.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    _textView.allowsUndo = YES;
    _textView.textContainerInset = NSMakeSize(24, 24);
    _textView.textColor = NSColor.textColor;
    _textView.backgroundColor = NSColor.textBackgroundColor;
    // Smart substitutions mangle Markdown and code — plain text only.
    _textView.automaticQuoteSubstitutionEnabled = NO;
    _textView.automaticDashSubstitutionEnabled = NO;
    _textView.automaticTextReplacementEnabled = NO;
    _textView.automaticSpellingCorrectionEnabled = NO;
    _textView.minSize = NSMakeSize(0, contentSize.height);
    _textView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    _textView.verticallyResizable = YES;
    _textView.horizontallyResizable = NO;
    _textView.autoresizingMask = NSViewWidthSizable;
    _textView.textContainer.containerSize = NSMakeSize(contentSize.width, FLT_MAX);
    _textView.textContainer.widthTracksTextView = YES;
    _textView.delegate = self;

    _editorScroll.documentView = _textView;
}

- (void)toggleEdit:(id)sender {
    if (self.editing) {
        if (self.window.documentEdited) [self saveDocument:nil];
        self.editing = NO;
        self.window.contentView = self.webView;
        self.editButton.image = [NSImage imageWithSystemSymbolName:@"pencil"
                                          accessibilityDescription:@"Edit"];
        self.editButton.toolTip = @"Edit (⌘E)";
        [self render];
    } else {
        if (!self.textView) [self setupEditor];
        [self.textView setString:[self fileContents] ?: @""];
        [self.textView.undoManager removeAllActions];
        self.window.documentEdited = NO;
        self.editing = YES;
        self.window.contentView = self.editorScroll;
        [self.window makeFirstResponder:self.textView];
        self.editButton.image = [NSImage imageWithSystemSymbolName:@"doc.richtext"
                                          accessibilityDescription:@"Preview"];
        self.editButton.toolTip = @"Preview (⌘E)";
    }
}

- (void)saveDocument:(id)sender {
    if (!self.editing) return;
    NSError *error;
    if ([self.textView.string writeToURL:self.fileURL atomically:YES
                                encoding:NSUTF8StringEncoding error:&error]) {
        self.window.documentEdited = NO;
    } else {
        NSAlert *alert = [NSAlert alertWithError:error];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    }
}

- (void)textDidChange:(NSNotification *)notification {
    self.window.documentEdited = YES;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (!(self.editing && self.window.documentEdited)) return YES;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Save changes to %@?", self.fileURL.lastPathComponent];
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Don't Save"];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        [self saveDocument:nil];
        return YES;
    }
    return response == NSAlertThirdButtonReturn;
}

#pragma mark Appearance

- (void)toggleAppearance:(id)sender {
    NSString *next = appIsDark() ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua;
    NSApp.appearance = [NSAppearance appearanceNamed:next];
    [[NSUserDefaults standardUserDefaults] setObject:next forKey:kAppearanceKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:kAppearanceChanged object:nil];
}

- (void)refreshAppearanceIcon {
    NSString *symbol = appIsDark() ? @"sun.max" : @"moon";
    self.appearanceButton.image = [NSImage imageWithSystemSymbolName:symbol
                                            accessibilityDescription:@"Light/dark mode"];
}

#pragma mark File watching

// Re-render whenever the file changes; editors often replace the file
// atomically (rename), so re-arm the watcher on rename/delete.
- (void)startWatching {
    int fd = open(self.fileURL.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return;
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_VNODE, fd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_DELETE,
        dispatch_get_main_queue());
    __weak ViewerController *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        ViewerController *strongSelf = weakSelf;
        if (!strongSelf) return;
        unsigned long events = dispatch_source_get_data(source);
        [strongSelf render];
        if (events & (DISPATCH_VNODE_RENAME | DISPATCH_VNODE_DELETE)) {
            dispatch_source_cancel(source);
            strongSelf.monitor = nil;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [weakSelf startWatching]; });
        }
    });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    dispatch_resume(source);
    self.monitor = source;
}

- (void)windowWillClose:(NSNotification *)notification {
    if (self.monitor) dispatch_source_cancel(self.monitor);
    self.monitor = nil;
    if (self.onClose) self.onClose();
}

- (void)reload:(id)sender { [self render]; }
- (void)zoomIn:(id)sender { self.webView.pageZoom = MIN(self.webView.pageZoom + 0.1, 3.0); }
- (void)zoomOut:(id)sender { self.webView.pageZoom = MAX(self.webView.pageZoom - 0.1, 0.5); }
- (void)actualSize:(id)sender { self.webView.pageZoom = 1.0; }

@end

#pragma mark - App delegate

@implementation AppDelegate {
    NSMutableArray<ViewerController *> *_viewers;
}

- (instancetype)init {
    self = [super init];
    _viewers = [NSMutableArray array];
    return self;
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) [self openFile:url];
}

- (BOOL)applicationOpenUntitledFile:(NSApplication *)sender {
    [self openDocument:nil];
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)openFile:(NSURL *)url {
    url = url.URLByStandardizingPath;
    for (ViewerController *viewer in _viewers) {
        if ([viewer.fileURL isEqual:url]) {
            [viewer.window makeKeyAndOrderFront:nil];
            [viewer render];
            return;
        }
    }
    ViewerController *viewer = [[ViewerController alloc] initWithFileURL:url];
    __weak AppDelegate *weakSelf = self;
    __weak ViewerController *weakViewer = viewer;
    viewer.onClose = ^{
        // Defer removal to the next runloop turn. Removing the viewer here
        // drops the last strong reference and would dealloc the window while
        // AppKit is still mid-close and holds it in the autorelease pool —
        // draining that pool would then over-release the freed window (crash).
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *strongSelf = weakSelf;
            if (strongSelf && weakViewer) [strongSelf->_viewers removeObject:weakViewer];
        });
    };
    [_viewers addObject:viewer];
    [viewer.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)openDocument:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    UTType *markdown = [UTType typeWithIdentifier:@"net.daringfireball.markdown"];
    panel.allowedContentTypes = @[markdown ?: UTTypePlainText];
    panel.allowsMultipleSelection = YES;
    if ([panel runModal] == NSModalResponseOK) {
        for (NSURL *url in panel.URLs) [self openFile:url];
    }
}

@end

#pragma mark - Menu bar

static NSMenu *buildMenu(void) {
    NSMenu *main = [NSMenu new];

    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"About Markdown Viewer"
                       action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Markdown Viewer" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Quit Markdown Viewer" action:@selector(terminate:) keyEquivalent:@"q"];
    [main addItemWithTitle:@"App" action:nil keyEquivalent:@""].submenu = appMenu;

    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Open…" action:@selector(openDocument:) keyEquivalent:@"o"];
    [fileMenu addItemWithTitle:@"Save" action:@selector(saveDocument:) keyEquivalent:@"s"];
    [fileMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [main addItemWithTitle:@"File" action:nil keyEquivalent:@""].submenu = fileMenu;

    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Find…" action:@selector(performTextFinderAction:) keyEquivalent:@"f"];
    [main addItemWithTitle:@"Edit" action:nil keyEquivalent:@""].submenu = editMenu;

    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    [viewMenu addItemWithTitle:@"Toggle Editing" action:@selector(toggleEdit:) keyEquivalent:@"e"];
    NSMenuItem *dark = [viewMenu addItemWithTitle:@"Toggle Light/Dark Mode"
                                           action:@selector(toggleAppearance:) keyEquivalent:@"D"];
    dark.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"Reload" action:@selector(reload:) keyEquivalent:@"r"];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"Actual Size" action:@selector(actualSize:) keyEquivalent:@"0"];
    [viewMenu addItemWithTitle:@"Zoom In" action:@selector(zoomIn:) keyEquivalent:@"+"];
    [viewMenu addItemWithTitle:@"Zoom Out" action:@selector(zoomOut:) keyEquivalent:@"-"];
    [main addItemWithTitle:@"View" action:nil keyEquivalent:@""].submenu = viewMenu;

    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [main addItemWithTitle:@"Window" action:nil keyEquivalent:@""].submenu = windowMenu;
    NSApp.windowsMenu = windowMenu;

    return main;
}

#pragma mark - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        NSString *savedAppearance = [[NSUserDefaults standardUserDefaults] stringForKey:kAppearanceKey];
        if (savedAppearance) app.appearance = [NSAppearance appearanceNamed:savedAppearance];
        static AppDelegate *delegate;
        delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        app.mainMenu = buildMenu();
        [app run];
    }
    return 0;
}

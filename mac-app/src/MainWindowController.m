//  MainWindowController.m  — tabbed window with shared status bar

#import "MainWindowController.h"
#import "PerfTestViewController.h"
#import "LatencyTestViewController.h"

@implementation MainWindowController {
    PerfTestViewController    *_perfVC;
    LatencyTestViewController *_latencyVC;
    NSTabView                 *_tabView;

    // Status area
    NSTextField             *_statusLabel;
    NSProgressIndicator     *_progressBar;
    NSButton                *_cancelButton;
    NSTextField             *_connLabel;

    // Content view
    NSView                  *_contentArea;
}

- (instancetype)init
{
    NSRect frame = NSMakeRect(0, 0, 620, 620);
    NSUInteger style = NSWindowStyleMaskTitled
                     | NSWindowStyleMaskClosable
                     | NSWindowStyleMaskMiniaturizable
                     | NSWindowStyleMaskResizable;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                               styleMask:style
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    self = [super initWithWindow:win];
    if (self) [self _setup];
    return self;
}

- (void)_setup
{
    NSWindow *win = self.window;
    win.title = @"MegaWifi Network Perf Test";
    win.minSize = NSMakeSize(580, 520);
    win.delegate = self;
    win.releasedWhenClosed = NO;

    win.titlebarAppearsTransparent = YES;
    if (@available(macOS 11.0, *)) {
        win.toolbarStyle = NSWindowToolbarStyleUnified;
    }

    [win center];

    [self _buildContentView];
    [self _buildStatusBar];

    // Create view controllers
    _perfVC = [[PerfTestViewController alloc] initWithWindowController:self];
    _latencyVC = [[LatencyTestViewController alloc] initWithWindowController:self];

    // Build tab view
    _tabView = [[NSTabView alloc] init];
    _tabView.translatesAutoresizingMaskIntoConstraints = NO;
    _tabView.tabViewType = NSTopTabsBezelBorder;
    _tabView.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];

    NSTabViewItem *throughputTab = [[NSTabViewItem alloc] initWithIdentifier:@"throughput"];
    throughputTab.label = @"Throughput";
    throughputTab.view = _perfVC.view;
    [_tabView addTabViewItem:throughputTab];

    NSTabViewItem *latencyTab = [[NSTabViewItem alloc] initWithIdentifier:@"latency"];
    latencyTab.label = @"Latency";
    latencyTab.view = _latencyVC.view;
    [_tabView addTabViewItem:latencyTab];

    [_contentArea addSubview:_tabView];
    [NSLayoutConstraint activateConstraints:@[
        [_tabView.topAnchor      constraintEqualToAnchor:_contentArea.topAnchor constant:8],
        [_tabView.bottomAnchor   constraintEqualToAnchor:_contentArea.bottomAnchor constant:-4],
        [_tabView.leadingAnchor  constraintEqualToAnchor:_contentArea.leadingAnchor constant:8],
        [_tabView.trailingAnchor constraintEqualToAnchor:_contentArea.trailingAnchor constant:-8],
    ]];
}

// ---------------------------------------------------------------------------
#pragma mark - Build UI
// ---------------------------------------------------------------------------

- (void)_buildContentView
{
    NSView *root = self.window.contentView;

    NSVisualEffectView *vev = [[NSVisualEffectView alloc] init];
    vev.material     = NSVisualEffectMaterialSidebar;
    vev.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    vev.state        = NSVisualEffectStateActive;
    vev.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:vev];
    _contentArea = vev;

    [NSLayoutConstraint activateConstraints:@[
        [_contentArea.topAnchor      constraintEqualToAnchor:root.topAnchor],
        [_contentArea.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor],
        [_contentArea.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_contentArea.bottomAnchor   constraintEqualToAnchor:root.bottomAnchor constant:-56],
    ]];
}

- (void)_buildStatusBar
{
    NSView *root = self.window.contentView;

    NSVisualEffectView *statusBg = [[NSVisualEffectView alloc] init];
    statusBg.material     = NSVisualEffectMaterialSidebar;
    statusBg.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    statusBg.state        = NSVisualEffectStateActive;
    statusBg.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:statusBg positioned:NSWindowBelow relativeTo:nil];

    // Connection indicator (right-aligned)
    _connLabel = [NSTextField labelWithString:@""];
    _connLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _connLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    _connLabel.textColor = [NSColor secondaryLabelColor];
    [statusBg addSubview:_connLabel];

    // Progress bar
    _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _progressBar.style = NSProgressIndicatorStyleBar;
    _progressBar.indeterminate = NO;
    _progressBar.minValue = 0; _progressBar.maxValue = 1;
    _progressBar.doubleValue = 0;
    _progressBar.controlSize = NSControlSizeSmall;
    _progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    _progressBar.hidden = YES;
    [statusBg addSubview:_progressBar];

    // Status label
    _statusLabel = [NSTextField labelWithString:@"Ready"];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [NSFont systemFontOfSize:11];
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [statusBg addSubview:_statusLabel];

    // Cancel button
    _cancelButton = [NSButton buttonWithTitle:@"Stop"
                                       target:self
                                       action:@selector(_cancel:)];
    _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    _cancelButton.hidden = YES;
    _cancelButton.controlSize = NSControlSizeSmall;
    [statusBg addSubview:_cancelButton];

    [NSLayoutConstraint activateConstraints:@[
        [statusBg.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor],
        [statusBg.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [statusBg.bottomAnchor   constraintEqualToAnchor:root.bottomAnchor],
        [statusBg.heightAnchor   constraintEqualToConstant:56],

        [_progressBar.leadingAnchor  constraintEqualToAnchor:statusBg.leadingAnchor  constant:12],
        [_progressBar.trailingAnchor constraintEqualToAnchor:statusBg.trailingAnchor constant:-12],
        [_progressBar.centerYAnchor  constraintEqualToAnchor:statusBg.topAnchor constant:14],

        [_statusLabel.leadingAnchor  constraintEqualToAnchor:statusBg.leadingAnchor constant:12],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:statusBg.trailingAnchor constant:-12],
        [_statusLabel.centerYAnchor  constraintEqualToAnchor:statusBg.topAnchor constant:14],

        [_connLabel.trailingAnchor constraintEqualToAnchor:statusBg.trailingAnchor constant:-12],
        [_connLabel.centerYAnchor  constraintEqualToAnchor:statusBg.topAnchor constant:42],

        [_cancelButton.trailingAnchor constraintEqualToAnchor:_connLabel.leadingAnchor constant:-8],
        [_cancelButton.centerYAnchor  constraintEqualToAnchor:statusBg.topAnchor constant:42],
    ]];
}

// ---------------------------------------------------------------------------
#pragma mark - Public interface
// ---------------------------------------------------------------------------

- (void)setStatus:(NSString *)message
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_statusLabel.stringValue = message ?: @"";
    });
}

- (void)setProgress:(double)fraction
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (fraction < 0) {
            self->_progressBar.hidden = YES;
            self->_progressBar.doubleValue = 0;
            self->_statusLabel.hidden = NO;
        } else {
            self->_progressBar.hidden = NO;
            self->_statusLabel.hidden = YES;
            self->_progressBar.doubleValue = fraction;
        }
    });
}

- (void)setOperationActive:(BOOL)active
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_cancelButton.hidden = !active;
        if (!active) {
            [self setProgress:-1];
        }
    });
}

- (void)setConnectionStatus:(NSString *)text color:(NSColor *)color
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_connLabel.stringValue = text;
        self->_connLabel.textColor = color;
    });
}

- (void)_cancel:(id)sender
{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MWPerfCancelRequested"
                                                        object:nil];
    [self setStatus:@"Stopping..."];
}

@end

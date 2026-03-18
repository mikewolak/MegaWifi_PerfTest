//  PerfTestViewController.m  — Network performance test panel

#import "PerfTestViewController.h"
#import "MainWindowController.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <unistd.h>
#import <errno.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// ---------------------------------------------------------------------------
#pragma mark - Helpers
// ---------------------------------------------------------------------------

static NSView *separator(void)
{
    NSBox *sep = [[NSBox alloc] init];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.boxType = NSBoxSeparator;
    return sep;
}

static NSTextField *sectionTitle(NSString *text)
{
    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.font = [NSFont boldSystemFontOfSize:13];
    lbl.textColor = [NSColor labelColor];
    return lbl;
}

static NSTextField *fieldLabel(NSString *text)
{
    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.font = [NSFont systemFontOfSize:12];
    lbl.alignment = NSTextAlignmentRight;
    return lbl;
}

static NSTextField *inputField(NSString *text, CGFloat width)
{
    NSTextField *f = [NSTextField textFieldWithString:text];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    return f;
}

static NSTextField *statsLabel(NSString *text)
{
    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    lbl.textColor = [NSColor secondaryLabelColor];
    return lbl;
}

// ---------------------------------------------------------------------------
#pragma mark - Implementation
// ---------------------------------------------------------------------------

@implementation PerfTestViewController {
    // Connection
    NSTextField         *_hostField;
    NSTextField         *_portField;

    // Configuration
    NSPopUpButton       *_blockSizePopup;
    NSTextField         *_numBlocksField;
    NSPopUpButton       *_protocolPopup;
    NSButton            *_continuousCheck;

    // Live stats
    NSProgressIndicator *_testProgress;
    NSTextField         *_progressLabel;
    NSTextField         *_rateLabel;
    NSTextField         *_timingLabel;

    // Log
    NSTextView          *_logView;
    NSScrollView        *_logScroll;

    // Controls
    NSButton            *_startButton;
    NSButton            *_exportButton;

    // State
    BOOL                 _running;
    BOOL                 _cancelled;
    int                  _sock;
    dispatch_queue_t     _netQueue;
    NSMutableArray<NSDictionary *> *_results;
}

- (instancetype)initWithWindowController:(MainWindowController *)wc
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _windowController = wc;
        _sock = -1;
        _netQueue = dispatch_queue_create("com.megawifi.perf.net", DISPATCH_QUEUE_SERIAL);
        _results = [NSMutableArray array];
    }
    return self;
}

#define LM  20.0   // left margin
#define LW  90.0   // label width
#define FG   8.0   // field gap after label

- (void)loadView
{
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 620, 540)];
    self.view = root;

    // ═══════════════════════════════════════════════════════════════════════
    // CONNECTION
    // ═══════════════════════════════════════════════════════════════════════
    NSTextField *connTitle = sectionTitle(@"Connection");
    [root addSubview:connTitle];

    NSTextField *hostLabel = fieldLabel(@"Host:");
    [root addSubview:hostLabel];

    _hostField = inputField(@"192.168.1.199", 180);
    _hostField.placeholderString = @"Genesis IP address";
    [root addSubview:_hostField];

    NSString *savedHost = [[NSUserDefaults standardUserDefaults] stringForKey:@"perfLastHost"];
    if (savedHost.length) _hostField.stringValue = savedHost;

    NSTextField *portLabel = fieldLabel(@"Port:");
    [root addSubview:portLabel];

    _portField = inputField(@"2026", 60);
    [root addSubview:_portField];

    NSView *sep1 = separator();
    [root addSubview:sep1];

    // ═══════════════════════════════════════════════════════════════════════
    // TEST CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════
    NSTextField *cfgTitle = sectionTitle(@"Test Configuration");
    [root addSubview:cfgTitle];

    NSTextField *bsLabel = fieldLabel(@"Block Size:");
    [root addSubview:bsLabel];

    _blockSizePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _blockSizePopup.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSString *s in @[@"64", @"128", @"256", @"512", @"1024", @"1460"])
        [_blockSizePopup addItemWithTitle:s];
    [_blockSizePopup selectItemWithTitle:@"512"];
    [root addSubview:_blockSizePopup];

    NSTextField *nbLabel = fieldLabel(@"Num Blocks:");
    [root addSubview:nbLabel];

    _numBlocksField = inputField(@"100", 70);
    [root addSubview:_numBlocksField];

    NSTextField *protoLabel = fieldLabel(@"Protocol:");
    [root addSubview:protoLabel];

    _protocolPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _protocolPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [_protocolPopup addItemWithTitle:@"TCP"];
    [_protocolPopup addItemWithTitle:@"UDP"];
    [root addSubview:_protocolPopup];

    _continuousCheck = [NSButton checkboxWithTitle:@"Continuous (repeat until stopped)"
                                            target:nil action:nil];
    _continuousCheck.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_continuousCheck];

    NSView *sep2 = separator();
    [root addSubview:sep2];

    // ═══════════════════════════════════════════════════════════════════════
    // LIVE STATISTICS
    // ═══════════════════════════════════════════════════════════════════════
    NSTextField *statTitle = sectionTitle(@"Live Statistics");
    [root addSubview:statTitle];

    _testProgress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _testProgress.style = NSProgressIndicatorStyleBar;
    _testProgress.indeterminate = NO;
    _testProgress.minValue = 0; _testProgress.maxValue = 1;
    _testProgress.doubleValue = 0;
    _testProgress.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_testProgress];

    _progressLabel = statsLabel(@"0% (0/0)");
    _progressLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium];
    [root addSubview:_progressLabel];

    _rateLabel = statsLabel(@"TX: --.-  RX: --.-  RTT: --.- ms");
    [root addSubview:_rateLabel];

    _timingLabel = statsLabel(@"Elapsed: --  ETA: --  Sent: --");
    [root addSubview:_timingLabel];

    NSView *sep3 = separator();
    [root addSubview:sep3];

    // ═══════════════════════════════════════════════════════════════════════
    // RESULTS LOG
    // ═══════════════════════════════════════════════════════════════════════
    NSTextField *logTitle = sectionTitle(@"Results Log");
    [root addSubview:logTitle];

    _logScroll = [[NSScrollView alloc] init];
    _logScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _logScroll.hasVerticalScroller = YES;
    _logScroll.borderType = NSBezelBorder;

    _logView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 560, 100)];
    _logView.editable = NO;
    _logView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _logView.backgroundColor = [NSColor textBackgroundColor];
    _logView.textColor = [NSColor textColor];
    _logView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _logScroll.documentView = _logView;
    [root addSubview:_logScroll];

    // ═══════════════════════════════════════════════════════════════════════
    // BUTTONS
    // ═══════════════════════════════════════════════════════════════════════
    _startButton = [NSButton buttonWithTitle:@"Start Test" target:self action:@selector(_startStop:)];
    _startButton.bezelStyle = NSBezelStyleRounded;
    _startButton.translatesAutoresizingMaskIntoConstraints = NO;
    _startButton.keyEquivalent = @"\r";
    [root addSubview:_startButton];

    _exportButton = [NSButton buttonWithTitle:@"Export CSV" target:self action:@selector(_exportCSV:)];
    _exportButton.bezelStyle = NSBezelStyleRounded;
    _exportButton.translatesAutoresizingMaskIntoConstraints = NO;
    _exportButton.enabled = NO;
    [root addSubview:_exportButton];

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRAINTS — top-to-bottom waterfall
    // ═══════════════════════════════════════════════════════════════════════
    [NSLayoutConstraint activateConstraints:@[
        // -- Connection --
        [connTitle.topAnchor      constraintEqualToAnchor:root.topAnchor constant:16],
        [connTitle.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],

        [hostLabel.topAnchor      constraintEqualToAnchor:connTitle.bottomAnchor constant:10],
        [hostLabel.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],
        [hostLabel.widthAnchor    constraintEqualToConstant:LW],

        [_hostField.leadingAnchor constraintEqualToAnchor:hostLabel.trailingAnchor constant:FG],
        [_hostField.centerYAnchor constraintEqualToAnchor:hostLabel.centerYAnchor],
        [_hostField.widthAnchor   constraintEqualToConstant:180],

        [portLabel.leadingAnchor  constraintEqualToAnchor:_hostField.trailingAnchor constant:20],
        [portLabel.centerYAnchor  constraintEqualToAnchor:hostLabel.centerYAnchor],
        [portLabel.widthAnchor    constraintEqualToConstant:40],

        [_portField.leadingAnchor constraintEqualToAnchor:portLabel.trailingAnchor constant:FG],
        [_portField.centerYAnchor constraintEqualToAnchor:hostLabel.centerYAnchor],
        [_portField.widthAnchor   constraintEqualToConstant:60],

        [sep1.topAnchor      constraintEqualToAnchor:hostLabel.bottomAnchor constant:12],
        [sep1.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],
        [sep1.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-LM],

        // -- Test Configuration --
        [cfgTitle.topAnchor      constraintEqualToAnchor:sep1.bottomAnchor constant:12],
        [cfgTitle.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],

        // Row 1: Block Size + Num Blocks
        [bsLabel.topAnchor      constraintEqualToAnchor:cfgTitle.bottomAnchor constant:10],
        [bsLabel.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],
        [bsLabel.widthAnchor    constraintEqualToConstant:LW],

        [_blockSizePopup.leadingAnchor constraintEqualToAnchor:bsLabel.trailingAnchor constant:FG],
        [_blockSizePopup.centerYAnchor constraintEqualToAnchor:bsLabel.centerYAnchor],
        [_blockSizePopup.widthAnchor   constraintEqualToConstant:90],

        [nbLabel.leadingAnchor  constraintEqualToAnchor:_blockSizePopup.trailingAnchor constant:24],
        [nbLabel.centerYAnchor  constraintEqualToAnchor:bsLabel.centerYAnchor],
        [nbLabel.widthAnchor    constraintEqualToConstant:LW],

        [_numBlocksField.leadingAnchor constraintEqualToAnchor:nbLabel.trailingAnchor constant:FG],
        [_numBlocksField.centerYAnchor constraintEqualToAnchor:bsLabel.centerYAnchor],
        [_numBlocksField.widthAnchor   constraintEqualToConstant:70],

        // Row 2: Protocol + Continuous
        [protoLabel.topAnchor      constraintEqualToAnchor:bsLabel.bottomAnchor constant:10],
        [protoLabel.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],
        [protoLabel.widthAnchor    constraintEqualToConstant:LW],

        [_protocolPopup.leadingAnchor constraintEqualToAnchor:protoLabel.trailingAnchor constant:FG],
        [_protocolPopup.centerYAnchor constraintEqualToAnchor:protoLabel.centerYAnchor],
        [_protocolPopup.widthAnchor   constraintEqualToConstant:90],

        [_continuousCheck.leadingAnchor constraintEqualToAnchor:_protocolPopup.trailingAnchor constant:24],
        [_continuousCheck.centerYAnchor constraintEqualToAnchor:protoLabel.centerYAnchor],

        [sep2.topAnchor      constraintEqualToAnchor:protoLabel.bottomAnchor constant:12],
        [sep2.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],
        [sep2.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-LM],

        // -- Live Statistics --
        [statTitle.topAnchor      constraintEqualToAnchor:sep2.bottomAnchor constant:12],
        [statTitle.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],

        [_testProgress.topAnchor      constraintEqualToAnchor:statTitle.bottomAnchor constant:10],
        [_testProgress.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],
        [_testProgress.widthAnchor    constraintEqualToConstant:370],
        [_testProgress.heightAnchor   constraintEqualToConstant:18],

        [_progressLabel.leadingAnchor constraintEqualToAnchor:_testProgress.trailingAnchor constant:10],
        [_progressLabel.centerYAnchor constraintEqualToAnchor:_testProgress.centerYAnchor],

        [_rateLabel.topAnchor     constraintEqualToAnchor:_testProgress.bottomAnchor constant:8],
        [_rateLabel.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:LM],

        [_timingLabel.topAnchor     constraintEqualToAnchor:_rateLabel.bottomAnchor constant:4],
        [_timingLabel.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:LM],

        [sep3.topAnchor      constraintEqualToAnchor:_timingLabel.bottomAnchor constant:12],
        [sep3.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],
        [sep3.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-LM],

        // -- Results Log --
        [logTitle.topAnchor      constraintEqualToAnchor:sep3.bottomAnchor constant:12],
        [logTitle.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],

        [_logScroll.topAnchor      constraintEqualToAnchor:logTitle.bottomAnchor constant:8],
        [_logScroll.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],
        [_logScroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-LM],
        [_logScroll.bottomAnchor   constraintEqualToAnchor:_startButton.topAnchor constant:-12],

        // -- Buttons --
        [_startButton.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:LM],
        [_startButton.bottomAnchor  constraintEqualToAnchor:root.bottomAnchor constant:-12],
        [_startButton.widthAnchor   constraintEqualToConstant:140],

        [_exportButton.leadingAnchor constraintEqualToAnchor:_startButton.trailingAnchor constant:12],
        [_exportButton.bottomAnchor  constraintEqualToAnchor:root.bottomAnchor constant:-12],
        [_exportButton.widthAnchor   constraintEqualToConstant:120],
    ]];

    // Listen for cancel
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_handleCancel:)
                                                 name:@"MWPerfCancelRequested"
                                               object:nil];
}

// ---------------------------------------------------------------------------
#pragma mark - Logging
// ---------------------------------------------------------------------------

- (void)appendLog:(NSString *)line
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *text = [line stringByAppendingString:@"\n"];
        NSAttributedString *as = [[NSAttributedString alloc]
            initWithString:text
                attributes:@{
                    NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
                    NSForegroundColorAttributeName: [NSColor textColor],
                }];
        [self->_logView.textStorage appendAttributedString:as];
        [self->_logView scrollToEndOfDocument:nil];
    });
}

- (void)clearLog
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_logView.string = @"";
    });
}

// ---------------------------------------------------------------------------
#pragma mark - UI updates
// ---------------------------------------------------------------------------

- (void)updateStatsOnMain:(uint32_t)done
                    total:(uint32_t)total
                  elapsed:(double)elapsed
                  txBytes:(uint64_t)txBytes
                  rxBytes:(uint64_t)rxBytes
                   rttAvg:(double)rttAvg
                   rttMin:(double)rttMin
                   rttMax:(double)rttMax
{
    dispatch_async(dispatch_get_main_queue(), ^{
        double frac = total > 0 ? (double)done / total : 0;
        self->_testProgress.doubleValue = frac;

        self->_progressLabel.stringValue = [NSString stringWithFormat:@"%d%% (%u/%u)",
                                            (int)(frac * 100), done, total];

        double txRate = elapsed > 0 ? txBytes / elapsed / 1024.0 : 0;
        double rxRate = elapsed > 0 ? rxBytes / elapsed / 1024.0 : 0;

        self->_rateLabel.stringValue = [NSString stringWithFormat:
            @"TX: %6.1f KB/s   RX: %6.1f KB/s   RTT: %.1f ms",
            txRate, rxRate, rttAvg];

        double eta = (done > 0 && done < total) ? elapsed / done * (total - done) : 0;
        self->_timingLabel.stringValue = [NSString stringWithFormat:
            @"Elapsed: %.1fs   ETA: %.1fs   Sent: %.1f KB   RTT: %.1f-%.1f ms",
            elapsed, eta, txBytes / 1024.0, rttMin, rttMax];
    });
}

// ---------------------------------------------------------------------------
#pragma mark - Network helpers
// ---------------------------------------------------------------------------

static double nowSec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int tcpConnect(const char *host, uint16_t port, int timeout_ms)
{
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%u", port);

    int gai = getaddrinfo(host, portStr, &hints, &res);
    if (gai != 0 || !res) {
        errno = EHOSTUNREACH;
        return -1;
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); return -1; }

    // Non-blocking connect with select() timeout
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);

    if (rc < 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }

    if (rc != 0) {
        fd_set wset;
        FD_ZERO(&wset);
        FD_SET(fd, &wset);
        struct timeval tv = { .tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000 };

        rc = select(fd + 1, NULL, &wset, NULL, &tv);
        if (rc <= 0) {
            close(fd);
            errno = ETIMEDOUT;
            return -1;
        }

        // Check for connect error
        int err = 0;
        socklen_t elen = sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen);
        if (err != 0) {
            close(fd);
            errno = err;
            return -1;
        }
    }

    // Back to blocking + set recv/send timeouts
    fcntl(fd, F_SETFL, flags);
    struct timeval tv = { .tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    return fd;
}

static int sendAll(int fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, p + sent, len - sent, 0);
        if (n <= 0) return -1;
        sent += n;
    }
    return 0;
}

static int recvAll(int fd, void *buf, size_t len)
{
    uint8_t *p = buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n <= 0) return -1;
        got += n;
    }
    return 0;
}

// ---------------------------------------------------------------------------
#pragma mark - Test execution
// ---------------------------------------------------------------------------

- (void)_startStop:(id)sender
{
    if (_running) {
        _cancelled = YES;
        return;
    }

    NSString *host = _hostField.stringValue;
    if (!host.length) {
        [_windowController setStatus:@"Enter a host address."];
        return;
    }

    [[NSUserDefaults standardUserDefaults] setObject:host forKey:@"perfLastHost"];

    uint16_t port = (uint16_t)[_portField.stringValue integerValue];
    if (port == 0) port = 2026;

    uint16_t blockSize = (uint16_t)[_blockSizePopup.titleOfSelectedItem integerValue];
    uint16_t numBlocks = (uint16_t)[_numBlocksField.stringValue integerValue];
    if (numBlocks == 0) numBlocks = 100;

    BOOL continuous = (_continuousCheck.state == NSControlStateValueOn);

    _running = YES;
    _cancelled = NO;
    _startButton.title = @"Stop Test";
    _exportButton.enabled = NO;
    [_results removeAllObjects];
    [self clearLog];
    // Reset progress bar instantly (no animation) before starting
    [NSAnimationContext beginGrouping];
    [[NSAnimationContext currentContext] setDuration:0];
    _testProgress.doubleValue = 0;
    [NSAnimationContext endGrouping];
    _progressLabel.stringValue = @"0% (0/0)";
    [_windowController setOperationActive:YES];

    dispatch_async(_netQueue, ^{
        [self _runTestWithHost:host port:port blockSize:blockSize
                     numBlocks:numBlocks continuous:continuous];
    });
}

- (void)_runTestWithHost:(NSString *)host
                    port:(uint16_t)port
               blockSize:(uint16_t)blockSize
               numBlocks:(uint16_t)numBlocks
              continuous:(BOOL)continuous
{
    uint32_t session = 0;

    do {
        session++;
        if (session > 1) {
            [self appendLog:[NSString stringWithFormat:@"\n── Session %u ──", session]];
            struct timespec ts = { .tv_sec = 3, .tv_nsec = 0 };
            nanosleep(&ts, NULL);
        }

        [self appendLog:[NSString stringWithFormat:@"Connecting to %@:%u...", host, port]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_windowController setStatus:
                [NSString stringWithFormat:@"Connecting to %@:%u...", host, port]];
            [self->_windowController setConnectionStatus:@"● Connecting..."
                                                   color:[NSColor systemOrangeColor]];
        });

        int fd = tcpConnect(host.UTF8String, port, 10000);
        if (fd < 0) {
            int e = errno;
            [self appendLog:[NSString stringWithFormat:@"Connection failed: %s (errno %d)", strerror(e), e]];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_windowController setStatus:
                    [NSString stringWithFormat:@"Connection failed: %s", strerror(e)]];
                [self->_windowController setConnectionStatus:@"● Disconnected"
                                                       color:[NSColor tertiaryLabelColor]];
            });
            break;
        }
        _sock = fd;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_windowController setConnectionStatus:@"● Connected"
                                                   color:[NSColor systemGreenColor]];
        });

        // Wait for Genesis server to arm recv after mw_sock_conn_wait
        struct timespec delay = { .tv_sec = 0, .tv_nsec = 500000000 };
        nanosleep(&delay, NULL);

        // Handshake
        uint8_t hs[4];
        hs[0] = (blockSize >> 8) & 0xFF;
        hs[1] = blockSize & 0xFF;
        hs[2] = (numBlocks >> 8) & 0xFF;
        hs[3] = numBlocks & 0xFF;

        if (sendAll(fd, hs, 4) != 0) {
            [self appendLog:@"Handshake send failed."];
            close(fd); _sock = -1;
            break;
        }

        uint8_t ack[4];
        if (recvAll(fd, ack, 4) != 0 || memcmp(ack, hs, 4) != 0) {
            [self appendLog:@"Handshake ACK failed."];
            close(fd); _sock = -1;
            break;
        }

        [self appendLog:[NSString stringWithFormat:
            @"Handshake OK  block_size=%u  num_blocks=%u", blockSize, numBlocks]];
        [self appendLog:@"  Seq#    Send(ms)    RTT(ms)    Bytes"];
        [self appendLog:@"  ----    --------    -------    -----"];

        // Reset progress bar instantly (no reverse animation) before each session
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSAnimationContext beginGrouping];
            [[NSAnimationContext currentContext] setDuration:0];
            self->_testProgress.doubleValue = 0;
            [NSAnimationContext endGrouping];
            self->_progressLabel.stringValue = [NSString stringWithFormat:@"0%% (0/%u)", numBlocks];
        });

        uint8_t *payload = malloc(blockSize);
        uint8_t *echoBuf = malloc(blockSize);
        for (uint32_t i = 0; i < blockSize; i++)
            payload[i] = (uint8_t)(i & 0xFF);

        double testStart = nowSec();
        uint64_t txTotal = 0, rxTotal = 0;
        double rttSum = 0, rttMin = 1e9, rttMax = 0;
        uint32_t okCount = 0;

        for (uint32_t b = 0; b < numBlocks; b++) {
            if (_cancelled) break;

            double sendStart = nowSec();

            if (sendAll(fd, payload, blockSize) != 0) {
                [self appendLog:[NSString stringWithFormat:@"  Block %u: send failed", b]];
                break;
            }
            txTotal += blockSize;

            double sendDone = nowSec();

            if (recvAll(fd, echoBuf, blockSize) != 0) {
                [self appendLog:[NSString stringWithFormat:@"  Block %u: recv failed", b]];
                break;
            }
            rxTotal += blockSize;

            double recvDone = nowSec();
            double rtt = (recvDone - sendStart) * 1000.0;
            double sendMs = (sendStart - testStart) * 1000.0;

            rttSum += rtt;
            if (rtt < rttMin) rttMin = rtt;
            if (rtt > rttMax) rttMax = rtt;
            okCount++;

            BOOL match = (memcmp(payload, echoBuf, blockSize) == 0);

            [_results addObject:@{
                @"block": @(b),
                @"sendStart": @(sendMs),
                @"sendDone": @((sendDone - testStart) * 1000.0),
                @"recvDone": @((recvDone - testStart) * 1000.0),
                @"rtt": @(rtt),
                @"bytes": @(blockSize),
                @"match": @(match),
            }];

            [self appendLog:[NSString stringWithFormat:
                @"  %4u    %8.1f    %7.1f    %5u%@",
                b, sendMs, rtt, blockSize, match ? @"" : @"  MISMATCH"]];

            if ((b & 3) == 0 || b == numBlocks - 1) {
                double elapsed = nowSec() - testStart;
                double rttAvg = okCount > 0 ? rttSum / okCount : 0;
                [self updateStatsOnMain:b + 1
                                  total:numBlocks
                                elapsed:elapsed
                                txBytes:txTotal
                                rxBytes:rxTotal
                                 rttAvg:rttAvg
                                 rttMin:rttMin
                                 rttMax:rttMax];
            }
        }

        free(payload);
        free(echoBuf);
        close(fd);
        _sock = -1;

        double totalElapsed = nowSec() - testStart;
        double avgRtt = okCount > 0 ? rttSum / okCount : 0;
        double throughput = totalElapsed > 0 ? (txTotal + rxTotal) / totalElapsed / 1024.0 : 0;

        [self appendLog:@""];
        [self appendLog:[NSString stringWithFormat:@"  Completed: %u/%u blocks OK", okCount, numBlocks]];
        [self appendLog:[NSString stringWithFormat:@"  Throughput: %.1f KB/s  (%.1f KB sent, %.1f KB received)",
                         throughput, txTotal / 1024.0, rxTotal / 1024.0]];
        [self appendLog:[NSString stringWithFormat:@"  RTT avg: %.1f ms  min: %.1f ms  max: %.1f ms",
                         avgRtt, rttMin, rttMax]];
        [self appendLog:[NSString stringWithFormat:@"  Total time: %.2f s", totalElapsed]];

        [self updateStatsOnMain:okCount total:numBlocks elapsed:totalElapsed
                        txBytes:txTotal rxBytes:rxTotal rttAvg:avgRtt rttMin:rttMin rttMax:rttMax];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_windowController setStatus:
                [NSString stringWithFormat:@"Done — %u/%u blocks, %.1f KB/s, %.1f ms avg RTT",
                 okCount, numBlocks, throughput, avgRtt]];
            [self->_windowController setConnectionStatus:@"● Disconnected"
                                                   color:[NSColor tertiaryLabelColor]];
        });

    } while (continuous && !_cancelled);

    dispatch_async(dispatch_get_main_queue(), ^{
        self->_running = NO;
        self->_startButton.title = @"Start Test";
        self->_exportButton.enabled = (self->_results.count > 0);
        [self->_windowController setOperationActive:NO];
    });
}

// ---------------------------------------------------------------------------
#pragma mark - Cancel
// ---------------------------------------------------------------------------

- (void)_handleCancel:(NSNotification *)note
{
    _cancelled = YES;
    if (_sock >= 0) {
        close(_sock);
        _sock = -1;
    }
}

// ---------------------------------------------------------------------------
#pragma mark - CSV Export
// ---------------------------------------------------------------------------

- (void)_exportCSV:(id)sender
{
    if (_results.count == 0) return;

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"perf_results.csv";
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"csv"]];

    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || !panel.URL) return;

        NSMutableString *csv = [NSMutableString string];
        [csv appendString:@"Block,SendStart(ms),SendDone(ms),RecvDone(ms),RTT(ms),Bytes,Match\n"];

        for (NSDictionary *rec in self->_results) {
            [csv appendFormat:@"%@,%.3f,%.3f,%.3f,%.3f,%@,%@\n",
             rec[@"block"], [rec[@"sendStart"] doubleValue],
             [rec[@"sendDone"] doubleValue], [rec[@"recvDone"] doubleValue],
             [rec[@"rtt"] doubleValue], rec[@"bytes"],
             [rec[@"match"] boolValue] ? @"OK" : @"MISMATCH"];
        }

        NSError *err;
        [csv writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&err];
        if (err) {
            [self->_windowController setStatus:
                [NSString stringWithFormat:@"Export failed: %@", err.localizedDescription]];
        } else {
            [self->_windowController setStatus:
                [NSString stringWithFormat:@"Exported %lu records to %@",
                 (unsigned long)self->_results.count, panel.URL.lastPathComponent]];
        }
    }];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_sock >= 0) close(_sock);
}

@end

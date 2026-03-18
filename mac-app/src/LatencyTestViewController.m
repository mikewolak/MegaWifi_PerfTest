//  LatencyTestViewController.m  — LSD round-trip latency measurement

#import "LatencyTestViewController.h"
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

static NSView *lat_separator(void)
{
    NSBox *sep = [[NSBox alloc] init];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.boxType = NSBoxSeparator;
    return sep;
}

static NSTextField *lat_sectionTitle(NSString *text)
{
    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.font = [NSFont boldSystemFontOfSize:13];
    lbl.textColor = [NSColor labelColor];
    return lbl;
}

static NSTextField *lat_fieldLabel(NSString *text)
{
    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.font = [NSFont systemFontOfSize:12];
    lbl.alignment = NSTextAlignmentRight;
    return lbl;
}

static NSTextField *lat_inputField(NSString *text, CGFloat width)
{
    (void)width;
    NSTextField *f = [NSTextField textFieldWithString:text];
    f.translatesAutoresizingMaskIntoConstraints = NO;
    f.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    return f;
}

static NSTextField *lat_statsLabel(NSString *text)
{
    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    lbl.textColor = [NSColor secondaryLabelColor];
    return lbl;
}

// ---------------------------------------------------------------------------
#pragma mark - Network helpers
// ---------------------------------------------------------------------------

static double lat_nowSec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int lat_tcpConnect(const char *host, uint16_t port, int timeout_ms)
{
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%u", port);

    int gai = getaddrinfo(host, portStr, &hints, &res);
    if (gai != 0 || !res) { errno = EHOSTUNREACH; return -1; }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); return -1; }

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);

    if (rc < 0 && errno != EINPROGRESS) { close(fd); return -1; }

    if (rc != 0) {
        fd_set wset;
        FD_ZERO(&wset);
        FD_SET(fd, &wset);
        struct timeval tv = { .tv_sec = timeout_ms / 1000,
                              .tv_usec = (timeout_ms % 1000) * 1000 };
        rc = select(fd + 1, NULL, &wset, NULL, &tv);
        if (rc <= 0) { close(fd); errno = ETIMEDOUT; return -1; }

        int err = 0;
        socklen_t elen = sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen);
        if (err != 0) { close(fd); errno = err; return -1; }
    }

    fcntl(fd, F_SETFL, flags);
    struct timeval tv = { .tv_sec = timeout_ms / 1000,
                          .tv_usec = (timeout_ms % 1000) * 1000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    return fd;
}

static int lat_sendAll(int fd, const void *buf, size_t len)
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

static int lat_recvAll(int fd, void *buf, size_t len)
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
#pragma mark - Implementation
// ---------------------------------------------------------------------------

#define VBLANK_MS  16.6667   // 1 frame at 60 Hz

@implementation LatencyTestViewController {
    // Connection
    NSTextField         *_hostField;
    NSTextField         *_portField;

    // Configuration
    NSPopUpButton       *_payloadPopup;
    NSTextField         *_pingCountField;

    // Summary stats
    NSTextField         *_summaryLabel1;
    NSTextField         *_summaryLabel2;
    NSTextField         *_summaryLabel3;

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
        _netQueue = dispatch_queue_create("com.megawifi.latency.net", DISPATCH_QUEUE_SERIAL);
        _results = [NSMutableArray array];
    }
    return self;
}

#define LM  20.0
#define LW  90.0
#define FG   8.0

- (void)loadView
{
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 620, 540)];
    self.view = root;

    // === CONNECTION ===
    NSTextField *connTitle = lat_sectionTitle(@"Connection");
    [root addSubview:connTitle];

    NSTextField *hostLabel = lat_fieldLabel(@"Host:");
    [root addSubview:hostLabel];

    _hostField = lat_inputField(@"192.168.1.199", 180);
    _hostField.placeholderString = @"Genesis IP address";
    [root addSubview:_hostField];

    NSString *savedHost = [[NSUserDefaults standardUserDefaults] stringForKey:@"perfLastHost"];
    if (savedHost.length) _hostField.stringValue = savedHost;

    NSTextField *portLabel = lat_fieldLabel(@"Port:");
    [root addSubview:portLabel];

    _portField = lat_inputField(@"2026", 60);
    [root addSubview:_portField];

    NSView *sep1 = lat_separator();
    [root addSubview:sep1];

    // === PING CONFIGURATION ===
    NSTextField *cfgTitle = lat_sectionTitle(@"Ping Configuration");
    [root addSubview:cfgTitle];

    NSTextField *plLabel = lat_fieldLabel(@"Payload:");
    [root addSubview:plLabel];

    _payloadPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _payloadPopup.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSString *s in @[@"4", @"16", @"64", @"128", @"256", @"512", @"1024", @"1460"])
        [_payloadPopup addItemWithTitle:s];
    [_payloadPopup selectItemWithTitle:@"4"];
    [root addSubview:_payloadPopup];

    NSTextField *plUnit = lat_fieldLabel(@"bytes");
    plUnit.alignment = NSTextAlignmentLeft;
    [root addSubview:plUnit];

    NSTextField *pcLabel = lat_fieldLabel(@"Pings:");
    [root addSubview:pcLabel];

    _pingCountField = lat_inputField(@"100", 70);
    [root addSubview:_pingCountField];

    NSView *sep2 = lat_separator();
    [root addSubview:sep2];

    // === SUMMARY STATISTICS ===
    NSTextField *statTitle = lat_sectionTitle(@"Summary");
    [root addSubview:statTitle];

    _summaryLabel1 = lat_statsLabel(@"RTT:  min --  avg --  max --  ms");
    [root addSubview:_summaryLabel1];

    _summaryLabel2 = lat_statsLabel(@"VBlk: min --  avg --  max --  frames");
    [root addSubview:_summaryLabel2];

    _summaryLabel3 = lat_statsLabel(@"Jitter: --  ms    Completed: --/--");
    [root addSubview:_summaryLabel3];

    NSView *sep3 = lat_separator();
    [root addSubview:sep3];

    // === PING LOG ===
    NSTextField *logTitle = lat_sectionTitle(@"Ping Log");
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

    // === BUTTONS ===
    _startButton = [NSButton buttonWithTitle:@"Start Ping"
                                      target:self action:@selector(_startStop:)];
    _startButton.bezelStyle = NSBezelStyleRounded;
    _startButton.translatesAutoresizingMaskIntoConstraints = NO;
    _startButton.keyEquivalent = @"\r";
    [root addSubview:_startButton];

    _exportButton = [NSButton buttonWithTitle:@"Export CSV"
                                       target:self action:@selector(_exportCSV:)];
    _exportButton.bezelStyle = NSBezelStyleRounded;
    _exportButton.translatesAutoresizingMaskIntoConstraints = NO;
    _exportButton.enabled = NO;
    [root addSubview:_exportButton];

    // === CONSTRAINTS ===
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

        // -- Ping Configuration --
        [cfgTitle.topAnchor      constraintEqualToAnchor:sep1.bottomAnchor constant:12],
        [cfgTitle.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],

        [plLabel.topAnchor      constraintEqualToAnchor:cfgTitle.bottomAnchor constant:10],
        [plLabel.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],
        [plLabel.widthAnchor    constraintEqualToConstant:LW],

        [_payloadPopup.leadingAnchor constraintEqualToAnchor:plLabel.trailingAnchor constant:FG],
        [_payloadPopup.centerYAnchor constraintEqualToAnchor:plLabel.centerYAnchor],
        [_payloadPopup.widthAnchor   constraintEqualToConstant:90],

        [plUnit.leadingAnchor  constraintEqualToAnchor:_payloadPopup.trailingAnchor constant:6],
        [plUnit.centerYAnchor  constraintEqualToAnchor:plLabel.centerYAnchor],

        [pcLabel.leadingAnchor  constraintEqualToAnchor:plUnit.trailingAnchor constant:24],
        [pcLabel.centerYAnchor  constraintEqualToAnchor:plLabel.centerYAnchor],
        [pcLabel.widthAnchor    constraintEqualToConstant:LW],

        [_pingCountField.leadingAnchor constraintEqualToAnchor:pcLabel.trailingAnchor constant:FG],
        [_pingCountField.centerYAnchor constraintEqualToAnchor:plLabel.centerYAnchor],
        [_pingCountField.widthAnchor   constraintEqualToConstant:70],

        [sep2.topAnchor      constraintEqualToAnchor:plLabel.bottomAnchor constant:12],
        [sep2.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],
        [sep2.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-LM],

        // -- Summary --
        [statTitle.topAnchor      constraintEqualToAnchor:sep2.bottomAnchor constant:12],
        [statTitle.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],

        [_summaryLabel1.topAnchor     constraintEqualToAnchor:statTitle.bottomAnchor constant:8],
        [_summaryLabel1.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:LM],

        [_summaryLabel2.topAnchor     constraintEqualToAnchor:_summaryLabel1.bottomAnchor constant:4],
        [_summaryLabel2.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:LM],

        [_summaryLabel3.topAnchor     constraintEqualToAnchor:_summaryLabel2.bottomAnchor constant:4],
        [_summaryLabel3.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:LM],

        [sep3.topAnchor      constraintEqualToAnchor:_summaryLabel3.bottomAnchor constant:12],
        [sep3.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:LM],
        [sep3.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-LM],

        // -- Ping Log --
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
#pragma mark - Summary update
// ---------------------------------------------------------------------------

- (void)updateSummary:(uint32_t)done
                total:(uint32_t)total
               rttMin:(double)rMin
               rttAvg:(double)rAvg
               rttMax:(double)rMax
               jitter:(double)jitter
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_summaryLabel1.stringValue = [NSString stringWithFormat:
            @"RTT:  min %.1f  avg %.1f  max %.1f  ms", rMin, rAvg, rMax];

        self->_summaryLabel2.stringValue = [NSString stringWithFormat:
            @"VBlk: min %.1f  avg %.1f  max %.1f  frames",
            rMin / VBLANK_MS, rAvg / VBLANK_MS, rMax / VBLANK_MS];

        self->_summaryLabel3.stringValue = [NSString stringWithFormat:
            @"Jitter: %.1f ms    Completed: %u/%u", jitter, done, total];
    });
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

    uint16_t payload = (uint16_t)[_payloadPopup.titleOfSelectedItem integerValue];
    uint16_t pingCount = (uint16_t)[_pingCountField.stringValue integerValue];
    if (pingCount == 0) pingCount = 100;

    _running = YES;
    _cancelled = NO;
    _startButton.title = @"Stop";
    _exportButton.enabled = NO;
    [_results removeAllObjects];
    [self clearLog];
    [_windowController setOperationActive:YES];

    dispatch_async(_netQueue, ^{
        [self _runPingWithHost:host port:port payload:payload count:pingCount];
    });
}

- (void)_runPingWithHost:(NSString *)host
                    port:(uint16_t)port
                 payload:(uint16_t)payload
                   count:(uint16_t)count
{
    [self appendLog:[NSString stringWithFormat:@"Connecting to %@:%u...", host, port]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_windowController setStatus:
            [NSString stringWithFormat:@"Connecting to %@:%u...", host, port]];
        [self->_windowController setConnectionStatus:@"● Connecting..."
                                               color:[NSColor systemOrangeColor]];
    });

    int fd = lat_tcpConnect(host.UTF8String, port, 10000);
    if (fd < 0) {
        int e = errno;
        [self appendLog:[NSString stringWithFormat:@"Connection failed: %s (errno %d)",
                         strerror(e), e]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_windowController setStatus:
                [NSString stringWithFormat:@"Connection failed: %s", strerror(e)]];
            [self->_windowController setConnectionStatus:@"● Disconnected"
                                                   color:[NSColor tertiaryLabelColor]];
        });
        [self _finish];
        return;
    }
    _sock = fd;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_windowController setConnectionStatus:@"● Connected"
                                               color:[NSColor systemGreenColor]];
    });

    // Wait for Genesis server to arm recv
    struct timespec delay = { .tv_sec = 0, .tv_nsec = 500000000 };
    nanosleep(&delay, NULL);

    // Handshake — use echo protocol: [blk_sz:u16][num_blks:u16]
    uint8_t hs[4];
    hs[0] = (payload >> 8) & 0xFF;
    hs[1] = payload & 0xFF;
    hs[2] = (count >> 8) & 0xFF;
    hs[3] = count & 0xFF;

    if (lat_sendAll(fd, hs, 4) != 0) {
        [self appendLog:@"Handshake send failed."];
        close(fd); _sock = -1;
        [self _finish];
        return;
    }

    uint8_t ack[4];
    if (lat_recvAll(fd, ack, 4) != 0 || memcmp(ack, hs, 4) != 0) {
        [self appendLog:@"Handshake ACK failed."];
        close(fd); _sock = -1;
        [self _finish];
        return;
    }

    [self appendLog:[NSString stringWithFormat:
        @"Handshake OK  payload=%u bytes  pings=%u", payload, count]];
    [self appendLog:@""];
    [self appendLog:@"  Ping#     RTT(ms)   VBlank(frames)"];
    [self appendLog:@"  -----     -------   --------------"];

    uint8_t *buf = malloc(payload);
    uint8_t *echoBuf = malloc(payload);
    for (uint32_t i = 0; i < payload; i++)
        buf[i] = (uint8_t)(i & 0xFF);

    double rttMin = 1e9, rttMax = 0, rttSum = 0, rttSumSq = 0;
    uint32_t ok = 0;

    for (uint32_t p = 0; p < count; p++) {
        if (_cancelled) break;

        double t0 = lat_nowSec();

        if (lat_sendAll(fd, buf, payload) != 0) {
            [self appendLog:[NSString stringWithFormat:@"  %5u     SEND FAILED", p]];
            break;
        }

        if (lat_recvAll(fd, echoBuf, payload) != 0) {
            [self appendLog:[NSString stringWithFormat:@"  %5u     RECV FAILED", p]];
            break;
        }

        double rtt = (lat_nowSec() - t0) * 1000.0;
        BOOL match = (memcmp(buf, echoBuf, payload) == 0);

        rttSum += rtt;
        rttSumSq += rtt * rtt;
        if (rtt < rttMin) rttMin = rtt;
        if (rtt > rttMax) rttMax = rtt;
        ok++;

        double vblk = rtt / VBLANK_MS;

        [_results addObject:@{
            @"ping": @(p),
            @"rtt": @(rtt),
            @"vblank": @(vblk),
            @"match": @(match),
        }];

        [self appendLog:[NSString stringWithFormat:
            @"  %5u     %7.1f   %6.1f%@",
            p, rtt, vblk, match ? @"" : @"  MISMATCH"]];

        if ((p & 7) == 0 || p == count - 1) {
            double avg = ok > 0 ? rttSum / ok : 0;
            double variance = ok > 1 ? (rttSumSq - rttSum * rttSum / ok) / (ok - 1) : 0;
            double jitter = variance > 0 ? sqrt(variance) : 0;
            [self updateSummary:ok total:count
                         rttMin:rttMin rttAvg:avg rttMax:rttMax jitter:jitter];
        }
    }

    free(buf);
    free(echoBuf);
    close(fd);
    _sock = -1;

    // Final summary
    double avg = ok > 0 ? rttSum / ok : 0;
    double variance = ok > 1 ? (rttSumSq - rttSum * rttSum / ok) / (ok - 1) : 0;
    double jitter = variance > 0 ? sqrt(variance) : 0;

    [self updateSummary:ok total:count rttMin:rttMin rttAvg:avg rttMax:rttMax jitter:jitter];

    [self appendLog:@""];
    [self appendLog:[NSString stringWithFormat:@"  Completed: %u/%u pings", ok, count]];
    [self appendLog:[NSString stringWithFormat:@"  RTT   min: %.1f  avg: %.1f  max: %.1f ms",
                     rttMin, avg, rttMax]];
    [self appendLog:[NSString stringWithFormat:@"  VBlank min: %.1f  avg: %.1f  max: %.1f frames",
                     rttMin / VBLANK_MS, avg / VBLANK_MS, rttMax / VBLANK_MS]];
    [self appendLog:[NSString stringWithFormat:@"  Jitter: %.1f ms (std dev)", jitter]];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_windowController setStatus:
            [NSString stringWithFormat:@"Done — %u pings, avg %.1f ms (%.1f VBlanks)",
             ok, avg, avg / VBLANK_MS]];
        [self->_windowController setConnectionStatus:@"● Disconnected"
                                               color:[NSColor tertiaryLabelColor]];
    });

    [self _finish];
}

- (void)_finish
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_running = NO;
        self->_startButton.title = @"Start Ping";
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
    panel.nameFieldStringValue = @"latency_results.csv";
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"csv"]];

    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || !panel.URL) return;

        NSMutableString *csv = [NSMutableString string];
        [csv appendString:@"Ping,RTT(ms),VBlank(frames),Match\n"];

        for (NSDictionary *rec in self->_results) {
            [csv appendFormat:@"%@,%.3f,%.2f,%@\n",
             rec[@"ping"], [rec[@"rtt"] doubleValue],
             [rec[@"vblank"] doubleValue],
             [rec[@"match"] boolValue] ? @"OK" : @"MISMATCH"];
        }

        NSError *err;
        [csv writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&err];
        if (err) {
            [self->_windowController setStatus:
                [NSString stringWithFormat:@"Export failed: %@", err.localizedDescription]];
        } else {
            [self->_windowController setStatus:
                [NSString stringWithFormat:@"Exported %lu pings to %@",
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

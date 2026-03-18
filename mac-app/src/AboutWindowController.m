//  AboutWindowController.m

#import "AboutWindowController.h"
#import "me_floyd_png.h"
#import <SceneKit/SceneKit.h>

@implementation AboutWindowController

+ (instancetype)sharedController
{
    static AboutWindowController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AboutWindowController alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    NSRect frame = NSMakeRect(0, 0, 380, 535);
    NSWindowStyleMask style = NSWindowStyleMaskTitled
                            | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                styleMask:style
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.title = @"About MegaWifi Perf";
    win.releasedWhenClosed = NO;

    self = [super initWithWindow:win];
    if (!self) return nil;

    [self buildUI];
    [win center];
    return self;
}

// ── Clickable link label ──────────────────────────────────────────────────────
- (NSTextField *)linkLabelWithTitle:(NSString *)title url:(NSString *)urlString fontSize:(CGFloat)size
{
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.editable = NO;
    field.selectable = YES;
    field.allowsEditingTextAttributes = YES;

    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.alignment = NSTextAlignmentCenter;

    NSMutableAttributedString *str = [[NSMutableAttributedString alloc] initWithString:title];
    NSRange all = NSMakeRange(0, str.length);
    [str addAttribute:NSLinkAttributeName           value:[NSURL URLWithString:urlString] range:all];
    [str addAttribute:NSFontAttributeName           value:[NSFont systemFontOfSize:size]  range:all];
    [str addAttribute:NSParagraphStyleAttributeName value:para                            range:all];
    field.attributedStringValue = str;
    return field;
}

// ── Grid tile texture ─────────────────────────────────────────────────────────
- (NSImage *)gridTile
{
    const CGFloat px = 128.0;
    NSImage *img = [NSImage imageWithSize:NSMakeSize(px, px)
                                  flipped:NO
                           drawingHandler:^BOOL(NSRect rect) {
        [[NSColor blackColor] setFill];
        NSRectFill(rect);

        NSColor *green = [NSColor colorWithRed:0.0 green:0.95 blue:0.3 alpha:1.0];
        [green setStroke];

        NSBezierPath *p = [NSBezierPath bezierPath];
        p.lineWidth = 2.0;

        [p moveToPoint:NSMakePoint(0,  0)];
        [p lineToPoint:NSMakePoint(px, 0)];

        [p moveToPoint:NSMakePoint(0, 0)];
        [p lineToPoint:NSMakePoint(0, px)];

        [p stroke];
        return YES;
    }];
    return img;
}

- (SCNMaterial *)gridMaterialWithRepeatS:(CGFloat)rs repeatT:(CGFloat)rt
{
    NSImage *tile = [self gridTile];
    SCNMaterial *m = [SCNMaterial material];
    m.lightingModelName = SCNLightingModelConstant;

    m.diffuse.contents             = tile;
    m.diffuse.wrapS                = SCNWrapModeRepeat;
    m.diffuse.wrapT                = SCNWrapModeRepeat;
    m.diffuse.contentsTransform    = SCNMatrix4MakeScale(rs, rt, 1);

    m.emission.contents            = tile;
    m.emission.wrapS               = SCNWrapModeRepeat;
    m.emission.wrapT               = SCNWrapModeRepeat;
    m.emission.contentsTransform   = SCNMatrix4MakeScale(rs, rt, 1);

    return m;
}

- (void)buildUI
{
    NSView *content = self.window.contentView;

    // ── SceneKit view ─────────────────────────────────────────────────────────
    SCNView *scnView = [[SCNView alloc] initWithFrame:NSZeroRect];
    scnView.translatesAutoresizingMaskIntoConstraints = NO;
    scnView.backgroundColor = [NSColor blackColor];
    scnView.antialiasingMode = SCNAntialiasingModeMultisampling4X;
    scnView.allowsCameraControl = NO;
    [content addSubview:scnView];

    // ── Text labels ───────────────────────────────────────────────────────────
    NSTextField *title = [NSTextField labelWithString:@"MegaWifi Network Perf Test"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [NSFont boldSystemFontOfSize:20];
    title.textColor = [NSColor labelColor];
    title.alignment = NSTextAlignmentCenter;
    [content addSubview:title];

    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0";
    NSTextField *version = [NSTextField labelWithString:[NSString stringWithFormat:@"Version %@", ver]];
    version.translatesAutoresizingMaskIntoConstraints = NO;
    version.font = [NSFont systemFontOfSize:13];
    version.textColor = [NSColor secondaryLabelColor];
    version.alignment = NSTextAlignmentCenter;
    [content addSubview:version];

    NSTextField *dateLabel = [NSTextField labelWithString:@"March 17, 2026"];
    dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    dateLabel.font = [NSFont systemFontOfSize:12];
    dateLabel.textColor = [NSColor tertiaryLabelColor];
    dateLabel.alignment = NSTextAlignmentCenter;
    [content addSubview:dateLabel];

    NSTextField *emailLabel = [NSTextField labelWithString:@"mikewolak@gmail.com"];
    emailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    emailLabel.font = [NSFont systemFontOfSize:12];
    emailLabel.textColor = [NSColor tertiaryLabelColor];
    emailLabel.alignment = NSTextAlignmentCenter;
    [content addSubview:emailLabel];

    NSTextField *repoLabel = [self linkLabelWithTitle:@"github.com/mikewolak"
                                                  url:@"https://github.com/mikewolak"
                                             fontSize:11];
    [content addSubview:repoLabel];

    NSTextField *basedOnLabel = [self linkLabelWithTitle:@"MegaWifi ESP32-C3 by doragasu"
                                                     url:@"https://gitlab.com/doragasu/mw"
                                                fontSize:10];
    [content addSubview:basedOnLabel];

    // ── Layout ────────────────────────────────────────────────────────────────
    [NSLayoutConstraint activateConstraints:@[
        [scnView.topAnchor constraintEqualToAnchor:content.topAnchor],
        [scnView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [scnView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scnView.heightAnchor constraintEqualToConstant:340],

        [title.topAnchor constraintEqualToAnchor:scnView.bottomAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [title.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],

        [version.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [version.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [version.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],

        [dateLabel.topAnchor constraintEqualToAnchor:version.bottomAnchor constant:4],
        [dateLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [dateLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],

        [emailLabel.topAnchor constraintEqualToAnchor:dateLabel.bottomAnchor constant:8],
        [emailLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [emailLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],

        [repoLabel.topAnchor constraintEqualToAnchor:emailLabel.bottomAnchor constant:3],
        [repoLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [repoLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],

        [basedOnLabel.topAnchor constraintEqualToAnchor:repoLabel.bottomAnchor constant:10],
        [basedOnLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [basedOnLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
    ]];

    // ── Scene ─────────────────────────────────────────────────────────────────
    SCNScene *scene = [SCNScene scene];
    scnView.scene = scene;

    scene.fogColor          = [NSColor blackColor];
    scene.fogStartDistance  = 10.0;
    scene.fogEndDistance    = 30.0;

    // ── Camera ────────────────────────────────────────────────────────────────
    SCNNode *cameraNode = [SCNNode node];
    cameraNode.camera = [SCNCamera camera];
    cameraNode.camera.fieldOfView = 60.0;
    cameraNode.position = SCNVector3Make(0, 3.2, 6.5);
    cameraNode.eulerAngles = SCNVector3Make(-0.42, 0, 0);
    [scene.rootNode addChildNode:cameraNode];

    // ── Lighting ──────────────────────────────────────────────────────────────
    SCNNode *ambient = [SCNNode node];
    ambient.light = [SCNLight light];
    ambient.light.type = SCNLightTypeAmbient;
    ambient.light.color = [NSColor colorWithWhite:0.15 alpha:1.0];
    [scene.rootNode addChildNode:ambient];

    SCNNode *fill = [SCNNode node];
    fill.light = [SCNLight light];
    fill.light.type = SCNLightTypeOmni;
    fill.light.color = [NSColor colorWithRed:0.0 green:0.8 blue:0.25 alpha:1.0];
    fill.light.intensity = 400;
    fill.position = SCNVector3Make(0, 8, 0);
    [scene.rootNode addChildNode:fill];

    SCNNode *key = [SCNNode node];
    key.light = [SCNLight light];
    key.light.type = SCNLightTypeOmni;
    key.light.color = [NSColor colorWithWhite:0.9 alpha:1.0];
    key.light.intensity = 600;
    key.position = SCNVector3Make(4, 5, 6);
    [scene.rootNode addChildNode:key];

    // ── Floor ─────────────────────────────────────────────────────────────────
    SCNFloor *floorGeom = [SCNFloor floor];
    floorGeom.reflectivity       = 0.25;
    floorGeom.reflectionFalloffEnd = 12.0;
    floorGeom.materials = @[[self gridMaterialWithRepeatS:16 repeatT:16]];

    SCNNode *floorNode = [SCNNode nodeWithGeometry:floorGeom];
    floorNode.position = SCNVector3Make(0, -1.5, 0);
    [scene.rootNode addChildNode:floorNode];

    // ── Walls ─────────────────────────────────────────────────────────────────
    SCNPlane *backPlane = [SCNPlane planeWithWidth:30 height:18];
    backPlane.materials = @[[self gridMaterialWithRepeatS:10 repeatT:6]];
    SCNNode *backWall = [SCNNode nodeWithGeometry:backPlane];
    backWall.position = SCNVector3Make(0, 7.5, -15);
    [scene.rootNode addChildNode:backWall];

    SCNPlane *sidePlane = [SCNPlane planeWithWidth:30 height:18];
    sidePlane.materials = @[[self gridMaterialWithRepeatS:10 repeatT:6]];

    SCNNode *leftWall = [SCNNode nodeWithGeometry:sidePlane];
    leftWall.position = SCNVector3Make(-15, 7.5, 0);
    leftWall.eulerAngles = SCNVector3Make(0, M_PI_2, 0);
    [scene.rootNode addChildNode:leftWall];

    SCNNode *rightWall = [SCNNode nodeWithGeometry:sidePlane];
    rightWall.position = SCNVector3Make(15, 7.5, 0);
    rightWall.eulerAngles = SCNVector3Make(0, -M_PI_2, 0);
    [scene.rootNode addChildNode:rightWall];

    // ── Cube ──────────────────────────────────────────────────────────────────
    SCNBox *box = [SCNBox boxWithWidth:2.0 height:2.0 length:2.0 chamferRadius:0.08];

    NSData  *pngData = [NSData dataWithBytesNoCopy:(void *)me_floyd_png_data
                                            length:me_floyd_png_data_len
                                      freeWhenDone:NO];
    NSImage *img = [[NSImage alloc] initWithData:pngData];

    SCNMaterial *cubeMat = [SCNMaterial material];
    cubeMat.diffuse.contents  = img ?: [NSColor systemPurpleColor];
    cubeMat.specular.contents = [NSColor colorWithWhite:0.6 alpha:1.0];
    cubeMat.shininess = 0.6;
    box.materials = @[cubeMat, cubeMat, cubeMat, cubeMat, cubeMat, cubeMat];

    SCNNode *cubeNode = [SCNNode nodeWithGeometry:box];
    cubeNode.position = SCNVector3Make(0, -0.2, 0);
    [scene.rootNode addChildNode:cubeNode];

    // Rotation animation
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"rotation"];
    spin.fromValue   = [NSValue valueWithSCNVector4:SCNVector4Make(1, 0.4, 0.2, 0)];
    spin.toValue     = [NSValue valueWithSCNVector4:SCNVector4Make(1, 0.4, 0.2, M_PI * 2)];
    spin.duration    = 6.0;
    spin.repeatCount = HUGE_VALF;
    [cubeNode addAnimation:spin forKey:@"spin"];

    scnView.playing = YES;
}

@end

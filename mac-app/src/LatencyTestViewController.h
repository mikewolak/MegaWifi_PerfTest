//  LatencyTestViewController.h

#import <Cocoa/Cocoa.h>
@class MainWindowController;

@interface LatencyTestViewController : NSViewController

@property (nonatomic, weak) MainWindowController *windowController;

- (instancetype)initWithWindowController:(MainWindowController *)wc;

@end

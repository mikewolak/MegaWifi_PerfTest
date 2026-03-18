//  PerfTestViewController.h

#import <Cocoa/Cocoa.h>
@class MainWindowController;

@interface PerfTestViewController : NSViewController

@property (nonatomic, weak) MainWindowController *windowController;

- (instancetype)initWithWindowController:(MainWindowController *)wc;

@end

//  MainWindowController.h

#import <Cocoa/Cocoa.h>

@interface MainWindowController : NSWindowController <NSWindowDelegate>

- (void)setStatus:(NSString *)message;
- (void)setProgress:(double)fraction;  // 0..1; pass -1 to hide bar
- (void)setOperationActive:(BOOL)active;
- (void)setConnectionStatus:(NSString *)text color:(NSColor *)color;

@end

//  AppDelegate.m

#import "AppDelegate.h"
#import "MainWindowController.h"
#import "AboutWindowController.h"

@implementation AppDelegate {
    MainWindowController *_mainWindowController;
}

- (void)buildMenu
{
    NSMenu *menuBar = [[NSMenu alloc] init];
    [NSApp setMainMenu:menuBar];

    // App menu
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [menuBar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    appItem.submenu = appMenu;

    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About MegaWifi Perf"
                                                       action:@selector(showAbout:)
                                                keyEquivalent:@""];
    aboutItem.target = self;
    [appMenu addItem:aboutItem];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit MegaWifi Perf"
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [appMenu addItem:quitItem];

    // Help menu
    NSMenuItem *helpItem = [[NSMenuItem alloc] init];
    [menuBar addItem:helpItem];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    helpItem.submenu = helpMenu;

    NSMenuItem *helpAbout = [[NSMenuItem alloc] initWithTitle:@"About MegaWifi Perf"
                                                       action:@selector(showAbout:)
                                                keyEquivalent:@""];
    helpAbout.target = self;
    [helpMenu addItem:helpAbout];
}

- (IBAction)showAbout:(id)sender
{
    [[AboutWindowController sharedController] showWindow:nil];
    [[AboutWindowController sharedController].window makeKeyAndOrderFront:nil];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    [self buildMenu];
    _mainWindowController = [[MainWindowController alloc] init];
    [_mainWindowController showWindow:nil];
    [_mainWindowController.window makeKeyAndOrderFront:nil];
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

@end

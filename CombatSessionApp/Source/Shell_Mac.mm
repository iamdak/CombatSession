// CombatSession :: Tray, macOS
//
// An NSStatusItem in the menu bar, which is what a tray icon is here.
//
// Two differences from the Windows host shape the code. The status item and its
// menu must be touched only on the main thread, so Update marshals; and AppKit
// owns the event loop, so Run is [NSApp run] rather than a loop of our own.

#include "Shell.h"

#include "Icon.h"
#include "Platform.h"

#import <Cocoa/Cocoa.h>

#include <atomic>
#include <cstring>
#include <string>
#include <vector>

namespace cs {
namespace {

NSString* Str(const std::string& text) {
    return [NSString stringWithUTF8String:text.c_str()];
}

// The renderer produces 0xAARRGGBB words, which is the byte order a Windows DIB
// wants and is not the one asked for here. Unpacked into plain R,G,B,A bytes
// rather than declared with endian flags: the shifts say what the layout is in
// the code, where a NSBitmapFormat combination would only say it in a name, and
// this runs three times at startup.
NSImage* MakeIcon(uint32_t accent) {
    const std::vector<uint32_t> pixels = RenderTrayIcon(accent);

    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:nullptr
                      pixelsWide:kIconSize
                      pixelsHigh:kIconSize
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                    bitmapFormat:0
                     bytesPerRow:kIconSize * 4
                    bitsPerPixel:32];
    if (!rep) return nil;

    unsigned char* out = [rep bitmapData];
    for (size_t i = 0; i < pixels.size(); ++i) {
        const uint32_t pixel = pixels[i];
        out[i * 4 + 0] = static_cast<unsigned char>((pixel >> 16) & 0xFF);  // R
        out[i * 4 + 1] = static_cast<unsigned char>((pixel >>  8) & 0xFF);  // G
        out[i * 4 + 2] = static_cast<unsigned char>( pixel        & 0xFF);  // B
        out[i * 4 + 3] = static_cast<unsigned char>((pixel >> 24) & 0xFF);  // A
    }

    // Menu bar height is 22 points regardless of the icon's pixel size, and a
    // status item that does not say its size gets drawn at the pixel size.
    NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
    [image addRepresentation:rep];

    // Deliberately not a template image. A template is recoloured by the system
    // to match the menu bar, which would throw away the green/amber/red that is
    // the entire point of the icon.
    //
    // Set through the setter, not the property: `template` is a C++ keyword, so
    // the dot form does not compile in Objective-C++.
    [image setTemplate:NO];
    return image;
}

} // namespace
} // namespace cs

//------------------------------------------------------------------------------

// Menu actions have to land on an Objective-C object, so this is the bridge
// between a clicked NSMenuItem and the controller. The tag carries the id.
@interface CombatSessionTarget : NSObject
@property(nonatomic, assign) cs::AppController* controller;
- (void)itemClicked:(id)sender;
@end

@implementation CombatSessionTarget
- (void)itemClicked:(id)sender {
    if (!self.controller) return;
    NSMenuItem* item = (NSMenuItem*)sender;
    self.controller->OnCommand(static_cast<int>(item.tag));
}
@end

//------------------------------------------------------------------------------

namespace cs {
namespace {

class MacTray : public ShellHost {
public:
    explicit MacTray(AppController& controller) : controller_(controller) {}
    ~MacTray() override;

    bool Create();

    void Update(TrayState state, const std::string& tooltip) override;
    int  Run() override;
    void Quit() override;
    bool HasWindow() const override { return false; }

    // Called from the menu delegate when the user opens the menu.
    void RebuildMenu(NSMenu* menu);

private:
    void ApplyState(TrayState state);

    AppController&      controller_;
    NSStatusItem*        item_    = nil;
    // One strong pointer rather than a C array of three: an array of retained
    // object pointers inside a C++ class is the kind of thing ARC has opinions
    // about, and an NSArray is what the framework would hand back anyway.
    NSArray<NSImage*>*   icons_   = nil;
    CombatSessionTarget* target_  = nil;
    // NSMenu holds its delegate weakly, so something has to hold it strongly or
    // ARC releases it the moment it is assigned and the menu never rebuilds.
    id                   menuDelegate_ = nil;
    std::atomic<bool>    quitting_{ false };
};

MacTray* g_tray = nullptr;

} // namespace
} // namespace cs

//------------------------------------------------------------------------------

// Rebuilding on open is what gives the menu the same "state as of the click"
// behaviour the Windows host gets for free by constructing the menu inside the
// click handler.
@interface CombatSessionMenuDelegate : NSObject <NSMenuDelegate>
@end

@implementation CombatSessionMenuDelegate
- (void)menuNeedsUpdate:(NSMenu*)menu {
    if (cs::g_tray) cs::g_tray->RebuildMenu(menu);
}
@end

//------------------------------------------------------------------------------

namespace cs {
namespace {

void MacTray::RebuildMenu(NSMenu* menu) {
    [menu removeAllItems];

    for (const MenuItem& entry : controller_.BuildMenu(false)) {
        if (entry.separator) {
            [menu addItem:[NSMenuItem separatorItem]];
            continue;
        }

        NSMenuItem* item =
            [[NSMenuItem alloc] initWithTitle:Str(entry.label)
                                       action:@selector(itemClicked:)
                                keyEquivalent:@""];
        item.tag    = entry.id;
        item.target = target_;
        item.state  = entry.checked ? NSControlStateValueOn
                                    : NSControlStateValueOff;
        // Honoured because the menu has autoenablesItems off; see Create.
        item.enabled = entry.enabled;
        [menu addItem:item];
    }
}

bool MacTray::Create() {
    g_tray = this;

    // Accessory, not regular: the application belongs in the menu bar and
    // should have no Dock icon and no application menu, which is the macOS
    // equivalent of the tool window the Windows host hides behind.
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    item_ = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSSquareStatusItemLength];
    if (!item_) return false;

    // In TrayState order: Idle, Working, NeedsReload.
    icons_ = @[ MakeIcon(kIdleGreen),
                MakeIcon(kWorkingAmber),
                MakeIcon(kReloadRed) ];

    target_ = [[CombatSessionTarget alloc] init];
    target_.controller = &controller_;

    menuDelegate_ = [[CombatSessionMenuDelegate alloc] init];

    NSMenu* menu = [[NSMenu alloc] init];
    // Off, so a disabled item stays disabled. Left on, AppKit decides for itself
    // from whether any responder handles the action, and the status line would
    // come out enabled.
    menu.autoenablesItems = NO;
    menu.delegate = menuDelegate_;
    item_.menu = menu;

    ApplyState(TrayState::Idle);
    item_.button.toolTip = @"CombatSession - starting";
    return true;
}

void MacTray::ApplyState(TrayState state) {
    NSImage* image = icons_[static_cast<NSUInteger>(state)];
    if (image) item_.button.image = image;
}

void MacTray::Update(TrayState state, const std::string& tooltip) {
    if (quitting_) return;

    // Both resolved here, on the calling thread, and captured by value. The
    // watcher thread returns to its sleep immediately; the block runs whenever
    // the main thread next gets to it, and must not be reading a std::string
    // that has since gone out of scope.
    NSString* tip   = Str("CombatSession - " + tooltip);
    NSImage*  image = icons_[static_cast<NSUInteger>(state)];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!item_) return;
        if (image) item_.button.image = image;
        item_.button.toolTip = tip;
    });
}

int MacTray::Run() {
    [NSApp run];
    return 0;
}

void MacTray::Quit() {
    quitting_ = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (item_) {
            [[NSStatusBar systemStatusBar] removeStatusItem:item_];
            item_ = nil;
        }
        [NSApp stop:nil];

        // stop: only takes effect when the loop next processes an event, and a
        // menu bar app that nobody is clicking may not see one for a long time.
        // A dummy event wakes it so quitting is immediate.
        NSEvent* wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                           location:NSZeroPoint
                                      modifierFlags:0
                                          timestamp:0
                                       windowNumber:0
                                            context:nil
                                            subtype:0
                                              data1:0
                                              data2:0];
        [NSApp postEvent:wake atStart:YES];
    });
}

MacTray::~MacTray() {
    if (item_) [[NSStatusBar systemStatusBar] removeStatusItem:item_];
    g_tray = nullptr;
}

} // namespace

std::unique_ptr<ShellHost> CreateShell(AppController& controller) {
    auto tray = std::make_unique<MacTray>(controller);
    if (!tray->Create()) return nullptr;
    return tray;
}


// The first-run question, macOS.
//
// A panel rather than a window of our own: there is no main window on this
// system yet, so there is nothing for a custom dialog to be modal to, and the
// folder chooser already asks exactly the question. A wrong choice is rejected
// and the user is asked again rather than being left with a setting that will
// silently never work.
bool PromptForWowFolder(std::string& path) {
    for (;;) {
        const std::string picked = PickFolder(
            "Select the World of Warcraft folder "
            "(the one containing Logs and Interface)");
        if (picked.empty()) return false;          // cancelled

        if (LooksLikeFlavor(picked)) {
            path = picked;
            return true;
        }

        @autoreleasepool {
            NSAlert* alert = [[NSAlert alloc] init];
            alert.messageText = @"That is not a World of Warcraft folder";
            alert.informativeText =
                @"The folder must contain both Logs and Interface/AddOns. "
                 "Choose the flavor folder itself, usually named _retail_.";
            alert.alertStyle = NSAlertStyleWarning;
            [alert runModal];
        }
    }
}
} // namespace cs

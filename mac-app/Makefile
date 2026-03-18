# Makefile — MegaWifi Network Perf Test (native macOS Obj-C)
#
# Builds MegaWifiPerf.app in ./build/
#
# Requires only Xcode Command Line Tools — no external dependencies.

APP_NAME    = MegaWifiPerf
BUNDLE_NAME = $(APP_NAME).app
BUILD_DIR   = build
OBJ_DIR     = $(BUILD_DIR)/obj
APP_BUNDLE  = $(BUILD_DIR)/$(BUNDLE_NAME)
BINARY      = $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)

# --------------------------------------------------------------------------
# Toolchain
# --------------------------------------------------------------------------
CC      = clang
CFLAGS  = -Wall -O2 -fobjc-arc \
          -Isrc \
          -mmacosx-version-min=11.0

LDFLAGS = -framework Cocoa \
          -framework SceneKit \
          -framework QuartzCore \
          -framework UniformTypeIdentifiers

# --------------------------------------------------------------------------
# Sources
# --------------------------------------------------------------------------
SRC_C = src/me_floyd_png.c

SRC_M = src/main.m \
        src/AppDelegate.m \
        src/AboutWindowController.m \
        src/MainWindowController.m \
        src/PerfTestViewController.m

OBJS_C = $(patsubst %.c,$(OBJ_DIR)/%.o,$(SRC_C))
OBJS_M = $(patsubst %.m,$(OBJ_DIR)/%.o,$(SRC_M))
OBJS   = $(OBJS_C) $(OBJS_M)

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
DMG_NAME    = MegaWifiPerf
DMG_OUT     = $(BUILD_DIR)/$(DMG_NAME).dmg

.PHONY: all clean run dmg

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(BINARY) Resources/Info.plist Resources/AppIcon.icns
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp Resources/Info.plist    $(APP_BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns  $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@echo "Built $(APP_BUNDLE)"

$(BINARY): $(OBJS)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	$(CC) $(OBJS) $(LDFLAGS) -o $@

$(OBJ_DIR)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJ_DIR)/%.o: %.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

run: all
	open $(APP_BUNDLE)

# --------------------------------------------------------------------------
# DMG distribution package
# --------------------------------------------------------------------------
DMG_STAGING = $(BUILD_DIR)/dmg-staging

dmg: all
	@rm -f $(DMG_OUT)
	@rm -rf $(DMG_STAGING)
	@mkdir -p $(DMG_STAGING)
	@cp -R $(APP_BUNDLE) $(DMG_STAGING)/
	@ln -s /Applications $(DMG_STAGING)/Applications
	@echo "Creating DMG..."
	@hdiutil create \
	    -volname "MegaWifi Perf" \
	    -srcfolder $(DMG_STAGING) \
	    -ov -format UDZO \
	    $(DMG_OUT)
	@rm -rf $(DMG_STAGING)
	@echo "DMG ready: $(DMG_OUT)"

clean:
	rm -rf $(BUILD_DIR)

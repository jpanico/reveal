APP         := Reveal.app
BUILD       := build
INSTALL_DIR := $(HOME)/Applications
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PBS         := /System/Library/CoreServices/pbs

.PHONY: build install uninstall clean

# The bundle is small enough to rebuild from scratch every time.
build:
	rm -rf $(BUILD)/$(APP)
	mkdir -p $(BUILD)/$(APP)/Contents/MacOS
	cp Info.plist $(BUILD)/$(APP)/Contents/Info.plist
	swiftc -O -swift-version 6 -parse-as-library \
		-o $(BUILD)/$(APP)/Contents/MacOS/Reveal Sources/Reveal.swift
	codesign --force --sign - $(BUILD)/$(APP)

# Only the installed copy may claim the reveal: scheme, so the build copy
# is unregistered in case Launch Services found it. lsregister ignores a
# relative path, hence $(CURDIR). pbs -update refreshes the Services menu.
install: build
	rm -rf $(INSTALL_DIR)/$(APP)
	ditto $(BUILD)/$(APP) $(INSTALL_DIR)/$(APP)
	-$(LSREGISTER) -u $(CURDIR)/$(BUILD)/$(APP)
	$(LSREGISTER) -f $(INSTALL_DIR)/$(APP)
	$(PBS) -update

uninstall:
	-$(LSREGISTER) -u $(INSTALL_DIR)/$(APP)
	rm -rf $(INSTALL_DIR)/$(APP)
	$(PBS) -update

clean:
	rm -rf $(BUILD)

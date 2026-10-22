APP         := Reveal.app
BUILD       := build
INSTALL_DIR := $(HOME)/Applications
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PBS         := /System/Library/CoreServices/pbs
EXECUTABLE  := $(INSTALL_DIR)/$(APP)/Contents/MacOS/Reveal
AGENT       := biz.panmachine.reveal
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(AGENT).plist
DOMAIN      := gui/$(shell id -u)

.PHONY: build install uninstall stop clean

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
# The LaunchAgent then starts the new copy, which runs from then on.
install: build stop
	rm -rf $(INSTALL_DIR)/$(APP)
	ditto $(BUILD)/$(APP) $(INSTALL_DIR)/$(APP)
	-$(LSREGISTER) -u $(CURDIR)/$(BUILD)/$(APP)
	$(LSREGISTER) -f $(INSTALL_DIR)/$(APP)
	$(PBS) -update
	mkdir -p $(dir $(AGENT_PLIST))
	sed 's|@EXECUTABLE@|$(EXECUTABLE)|' $(AGENT).plist > $(AGENT_PLIST)
	launchctl bootstrap $(DOMAIN) $(AGENT_PLIST)

uninstall: stop
	rm -f $(AGENT_PLIST)
	-$(LSREGISTER) -u $(INSTALL_DIR)/$(APP)
	rm -rf $(INSTALL_DIR)/$(APP)
	$(PBS) -update

# Unloads the LaunchAgent, which stops its copy of the app, and stops any
# copy that Launch Services started for a link while the agent wasn't loaded.
stop:
	launchctl bootout $(DOMAIN)/$(AGENT) 2>/dev/null || true
	pkill -f '$(EXECUTABLE)' || true

clean:
	rm -rf $(BUILD)

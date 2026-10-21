APP := /Applications/OpenOats.app
BUILT := dist/OpenOats.app

.PHONY: install clean-test-defaults
# Build, ad-hoc sign, and replace the installed app. The old app goes to the Trash
# because macOS App Management blocks overwriting it in place.
install:
	SKIP_SIGN=1 SKIP_INSTALL=1 ./scripts/build_swift_app.sh
	codesign --force --deep --sign - $(BUILT)
	-osascript -e 'quit app "OpenOats"'
	@while pgrep -xq OpenOats; do sleep 0.5; done
	@if [ -e $(APP) ]; then trash $(APP); fi
	ditto $(BUILT) $(APP)
	codesign --verify --deep $(APP)
	@echo "Installed $(APP)"

# Remove the empty settings domains (com.openoats.test*) that test runs leave in ~/Library/Preferences.
clean-test-defaults:
	./scripts/clean_test_defaults.sh

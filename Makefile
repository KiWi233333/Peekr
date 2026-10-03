.PHONY: build dev inject app run dmg clean

# Quick compile check.
build:
	swift build

# CEF requires a real app bundle and helper processes. Build the bundle, then
# launch the Xcode/InjectionIII-compatible Debug app for SwiftUI hot reload.
# Follow Chromium's log after launch; Ctrl+C stops tail and closes the dev app.
dev:
	./scripts/bundle.sh debug
	./scripts/dev-inject.sh
	@cleanup() { \
		trap - 0 INT TERM; \
		pkill -f '[P]eekr\.app/Contents/MacOS/Peekr' 2>/dev/null || true; \
	}; \
	trap 'exit 130' INT; \
	trap 'exit 143' TERM; \
	trap cleanup 0; \
	echo "Following Chromium log (Ctrl+C stops log output and closes Peekr):"; \
	tail -F "$${HOME}/Library/Application Support/Peekr/Chromium/debug.log"

# Rebuild and relaunch the injection-ready Debug app without rebuilding CEF.
inject:
	./scripts/dev-inject.sh

# Assemble the signed release .app with bundled Chromium.
app:
	./scripts/bundle.sh release

# Build the bundle and launch it.
run: app
	open build/Peekr.app

# Assemble the styled install DMG (brand background, centered app + Applications).
dmg: app
	./scripts/make-dmg.sh build/Peekr.app dist/Peekr.dmg Peekr

clean:
	rm -rf .build build

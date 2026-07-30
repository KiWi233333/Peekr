.PHONY: build dev app run dmg clean

# Quick compile check.
build:
	swift build

# CEF requires a real app bundle and helper processes; build a debug bundle.
dev:
	./scripts/bundle.sh debug
	open build/Peekr.app

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

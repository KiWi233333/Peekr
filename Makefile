.PHONY: build dev app run dmg clean

# Quick compile check.
build:
	swift build

# Run the bare executable (shared web session, fast iteration).
dev:
	swift run

# Assemble the signed .app bundle (per-app isolated sessions).
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

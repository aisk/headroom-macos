.PHONY: build test app dmg run icon clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

dmg:
	scripts/build-dmg.sh

run: app
	open build/Headroom.app

icon:
	swift tools/generate-icon.swift Sources/Headroom/Resources/AppIcon.icns

clean:
	rm -rf .build build

.PHONY: build test app run icon clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

run: app
	open build/Headroom.app

icon:
	swift tools/generate-icon.swift Sources/Headroom/Resources/AppIcon.icns

clean:
	rm -rf .build build

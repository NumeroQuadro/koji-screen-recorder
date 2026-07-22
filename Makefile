.PHONY: build release dmg clean

build:
	swift build

release:
	swift build -c release

dmg: release
	./scripts/build-dmg.sh

clean:
	swift package clean
	rm -rf build/ dist/

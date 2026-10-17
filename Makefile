# Common tasks. See CONTRIBUTING.md for what each check is for.

PROJECT := Brim.xcodeproj
SCHEME := brim
PACKAGE := BrimCore

.PHONY: build run test test-real lint release clean

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug build

# Opens the build just made by its path, so macOS cannot start an older copy.
run: build
	open "$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -showBuildSettings \
		| awk '/ BUILT_PRODUCTS_DIR = /{print $$3}')/Brim.app"

test:
	swift test --package-path $(PACKAGE)

# Touches the real Mac. Use an account or virtual machine you can spare.
test-real:
	BRIM_REAL_ENV=1 swift test --package-path $(PACKAGE)

lint:
	python3 scripts/lint_changes.py --base origin/main

release:
	./scripts/build_release.sh

clean:
	rm -rf build $(PACKAGE)/.build

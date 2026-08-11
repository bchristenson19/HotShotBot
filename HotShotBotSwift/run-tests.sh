#!/bin/sh
# Builds and runs the HotShotBotSwift test suite.
#
# Why this script exists instead of a plain `swift test`: on a machine with only the Xcode
# Command Line Tools installed (no full Xcode.app), `swift test`'s default invocation of the
# swiftpm-testing-helper subprocess drops the DYLD_FRAMEWORK_PATH/DYLD_LIBRARY_PATH env vars it
# needs to find Testing.framework and lib_TestingInterop.dylib (they only ship under
# CommandLineTools/Library/Developer, not the default search paths). Building with
# --build-tests and then invoking the compiled .xctest bundle directly through
# swiftpm-testing-helper, with those env vars set explicitly, works around it.
#
# If this is ever run on a machine with full Xcode installed, plain `swift test` should work
# fine on its own and this script becomes unnecessary (but remains harmless).

set -e
cd "$(dirname "$0")"

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

swift build --build-tests -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS"

BUNDLE=".build/arm64-apple-macosx/debug/HotShotBotSwiftPackageTests.xctest/Contents/MacOS/HotShotBotSwiftPackageTests"

DYLD_FRAMEWORK_PATH="$CLT_FRAMEWORKS" \
DYLD_LIBRARY_PATH="$CLT_LIB" \
/Library/Developer/CommandLineTools/usr/libexec/swift/pm/swiftpm-testing-helper \
  --test-bundle-path "$BUNDLE" "$BUNDLE" --testing-library swift-testing

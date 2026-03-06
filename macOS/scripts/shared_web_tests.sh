#!/bin/sh

# Shared Web Tests runner for macOS
# Mirrors iOS/scripts/shared_web_tests.sh but targets the macOS app.

# Check that we have Rust installed:
if ! command -v cargo > /dev/null 2>&1; then
    echo "‼️ Error: Rust is not installed. Please install Rust from https://rustup.rs/"
    exit 1
fi

# Check that we have npm installed:
if ! command -v npm > /dev/null 2>&1; then
    echo "‼️ Error: Node is not installed. Please install nvm https://github.com/nvm-sh/nvm"
    exit 1
fi

# Check for --clean flag
if [ "$1" = "--clean" ]; then
    echo "Clearing tmp directory"
    rm -rf tmp
fi

# Ensure we have a tmp directory
mkdir -p tmp

# Build the macOS app
MACOS_HASH_FILE="$(pwd)/tmp/macos_source_hash.txt"
find macOS -type f -name '*.swift' 2>/dev/null | sort | xargs cat 2>/dev/null | sha256sum > "$MACOS_HASH_FILE"

if [ -f "$MACOS_HASH_FILE" ] && cmp -s "$MACOS_HASH_FILE" "$MACOS_HASH_FILE.old"; then
    echo "macOS source files have not changed, skipping build."
else
    echo "macOS source files have changed, building app."
    if [ -z "$PROJECT_ROOT" ]; then
        PROJECT_ROOT="$(realpath "$(dirname "$0")"/../..)"
    fi
    export PROJECT_ROOT
    DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$(pwd)/DerivedData}"
    export DERIVED_DATA_PATH

    echo "Building macOS app to $DERIVED_DATA_PATH"
    set -o pipefail && xcodebuild -workspace DuckDuckGo.xcworkspace \
        -scheme "macOS Browser" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -skipPackagePluginValidation \
        -skipMacroValidation \
        ONLY_ACTIVE_ARCH=NO || {
        echo "‼️ Error: macOS app build failed."
        exit 1
    }
    cp "$MACOS_HASH_FILE" "$MACOS_HASH_FILE.old"
fi

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$(pwd)/DerivedData}"
export DERIVED_DATA_PATH
MACOS_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/DuckDuckGo.app"
export MACOS_APP_PATH
export TARGET_PLATFORM="macos"

if [ ! -d "$MACOS_APP_PATH" ]; then
    echo "‼️ Error: macOS app not found at $MACOS_APP_PATH"
    exit 1
fi

# Clone the shared-web-tests repo
cd tmp || exit

if [ ! -d "shared-web-tests" ]; then
    git clone --recurse-submodules git@github.com:duckduckgo/shared-web-tests.git
fi
cd shared-web-tests || exit

# Build the test suite
if ! npm run build; then
    echo "‼️ Error: npm build failed."
    exit 1
fi

# Install the hosts file for the web driver server
if ! grep -q "Start web-platform-tests hosts" /etc/hosts; then
    echo "Installing hosts, sudo required"
    sudo -- sh -c 'npm run install-hosts'
else
    echo "Hosts already installed, skipping"
fi

echo "Starting macOS test run:"
echo "DERIVED_DATA_PATH=$DERIVED_DATA_PATH"
echo "MACOS_APP_PATH=$MACOS_APP_PATH"
echo "TARGET_PLATFORM=$TARGET_PLATFORM"

npm run test:macos | tee "../../tmp/test_out_macos_$(date +"%Y%m%d_%H%M%S").log"
cd ../.. || exit

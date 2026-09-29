#!/bin/bash

# Exit the script immediately if any individual command fails
set -e

# ==========================================
# CONFIGURATION
# ==========================================
FRAMEWORK_NAME="UnixDomainSocket"
SCHEME_NAME="UnixDomainSocket"
OUTPUT_DIR="./build"
DERIVED_DATA_DIR="${OUTPUT_DIR}/DerivedData"

echo "🚀 Starting pure-package XCFramework compilation for ${FRAMEWORK_NAME}..."

# Clean up previous artifacts
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# ==========================================
# STEP 1: Build for Physical iOS Devices
# ==========================================
echo "📦 Compiling for physical iOS devices..."
xcodebuild build \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  SKIP_INSTALL=NO

# ==========================================
# STEP 2: Build for the iOS Simulator
# ==========================================
echo "📦 Compiling for iOS Simulators..."
xcodebuild build \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  SKIP_INSTALL=NO

# ==========================================
# STEP 3: Dynamically Resolve Framework Paths
# ==========================================
echo "🔍 Searching for generated framework structures inside PackageFrameworks..."

# Pure SPM outputs live deep inside DerivedData/Build/Products/.../PackageFrameworks/
IOS_FRAMEWORK_PATH=$(find "$DERIVED_DATA_DIR" -path "*/Release-iphoneos/PackageFrameworks/${FRAMEWORK_NAME}.framework" -type d | head -n 1)
SIM_FRAMEWORK_PATH=$(find "$DERIVED_DATA_DIR" -path "*/Release-iphonesimulator/PackageFrameworks/${FRAMEWORK_NAME}.framework" -type d | head -n 1)

# Safety Fallback: Search anywhere within the respective build configuration folders if the explicit path varies
if [ -z "$IOS_FRAMEWORK_PATH" ]; then
    IOS_FRAMEWORK_PATH=$(find "$DERIVED_DATA_DIR" -path "*/Release-iphoneos/*" -name "${FRAMEWORK_NAME}.framework" -type d | head -n 1)
fi
if [ -z "$SIM_FRAMEWORK_PATH" ]; then
    SIM_FRAMEWORK_PATH=$(find "$DERIVED_DATA_DIR" -path "*/Release-iphonesimulator/*" -name "${FRAMEWORK_NAME}.framework" -type d | head -n 1)
fi

# Verify the target bundles were successfully intercepted
if [ -z "$IOS_FRAMEWORK_PATH" ] || [ -z "$SIM_FRAMEWORK_PATH" ]; then
    echo "❌ Error: Could not locate ${FRAMEWORK_NAME}.framework inside DerivedData."
    echo "Please ensure 'type: .dynamic' is declared in your Package.swift manifest."
    exit 1
fi

echo "📍 Found Device Framework: $IOS_FRAMEWORK_PATH"
echo "📍 Found Simulator Framework: $SIM_FRAMEWORK_PATH"

# ==========================================
# STEP 4: Assemble the Unified XCFramework
# ==========================================
echo "🛠️ Bundling architectures into unified .xcframework..."
xcodebuild -create-xcframework \
  -framework "$IOS_FRAMEWORK_PATH" \
  -framework "$SIM_FRAMEWORK_PATH" \
  -output "${OUTPUT_DIR}/${FRAMEWORK_NAME}.xcframework"

# Clean up temporary build artifacts to leave a clean directory
rm -rf "$DERIVED_DATA_DIR"

echo "✅ Success! Your framework is compiled and ready at: ${OUTPUT_DIR}/${FRAMEWORK_NAME}.xcframework"


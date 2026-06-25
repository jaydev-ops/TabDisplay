#!/bin/bash

# Compiles Protocol Buffers schemas for both Swift (macOS) and Java/Kotlin (Android)

PROTO_DIR="$(dirname "$0")/proto"
SHARED_DIR="$(dirname "$0")"

echo "Compiling Protobuf schemas from: $PROTO_DIR"

if ! command -v protoc &> /dev/null; then
    echo "Error: protoc is not installed. Please install it using 'brew install protobuf'."
    exit 1
fi

# Define destination folders relative to script location
SWIFT_OUT="$(dirname "$0")/../macos/Sources/TabDisplayServer/Network"
JAVA_OUT="$(dirname "$0")/../android/app/src/main/java"

mkdir -p "$SWIFT_OUT"
mkdir -p "$JAVA_OUT"

# Compile to Java (for Android Client)
echo "Generating Java sources for Android..."
protoc -I="$PROTO_DIR" --java_out="$JAVA_OUT" "$PROTO_DIR/events.proto"
if [ $? -eq 0 ]; then
    echo "-> Java sources written to: $JAVA_OUT"
else
    echo "-> Error compiling Java sources."
    exit 2
fi

# Compile to Swift (for macOS Server)
if command -v protoc-gen-swift &> /dev/null; then
    echo "Generating Swift sources for macOS..."
    protoc -I="$PROTO_DIR" --swift_out="$SWIFT_OUT" "$PROTO_DIR/events.proto"
    if [ $? -eq 0 ]; then
        echo "-> Swift sources written to: $SWIFT_OUT"
    else
        echo "-> Error compiling Swift sources."
        exit 3
    fi
else
    echo "Warning: protoc-gen-swift not found. Swift files will not be generated."
    echo "To compile for Swift, install swift-protobuf using: brew install swift-protobuf"
fi

echo "Compilation process finished."

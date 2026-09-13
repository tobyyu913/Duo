#!/bin/bash
# Builds the offline shader harness: Tools/duo-render/duo-render
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
swiftc -O -o "$HERE/Tools/duo-render/duo-render" "$HERE/Tools/duo-render/main.swift" "$HERE/Sources/Duo/FoldState.swift" -framework AppKit -framework Metal -framework MetalKit
echo "built $HERE/Tools/duo-render/duo-render"

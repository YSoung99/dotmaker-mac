#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
target="${1:-$PWD/build/도트메이커 새 버전.app}"
if [[ "$target" != /* ]]; then target="$PWD/$target"; fi
mkdir -p "$target/Contents/MacOS" "$target/Contents/Resources" "$target/Contents/Frameworks"
ort="$PWD/../vendor/onnxruntime"
swiftc -O -target "$(uname -m)-apple-macosx14.0" -I "$ort/module" -L "$ort/lib" -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Raster.swift Subject.swift AnimeSeg.swift Pipeline.swift ColorReducer.swift JevColors.swift JevDetails.swift LegacyDot.swift LineCleanup.swift FaceDetail.swift Upscale.swift SoftDot.swift LinesAI.swift Cloud.swift App.swift Legacy/*.swift -o "$target/Contents/MacOS/DotMaker"
cp Info.plist "$target/Contents/"
cp DotMaker.icns "$target/Contents/Resources/"
cp lines-graph.onnx lines-manifest.json "$target/Contents/Resources/"
cp "$PWD/../vendor/models/isnetis.onnx" "$PWD/../vendor/models/esrgan-anime-6b.onnx" "$PWD/../vendor/models/esrgan-animevideo-v3.onnx" "$target/Contents/Resources/"
cp "$ort/lib/libonnxruntime.1.31.1.dylib" "$target/Contents/Frameworks/libonnxruntime.1.dylib"
codesign --force --sign - "$target/Contents/Frameworks/libonnxruntime.1.dylib"
codesign --force --sign - "$target"
codesign --verify --strict "$target"

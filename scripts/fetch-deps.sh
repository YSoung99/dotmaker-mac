#!/bin/zsh
# 빌드에 필요한 외부 파일을 vendor/에 받는다(저장소에는 넣지 않음).
# - ONNX Runtime 1.31.1 (MIT) 맥 arm64
# - skytnt/anime-seg isnetis.onnx (Apache-2.0, 배경 분리 AI)
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p vendor/models vendor/onnxruntime/module
if [[ ! -f vendor/onnxruntime/lib/libonnxruntime.1.31.1.dylib ]]; then
  curl -L --fail -o /tmp/ort.tgz https://github.com/microsoft/onnxruntime/releases/download/v1.31.1/onnxruntime-osx-arm64-1.31.1.tgz
  tar -xzf /tmp/ort.tgz -C vendor/onnxruntime --strip-components 1 onnxruntime-osx-arm64-1.31.1/include onnxruntime-osx-arm64-1.31.1/lib onnxruntime-osx-arm64-1.31.1/LICENSE
  rm -rf vendor/onnxruntime/lib/*.dSYM /tmp/ort.tgz
fi
cat > vendor/onnxruntime/module/module.modulemap <<'EOF'
module COnnxRuntime [system] {
    header "../include/onnxruntime_c_api.h"
    link "onnxruntime"
    export *
}
EOF
if [[ ! -f vendor/models/isnetis.onnx ]]; then
  curl -L --fail -o vendor/models/isnetis.onnx https://huggingface.co/skytnt/anime-seg/resolve/493cb60893f47441b26ec4fb9a306bce9e342982/isnetis.onnx
fi
echo "준비 완료: vendor/"

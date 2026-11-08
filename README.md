# 도트메이커 (맥)

캐릭터 그림 한 장을 열면 **원본의 선 굵기와 명암을 그대로 살린 도트 그림(투명 PNG)**으로 바꿔 주는 맥 앱입니다.
결과 크기는 100×100부터 200×200까지 10px 단위로 고를 수 있습니다.

## 주요 기능

- **원본 보존 방식**: 원본 픽셀이 결과 격자 한 칸에 걸치는 넓이만큼 그대로 평균 내서, 중간 축소 없이 바로 도트로 만듭니다.
- **바깥 외곽선 1픽셀 검정**: 가장 바깥 외곽선을 또렷한 검은 1픽셀로 다시 긋습니다. 흰 외곽선 장식과 바닥 그림자는 건드리지 않습니다.
- **경계 섞인 색 정리**: 축소하면서 경계에 생긴 탁한 중간색(빨강+검정 → 자주 등)을 가까운 원래 색으로 바꿉니다.
- **배경 분리 AI**: 흰색·단색·투명 배경은 코드로, 그 밖의 배경은 [anime-seg](https://huggingface.co/skytnt/anime-seg)(ONNX Runtime)로 캐릭터만 오려 냅니다. 모델은 앱에 들어 있습니다.
- **JEV 부위별 진단 / 섞인 색 판정**: [LLM Gateway](https://llmgateway.io)의 판정 모델(JEV)이 선 굵기·머리색·투명 테두리·바깥 외곽선·섞인 색을 원본과 비교해 후보를 고릅니다. 항목마다 직접 후보를 고를 수도 있고, **선택 적용**으로 그림에 반영합니다.
- 그 밖의 도트화 방식: 베리 잉크, 2.0 방식, 원본 직행.

## 설치

1. [Releases](../../releases)에서 `DotMaker-mac-*.zip`을 받아 압축을 풉니다.
2. `도트메이커 JEV 부위별 진단 시험.app`을 **응용 프로그램** 폴더로 옮깁니다.
3. 개발자 서명이 없는 앱이라 처음 열 때 "확인할 수 없는 개발자" 또는 "손상됨" 경고가 뜰 수 있습니다. 터미널에서 아래 명령을 한 번 실행한 뒤 다시 여세요.

```sh
xattr -dr com.apple.quarantine "/Applications/도트메이커 JEV 부위별 진단 시험.app"
```

필요 환경: Apple Silicon(M1 이상) 맥, macOS 14 이상.

## JEV 사용

- **JEV 설정**에서 LLM Gateway API 키를 넣으면 맥 키체인에 저장됩니다.
- 판정할 때 배경을 분리한 원본과 후보 그림이 LLM Gateway로 전송되며, 요금은 내 키 계정에 청구됩니다.
- 처음 판정할 때 macOS가 키체인 접근을 물으면 **항상 허용**을 누르세요.

## 소스에서 빌드

```sh
./scripts/fetch-deps.sh                              # ONNX Runtime·배경 분리 모델을 vendor/에 받기
./DotMaker/build.sh "$PWD/build/도트메이커.app"      # Xcode 명령줄 도구(swiftc) 필요
```

## 라이선스

- 이 저장소의 코드: MIT
- [ONNX Runtime](https://github.com/microsoft/onnxruntime): MIT
- [skytnt/anime-seg](https://huggingface.co/skytnt/anime-seg) (isnetis.onnx): Apache-2.0

윈도우판은 준비 중입니다.

> **📦 도트메이커는 [YSoung99/dotmaker](https://github.com/YSoung99/dotmaker)로 합쳐졌습니다.**
> 3.5.0부터 맥용과 윈도우용을 [한 곳](https://github.com/YSoung99/dotmaker/releases/latest)에서 받습니다. 이 저장소는 예전 맥 전용 앱(Swift, 3.4.0까지)의 보관용이며 더 이상 업데이트하지 않습니다.

# 도트메이커 (맥)

캐릭터 그림 한 장을 열면 **원본의 선 굵기와 명암을 그대로 살린 도트 그림(투명 PNG)**으로 바꿔 주는 맥 앱입니다.
결과 크기는 50×50부터 200×200까지 10px 단위로 고를 수 있습니다.

## 주요 기능

- **원본 보존 방식**: 원본 픽셀이 결과 격자 한 칸에 걸치는 넓이만큼 그대로 평균 내서, 중간 축소 없이 바로 도트로 만듭니다.
- **바깥 외곽선 1픽셀(원본 선 색)**: 투명 배경 바로 앞 가장 바깥 칸만, 원본 그 자리에 선이 있으면 원본 선 색으로 또렷하게 다시 긋습니다. 흰 외곽선 장식과 바닥 그림자는 건드리지 않습니다.
- **원본 색 맞추기**: 축소하면서 생긴 탁한 중간색 대신, 그 칸 원본에 실제로 있는 가장 가까운 색을 넣습니다.
- **경계 섞인 색 정리**: 축소하면서 경계에 생긴 탁한 중간색(빨강+검정 → 자주 등)을 가까운 원래 색으로 바꿉니다.
- **작은 입선 보존**: 눈 사이의 작은 입 선(ω 등)이 회색으로 뭉개지지 않게 원본 선 색으로 살립니다.
- **AI 업스케일(ESRGAN)**: 도트화하기 전에 원본을 [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) 애니 모델로 4배 키워 흐린 선·잡티를 정리합니다. 자동(원본이 결과 크기의 4배보다 작을 때만 6B) · 6B(더 깔끔) · v3(더 빠름) · 끄기 중에서 고릅니다. 모델은 앱에 들어 있습니다.
- **배경 분리 AI**: 흰색·단색·투명 배경은 코드로, 그 밖의 배경은 [anime-seg](https://huggingface.co/skytnt/anime-seg)(ONNX Runtime)로 캐릭터만 오려 냅니다. 모델은 앱에 들어 있습니다.
- **JEV 부위별 진단 / 섞인 색 판정 / 선·색 비교 / 자동 선택**: [LLM Gateway](https://llmgateway.io)의 판정 모델(JEV)이 선 굵기·머리색·투명 테두리·바깥 외곽선·섞인 색을 원본과 비교해 후보를 고릅니다. 항목마다 직접 후보를 고를 수도 있고, **선택 적용**으로 그림에 반영합니다.
- **원본 색 살림**: 원본의 색을 살리고 색 수만 줄입니다(선 1픽셀 정리 · 선명하게 · 테두리·색 면 정리).
- 그 밖의 도트화 방식: 베리 잉크, 2.0 방식, 원본 직행. **선 추출 AI**(MangaLineExtraction, 처음 쓸 때 약 82MB 받음)로 빠진 안쪽 선을 채울 수 있습니다.
- **AI 보정 탭**: PixelLab·Gemini·OpenAI(내 API 키)로 다시 그리거나 다듬습니다. 키는 맥 키체인에 저장됩니다.
- **설명서 탭**: 기능과 문제 해결 안내.
- 윈도우 프로그램과 기능이 모두 같습니다.

## 업데이트 기록

- **3.4.0**: 결과 크기를 **50×50부터** 고를 수 있습니다(50 ~ 200, 10px 단위). 도트화 탭과 AI 보정 탭이 같은 크기를 씁니다.
- **3.3.0**: 맥 앱과 윈도우 프로그램의 기능을 모두 같게 맞췄습니다. 원본 색 살림·원본 직행 방식, 선 추출 AI, AI 보정 탭(PixelLab·Gemini·OpenAI), 설명서 탭, JEV 선·색 비교와 자동 선택. 윈도우는 인터넷 없이도 AI 업스케일이 되고, 실패하면 업스케일 없이 도트화합니다.
- **3.2.1**(윈도우): 인터넷 없이도 AI 업스케일, 업스케일이 실패해도 그림은 열기.
- **3.2.0**: 바깥 외곽선 1픽셀을 원본 선 색으로, 원본 색 맞추기(기본 끔).
- **3.1.0**: AI 업스케일(Real-ESRGAN 4배, 자동·6B·v3·끄기), 작은 입선 보존.
- **3.0.0**: 첫 공개. 원본 보존 도트화(100×100 ~ 200×200), 바깥 외곽선 1픽셀 검정, 경계 섞인 색 정리, 배경 분리 AI, JEV 부위별 진단·섞인 색 판정.

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
./scripts/fetch-deps.sh                              # ONNX Runtime·배경 분리·AI 업스케일 모델을 vendor/에 준비(업스케일 모델 변환에 torch·onnx 필요)
./DotMaker/build.sh "$PWD/build/도트메이커.app"      # Xcode 명령줄 도구(swiftc) 필요
```

## 라이선스

- 이 저장소의 코드: MIT
- [ONNX Runtime](https://github.com/microsoft/onnxruntime): MIT
- [skytnt/anime-seg](https://huggingface.co/skytnt/anime-seg) (isnetis.onnx): Apache-2.0
- [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) (RealESRGAN_x4plus_anime_6B, realesr-animevideov3 → ONNX): BSD-3-Clause
- [p1atdev/MangaLineExtraction-hf](https://huggingface.co/p1atdev/MangaLineExtraction-hf) (선 추출, `DotMaker/lines-graph.onnx`는 구조만): MIT

윈도우판: [DotMaker-3.4.0-win-x64.exe](https://github.com/YSoung99/dotmaker/releases/download/v3.4.0-windows/DotMaker-3.4.0-win-x64.exe) (소스는 [YSoung99/dotmaker의 desktop-app 브랜치](https://github.com/YSoung99/dotmaker/tree/desktop-app)).

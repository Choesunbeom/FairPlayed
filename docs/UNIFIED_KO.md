# FairPlayed 통합 패커 2.0 — iPhone 독립 실행 버전

**목표:** 아이폰에서 암호화된 App Store IPA **하나만 선택**해 SideStore용 미서명 IPA를 만들고, **그 IPA를 설치한 뒤 동일한 FairPlayed 통합 앱에서 복호화 결과를 내보내는 앱**입니다.

## 핵심 구조

FairPlayed 원본 C/Objective-C 복호화 엔진(`fpcore.c`, `main.m`의 `FPRunner`)과 IPA 패커를 단일 실행 파일로 빌드했습니다.

빌드할 때 **앱 자체의 깨끗한 IPA 템플릿**(`FairPlayed-base-template.ipa`)을 앱 리소스에 내장하므로, **기본 FairPlayed IPA 파일을 따로 선택할 필요가 없습니다.** 템플릿도 완성된 재패키징 IPA에 보존되어, 다른 앱을 선택할 때 다시 사용할 수 있습니다.

## 사용 방법

1. [통합 앱 자동 빌드](https://github.com/Choesunbeom/FairPlayed/actions/workflows/build-unified-ios27.yml) 성공 기록의 아티팩트에서 `FairPlayedUnified-iOS27.1-unsigned.ipa`를 다운로드합니다.
2. 아이폰에서 **SideStore로 서명 및 설치**합니다.
3. 통합 앱에서 **① 암호화된 IPA 선택** → iPadn에서 받은, 본인 Apple ID 라이선스가 있는 앱의 IPA를 선택합니다.
4. **② 서명용 IPA 만들기**를 누릅니다. 이 단계는 복호화가 아니라 앱을 **재패키징**하는 작업입니다.
5. **④ IPA · 결과 파일 공유**를 눌러 `FairPlayed-target-unsigned.ipa`를 SideStore로 보내거나 파일 앱에 저장합니다.
6. **SideStore로 생성된 IPA를 서명해 재설치합니다.** 같은 번들 ID를 사용하므로 같은 서명 팀이라면 덮어씌우기가 가능할 수 있지만, 중요한 파일은 먼저 백업하세요. 설치 시 데이터 보존은 환경에 따라 다릅니다.
7. 다시 실행한 통합 앱에 **내장 대상 앱 발견**이라고 표시되면 **③ 내장 앱 복호화**를 눌러 복호화를 시도합니다.
8. **④ IPA · 결과 파일 공유** 또는 파일 앱의 FairPlayed 통합 → Decrypted 폴더에서 출력된 IPA와 로그를 확인합니다.

> **왜 재설치가 필요한가요?** 원본 FairPlayed의 FairPlay 복호화 실험은 대상 바이너리와 SINF가 **서명·설치된 앱 번들 내에 있어야** 합니다. 패커가 현재 실행 중인 앱의 **데이터 폴더**에 대상 IPA를 풀어 놓기만 해서는 FairPlay 서비스가 읽지 못합니다. 따라서 탈옥하지 않은 일반 아이폰에서는 한 번의 재서명/재설치가 필요합니다. **재설치 없는 즉시 복호화는 현재 제공하지 않습니다.**

## 기술

- 컴파일: Xcode **27.1**, iOS **27.1 SDK** (워크플로에서 버전 검사)
- 실행 기기: iPhone ARM64, iOS 17 이상 최소 타깃
- 입력: 파일 앱에서 암호화된 IPA 1개 선택
- 출력: `FairPlayed-target-unsigned.ipa` (서명 필요), 성공 시 `Decrypted/<app>-decrypted.ipa`
- 앱 자체에는 암호화 해제 기능이 포함되어 있지만 **iOS 27.2.1에서 실제 성공은 미검증**
- 출력이 `-PARTIAL.ipa`이면 일부 바이너리가 복호화되지 않았음을 뜻합니다.
- 원본 [FairPlayed](https://github.com/morzelowski/FairPlayed)는 iOS 27.0.1에서 동작을 보고했습니다.

## 유의사항

대용량 게임의 IPA를 압축 해제할 때 추가 저장 공간이 상당히 필요합니다. 개발자 서명/SideStore 서명 중 앱의 내장 SINF 리소스가 유지되어야 원본 FairPlayed 복호화 실험을 할 수 있습니다. 이 앱 자체가 Apple ID 로그인을 요구하거나 FairPlay 라이선스를 생성하지는 않습니다.

자신이 사용 허가를 가진 앱만 다루고, 계정 비밀번호나 개인 IPA 파일을 공개 GitHub 저장소에 업로드하지 마세요.

이 포크의 iPhone 통합 앱 코드는 [Packer/UnifiedMain.m](../Packer/UnifiedMain.m)에 있습니다.

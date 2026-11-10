# FairPlayed IPA Packer — iPhone 전용 한국어 안내

이 앱은 **아이폰 안에서** 아래 두 IPA 파일을 합쳐 SideStore에서 서명 가능한 IPA를 만들어 줍니다.

1. **FairPlayed IPA** — 이 포크의 `FairPlayed-base-unsigned.ipa` 또는 한국어 FairPlayed 기본 IPA
2. **암호화된 App Store IPA** — 본인 Apple 계정으로 내려받은 대상 앱 IPA (예: iPadn에서 내보낸 파일)

## 설치

[FairPlayed Packer 자동 빌드](https://github.com/Choesunbeom/FairPlayed/actions/workflows/build-packer-ios27.yml)의 최신 성공 실행에서 `FairPlayedPacker-iOS27.1-unsigned.ipa`를 내려받아 SideStore로 서명해 설치합니다.

별도 컴퓨터는 필요하지 않습니다. **Xcode 27.1과 iOS 27.1 SDK로 빌드한 iPhone ARM64 앱**이며, 최소 실행 버전은 iOS 17.0입니다. 앱은 한국어 인터페이스를 제공합니다.

## 사용 방법

1. 파일 앱에 `FairPlayed-base-unsigned.ipa`와 `target.ipa`를 저장합니다.
2. **FairPlayed 패커** 실행
3. **FairPlayed IPA 선택** → 기본 FairPlayed 파일 선택
4. **대상 IPA 선택** → iPadn에서 추출한 암호화 IPA 선택
5. **서명용 IPA 만들기** 선택
6. **IPA 공유 · SideStore로 보내기**를 눌러 SideStore에서 서명/설치합니다.
7. 새로 설치한 **FairPlayed** 실행 → **복호화** 선택 → 성공 시 파일 앱의 FairPlayed 문서 영역에 생성된 IPA를 확인합니다.

생성 파일은 패커 앱의 파일 공유 문서 폴더에 `FairPlayed-target-unsigned.ipa`라는 이름으로 보관됩니다. 재실행 시 같은 파일명을 덮어씁니다.

## 중요

- 패커는 **복호화하거나 서명하지 않습니다**. 설치 전 대상 앱을 FairPlayed 앱 안에 넣는 작업만 합니다.
- 복호화는 **FairPlayed 앱에서 별도로** 시도해야 합니다.
- 원본 FairPlayed 복호화는 iOS 27.0.1에서 실험적으로 확인된 것으로, iOS 27.2.1에서는 아직 검증되지 않았습니다.
- 출력 파일의 앱 ID는 `com.m0u.fairplayed` 계열이며, 대상 앱 자체의 홈 화면 설치 파일이 아닙니다.
- 입력 IPA가 크면 파일 앱에서 가져오기·압축 해제·재압축을 위해 충분한 **저장 공간**이 필요합니다. 수 GB 이상에서는 시간이 오래 걸리고 파일 크기 제한으로 실패할 수도 있습니다.
- IPA 안에 `SC_Info`/SINF가 없다면 FairPlay 복호화가 실패할 수 있습니다.
- App Store 계정 인증 정보를 패커가 요구하지 않습니다. 공개 저장소에 IPA나 인증서를 올리지 마세요.

## 출처

- FairPlayed 원본: https://github.com/morzelowski/FairPlayed
- 빌드 워크플로: https://github.com/Choesunbeom/FairPlayed/actions/workflows/build-packer-ios27.yml

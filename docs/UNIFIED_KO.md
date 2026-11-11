# FairPlayed 통합 패커 2.3 — 아이폰 단독 패키징과 복호화 실험

빌드: **Xcode 27.1 / iOS 27.1 SDK**, ARM64. 설치: **SideStore에서 독립 설치**. LiveContainer 안에 통합 앱을 설치하면 FairPlay 복호화가 불가능합니다.

## 변경된 메뉴 구성

- **패키징** — ① 암호화된 IPA 선택 → ② 서명용 IPA 만들기 → ③ IPA 공유 및 SideStore 서명·재설치
- **복호화** — ④ 내장된 앱 복호화 → ⑤ 결과 확인 및 공유
- **로그** — 전체 실행·오류 기록 보기 및 로그 파일 내보내기

작업 화면에서 **IPA 생성 버튼과 실시간 로그는 같은 '작업 진행' 영역에 별도 패널로 배치**했습니다. iOS 26 이상은 Xcode 27.1 SDK의 기본 UITabBar Liquid Glass 디자인과 UIGlassEffect를 사용하며, 이전 버전은 시스템 블러를 사용합니다.

## 설치 및 사용

1. [통합 패커 최신 GitHub Release](https://github.com/Choesunbeom/FairPlayed/releases)에서 `FairPlayed-Unified-v2.3-unsigned.ipa`를 다운로드합니다.
2. **SideStore를 열어 미서명 IPA를 서명하고 홈 화면에 설치**합니다. 실행 위치가 `/Documents/Applications/`라면 LiveContainer 게스트이므로 복호화할 수 없습니다.
3. '패키징'에서 iPadn이 내려받은, 본인 계정이 합법적으로 보유한 암호화 IPA를 선택합니다.
4. '② 서명용 IPA 만들기' → '③ IPA 공유'로 생성된 `FairPlayed-target-unsigned.ipa`를 내보냅니다.
5. **SideStore에서 생성된 IPA를 다시 서명해 설치**하고 홈 화면에서 실행합니다. 동일 앱의 데이터를 보존하려면 중요한 파일을 먼저 백업하세요.
6. 하단 '복호화' 메뉴에서 '④ 복호화 실행'을 누릅니다.
7. 로그에서 실패 개수와 파일명을 확인하고, '⑤ 결과 내보내기'에서 IPA를 공유합니다.

## NAVER Map 6.12.3 로그 원인

사용자가 제공한 **실기기 iOS 27.2.1** 로그에는 실행 파일 115개가 복호화되고 2개는 원래 암호화되지 않았지만 **6개가 실패**했습니다. 실패 항목에는 `Frameworks/AppServiceObjC.framework/AppServiceObjC`가 포함됩니다. LiveContainer의 `could not register fairplay decryption, mremap_encrypted() => -1` 오류는 앱 내부에 암호화 상태의 프레임워크가 남아 있음을 나타냅니다.

6개 모두 1페이지(4KB) 암호화 구간이었고, FairPlay 커널 호출과 읽기는 성공했으나 결과의 ARM64 RET 명령어 탐지 수가 0개여서 원본 코드의 검증 규칙을 통과하지 못했습니다.

### 초소형 프레임워크 실험 모드

v2.3에는 **기본 OFF**인 '초소형 프레임워크 실험 모드'가 있습니다. 켜면 단 1페이지 영역에 대해 FairPlay 매핑·전체 페이지 읽기 성공, 암호문에서 바뀜, 복호화 후 엔트로피 1.0 미만 등의 엄격한 조건을 만족할 때 **추정 복호화**로 받아들입니다.

이 데이터가 실행 가능한 코드임을 보장하지 않으므로, 모드가 실제로 사용된 출력은 `-EXPERIMENTAL.ipa`로 표시합니다. 하나라도 통과하지 못한 바이너리가 남으면 `-PARTIAL.ipa`로 표시합니다. **EXPERIMENTAL과 PARTIAL은 복호화 완료가 검증된 파일이 아닙니다.** 실제 LiveContainer 실행 성공 여부를 관찰해야 합니다.

표준 모드(실험 옵션 OFF)로 먼저 시도하고, 기존 오류가 계속될 때에만 실험 모드에서 재시도해 결과 로그를 비교해 주세요. iOS 27.2.1에서 안정적인 작동은 아직 실기기로 검증되지 않았습니다.

## 주의

- 출처/버전에 따라 IPA의 내부 프레임워크와 Apple 라이선스 구조가 달라 성공을 보장할 수 없습니다.
- 단순히 `cryptid`를 0으로 바꾸는 방법은 복호화가 아니므로 사용하지 않습니다.
- `-PARTIAL.ipa`, `-EXPERIMENTAL.ipa`는 검사·연구 목적이며 완전한 결과로 안내하지 않습니다.
- 앱 공유 폴더에는 큰 IPA와 여러 임시 복사본이 생길 수 있어 충분한 저장 공간이 필요합니다.
- 공개 GitHub 저장소에 IPA, Apple 계정 토큰, 프로비저닝 인증서를 업로드하지 마세요.

원본 FairPlayed: https://github.com/morzelowski/FairPlayed

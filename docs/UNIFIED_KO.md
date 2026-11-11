# daru 2.4 — iOS IPA 패커 및 FairPlayed 실험

**앱 이름:** daru  
**아이콘:** 사용자가 제공한 검은 고양이 이미지 (원본 그대로, 시스템용 정사각형 아이콘으로 변환)  
**빌드 환경:** Xcode 27.1 / iOS 27.1 SDK / ARM64  
**설치:** SideStore로 미서명 IPA 서명 및 홈 화면 독립 설치

## 달라진 점

### 1. iOS 파일 앱의 '최근 항목' 화면이 멈출 때

v2.3에서 '파일 앱에서 IPA 선택'을 누르면 iOS의 파일 선택기 '최근 항목' 화면이 빈 채로 멈추는 사례가 있었습니다. IPA를 선택하기 **전**에 발생하는 현상이므로, 압축 처리 문제와 다릅니다.

v2.4에서는 파일 선택기를 **전체 화면**으로 띄우고 지원 확장자를 IPA/ZIP로 제한했습니다. 복사 방식도 iOS가 제공하는 문서 접근 방식으로 변경했습니다. 다만 iOS 파일 제공자 자체의 오류까지 앱에서 완전히 해결한다고 보장할 수는 없습니다.

그 경우 앱 내 **'daru 폴더의 IPA 선택 (안정적)'** 버튼을 사용하세요.

1. 아이폰 **파일 앱**을 엽니다.
2. 다운로드한 IPA를 길게 누르고 **이동** 또는 **복사**를 선택합니다.
3. **나의 iPhone → daru** 폴더로 IPA를 복사합니다. daru를 한 번 실행하면 폴더 안에 `IPA를 이 폴더에 복사하세요.txt`가 생성됩니다.
4. daru의 **패키징 탭 → daru 폴더의 IPA 선택 (안정적)**을 누릅니다.
5. 나타나는 파일 이름을 선택합니다. 이 방식은 iOS의 '최근 항목' 파일 선택기를 전혀 사용하지 않습니다.

또는 파일 앱에서 IPA를 **공유 → daru에서 열기**를 선택하는 방식도 추가했습니다. 파일 공유 목록에 앱이 표시되는지는 iOS 파일 형식 등록과 SideStore 서명 상태에 따라 달라질 수 있습니다.

### 2. UI

하단에는 iOS 27 기본 Liquid Glass 탭바가 유지됩니다.

- **패키징:** ① 암호화 IPA 선택 → ② 서명용 IPA 만들기 → ③ 생성 IPA 공유 및 SideStore 재서명·재설치
- **복호화:** ④ 내장 앱 복호화 → ⑤ 복호화 결과 공유
- **로그:** 전체 로그와 파일 공유

IPA 생성 버튼과 실시간 로그는 같은 '작업 진행' 영역에서 각각 독립 패널로 표시됩니다.

### 3. 기존 앱 데이터

앱의 `CFBundleIdentifier`는 **com.choesunbeom.fairplayedpacker**로 유지했습니다. SideStore 서명 팀과 기기 상태가 동일하면 업데이트 설치가 가능할 수 있습니다. 그래도 기존 작업 파일은 반드시 백업하세요.

### 4. 복호화 관련 제한

패커는 FairPlayed 엔진과 기본 IPA 템플릿을 내장합니다. 암호화된 IPA 하나를 선택하고 **서명용 IPA를 먼저 만들고**, 해당 출력물을 SideStore로 직접 설치한 뒤 복호화 메뉴로 돌아와야 합니다.

LiveContainer 안에 daru 자체를 설치한 상태에서는 FairPlay 서비스가 내장 IPA에 접근하지 못합니다. 정상 설치하더라도 일부 프레임워크 복호화에 실패하면 출력은 `-PARTIAL.ipa` 또는 `-EXPERIMENTAL.ipa`로 남습니다. 이 파일은 LiveContainer에서 정상 실행된다는 보장이 없습니다.

iOS 27.2.1 실제 기기에서 완전 복호화 성공은 아직 검증되지 않았습니다.

## 코드/빌드

- [통합 빌드 워크플로](https://github.com/Choesunbeom/FairPlayed/actions/workflows/build-unified-ios27.yml)
- [daru 앱 소스](https://github.com/Choesunbeom/FairPlayed/blob/main/Packer/UnifiedMain.m)
- [아이콘 원본](https://github.com/Choesunbeom/FairPlayed/blob/main/Packer/Assets/daru-cat.png)

다른 사람의 Apple 계정 인증정보와 개인 소유 IPA를 공개 저장소에 업로드하지 마세요.

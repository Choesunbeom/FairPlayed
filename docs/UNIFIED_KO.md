# daru 2.5 — 자체 IPA 파일 목록으로 선택기 멈춤 우회

**앱 이름:** daru  
**아이콘:** 사용자가 제공한 검은 고양이 이미지 (원본 그대로, 시스템용 정사각형 아이콘으로 변환)  
**빌드 환경:** Xcode 27.1 / iOS 27.1 SDK / ARM64  
**설치:** SideStore로 미서명 IPA 서명 및 홈 화면 독립 설치

## 파일 선택기 멈춤 원인과 해결

보내주신 iOS 27.2.1 실기기 스크린샷과 로그 `fairplayed(1).log`에서는 **외부 iOS 파일 선택기의 '최근 항목' 화면이 빈 상태로 나타나는 현상**이 확인됐습니다. 로그에 '파일 선택' 호출 기록이 있지만 해당 화면에서 선택 완료 기록은 없습니다. 앱의 패키징이나 복호화 코드에 들어가기 전의 문제입니다.

Liquid Glass를 도입하면서 앱의 최상위 화면 컨트롤러가 `UIViewController`에서 `UITabBarController`로 바뀌고, 외부 선택기를 여는 위치도 함께 바뀌었습니다. **이 변화와 iOS 파일 제공자의 상호작용이 원인일 가능성**이 있지만 크래시/스레드 덤프가 없어 확정하지 않았습니다.

그래서 v2.5는 **기본 선택 버튼에서 UIDocumentPickerViewController를 전혀 열지 않습니다**. UIKit의 `UITableViewController`로 daru 앱 전용 문서 폴더를 보여줍니다.

### 가장 안정적인 IPA 등록 방법

1. SideStore로 `daru v2.5`를 설치하고 한 번 실행합니다.
2. iOS **파일 앱**에서 IPA 파일을 길게 눌러 **복사**합니다.
3. **나의 iPhone → daru** 폴더로 이동해 붙여넣습니다. (앱이 문서 공유를 활성화했습니다.)
4. daru의 **패키징 → IPA 선택 (daru 파일 목록)** 버튼을 누릅니다.
5. **앱 내 목록**에서 IPA 파일 이름을 선택합니다. '최근 항목' 화면은 나타나지 않아야 합니다.
6. 이후 ② 서명용 IPA 만들기 → ③ SideStore 공유 → 재설치 → 복호화를 진행합니다.

앱 자체 목록에서는 **새로고침**과 **아래로 당겨 새로고침**을 제공합니다. 앱이 백그라운드로 갔다 오더라도 새로고침하면 파일이 나타납니다.

### iOS 선택기 직접 사용 (선택 사항)

**'iOS 파일 앱에서 직접 찾아보기 (보조)'** 버튼은 iOS의 문서 선택기를 여는 기능입니다. 이전에 작동하던 구성인 `asCopy:YES`, 허용 유형 IPA/ZIP/Data, 최상위 `UITabBarController`에서 표시하도록 복원했습니다. 그러나 iOS 파일 제공자 문제로 이 모드에서도 멈출 수 있으므로 정상 사용 방법은 **daru 파일 목록**입니다.

또한 IPA를 파일 앱에서 **공유 → daru로 열기**로 가져오는 방식도 유지합니다. iOS 공유 메뉴에서 앱 노출 여부는 시스템과 서명 상태에 따라 다릅니다.

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

# FairPlayed: 아이폰 단독 사용 안내 (실험용)

이 포크에는 **미서명 iOS 앱을 빌드하는 GitHub Actions 워크플로**와 **아이폰에서 IPA를 재패키징하는 Python 스크립트**를 추가했습니다. 원본 FairPlayed의 복호화 코드는 변경하지 않았습니다.

> **중요:** FairPlayed는 실행 중 외부 IPA를 불러와 바로 복호화하는 범용 앱이 아닙니다. 대상 앱의 실행 파일과 `SC_Info`가 FairPlayed 앱 번들 안에 **설치 전에 포함**되어 있어야 합니다. 기본 IPA만 설치하면 내장된 복호화 대상이 없습니다.

## 1. GitHub Actions에서 기본 IPA 내려받기

1. [Build FairPlayed unsigned iOS IPA](../..//actions/workflows/build-ios-ipa.yml) 페이지를 엽니다.
2. **Run workflow**를 실행하거나 최신 성공 실행을 엽니다.
3. 해당 실행의 **Artifacts**에서 `FairPlayed-unsigned-IPA` ZIP을 다운로드합니다.
4. 압축을 풀어 `FairPlayed-base-unsigned.ipa`를 확보합니다.

## 2. 아이폰에서 대상 앱 IPA 포함하기

아이폰의 Python 3 실행 환경(예: a-Shell)에서 파일 앱을 통해 같은 폴더에 아래 파일을 둡니다.

- `FairPlayed-base-unsigned.ipa` — 위에서 빌드한 기본 IPA
- `target.ipa` — iPadn에서 받은, 본인 계정이 라이선스를 보유한 암호화된 App Store IPA
- `repack_for_iphone.py` — 이 저장소의 [재패키징 스크립트](../tools/repack_for_iphone.py)

해당 폴더에서 실행합니다.

```sh
python3 repack_for_iphone.py FairPlayed-base-unsigned.ipa target.ipa -o FairPlayed-target-unsigned.ipa
```

출력된 IPA에는 `Payload/FairPlayed.app/EmbeddedPayload/<대상 앱>/`이 추가되며 원본 앱의 SINF 복제 경로도 처리됩니다. **이 단계는 복호화가 아니라 단순 재패키징입니다.**

## 3. SideStore로 설치하고 복호화 내보내기 시도

1. 결과물 `FairPlayed-target-unsigned.ipa`를 SideStore로 **재서명 및 설치**합니다. **기본 IPA와 달리 대상 앱이 포함된 파일**을 설치해야 합니다.
2. 아이폰에서 개발자 모드를 켜고, 해당 앱을 구입·다운로드한 Apple 계정으로 로그인한 상태인지 확인합니다.
3. FairPlayed 앱을 실행하고 내장 페이로드 내보내기를 시도합니다.
4. 파일 앱의 FairPlayed 문서 폴더에 생성되는 `Decrypted/`의 IPA를 확인합니다.
5. 이름이 `-PARTIAL.ipa`라면 일부 바이너리가 복호화되지 않은 것으로 LiveContainer에서 정상 실행을 기대하기 어렵습니다.

## 제한사항

- 원본 개발자가 복호화 성공을 보고한 iOS는 **27.0.1**이며, **27.2.1에서의 성공은 검증되지 않았습니다.**
- **대상 IPA를 교체할 때마다** 재패키징과 재서명이 필요합니다.
- SideStore가 자원 파일을 재작성하거나 서명·설치 제약이 있으면 동작하지 않을 수 있습니다.
- 본인의 Apple 계정으로 라이선스를 보유한 앱에 한해 시험하세요. Apple 계정 비밀번호·토큰·상용 IPA를 공개 저장소에 올리지 마세요.
- GitHub Actions는 미서명 **기본 IPA**만 빌드합니다. 컴파일 성공은 복호화 성공이나 LiveContainer 호환을 보장하지 않습니다.

원본: https://github.com/morzelowski/FairPlayed

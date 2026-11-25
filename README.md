# HeartCheck — 버튼 누르면 워치 심박 실시간 확인

```
[확인 페이지] 버튼 ──▶ [NAS 서버] ──APNs 무음 푸시──▶ [아이폰 앱]
                                                      │ startWatchApp()
      ▲ SSE 실시간                                    ▼
      └──────────── /api/hr ◀── 심박(2초 간격) ── [워치 앱: 운동 세션]
```

- 버튼 한 번에 **5분** 측정 (`SESSION_MINUTES`). 측정 중 다시 누르면 연장, "그만하기"로 바로 종료
- 운동 기록은 저장하지 않고 버림 → 건강 앱/활동 링에 안 남음
- 워치 앱의 **밤새 모드**: 자기 전에 직접 켜두면 푸시 없이 계속 측정. 아무도 안 보고 있을 땐 60초 간격으로만 전송

## 필요한 것
- **Apple Developer Program (유료, 연 $99)** — 푸시(APNs)와 HealthKit 실기기 배포에 필요
- Mac + Xcode 16 이상, XcodeGen (`brew install xcodegen`)
- 애플워치 (watchOS 10+), 아이폰 (iOS 17+)

## 1. NAS 서버
1. developer.apple.com → Certificates, IDs & Profiles → **Keys** → `+` → *Apple Push Notifications service* 체크 → `AuthKey_XXXX.p8` 다운로드
2. `server/data/AuthKey.p8` 로 이름 바꿔 넣기
3. `docker-compose.yml` 에서 `VIEW_KEY`, `DEVICE_KEY`(각각 긴 랜덤 문자열), `APNS_TEAM_ID`, `APNS_KEY_ID` 입력
   - 랜덤 문자열: `openssl rand -hex 24`
4. `docker compose up -d --build`
5. 시놀로지 **제어판 → 로그인 포털 → 고급 → 역방향 프록시**로 `https://heart.내도메인` → `localhost:8787` 연결 + 인증서
   - 워치/아이폰 앱은 HTTPS만 허용(ATS) → HTTPS 필수
   - 역방향 프록시의 사용자 지정 헤더에 WebSocket 항목 추가 안 해도 됨 (SSE라 일반 HTTP로 동작)

## 2. 앱
1. `app/Shared/Config.swift` 에 서버 주소와 `DEVICE_KEY` 입력
2. `cd app && xcodegen` → `HeartCheck.xcodeproj` 열기
3. 두 타깃 모두 Signing & Capabilities에서 팀 선택 (Push Notifications, HealthKit, Background Modes가 이미 들어가 있음)
4. 아이폰에 HeartCheck 스킴으로 실행 → 워치 앱도 같이 설치됨
5. 아이폰 앱에서 **건강 권한 요청**, 워치에서도 앱 한 번 열어 권한 허용
6. 아이폰 앱의 **워치 측정 테스트** → 확인 페이지에 심박이 뜨면 성공

## 3. 확인 페이지 공유
`https://heart.내도메인/?k=VIEW_KEY` 를 보내주면 됨. 한 번 열면 키는 기기에 저장되고 주소창에서는 지워져요.
아이폰 사파리 → 공유 → **홈 화면에 추가** 하면 앱처럼 쓸 수 있어요.

## 알아둘 점 (중요)
- **무음 푸시는 애플이 지연·생략할 수 있어요.** 저전력 모드, 아이폰 앱 강제종료(앱 전환기에서 위로 밀기), 푸시를 너무 자주 보낸 경우에 잘 생겨요. 안 되면 페이지에 "아이폰이 응답하지 않아요"가 떠요.
  → 자는 동안 꼭 확실해야 하면 **밤새 모드**를 쓰는 게 가장 안정적이에요 (대신 배터리 소모 큼, 기종에 따라 8시간에 30~50% 정도 예상 — 실측 필요).
- `startWatchApp`은 워치를 **차고 있고 잠금 해제된 상태**여야 동작해요 (손목 감지로 자는 중엔 보통 유지됨).
- TestFlight/배포 빌드는 `aps-environment`를 `production`으로, 서버 `APNS_SANDBOX`를 `0`으로 바꾸기.
- 디버그: `docker logs heartcheck` 에 APNs 응답 코드가 찍혀요. `400 BadDeviceToken`이면 sandbox/production 불일치.

## API
| 경로 | 키 | 설명 |
|---|---|---|
| `POST /api/request` | VIEW | 측정 요청(푸시) / 측정 중이면 연장 |
| `POST /api/stop` | VIEW | 측정 종료 지시 |
| `GET /api/stream?k=` | VIEW | SSE: `status`, `history`, `hr` |
| `POST /api/register` | DEVICE | 아이폰 푸시 토큰 등록 |
| `POST /api/hr` | DEVICE | `{bpm, ts}` → `{keepUntil, watching}` |
| `POST /api/event` | DEVICE | `phone_woke` / `watch_started` / `watch_ended` / `error` |

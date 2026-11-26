# HeartCheck — 웹 버튼으로 애플워치 심박 실시간 확인

```
워치(HeartCheck 열어두기 = 대기) ──10초마다 생존 신호──▶ NAS 서버 ◀── Cloudflare 터널 ── 확인 페이지
                                  ◀──[측정 시작] 응답──              (버튼 → 5분 실시간, 2초 간격)
```

## 동작
- 워치에서 HeartCheck를 열면 **자동으로 대기** (버튼 없음). 센서를 켜두고 10초마다 서버에 신호.
- 웹에서 **측정 시작** → 10초 안에 워치가 2초 간격 실시간 전송 → **5분 뒤 자동으로 대기 복귀**. **측정 중지**로 바로 종료.
- 밤새 센서가 켜져 있어서 배터리를 씀 (하룻밤 30~50% 예상) — 자기 전 충전.

## 서명 (중요)
FlareStore 프로필 앱 ID(`app.lychee6613.pomelo9140`)에 맞춰 번들 ID가 고정돼 있음.
- 아이폰 앱: `app.lychee6613`
- 워치 앱: `app.lychee6613.pomelo9140` ← **서명 앱 ID와 정확히 같아야 함** (다르면 워치에서 HKError 14)
인증서를 바꾸면 `app/project.yml`의 번들 ID를 그 프로필 앱 ID에 맞게 바꿀 것.

## NAS 설치 (Synology, SSH)
```bash
cd /volume1/docker
curl -L https://github.com/KuronexArt/HeartCheck/archive/refs/heads/main.tar.gz -H "Authorization: token <GitHub 토큰>" | tar xz
cp -r HeartCheck-main/server heartcheck && rm -rf HeartCheck-main && cd heartcheck
vi docker-compose.yml          # VIEW_KEY, DEVICE_KEY 바꾸기
sudo docker-compose up -d --build
sudo docker logs HeartCheck_Tunnel 2>&1 | grep trycloudflare   # 접속 주소 확인
```
- 퀵 터널 주소는 **컨테이너 재시작 때마다 바뀜** → 바뀌면 아이폰 앱에 새 주소 저장(워치로 자동 전달)

## 앱 설정
1. 아이폰 HeartCheck → 서버 주소(`https://xxxx.trycloudflare.com`) + DEVICE_KEY 입력 → **저장하고 워치로 보내기**
2. 워치에서 HeartCheck 열기 → "대기 중" 확인
3. 확인 페이지: `https://xxxx.trycloudflare.com/?k=VIEW_KEY`

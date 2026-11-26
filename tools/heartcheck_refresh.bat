@echo off
rem HeartCheck 자동 갱신 (무료 애플 ID 7일 만료 대비) - 매일 새벽 실행용
rem 이 파일, plumesign.exe, watch_install.py, HeartCheck-unsigned.ipa 를 같은 폴더에 두세요.
chcp 65001 >nul
cd /d "%~dp0"
set RUST_LOG=info
set PYTHONIOENCODING=utf-8
set LOG=%~dp0refresh.log

echo ===== %date% %time% 갱신 시작 >> "%LOG%"

plumesign.exe sign -p HeartCheck-unsigned.ipa --apple-id -o HeartCheck-signed.ipa >> "%LOG%" 2>&1
if errorlevel 1 (
  echo [실패] 서명 실패 - 애플 ID 다시 로그인 필요할 수 있음 >> "%LOG%"
  exit /b 1
)

pymobiledevice3 apps install HeartCheck-signed.ipa >> "%LOG%" 2>&1
if errorlevel 1 echo [실패] 아이폰 설치 실패 - 아이폰이 같은 와이파이/USB에 있는지 확인 >> "%LOG%"

python watch_install.py install HeartCheck-signed.ipa >> "%LOG%" 2>&1
if errorlevel 1 echo [실패] 워치 설치 실패 - 워치가 아이폰 근처, 잠금 해제 상태인지 확인 >> "%LOG%"

echo ===== %date% %time% 갱신 끝 >> "%LOG%"

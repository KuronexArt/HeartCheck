"""
HeartCheck 자동 갱신 (시놀로지 Docker)
매일 REFRESH_HOUR시에: 무료 애플 ID로 다시 서명 → 와이파이로 아이폰 설치 → 아이폰을 거쳐 워치 설치
  python refresh.py          # 스케줄 모드 (컨테이너 기본)
  python refresh.py now      # 지금 한 번 실행
/data 안에 필요한 것:
  HeartCheck-unsigned.ipa
  lockdown/<아이폰UDID>.plist   (PC의 C:\\ProgramData\\Apple\\Lockdown 에서 복사)
plumesign 로그인 정보는 /root/.config/PlumeImpactor 에 마운트
"""
import asyncio, datetime as dt, os, subprocess, sys, tempfile, zipfile, pathlib, traceback

from pymobiledevice3.lockdown import LockdownClient, create_using_mobdev2
from pymobiledevice3.service_connection import ServiceConnection
from pymobiledevice3.services.companion import CompanionProxyService
from pymobiledevice3.services.installation_proxy import InstallationProxyService
from pymobiledevice3.services.streaming_zip_conduit import StreamingZipConduitService

DATA = pathlib.Path("/data")
UNSIGNED = DATA / "HeartCheck-unsigned.ipa"
SIGNED = DATA / "HeartCheck-signed.ipa"
PAIRS = DATA / "lockdown"
LOG = DATA / "refresh.log"
IPHONE_UDID = os.environ.get("IPHONE_UDID") or None
IPHONE_IP = os.environ.get("IPHONE_IP") or None
HOUR = int(os.environ.get("REFRESH_HOUR", "4"))


def log(msg):
    line = f"{dt.datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


class WatchLockdown(LockdownClient):
    """아이폰의 companion proxy를 거쳐 워치 lockdownd에 붙는 클라이언트 (와이파이)"""

    def __init__(self, service, host_id, *args, phone_ip=None, comp=None, **kw):
        super().__init__(service, host_id, *args, **kw)
        self.phone_ip, self.comp = phone_ip, comp

    async def create_service_connection(self, port, ssl_context=None, strip_ssl=False):
        local = await self.comp.start_forwarding_service_port(port)
        return await ServiceConnection.create_using_tcp(self.phone_ip, local, ssl_context=ssl_context, strip_ssl=strip_ssl)


def sign():
    log("1/3 서명 중…")
    r = subprocess.run(["plumesign", "sign", "-p", str(UNSIGNED), "--apple-id", "-o", str(SIGNED)],
                       capture_output=True, text=True)
    tail = "\n".join((r.stdout + r.stderr).strip().splitlines()[-3:])
    if r.returncode != 0 or not SIGNED.exists():
        raise RuntimeError(f"서명 실패 (애플 ID 재로그인 필요할 수 있음): {tail[-400:]}")
    log("   서명 완료")


async def install():
    log("2/3 아이폰 찾는 중 (와이파이)…")
    phone = await create_using_mobdev2(hostname=IPHONE_IP, udid=IPHONE_UDID, pair_records=PAIRS)
    log(f"   아이폰: {phone.udid} {phone.product_version} @ {phone.hostname}")
    try:
        await InstallationProxyService(lockdown=phone).install_from_local(str(SIGNED))
        log("   아이폰 설치 완료")

        log("3/3 워치 설치 중…")
        comp = CompanionProxyService(phone)
        watches = await comp.list()
        if not watches:
            raise RuntimeError("페어링된 워치를 못 찾음")
        w = watches[0] if isinstance(watches[0], str) else str(watches[0])
        local = await comp.start_forwarding_service_port(62078)
        svc = await ServiceConnection.create_using_tcp(phone.hostname, local)
        watch = await WatchLockdown.create(svc, identifier=w, phone_ip=phone.hostname, comp=comp)
        app_dir = pathlib.Path(tempfile.mkdtemp())
        with zipfile.ZipFile(SIGNED) as z:
            z.extractall(app_dir)
        app = next((app_dir / "Payload").glob("*.app/Watch/*.app"))
        async with StreamingZipConduitService(watch) as c:
            await c.install(app, developer=True)
        log(f"   워치 설치 완료 ({watch.product_type} {watch.product_version})")
    finally:
        await phone.close()


def run_once():
    log("===== 갱신 시작")
    try:
        sign()
        asyncio.run(install())
        log("===== 갱신 성공")
        return True
    except Exception as e:
        log(f"[실패] {e}")
        log(traceback.format_exc().strip().splitlines()[-1])
        return False


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "now":
        sys.exit(0 if run_once() else 1)
    log(f"스케줄 모드: 매일 {HOUR}시 갱신 (실패하면 1시간 뒤 재시도, 최대 3번)")
    while True:
        now = dt.datetime.now()
        nxt = now.replace(hour=HOUR, minute=0, second=0, microsecond=0)
        if nxt <= now:
            nxt += dt.timedelta(days=1)
        import time
        time.sleep((nxt - now).total_seconds())
        for attempt in range(3):
            if run_once():
                break
            time.sleep(3600)


if __name__ == "__main__":
    main()

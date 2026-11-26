"""
HeartCheck 워치 직접 설치 도구 (무료 애플 ID 서명용)

아이폰을 USB로 PC에 연결하고, 워치는 아이폰 근처에 두세요.
  python watch_install.py list               # 아이폰·워치 UDID 보기
  python watch_install.py devmode            # 워치 설정에 '개발자 모드' 메뉴 띄우기
  python watch_install.py install 서명된.ipa  # 워치 앱만 꺼내서 워치에 직접 설치
필요: pip install -U pymobiledevice3
"""
import asyncio, sys, zipfile, tempfile, pathlib
from pymobiledevice3.lockdown import LockdownClient, create_using_usbmux
from pymobiledevice3.service_connection import ServiceConnection
from pymobiledevice3.services.companion import CompanionProxyService
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.services.streaming_zip_conduit import StreamingZipConduitService

WATCH_LOCKDOWN_PORT = 62078


class WatchLockdown(LockdownClient):
    """아이폰의 companion proxy를 거쳐 워치 lockdownd에 붙는 클라이언트"""

    def __init__(self, service, host_id, *args, phone_udid=None, comp=None, **kw):
        super().__init__(service, host_id, *args, **kw)
        self.phone_udid = phone_udid
        self.comp = comp

    async def create_service_connection(self, port, ssl_context=None, strip_ssl=False):
        local = await self.comp.start_forwarding_service_port(port)
        return await ServiceConnection.create_using_usbmux(
            self.phone_udid, local, ssl_context=ssl_context, strip_ssl=strip_ssl)


async def phone():
    ld = await create_using_usbmux()
    return ld


async def watch_udid(ld):
    devs = await CompanionProxyService(ld).list()
    if not devs:
        sys.exit("페어링된 워치를 못 찾았어요. 워치를 아이폰 근처에 두고 잠금을 풀어주세요.")
    d = devs[0]
    return d if isinstance(d, str) else (d.get("DeviceUDID") or d.get("UDID") or str(d))


async def connect_watch():
    ld = await phone()
    w = await watch_udid(ld)
    comp = CompanionProxyService(ld)
    local = await comp.start_forwarding_service_port(WATCH_LOCKDOWN_PORT)
    svc = await ServiceConnection.create_using_usbmux(ld.udid, local)
    wl = await WatchLockdown.create(svc, identifier=w, phone_udid=ld.udid, comp=comp)
    return ld, wl


def extract_watch_app(ipa: pathlib.Path) -> pathlib.Path:
    out = pathlib.Path(tempfile.mkdtemp(prefix="hc_watch_"))
    with zipfile.ZipFile(ipa) as z:
        z.extractall(out)
    apps = list((out / "Payload").glob("*.app/Watch/*.app"))
    if not apps:
        sys.exit("IPA 안에 워치 앱이 없어요.")
    return apps[0]


async def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        ld = await phone()
        print("아이폰 UDID:", ld.udid, ld.product_type, ld.product_version)
        print("워치 UDID  :", await watch_udid(ld))
    elif cmd == "devmode":
        _, wl = await connect_watch()
        print("워치:", wl.product_type, wl.product_version)
        await AmfiService(wl).reveal_developer_mode_option_in_ui()
        print("워치 설정 → 개인정보 보호 및 보안 → 개발자 모드 를 켜고 재시동하세요.")
    elif cmd == "install":
        app = extract_watch_app(pathlib.Path(sys.argv[2]))
        print("워치 앱:", app.name)
        _, wl = await connect_watch()
        print("워치:", wl.product_type, wl.product_version, "에 설치 중…")
        async with StreamingZipConduitService(wl) as c:
            await c.install(app, developer=True, handler=lambda p: print(f"  {p}%"))
        print("워치 설치 완료!")
    else:
        print(__doc__)


if __name__ == "__main__":
    asyncio.run(main())

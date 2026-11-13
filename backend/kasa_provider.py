"""TP-Link Kasa / Tapo provider (local network, via python-kasa).

Device ids are `kasa:<deviceId>`. deviceId is a hardware id reported by the plug itself
(for power-strip outlets, each child outlet has its own deviceId). It does not change when
the device is renamed or gets a new IP address.
"""
import asyncio
import json
import logging
import time
from dataclasses import dataclass, field
from pathlib import Path

from kasa import Credentials, Device, DeviceType, Discover, Module

from colors import hex_to_hsv, hsv_to_hex, kelvin_to_hex
from errors import DeviceError

log = logging.getLogger("kasa")

KINDS = {
    DeviceType.Plug: "plug",
    DeviceType.StripSocket: "outlet",
    DeviceType.Bulb: "bulb",
    DeviceType.LightStrip: "lightstrip",
    DeviceType.WallSwitch: "switch",
    DeviceType.Dimmer: "dimmer",
}
OP_TIMEOUT = 6
REDISCOVER_EVERY = 300  # s, background refresh of IPs / new devices
REDISCOVER_OFFLINE = 45  # s, faster retry while something is missing


@dataclass
class Root:
    dev: Device
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    online: bool = True
    updated: float = 0.0
    error: str | None = None


class KasaProvider:
    name = "kasa"

    def __init__(self, username: str, password: str, cache_path: Path, discovery_timeout: int = 5):
        self.creds = Credentials(username, password) if username and password else None
        self.cache_path = cache_path
        self.discovery_timeout = discovery_timeout
        self.roots: dict[str, Root] = {}  # root deviceId -> Root
        self.index: dict[str, tuple[str, Device]] = {}  # exposed id -> (root id, Device)
        self.known: dict[str, dict] = self._load_cache()  # exposed id -> last static info
        self.last_discovery = 0.0
        self.last_error: str | None = None
        self._discovery: asyncio.Task | None = None

    @property
    def has_credentials(self) -> bool:
        return self.creds is not None

    # ---------- persistence of last-seen devices (so offline plugs still show up) ----------
    def _load_cache(self) -> dict:
        try:
            return json.loads(self.cache_path.read_text())
        except Exception:
            return {}

    def _save_cache(self):
        try:
            self.cache_path.write_text(json.dumps(self.known, indent=1))
        except Exception as e:
            log.warning("could not write cache: %s", e)

    # ---------- discovery ----------
    def kick_discovery(self) -> asyncio.Task:
        if self._discovery is None or self._discovery.done():
            self._discovery = asyncio.create_task(self._discover())
        return self._discovery

    async def discover(self):
        await asyncio.shield(self.kick_discovery())

    async def _discover(self):
        t0 = time.monotonic()
        try:
            found = await Discover.discover(credentials=self.creds, discovery_timeout=self.discovery_timeout)
        except Exception as e:
            self.last_error = f"Kasa discovery failed: {e}"
            log.error(self.last_error)
            return
        errors = []

        async def init(dev: Device):
            try:
                await asyncio.wait_for(dev.update(), OP_TIMEOUT)
                return dev
            except Exception as e:
                msg = str(e) or type(e).__name__
                if "auth" in msg.lower() or "credential" in msg.lower():
                    msg = "authentication failed — check KASA_USERNAME / KASA_PASSWORD in .env"
                errors.append(f"{dev.host}: {msg}")
                await _safe_disconnect(dev)
                return None

        devs = [d for d in await asyncio.gather(*(init(d) for d in found.values())) if d]
        for dev in devs:
            rid = dev.device_id
            old = self.roots.get(rid)
            if old and old.dev is not dev:
                async with old.lock:
                    await _safe_disconnect(old.dev)
                    old.dev, old.online, old.updated, old.error = dev, True, time.monotonic(), None
            elif not old:
                self.roots[rid] = Root(dev, updated=time.monotonic())
            self._register(rid, dev)
        self._save_cache()
        self.last_discovery = time.monotonic()
        self.last_error = "; ".join(errors) if errors else None
        if not devs and not errors:
            self.last_error = None if self.known else "No Kasa devices found on the local network"
        log.info("discovered %d kasa devices in %.1fs (%d errors)", len(devs), time.monotonic() - t0, len(errors))

    def _register(self, rid: str, dev: Device):
        for d in self._exposed(dev):
            did = d.device_id
            self.index[did] = (rid, d)
            info = self._describe(d, online=True)
            self.known[did] = {k: info[k] for k in ("name", "kind", "model", "capabilities")} | {"host": dev.host}

    @staticmethod
    def _exposed(dev: Device) -> list[Device]:
        # Power strips: expose each outlet, not the strip itself.
        if dev.device_type == DeviceType.Strip and dev.children:
            return list(dev.children)
        return [dev]

    # ---------- state ----------
    def _describe(self, d: Device, online: bool) -> dict:
        light = d.modules.get(Module.Light)
        dimmable = bool(light and light.has_feature("brightness"))
        has_color = bool(light and light.has_feature("hsv"))
        has_ct = bool(light and light.has_feature("color_temp"))
        ct_range = None
        color = color_temp = None
        brightness = light.brightness if dimmable else None
        if has_ct:
            f = light.get_feature("color_temp")
            ct_range = [f.minimum_value, f.maximum_value] if f else None
            if light.color_temp:
                color_temp = light.color_temp
                color = kelvin_to_hex(color_temp)
        if has_color and not color_temp:
            h, s, _ = light.hsv
            color = hsv_to_hex(h, s, 100)
        return {
            "id": f"kasa:{d.device_id}",
            "provider": "kasa",
            "name": d.alias or d.model,
            "kind": KINDS.get(d.device_type, d.device_type.name.lower()),
            "model": d.model,
            "online": online,
            "on": bool(d.is_on),
            "brightness": brightness,
            "color": color,
            "color_temp": color_temp,
            "capabilities": {
                "dimmable": dimmable,
                "color": has_color,
                "color_temp": has_ct,
                "color_temp_range": ct_range,
                "rename": True,
            },
            "native_id": d.host,
        }

    async def _refresh_root(self, root: Root, max_age: float = 1.5):
        if root.online and time.monotonic() - root.updated < max_age:
            return
        async with root.lock:
            try:
                await asyncio.wait_for(root.dev.update(), OP_TIMEOUT)
                root.online, root.error, root.updated = True, None, time.monotonic()
            except Exception as e:
                root.online, root.error = False, str(e) or type(e).__name__

    async def list(self) -> list[dict]:
        now = time.monotonic()
        if not self.last_discovery:
            await self.discover()
        await asyncio.gather(*(self._refresh_root(r) for r in self.roots.values()))
        out, seen = [], set()
        for did, (rid, d) in self.index.items():
            root = self.roots[rid]
            out.append(self._describe(d, online=root.online))
            seen.add(did)
        for did, info in self.known.items():  # remembered from earlier runs but not found now
            if did not in seen:
                out.append({"id": f"kasa:{did}", "provider": "kasa", "online": False, "on": False,
                            "brightness": None, "color": None, "color_temp": None, "native_id": info.get("host"),
                            **{k: info.get(k) for k in ("name", "kind", "model", "capabilities")}})
        offline = any(not d["online"] for d in out)
        if now - self.last_discovery > (REDISCOVER_OFFLINE if offline else REDISCOVER_EVERY):
            self.kick_discovery()
        return out

    # ---------- control ----------
    async def _lookup(self, dev_id: str) -> tuple[Root, Device]:
        did = dev_id.removeprefix("kasa:")
        if did not in self.index:
            if did in self.known:
                await self.discover()
            if did not in self.index:
                name = self.known.get(did, {}).get("name", dev_id)
                raise DeviceError(f"{name} is offline (not found on the network)", status=503 if did in self.known else 404)
        rid, d = self.index[did]
        return self.roots[rid], d

    async def set(self, dev_id: str, cmd: dict) -> dict:
        root, d = await self._lookup(dev_id)
        for attempt in range(2):
            try:
                async with root.lock:
                    await asyncio.wait_for(self._apply(root, d, cmd), OP_TIMEOUT * 2)
                    await asyncio.wait_for(root.dev.update(), OP_TIMEOUT)
                    root.online, root.error, root.updated = True, None, time.monotonic()
                break
            except DeviceError:
                raise
            except Exception as e:
                log.warning("kasa command to %s failed (attempt %d): %r", d.alias, attempt + 1, e)
                if attempt:
                    root.online = False
                    raise DeviceError(f"{d.alias}: {e or type(e).__name__}", status=503)
                await self._reconnect(root)
                root, d = await self._lookup(dev_id)
        if cmd.get("name"):
            self._register(root.dev.device_id, root.dev)
            self._save_cache()
        return self._describe(d, online=True)

    async def _apply(self, root: Root, d: Device, cmd: dict):
        light = d.modules.get(Module.Light)
        name = d.alias
        if cmd.get("name"):
            await d.set_alias(str(cmd["name"])[:32])
        on = cmd.get("on")
        if cmd.get("toggle"):
            await root.dev.update()
            on = not d.is_on
        attrs = cmd.get("brightness") is not None or cmd.get("color") or cmd.get("color_temp")
        if attrs and on is False:
            attrs = False  # turning off: skip attributes
        if attrs:
            if cmd.get("brightness") is not None and not (light and light.has_feature("brightness")):
                raise DeviceError(f"{name} is not dimmable")
            if cmd.get("color") and not (light and light.has_feature("hsv")):
                raise DeviceError(f"{name} does not support color")
            if cmd.get("color_temp") and not cmd.get("color") and not (light and light.has_feature("color_temp")):
                raise DeviceError(f"{name} does not support color temperature")
            bri = cmd.get("brightness")
            if cmd.get("color"):
                h, s, v = hex_to_hsv(cmd["color"])
                await light.set_hsv(h, s, int(bri) if bri is not None else (light.brightness or 100))
            elif cmd.get("color_temp"):
                await light.set_color_temp(int(cmd["color_temp"]), brightness=int(bri) if bri is not None else None)
            elif bri is not None:
                await light.set_brightness(max(1, int(bri)))
            if on is None:
                on = True
        if on is True:
            await d.turn_on()
        elif on is False:
            await d.turn_off()

    async def _reconnect(self, root: Root):
        """Device stopped answering: try its last IP, then a full rediscovery (IP may have changed)."""
        host = root.dev.host
        try:
            dev = await Discover.discover_single(host, credentials=self.creds, discovery_timeout=3)
            await asyncio.wait_for(dev.update(), OP_TIMEOUT)
            if dev.device_id == root.dev.device_id:
                async with root.lock:
                    await _safe_disconnect(root.dev)
                    root.dev, root.online, root.updated = dev, True, time.monotonic()
                self._register(dev.device_id, dev)
                return
            await _safe_disconnect(dev)
        except Exception as e:
            log.info("reconnect to %s failed: %r — rediscovering", host, e)
        await self.discover()

    async def test(self) -> dict:
        t0 = time.perf_counter()
        await self.discover()
        devices = await self.list()
        online = [d for d in devices if d["online"]]
        return {
            "ok": bool(online),
            "has_credentials": self.has_credentials,
            "latency_ms": round((time.perf_counter() - t0) * 1000),
            "device_count": len(devices),
            "online_count": len(online),
            "devices": sorted(d["name"] for d in online),
            "error": self.last_error,
        }

    async def close(self):
        if self._discovery and not self._discovery.done():
            self._discovery.cancel()
        for r in self.roots.values():
            await _safe_disconnect(r.dev)


async def _safe_disconnect(dev: Device):
    try:
        await dev.disconnect()
    except Exception:
        pass


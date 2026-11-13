"""Philips Hue provider (local bridge, v1 REST API).

Device ids are `hue:<uniqueid>` where uniqueid is the bulb's Zigbee MAC + endpoint
(e.g. 00:17:88:01:0d:bf:61:0e-0b). It is burned into the bulb, so it survives renames,
bridge light re-numbering and even moving the bulb to another bridge.
"""
import asyncio
import time

import aiohttp

from colors import hex_to_rgb, kelvin_to_hex, rgb_to_xy, xy_to_hex
from errors import DeviceError, ProviderError


class HueProvider:
    name = "hue"

    def __init__(self, bridge_ip: str, username: str, session: aiohttp.ClientSession):
        self.bridge_ip = (bridge_ip or "").strip()
        self.username = (username or "").strip()
        self.session = session
        self._cache: tuple[float, dict] | None = None
        self._lock = asyncio.Lock()

    @property
    def configured(self) -> bool:
        return bool(self.bridge_ip and self.username)

    def _require_config(self):
        if not self.bridge_ip:
            raise ProviderError("Hue bridge IP is not set (Settings → Philips Hue)")
        if not self.username:
            raise ProviderError("Hue bridge is not paired (Settings → Philips Hue → Pair)")

    async def _req(self, method: str, path: str, body=None, timeout: float = 4.0):
        self._require_config()
        url = f"http://{self.bridge_ip}/api/{self.username}/{path}"
        try:
            async with self.session.request(method, url, json=body, timeout=aiohttp.ClientTimeout(total=timeout)) as r:
                data = await r.json(content_type=None)
        except asyncio.TimeoutError:
            raise ProviderError(f"Hue bridge {self.bridge_ip} timed out")
        except aiohttp.ClientError as e:
            raise ProviderError(f"Hue bridge {self.bridge_ip} unreachable: {e}")
        if isinstance(data, list) and data and isinstance(data[0], dict) and "error" in data[0] and method == "GET":
            raise ProviderError(f"Hue: {data[0]['error'].get('description')}")
        return data

    async def _lights(self, max_age: float = 1.0) -> dict:
        async with self._lock:
            if self._cache and time.monotonic() - self._cache[0] < max_age:
                return self._cache[1]
            lights = await self._req("GET", "lights")
            self._cache = (time.monotonic(), lights)
            return lights

    @staticmethod
    def _to_device(num: str, l: dict) -> dict:
        st = l.get("state", {})
        ctl = l.get("capabilities", {}).get("control", {})
        ct_caps = ctl.get("ct") or {}
        has_color = "xy" in st or "colorgamut" in ctl
        has_ct = "ct" in st
        ct_range = None
        if has_ct:
            lo, hi = ct_caps.get("min", 153), ct_caps.get("max", 500)
            ct_range = [round(1_000_000 / hi), round(1_000_000 / lo)]
        mode = st.get("colormode")
        color = color_temp = None
        if mode == "ct" and st.get("ct"):
            color_temp = round(1_000_000 / st["ct"])
            color = kelvin_to_hex(color_temp)
        elif mode in ("xy", "hs") and st.get("xy"):
            color = xy_to_hex(*st["xy"])
        product = (l.get("productname") or l.get("type") or "").lower()
        return {
            "id": f"hue:{l.get('uniqueid') or 'bridge-' + num}",
            "provider": "hue",
            "name": l.get("name", f"Hue light {num}"),
            "kind": "lightstrip" if "strip" in product else "bulb",
            "model": l.get("productname") or l.get("modelid") or l.get("type"),
            "online": bool(st.get("reachable", False)),
            "on": bool(st.get("on", False)),
            "brightness": round(st["bri"] / 254 * 100) if "bri" in st else None,
            "color": color,
            "color_temp": color_temp,
            "capabilities": {
                "dimmable": "bri" in st,
                "color": has_color,
                "color_temp": has_ct,
                "color_temp_range": ct_range,
                "rename": True,
            },
            "native_id": num,
        }

    async def list(self) -> list[dict]:
        if not self.configured:
            return []
        return [self._to_device(k, v) for k, v in (await self._lights()).items()]

    async def _find(self, dev_id: str) -> tuple[str, dict]:
        for k, v in (await self._lights(max_age=5)).items():
            if self._to_device(k, v)["id"] == dev_id:
                return k, v
        # maybe a fresh bulb — retry uncached
        for k, v in (await self._lights(max_age=0)).items():
            if self._to_device(k, v)["id"] == dev_id:
                return k, v
        raise DeviceError("Hue light not found on bridge", status=404)

    async def set(self, dev_id: str, cmd: dict) -> dict:
        num, light = await self._find(dev_id)
        dev = self._to_device(num, light)
        caps = dev["capabilities"]
        if "name" in cmd and cmd["name"]:
            await self._check(await self._req("PUT", f"lights/{num}", {"name": str(cmd["name"])[:32]}))
        state: dict = {}
        if cmd.get("toggle"):
            # Use live state for toggles so a stale cache can't invert intent.
            light = (await self._req("GET", f"lights/{num}"))
            state["on"] = not light.get("state", {}).get("on", False)
        if "on" in cmd and cmd["on"] is not None:
            state["on"] = bool(cmd["on"])
        if cmd.get("brightness") is not None:
            if not caps["dimmable"]:
                raise DeviceError(f"{dev['name']} is not dimmable")
            state["bri"] = max(1, min(254, round(float(cmd["brightness"]) / 100 * 254)))
        if cmd.get("color"):
            if not caps["color"]:
                raise DeviceError(f"{dev['name']} does not support color")
            state["xy"] = list(rgb_to_xy(*hex_to_rgb(cmd["color"])))
        elif cmd.get("color_temp"):
            if not caps["color_temp"]:
                raise DeviceError(f"{dev['name']} does not support color temperature")
            state["ct"] = max(153, min(500, round(1_000_000 / float(cmd["color_temp"]))))
        if any(k in state for k in ("bri", "xy", "ct")) and "on" not in state:
            state["on"] = True  # attributes can't change while a bulb is off
        if state:
            if not dev["online"]:
                raise DeviceError(f"{dev['name']} is unreachable (powered off at the switch?)", status=503)
            if state.get("on") is False:
                state = {"on": False}  # don't bother sending attributes when turning off
            await self._check(await self._req("PUT", f"lights/{num}/state", state))
        self._cache = None
        return self._to_device(num, await self._req("GET", f"lights/{num}"))

    @staticmethod
    async def _check(resp):
        errs = [r["error"].get("description", "error") for r in resp if isinstance(r, dict) and "error" in r]
        if errs:
            raise DeviceError("Hue: " + "; ".join(errs))

    async def test(self) -> dict:
        t0 = time.perf_counter()
        cfg = await self._req("GET", "config")
        if isinstance(cfg, list):
            raise ProviderError(f"Hue: {cfg[0].get('error', {}).get('description')}")
        if "whitelist" not in cfg and "zigbeechannel" not in cfg:
            raise ProviderError("Hue bridge rejected the stored username (re-pair the bridge)")
        lights = await self._lights(max_age=0)
        return {
            "ok": True,
            "latency_ms": round((time.perf_counter() - t0) * 1000),
            "bridge_name": cfg.get("name"),
            "bridge_id": cfg.get("bridgeid"),
            "api_version": cfg.get("apiversion"),
            "light_count": len(lights),
            "unreachable": sum(1 for v in lights.values() if not v.get("state", {}).get("reachable")),
        }


async def pair(session: aiohttp.ClientSession, bridge_ip: str) -> dict:
    """One pairing attempt. Returns {paired: bool, username?, message}."""
    url = f"http://{bridge_ip.strip()}/api"
    try:
        async with session.post(url, json={"devicetype": "homecontrol#mac"}, timeout=aiohttp.ClientTimeout(total=4)) as r:
            data = await r.json(content_type=None)
    except (aiohttp.ClientError, asyncio.TimeoutError) as e:
        raise ProviderError(f"Could not reach a Hue bridge at {bridge_ip}: {e or 'timeout'}")
    item = data[0] if isinstance(data, list) and data else {}
    if "success" in item:
        return {"paired": True, "username": item["success"]["username"], "message": "Paired"}
    err = item.get("error", {})
    if err.get("type") == 101:
        return {"paired": False, "message": "Press the round link button on the bridge"}
    raise ProviderError(f"Hue: {err.get('description', 'unexpected response')}")

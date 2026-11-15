"""Tuya / Smart Life provider (local network, via tinytuya) — Eightree plugs and other Tuya sockets.

Device ids are `tuya:<gwId>`, the id Tuya burns into the device. It survives renames and IP changes.

Control is fully local (protocol 3.3 / 3.4 / 3.5), but each device needs a secret *local key* that only
Tuya's cloud can hand out. `tuya_devices.json` (next to config.json, mode 0600) holds those keys. Create it
with POST /integrations/tuya/refresh after putting TUYA_ACCESS_ID / TUYA_ACCESS_SECRET / TUYA_REGION in .env
(see the Tuya pane in Settings). Re-run it whenever a device is re-paired in the Smart Life app.

Only on/off sockets are supported for now (DPS 1, `switch_1`).
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import select
import socket
import time
from dataclasses import dataclass, field
from pathlib import Path

import tinytuya

from errors import DeviceError, ProviderError

log = logging.getLogger("tuya")

OP_TIMEOUT = 8
UDP_PORTS = (6666, 6667, 7000)  # plain / encrypted / 3.5 device broadcasts
REDISCOVER_EVERY = 300  # s
REDISCOVER_OFFLINE = 45  # s, faster retry while something is missing
STATUS_MAX_AGE = 1.5  # s
DEFAULT_VERSION = "3.5"


@dataclass
class Dev:
    id: str
    name: str
    key: str
    model: str | None = None
    switch_dp: str = "1"
    ip: str | None = None
    version: str = DEFAULT_VERSION
    online: bool = False
    on: bool = False
    updated: float = 0.0
    error: str | None = None
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class TuyaProvider:
    name = "tuya"

    def __init__(self, devices_path: Path, ips_path: Path, discovery_timeout: int = 8,
                 access_id: str = "", access_secret: str = "", region: str = ""):
        self.devices_path = devices_path
        self.ips_path = ips_path
        self.discovery_timeout = discovery_timeout
        self.cloud = (access_id, access_secret, region)
        self.devs: dict[str, Dev] = {}
        self._file_stamp = None
        self.ips: dict[str, dict] = self._load_ips()
        self.last_discovery = 0.0
        self.last_error: str | None = None
        self._discovery: asyncio.Task | None = None
        self._load_devices()

    @property
    def has_keys(self) -> bool:
        return bool(self.devs)

    @property
    def has_credentials(self) -> bool:
        return all(self.cloud)

    # ---------- key file + IP cache ----------
    def _load_ips(self) -> dict:
        try:
            return json.loads(self.ips_path.read_text())
        except Exception:
            return {}

    def _save_ips(self):
        try:
            self.ips_path.write_text(json.dumps(self.ips, indent=1))
        except Exception as e:
            log.warning("could not write ip cache: %s", e)

    def _load_devices(self):
        try:
            stamp = self.devices_path.stat().st_mtime_ns
        except FileNotFoundError:
            self.devs, self._file_stamp = {}, None
            return
        if stamp == self._file_stamp:
            return
        try:
            rows = json.loads(self.devices_path.read_text())
        except Exception as e:
            self.last_error = f"tuya_devices.json is not valid ({e}); keeping previous devices"
            log.error(self.last_error)
            return
        self._file_stamp = stamp
        new = {}
        for r in rows:
            if r.get("sub") or not r.get("id") or not r.get("key"):
                continue  # sub-devices (Zigbee behind a hub) are not reachable directly
            old = self.devs.get(r["id"])
            d = old or Dev(r["id"], r.get("name") or r["id"], r["key"])
            d.name, d.key, d.model = r.get("name") or r["id"], r["key"], r.get("product_name", "").strip() or r.get("model")
            mapping = r.get("mapping") or {}
            d.switch_dp = next((str(k) for k, v in mapping.items() if (v or {}).get("code") in ("switch_1", "switch")), "1")
            cached = self.ips.get(d.id)
            if cached and not d.ip:
                d.ip, d.version = cached.get("ip"), cached.get("version") or DEFAULT_VERSION
            new[d.id] = d
        self.devs = new

    # ---------- discovery (UDP broadcasts every device sends every few seconds) ----------
    def kick_discovery(self) -> asyncio.Task:
        if self._discovery is None or self._discovery.done():
            self._discovery = asyncio.create_task(self._discover())
        return self._discovery

    async def discover(self):
        await asyncio.shield(self.kick_discovery())

    def _scan(self, timeout: float) -> dict:
        socks = []
        for port in UDP_PORTS:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                if hasattr(socket, "SO_REUSEPORT"):
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                s.bind(("", port))
                s.setblocking(False)
                socks.append(s)
            except OSError as e:
                log.debug("cannot listen on udp/%d: %s", port, e)
                s.close()
        if not socks:
            raise OSError("could not listen for Tuya broadcasts (UDP 6666/6667/7000 are all in use)")
        found, t0 = {}, time.monotonic()
        try:
            while time.monotonic() - t0 < timeout:
                ready, _, _ = select.select(socks, [], [], 0.5)
                for s in ready:
                    try:
                        data, addr = s.recvfrom(4096)
                        msg = tinytuya.decrypt_udp(data)
                        msg = json.loads(msg) if isinstance(msg, (str, bytes)) else msg
                        if isinstance(msg, dict) and msg.get("gwId"):
                            found[msg["gwId"]] = {"ip": msg.get("ip") or addr[0], "version": str(msg.get("version") or DEFAULT_VERSION)}
                    except Exception:
                        continue
        finally:
            for s in socks:
                s.close()
        return found

    async def _discover(self):
        t0 = time.monotonic()
        try:
            found = await asyncio.to_thread(self._scan, self.discovery_timeout)
        except Exception as e:
            self.last_error = f"Tuya discovery failed: {e}"
            log.error(self.last_error)
            return
        self._load_devices()
        mine = 0
        for gid, info in found.items():
            d = self.devs.get(gid)
            if not d:
                continue  # a Tuya device that isn't in our key file
            mine += 1
            d.ip, d.version = info["ip"], info["version"]
            self.ips[gid] = info
        if mine:
            self._save_ips()
        self.last_discovery = time.monotonic()
        log.info("heard %d/%d tuya devices in %.1fs", mine, len(self.devs), time.monotonic() - t0)

    # ---------- device I/O (tinytuya is blocking: run in threads) ----------
    @staticmethod
    def _dev(d: Dev) -> tinytuya.OutletDevice:
        t = tinytuya.OutletDevice(d.id, d.ip, d.key, version=float(d.version), connection_timeout=4)
        t.set_socketPersistent(False)
        return t

    @staticmethod
    def _check(resp, what: str) -> dict:
        if not isinstance(resp, dict):
            raise DeviceError(f"{what}: no response", status=503)
        if resp.get("Error"):
            msg = str(resp["Error"])
            if "914" in str(resp.get("Err", "")):
                msg = "wrong local key — refresh keys in Settings → Tuya"
            raise DeviceError(f"{what}: {msg}", status=503)
        return resp

    def _read_sync(self, d: Dev) -> bool:
        resp = self._check(self._dev(d).status(), d.name)
        dps = resp.get("dps") or {}
        if d.switch_dp not in dps:
            raise DeviceError(f"{d.name}: unexpected status {sorted(dps)}")
        return bool(dps[d.switch_dp])

    def _write_sync(self, d: Dev, on: bool | None, toggle: bool) -> bool:
        t = self._dev(d)
        if toggle:
            resp = self._check(t.status(), d.name)
            on = not bool((resp.get("dps") or {}).get(d.switch_dp))
        self._check(t.set_value(d.switch_dp, bool(on)), d.name)
        return bool(self._check(t.status(), d.name).get("dps", {}).get(d.switch_dp))

    async def _refresh(self, d: Dev, max_age: float = STATUS_MAX_AGE):
        if not d.ip:
            d.online, d.error = False, "not found on the network"
            return
        if d.online and time.monotonic() - d.updated < max_age:
            return
        async with d.lock:
            try:
                d.on = await asyncio.wait_for(asyncio.to_thread(self._read_sync, d), OP_TIMEOUT)
                d.online, d.error, d.updated = True, None, time.monotonic()
            except Exception as e:
                d.online, d.error = False, str(e) or type(e).__name__

    # ---------- API used by the server ----------
    def _describe(self, d: Dev) -> dict:
        return {
            "id": f"tuya:{d.id}",
            "provider": "tuya",
            "name": d.name,
            "kind": "plug",
            "model": d.model,
            "online": d.online,
            "on": d.on if d.online else False,
            "brightness": None,
            "color": None,
            "color_temp": None,
            "capabilities": {"dimmable": False, "color": False, "color_temp": False, "color_temp_range": None,
                             "rename": False},
            "native_id": d.ip,
        }

    async def list(self) -> list[dict]:
        self._load_devices()
        if not self.devs:
            return []
        now = time.monotonic()
        if not self.last_discovery:
            if not any(d.ip for d in self.devs.values()):
                await self.discover()  # first run: nothing known yet
            else:
                self.kick_discovery()
        await asyncio.gather(*(self._refresh(d) for d in self.devs.values()))
        out = [self._describe(d) for d in self.devs.values()]
        offline = any(not d.online for d in self.devs.values())
        if self.last_discovery and now - self.last_discovery > (REDISCOVER_OFFLINE if offline else REDISCOVER_EVERY):
            self.kick_discovery()
        return out

    async def _lookup(self, dev_id: str) -> Dev:
        self._load_devices()
        d = self.devs.get(dev_id.removeprefix("tuya:"))
        if not d:
            raise DeviceError("Tuya device not found (is it in tuya_devices.json?)", status=404)
        return d

    async def set(self, dev_id: str, cmd: dict) -> dict:
        d = await self._lookup(dev_id)
        if cmd.get("name"):
            raise DeviceError("Tuya devices are renamed in the Smart Life app")
        for k, label in (("brightness", "is not dimmable"), ("color", "does not support color"),
                         ("color_temp", "does not support color temperature")):
            if cmd.get(k) not in (None, ""):
                raise DeviceError(f"{d.name} {label}")
        on, toggle = cmd.get("on"), bool(cmd.get("toggle"))
        for attempt in range(2):
            if not d.ip:
                await self.discover()
            if not d.ip:
                raise DeviceError(f"{d.name} is offline (not found on the network)", status=503)
            try:
                async with d.lock:
                    if on is None and not toggle:
                        d.on = await asyncio.wait_for(asyncio.to_thread(self._read_sync, d), OP_TIMEOUT)
                    else:
                        d.on = await asyncio.wait_for(asyncio.to_thread(self._write_sync, d, on, toggle), OP_TIMEOUT * 2)
                    d.online, d.error, d.updated = True, None, time.monotonic()
                break
            except Exception as e:
                log.warning("tuya command to %s failed (attempt %d): %r", d.name, attempt + 1, e)
                if attempt:
                    d.online, d.error = False, str(e) or type(e).__name__
                    raise e if isinstance(e, DeviceError) else DeviceError(f"{d.name}: {e or type(e).__name__}", status=503)
                await self.discover()  # its IP may have changed
        return self._describe(d)

    async def test(self) -> dict:
        t0 = time.perf_counter()
        self._load_devices()
        if not self.devs:
            return {"ok": False, "has_keys": False, "has_credentials": self.has_credentials, "latency_ms": 0,
                    "device_count": 0, "online_count": 0, "devices": [],
                    "error": "No device keys yet — click Fetch Device Keys" if self.has_credentials
                             else "No device keys yet — add TUYA_ACCESS_ID, TUYA_ACCESS_SECRET and TUYA_REGION to .env"}
        await self.discover()
        devices = await self.list()
        online = [d for d in devices if d["online"]]
        return {
            "ok": bool(online),
            "has_keys": True,
            "has_credentials": self.has_credentials,
            "latency_ms": round((time.perf_counter() - t0) * 1000),
            "device_count": len(devices),
            "online_count": len(online),
            "devices": sorted(d["name"] for d in online),
            "error": self.last_error,
        }

    # ---------- fetch / refresh local keys from Tuya's cloud ----------
    def _fetch_sync(self) -> list[dict]:
        access_id, secret, region = self.cloud
        c = tinytuya.Cloud(apiRegion=region, apiKey=access_id, apiSecret=secret)
        if not getattr(c, "token", None):
            err = getattr(c, "error", None)
            raise ProviderError(f"Tuya cloud login failed: {(err or {}).get('Payload') or err or 'no token'} — check the Access ID/Secret and region")
        devs = c.getdevices()
        if not isinstance(devs, list):
            raise ProviderError(f"Tuya cloud returned an unexpected response: {str(devs)[:120]}")
        return [{k: d.get(k) for k in ("id", "name", "key", "category", "product_name", "model", "mac", "sub", "mapping")}
                for d in devs]

    async def refresh_keys(self) -> dict:
        if not self.has_credentials:
            raise ProviderError("Add TUYA_ACCESS_ID, TUYA_ACCESS_SECRET and TUYA_REGION to .env first")
        rows = await asyncio.to_thread(self._fetch_sync)
        tmp = self.devices_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(rows, indent=1))
        os.chmod(tmp, 0o600)
        tmp.replace(self.devices_path)
        self._load_devices()
        self.last_error = None
        self.kick_discovery()
        return {"ok": True, "device_count": len(self.devs), "devices": sorted(d.name for d in self.devs.values())}

    async def close(self):
        if self._discovery and not self._discovery.done():
            self._discovery.cancel()

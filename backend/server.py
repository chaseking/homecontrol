#!/usr/bin/env python3
"""HomeControl backend: a tiny HTTP API over Philips Hue + TP-Link Kasa.

  python server.py [--host 127.0.0.1] [--port 8790] [--config ../config.json] [--env ../.env]

Reads integration settings from config.json (`integrations` section, written by the app) and
secrets from .env (KASA_USERNAME, KASA_PASSWORD, HUE_USERNAME, optional HOMECONTROL_TOKEN).
Both files are re-read automatically when they change.

API (JSON everywhere):
  GET  /health                      service info, no auth needed
  GET  /devices                     all devices from all integrations (+ per-integration errors)
  GET  /devices/{id}                one device
  POST /devices/{id}                {on?, toggle?, brightness? 0-100, color? "#rrggbb", color_temp? K, name?}
  POST /run                         {mode: "parallel"|"sequential", delay_ms?, steps: [{device_id, action: on|off|toggle, brightness?, color?, color_temp?}]}
  GET  /integrations/hue/test       ping the bridge
  POST /integrations/hue/pair       {bridge_ip?} one pairing attempt (press the link button first)
  GET  /integrations/kasa/test      rediscover Kasa devices
  POST /reload                      force re-reading config/.env
  POST /shutdown                    stop the server (loopback only)
"""
import argparse
import asyncio
import json
import logging
import os
import sys
import time
from pathlib import Path

import aiohttp
from aiohttp import web

sys.path.insert(0, str(Path(__file__).parent))
import hue as hue_mod  # noqa: E402
from errors import DeviceError, ProviderError  # noqa: E402
from hue import HueProvider  # noqa: E402
from kasa_provider import KasaProvider  # noqa: E402



def _read_version() -> str:
    try:
        return (Path(__file__).resolve().parent.parent / "VERSION").read_text().strip()
    except OSError:
        return "unknown"


VERSION = _read_version()
log = logging.getLogger("homecontrol")


def read_env(path: Path) -> dict:
    out = {}
    try:
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip().removeprefix("export ").strip()] = v.strip().strip("\"'")
    except FileNotFoundError:
        pass
    return out


def write_env_var(path: Path, key: str, value: str):
    lines = path.read_text().splitlines() if path.exists() else []
    lines = [l for l in lines if not l.strip().startswith(f"{key}=")]
    lines.append(f"{key}={value}")
    path.write_text("\n".join(lines) + "\n")
    os.chmod(path, 0o600)


class Backend:
    def __init__(self, config_path: Path, env_path: Path):
        self.config_path, self.env_path = config_path, env_path
        self.started = time.time()
        self.session: aiohttp.ClientSession | None = None
        self.hue: HueProvider | None = None
        self.kasa: KasaProvider | None = None
        self._stamp = None
        self._sig: dict = {}
        self.env: dict = {}
        self.config: dict = {}

    def _mtime(self, p: Path):
        try:
            return p.stat().st_mtime_ns
        except FileNotFoundError:
            return None

    async def sync(self, force=False):
        """(Re)build providers if config.json or .env changed."""
        stamp = (self._mtime(self.config_path), self._mtime(self.env_path))
        if stamp == self._stamp and not force:
            return
        self._stamp = stamp
        try:
            self.config = json.loads(self.config_path.read_text()) if self.config_path.exists() else {}
        except json.JSONDecodeError as e:
            log.error("config.json is not valid JSON (%s); keeping previous settings", e)
        self.env = {**{k: v for k, v in os.environ.items() if k.startswith(("KASA_", "HUE_", "HOMECONTROL_"))},
                    **read_env(self.env_path)}
        integ = self.config.get("integrations", {})
        h, k = integ.get("hue", {}), integ.get("kasa", {})
        hue_sig = (h.get("enabled", True), h.get("bridgeIP", ""), self.env.get("HUE_USERNAME", ""))
        kasa_sig = (k.get("enabled", True), self.env.get("KASA_USERNAME", ""), self.env.get("KASA_PASSWORD", ""),
                    int(k.get("discoveryTimeout", 5)))
        if hue_sig != self._sig.get("hue"):
            self._sig["hue"] = hue_sig
            self.hue = HueProvider(hue_sig[1], hue_sig[2], self.session) if hue_sig[0] else None
            log.info("hue provider: %s", "enabled, bridge " + (hue_sig[1] or "<unset>") if hue_sig[0] else "disabled")
        if kasa_sig != self._sig.get("kasa"):
            self._sig["kasa"] = kasa_sig
            if self.kasa:
                await self.kasa.close()
            self.kasa = None
            if kasa_sig[0]:
                self.kasa = KasaProvider(kasa_sig[1], kasa_sig[2], self.config_path.parent / ".kasa_devices.json", kasa_sig[3])
                self.kasa.kick_discovery()
            log.info("kasa provider: %s", "enabled" if kasa_sig[0] else "disabled")

    @property
    def token(self) -> str:
        return self.env.get("HOMECONTROL_TOKEN", "")

    def provider_for(self, dev_id: str):
        prefix = dev_id.split(":", 1)[0]
        p = {"hue": self.hue, "kasa": self.kasa}.get(prefix)
        if p is None:
            raise DeviceError(f"No enabled integration for {dev_id}", status=404)
        return p

    async def devices(self) -> tuple[list, dict]:
        provs = [p for p in (self.hue, self.kasa) if p]
        res = await asyncio.gather(*(p.list() for p in provs), return_exceptions=True)
        devices, errors = [], {}
        for p, r in zip(provs, res):
            if isinstance(r, BaseException):
                errors[p.name] = str(r) if isinstance(r, (ProviderError, DeviceError)) else f"{type(r).__name__}: {r}"
                if not isinstance(r, ProviderError):
                    log.exception("listing %s failed", p.name, exc_info=r)
            else:
                devices += r
        if self.kasa and self.kasa.last_error and "kasa" not in errors:
            errors["kasa"] = self.kasa.last_error
        devices.sort(key=lambda d: (d["name"] or "").lower())
        return devices, errors

    async def command(self, dev_id: str, cmd: dict) -> dict:
        return await self.provider_for(dev_id).set(dev_id, cmd)


def step_to_cmd(step: dict) -> dict:
    action = step.get("action", "on")
    if action == "off":
        return {"on": False}
    if action == "toggle":
        return {"toggle": True}
    cmd = {"on": True}
    for k in ("brightness", "color", "color_temp"):
        if step.get(k) not in (None, ""):
            cmd[k] = step[k]
    return cmd


# ---------------- HTTP ----------------
routes = web.RouteTableDef()


def err(msg: str, status: int = 400):
    return web.json_response({"error": msg}, status=status)


@web.middleware
async def middleware(request: web.Request, handler):
    be: Backend = request.app["backend"]
    await be.sync()
    if request.path != "/health" and be.token:
        if request.headers.get("Authorization", "") != f"Bearer {be.token}":
            return err("unauthorized (set the backend token in Settings → Advanced)", 401)
    try:
        return await handler(request)
    except web.HTTPException:
        raise
    except DeviceError as e:
        return err(str(e), e.status)
    except ProviderError as e:
        return err(str(e), 503)
    except (ValueError, KeyError, TypeError) as e:
        return err(f"bad request: {e}", 400)
    except Exception as e:  # pragma: no cover
        log.exception("unhandled error on %s", request.path)
        return err(f"{type(e).__name__}: {e}", 500)


@routes.get("/health")
async def health(request):
    be: Backend = request.app["backend"]
    auth = request.headers.get("Authorization", "")
    return web.json_response({
        "service": "homecontrol-backend",
        "version": VERSION,
        "uptime_s": round(time.time() - be.started),
        "auth_required": bool(be.token),
        "authorized": not be.token or auth == f"Bearer {be.token}",
        "integrations": {
            "hue": {"enabled": be.hue is not None, "configured": bool(be.hue and be.hue.configured),
                    "bridge_ip": be.hue.bridge_ip if be.hue else None},
            "kasa": {"enabled": be.kasa is not None, "has_credentials": bool(be.kasa and be.kasa.has_credentials)},
        },
    })


@routes.get("/devices")
async def list_devices(request):
    devices, errors = await request.app["backend"].devices()
    return web.json_response({"devices": devices, "errors": errors})


@routes.get("/devices/{id}")
async def get_device(request):
    devices, _ = await request.app["backend"].devices()
    for d in devices:
        if d["id"] == request.match_info["id"]:
            return web.json_response(d)
    return err("device not found", 404)


@routes.post("/devices/{id}")
async def set_device(request):
    body = await request.json()
    if not isinstance(body, dict):
        return err("expected a JSON object")
    return web.json_response(await request.app["backend"].command(request.match_info["id"], body))


@routes.post("/run")
async def run(request):
    be: Backend = request.app["backend"]
    body = await request.json()
    steps = body.get("steps") or []
    mode = body.get("mode", "parallel")
    delay = max(0, int(body.get("delay_ms", 0))) / 1000

    async def one(step: dict) -> dict:
        res = {"step_id": step.get("id"), "device_id": step.get("device_id"), "ok": True, "error": None}
        t0 = time.perf_counter()
        try:
            res["device"] = await be.command(step["device_id"], step_to_cmd(step))
        except Exception as e:
            res["ok"], res["error"] = False, str(e) or type(e).__name__
        res["ms"] = round((time.perf_counter() - t0) * 1000)
        return res

    t0 = time.perf_counter()
    if mode == "sequential":
        results = []
        for i, s in enumerate(steps):
            if i and delay:
                await asyncio.sleep(delay)
            results.append(await one(s))
    else:
        results = list(await asyncio.gather(*(one(s) for s in steps)))
    failed = [r for r in results if not r["ok"]]
    log.info("run %s: %d steps, %d failed", mode, len(steps), len(failed))
    return web.json_response({"ok": not failed, "results": results, "ms": round((time.perf_counter() - t0) * 1000)})


@routes.get("/integrations/hue/test")
async def hue_test(request):
    be: Backend = request.app["backend"]
    if not be.hue:
        return err("Hue integration is disabled", 503)
    return web.json_response(await be.hue.test())


@routes.post("/integrations/hue/pair")
async def hue_pair(request):
    be: Backend = request.app["backend"]
    body = await request.json() if request.can_read_body else {}
    ip = (body.get("bridge_ip") or (be.hue.bridge_ip if be.hue else "")).strip()
    if not ip:
        return err("Set the bridge IP first")
    res = await hue_mod.pair(be.session, ip)
    if res.get("paired"):
        write_env_var(be.env_path, "HUE_USERNAME", res["username"])
        await be.sync(force=True)
        res.pop("username")  # never echo secrets
    return web.json_response(res)


@routes.get("/integrations/kasa/test")
async def kasa_test(request):
    be: Backend = request.app["backend"]
    if not be.kasa:
        return err("Kasa integration is disabled", 503)
    return web.json_response(await be.kasa.test())


@routes.post("/reload")
async def reload(request):
    await request.app["backend"].sync(force=True)
    return web.json_response({"ok": True})


@routes.post("/shutdown")
async def shutdown(request):
    if request.remote not in ("127.0.0.1", "::1"):
        return err("shutdown is only allowed from localhost", 403)
    asyncio.get_running_loop().call_later(0.2, lambda: os._exit(0))
    return web.json_response({"ok": True})


async def watch_parent(ppid: int):
    """Exit when the app that launched us goes away (so we never orphan a backend)."""
    while True:
        await asyncio.sleep(2)
        if os.getppid() != ppid:
            log.info("parent %d exited; shutting down", ppid)
            os._exit(0)


def main():
    root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1", help="bind address (use 0.0.0.0 to serve the LAN)")
    ap.add_argument("--port", type=int, default=8790)
    ap.add_argument("--config", type=Path, default=root / "config.json")
    ap.add_argument("--env", type=Path, default=root / ".env")
    ap.add_argument("--parent-pid", type=int, default=0, help="exit when this process is no longer our parent")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("aiohttp.access").setLevel(logging.WARNING)

    backend = Backend(args.config.resolve(), args.env.resolve())

    async def on_startup(app):
        backend.session = aiohttp.ClientSession()
        await backend.sync(force=True)
        if args.parent_pid:
            app["watchdog"] = asyncio.create_task(watch_parent(args.parent_pid))

    async def on_cleanup(app):
        if backend.kasa:
            await backend.kasa.close()
        await backend.session.close()

    app = web.Application(middlewares=[middleware])
    app["backend"] = backend
    app.add_routes(routes)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    log.info("homecontrol backend %s on http://%s:%d (config %s)", VERSION, args.host, args.port, args.config)
    web.run_app(app, host=args.host, port=args.port, print=None)


if __name__ == "__main__":
    main()

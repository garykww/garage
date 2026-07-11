"""whoop-raw command-line interface."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from datetime import datetime

from bleak import BleakClient, BleakScanner
from rich.console import Console
from rich.live import Live
from rich.panel import Panel
from rich.table import Table

from . import protocol
from .parse import history_end_ids, parse_frame, parse_hr_measurement
from .protocol import (
    CHAR_BATTERY_LEVEL,
    CHAR_CMD_TO_STRAP_MG,
    CHAR_HR_MEASUREMENT,
    CMD_TO_STRAP_CHARS,
    KNOWN_COMMANDS,
    NOTIFY_CHARS,
    WHOOP_SERVICES,
    FrameParser,
    MaverickFrameParser,
    build_command,
    build_command_mg,
)

console = Console(highlight=False)

SOURCE_STYLES = {
    "CMD": "cyan",
    "EVENTS": "magenta",
    "DATA": "green",
    "MEMFAULT": "yellow",
    "HR": "red",
}


def _now() -> str:
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


async def find_whoop(args) -> object:
    if args.address:
        console.print(f"Looking for device [bold]{args.address}[/]...")
        device = await BleakScanner.find_device_by_address(args.address, timeout=args.timeout)
        if not device:
            console.print("[red]Device not found. Is it in range and advertising?[/]")
            sys.exit(1)
        return device
    console.print(f"Scanning for a WHOOP ({args.timeout:.0f}s)...")
    devices = await BleakScanner.discover(timeout=args.timeout, return_adv=True)
    for device, adv in devices.values():
        name = device.name or adv.local_name or ""
        if "whoop" in name.lower() or any(s in adv.service_uuids for s in WHOOP_SERVICES):
            console.print(f"Found [bold]{name or '(unnamed)'}[/] @ {device.address}")
            return device
    console.print(
        "[red]No WHOOP found.[/] Make sure the band is charged and nearby. "
        "If it never shows up, toggle Bluetooth off on your phone so the band "
        "starts advertising, or enable HR Broadcast in the WHOOP app."
    )
    sys.exit(1)


async def cmd_scan(args) -> None:
    console.print(f"Scanning for {args.timeout:.0f}s...")
    devices = await BleakScanner.discover(timeout=args.timeout, return_adv=True)
    table = Table(title="BLE devices")
    table.add_column("Name")
    table.add_column("Address")
    table.add_column("RSSI", justify="right")
    table.add_column("WHOOP?", justify="center")
    rows = 0
    for device, adv in sorted(devices.values(), key=lambda d: d[1].rssi or -127, reverse=True):
        name = device.name or adv.local_name or ""
        is_whoop = "whoop" in name.lower() or any(s in adv.service_uuids for s in WHOOP_SERVICES)
        if not name and not is_whoop and not args.all:
            continue
        table.add_row(
            name or "(unnamed)",
            device.address,
            str(adv.rssi),
            "[green]yes[/]" if is_whoop else "",
        )
        rows += 1
    console.print(table if rows else "No named devices found.")


async def cmd_services(args) -> None:
    device = await find_whoop(args)
    async with BleakClient(device) as client:
        console.print(f"[bold green]Connected.[/] GATT table for {device.address}:\n")
        for service in client.services:
            console.print(f"[bold]{service.uuid}[/]  {service.description}")
            for char in service.characteristics:
                props = ",".join(char.properties)
                console.print(f"  {char.uuid}  [{props}]  {char.description}")
        console.print(
            "\n61080xxx characteristics = WHOOP 4.0 framing; fd4b0xxx = "
            "WHOOP 5.0/MG (Maverick) framing. Both are in protocol.py."
        )


def _parse_send_spec(spec: str) -> tuple[int, bytes]:
    cmd_hex, _, payload_hex = spec.partition(":")
    return int(cmd_hex, 16), bytes.fromhex(payload_hex or "")


class Session:
    """Shared connect-subscribe-log plumbing for listen/hr/send."""

    def __init__(self, args, quiet: bool = False, frame_hook=None):
        self.args = args
        self.parsers: dict[str, FrameParser | MaverickFrameParser] = {}
        self.log_fh = open(args.log, "a") if getattr(args, "log", None) else None
        self.disconnected = asyncio.Event()
        self.quiet = quiet
        self.frame_hook = frame_hook

    def log(self, source: str, raw: bytes, parsed: dict) -> None:
        if self.log_fh:
            self.log_fh.write(
                json.dumps(
                    {"t": time.time(), "source": source, "raw": raw.hex(), **parsed}
                )
                + "\n"
            )
            self.log_fh.flush()

    def on_notify(self, source: str, mg: bool = False):
        style = SOURCE_STYLES.get(source, "white")

        def callback(_char, data: bytearray) -> None:
            raw = bytes(data)
            if source == "HR":
                parsed = parse_hr_measurement(raw)
                if not self.quiet:
                    console.print(
                        f"[dim]{_now()}[/] [{style}]HR[/] {parsed['bpm']} bpm  "
                        f"rr={parsed.get('rr_intervals_ms', [])}  [dim]{raw.hex()}[/]"
                    )
                self.log(source, raw, parsed)
                return
            parser = self.parsers.setdefault(
                source, MaverickFrameParser() if mg else FrameParser()
            )
            frames = parser.feed(raw)
            if not frames:
                if not self.quiet:
                    console.print(f"[dim]{_now()}[/] [{style}]{source}[/] (partial) [dim]{raw.hex()}[/]")
                return
            for frame in frames:
                parsed = parse_frame(frame)
                if not self.quiet:
                    crc = "" if frame.crc_ok else " [red]CRC!?[/]"
                    fields = "  ".join(f"{k}={v}" for k, v in parsed.items())
                    console.print(
                        f"[dim]{_now()}[/] [{style}]{source}[/] {frame.type_name}{crc} "
                        f"{fields}  [dim]{frame.raw.hex()}[/]"
                    )
                self.log(source, frame.raw, {"type": frame.type_name, "crc_ok": frame.crc_ok, **parsed})
                if self.frame_hook:
                    self.frame_hook(source, frame, parsed)

        return callback

    async def subscribe_all(self, client: BleakClient) -> list[str]:
        subscribed = []
        for uuid, source in NOTIFY_CHARS.items():
            if client.services.get_characteristic(uuid):
                mg = uuid.lower().startswith("fd4b")
                await client.start_notify(uuid, self.on_notify(source, mg=mg))
                subscribed.append(source)
        return subscribed

    def cmd_char(self, client: BleakClient) -> str | None:
        return next(
            (u for u in CMD_TO_STRAP_CHARS if client.services.get_characteristic(u)), None
        )

    async def send(self, client: BleakClient, cmd: int, payload: bytes) -> None:
        char = self.cmd_char(client)
        if char is None:
            console.print("[red]No CMD_TO_STRAP characteristic on this device — can't send.[/]")
            return
        mg = char == CHAR_CMD_TO_STRAP_MG
        pkt = build_command_mg(cmd, payload) if mg else build_command(cmd, payload)
        if not self.quiet:
            desc = KNOWN_COMMANDS.get(cmd, "unknown command")
            framing = "MG" if mg else "4.0"
            console.print(f"[dim]{_now()}[/] [bold]→ 0x{cmd:02x}[/] ({desc}, {framing} framing) [dim]{pkt.hex()}[/]")
        await client.write_gatt_char(char, pkt, response=True)

    def close(self) -> None:
        if self.log_fh:
            self.log_fh.close()


async def cmd_listen(args) -> None:
    device = await find_whoop(args)
    session = Session(args)
    try:
        async with BleakClient(
            device, disconnected_callback=lambda _c: session.disconnected.set()
        ) as client:
            console.print("[bold green]Connected.[/]")
            if client.services.get_characteristic(CHAR_BATTERY_LEVEL):
                level = (await client.read_gatt_char(CHAR_BATTERY_LEVEL))[0]
                console.print(f"Battery: {level}%")
            subscribed = await session.subscribe_all(client)
            console.print(f"Subscribed: {', '.join(subscribed) or 'nothing (no known characteristics!)'}")

            if args.broadcast:
                await session.send(client, 0x0E, b"\x01" if args.broadcast == "on" else b"\x00")
            if args.record:
                await session.send(client, 0x03, b"\x01" if args.record == "start" else b"\x00")
            for spec in args.send or []:
                cmd, payload = _parse_send_spec(spec)
                await session.send(client, cmd, payload)

            console.print("Streaming — Ctrl-C to stop.\n")
            try:
                await asyncio.wait_for(session.disconnected.wait(), timeout=args.duration)
                console.print("[red]Device disconnected.[/]")
            except asyncio.TimeoutError:
                pass
    finally:
        session.close()


async def cmd_hr(args) -> None:
    device = await find_whoop(args)
    session = Session(args)
    latest: dict = {}

    def callback(_char, data: bytearray) -> None:
        latest.update(parse_hr_measurement(bytes(data)))
        latest["at"] = _now()
        session.log("HR", bytes(data), latest)

    def render() -> Panel:
        if not latest:
            return Panel("waiting for heart rate...", title="WHOOP")
        rr = latest.get("rr_intervals_ms", [])
        body = f"[bold red]♥ {latest['bpm']}[/] bpm"
        if rr:
            body += f"   RR {rr} ms"
        return Panel(body, title=f"WHOOP  {latest['at']}")

    try:
        async with BleakClient(device) as client:
            if not client.services.get_characteristic(CHAR_HR_MEASUREMENT):
                console.print(
                    "[red]No Heart Rate service on this device.[/] Enable "
                    "HR Broadcast in the WHOOP app (Device Settings)."
                )
                return
            if args.broadcast:
                await session.send(client, 0x0E, b"\x01" if args.broadcast == "on" else b"\x00")
            await client.start_notify(CHAR_HR_MEASUREMENT, callback)
            with Live(render(), console=console, refresh_per_second=4) as live:
                end = time.monotonic() + args.duration if args.duration else None
                while end is None or time.monotonic() < end:
                    await asyncio.sleep(0.25)
                    live.update(render())
    finally:
        session.close()


async def cmd_temp(args) -> None:
    """Skin temperature. The band doesn't stream it live — it lives in K18
    history records, so this triggers a history download and acks each batch
    (HISTORY_END → cmd 0x17) until the strap reports HISTORY_COMPLETE."""
    device = await find_whoop(args)
    state: dict = {"records": 0, "batches": 0, "latest": None, "complete": False}
    acks: asyncio.Queue[bytes] = asyncio.Queue()

    def hook(_source: str, frame, parsed: dict) -> None:
        if frame.packet_type == protocol.PACKET_TYPE_HISTORICAL:
            state["records"] += 1
            if "skin_temp_hp_c" in parsed:
                state["latest"] = parsed
        elif frame.packet_type == protocol.PACKET_TYPE_METADATA:
            ids = history_end_ids(frame.body)
            if ids is not None:
                acks.put_nowait(b"\x01" + ids)
            elif parsed.get("meta") == "HISTORY_COMPLETE":
                state["complete"] = True

    session = Session(args, quiet=True, frame_hook=hook)

    def render() -> Panel:
        latest = state["latest"]
        if latest is None:
            body = "waiting for a temperature record..."
        else:
            when = datetime.fromtimestamp(latest["unix_ts"]).strftime("%Y-%m-%d %H:%M:%S")
            body = (
                f"[bold cyan]🌡 {latest['skin_temp_hp_c']:.2f} °C[/] skin"
                f"   ({latest['skin_temp_c']:.1f} °C coarse)\n"
                f"recorded {when}"
            )
            if latest.get("on_body") is False:
                body += "  [yellow](off wrist?)[/]"
        status = "drained, band is up to date" if state["complete"] else "draining history..."
        body += f"\n[dim]{state['records']} records / {state['batches']} batches acked — {status}[/]"
        return Panel(body, title="WHOOP skin temperature")

    try:
        async with BleakClient(
            device, disconnected_callback=lambda _c: session.disconnected.set()
        ) as client:
            subscribed = await session.subscribe_all(client)
            if "DATA" not in subscribed:
                console.print("[red]No WHOOP proprietary service on this device — can't read temperature.[/]")
                return
            console.print(
                "[bold green]Connected.[/] Requesting history — skin temperature "
                "arrives in K18 history records, newest last."
            )
            if session.cmd_char(client) == CHAR_CMD_TO_STRAP_MG:
                await session.send(client, 0x60, b"")  # enter high-freq sync
            await session.send(client, 0x16, b"")  # trigger history download
            end = time.monotonic() + args.duration if args.duration else None
            with Live(render(), console=console, refresh_per_second=4) as live:
                while not session.disconnected.is_set():
                    if end is not None and time.monotonic() >= end:
                        break
                    try:
                        await session.send(client, 0x17, acks.get_nowait())
                        state["batches"] += 1
                    except asyncio.QueueEmpty:
                        if state["complete"]:
                            break
                        await asyncio.sleep(0.1)
                    live.update(render())
                live.update(render())
            if session.disconnected.is_set():
                console.print("[red]Device disconnected.[/]")
    finally:
        session.close()


async def cmd_send(args) -> None:
    device = await find_whoop(args)
    session = Session(args)
    try:
        async with BleakClient(device) as client:
            await session.subscribe_all(client)
            cmd, payload = _parse_send_spec(args.command)
            await session.send(client, cmd, payload)
            console.print(f"Waiting {args.wait:.0f}s for responses...")
            await asyncio.sleep(args.wait)
    finally:
        session.close()


def cmd_commands(_args) -> None:
    table = Table(title="Known WHOOP commands (from 4.0 reverse engineering)")
    table.add_column("Byte")
    table.add_column("Meaning")
    for cmd, desc in sorted(KNOWN_COMMANDS.items()):
        table.add_row(f"0x{cmd:02x}", desc)
    console.print(table)
    console.print("Use: whoop-raw send 0e:01   (command byte, ':', payload hex)")


def main() -> None:
    ap = argparse.ArgumentParser(
        prog="whoop-raw",
        description="Connect to a WHOOP band over BLE and stream raw data.",
    )
    ap.add_argument("--address", help="connect to this BLE address/UUID instead of scanning")
    ap.add_argument("--timeout", type=float, default=10.0, help="scan timeout seconds")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("scan", help="list nearby BLE devices, highlighting WHOOPs")
    p.add_argument("--all", action="store_true", help="include unnamed devices")
    p.set_defaults(fn=cmd_scan)

    p = sub.add_parser("services", help="connect and dump the full GATT table")
    p.set_defaults(fn=cmd_services)

    p = sub.add_parser("listen", help="subscribe to every WHOOP characteristic and stream raw frames")
    p.add_argument("--log", help="append every packet as JSON lines to this file")
    p.add_argument("--duration", type=float, help="stop after N seconds (default: until Ctrl-C)")
    p.add_argument("--broadcast", choices=["on", "off"], help="toggle HR broadcast (cmd 0x0e)")
    p.add_argument("--record", choices=["start", "stop"], help="toggle recording mode (cmd 0x03)")
    p.add_argument("--send", action="append", metavar="CMD[:PAYLOAD]", help="send a raw command, hex")
    p.set_defaults(fn=cmd_listen)

    p = sub.add_parser("hr", help="live heart rate via the standard BLE HR service")
    p.add_argument("--log", help="append readings as JSON lines to this file")
    p.add_argument("--duration", type=float, help="stop after N seconds")
    p.add_argument(
        "--broadcast",
        choices=["on", "off"],
        help="toggle HR broadcast via the proprietary channel first (no app needed)",
    )
    p.set_defaults(fn=cmd_hr)

    p = sub.add_parser("temp", help="skin temperature from history records (drains the band's history)")
    p.add_argument("--log", help="append every packet as JSON lines to this file")
    p.add_argument("--duration", type=float, help="stop after N seconds even if not fully drained")
    p.set_defaults(fn=cmd_temp)

    p = sub.add_parser("send", help="send one raw command and print responses")
    p.add_argument("command", metavar="CMD[:PAYLOAD]", help="e.g. 0e:01 or 4c")
    p.add_argument("--wait", type=float, default=5.0, help="seconds to wait for responses")
    p.add_argument("--log", help="append responses as JSON lines to this file")
    p.set_defaults(fn=cmd_send)

    p = sub.add_parser("commands", help="list known command bytes")
    p.set_defaults(fn=cmd_commands)

    args = ap.parse_args()
    try:
        result = args.fn(args)
        if asyncio.iscoroutine(result):
            asyncio.run(result)
    except KeyboardInterrupt:
        console.print("\nbye")


if __name__ == "__main__":
    main()

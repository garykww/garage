"""Decoders for WHOOP notification payloads.

The standard Heart Rate Measurement decoder follows the Bluetooth SIG spec.
The proprietary-frame field layouts are tentative — they match packets
captured from a WHOOP 4.0 and may differ on the 5.0 / MG, which is why every
decoded dict is emitted alongside the raw hex by the CLI.
"""

from __future__ import annotations

import struct

from .protocol import METADATA_TYPES, Frame


def parse_hr_measurement(data: bytes) -> dict:
    """Standard BLE Heart Rate Measurement characteristic (0x2A37)."""
    flags = data[0]
    i = 1
    if flags & 0x01:
        bpm = struct.unpack_from("<H", data, i)[0]
        i += 2
    else:
        bpm = data[i]
        i += 1
    out: dict = {"bpm": bpm}
    if flags & 0x04:
        out["sensor_contact"] = bool(flags & 0x02)
    if flags & 0x08:
        out["energy_kj"] = struct.unpack_from("<H", data, i)[0]
        i += 2
    if flags & 0x10:
        rr = []
        while i + 1 < len(data):
            rr.append(round(struct.unpack_from("<H", data, i)[0] / 1024 * 1000))
            i += 2
        out["rr_intervals_ms"] = rr
    return out


def parse_frame(frame: Frame) -> dict:
    if frame.packet_type == 0x28:
        return _parse_realtime(frame.body)
    if frame.packet_type == 0x2F:
        return _parse_historical(frame.body)
    if frame.packet_type == 0x31:
        return _parse_metadata(frame.body)
    return {}


def _parse_realtime(body: bytes) -> dict:
    # Observed layout: subtype, unix ts u32, u16 (strain?), HR, RR count, RR data
    if len(body) < 9:
        return {}
    return {
        "subtype": body[0],
        "unix_ts": struct.unpack_from("<I", body, 1)[0],
        "unknown_u16": struct.unpack_from("<H", body, 5)[0],
        "bpm?": body[7],
        "rr_count?": body[8],
    }


def _parse_historical(body: bytes) -> dict:
    # body: record type ("Kn"), one unknown byte, then the record payload:
    # record id u32, unix ts u32, sub-second u16, status flags u16
    # (bit 9 = on-body), then sensor fields. K18 records carry skin
    # temperature as u16 LE at payload offsets 58 (0.1 °C), 60 (0.1 °C,
    # smoothed variant), and 62 (0.01 °C high-precision) — offsets found
    # empirically by the whoop-vault project on a 5.0; the 4.0 record
    # layout matches at the body level but its temps are unverified.
    if len(body) < 10:
        return {}
    payload = body[2:]
    out: dict = {
        "record": f"K{body[0]}",
        "unix_ts": struct.unpack_from("<I", payload, 4)[0],
    }
    if len(payload) >= 12:
        out["on_body"] = bool(struct.unpack_from("<H", payload, 10)[0] & 0x200)
    if body[0] == 18 and len(payload) >= 64:
        out["skin_temp_c"] = struct.unpack_from("<H", payload, 58)[0] / 10
        out["skin_temp_hp_c"] = struct.unpack_from("<H", payload, 62)[0] / 100
    return out


def _parse_metadata(body: bytes) -> dict:
    if len(body) < 2:
        return {}
    return {"meta": METADATA_TYPES.get(body[1], f"UNKNOWN(0x{body[1]:02x})")}


def history_end_ids(body: bytes) -> bytes | None:
    """Batch start/end ids from a HISTORY_END metadata body.

    Acking with command 0x17, payload 0x01 (success) + these 8 bytes, makes
    the strap send the next batch of history. Returns None for any other
    metadata sub-event.
    """
    if len(body) >= 20 and body[1] == 0x02:
        return bytes(body[12:20])
    return None

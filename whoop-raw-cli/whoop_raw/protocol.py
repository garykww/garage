"""WHOOP proprietary BLE protocol framing.

Two wire formats, both community reverse engineering:

WHOOP 4.0 frame (verified against captured 4.0 packets):

    offset  size  field
    0       1     SOF, always 0xAA
    1       2     length N, little-endian = len(type..payload) + 4 (CRC32)
    3       1     CRC-8 (poly 0x07, init 0) over the two length bytes
    4       1     packet type
    5       N-5   body (for commands: seq, command byte, args)
    -4      4     CRC-32 little-endian over frame[0:-4]
                  (poly 0x04C11DB7 reflected, init 0, xor-out 0xF43F44AC)

WHOOP 5.0 / MG "Maverick" frame (verified against a live MG, fw 50.40.1.0):

    offset  size  field
    0       1     SOF, always 0xAA
    1       1     version, always 0x01
    2       2     length N, little-endian = len(inner) + 4 (CRC32)
    4       2     role bytes, 0x01 0x00
    6       2     CRC-16/MODBUS little-endian over bytes 0..5
    8       N-4   inner: packet type, then body, zero-padded to a multiple
                  of 4 (commands: seq, command byte, 0x01, args)
    -4      4     standard CRC-32 (zlib) little-endian over inner only

Commands to an MG must be written WITH response; write-without-response is
silently dropped, as is anything in 4.0 framing.
"""

from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass, field

SOF = 0xAA
CRC32_XOR_OUT = 0xF43F44AC

# --- GATT UUIDs -------------------------------------------------------------

# WHOOP 4.0 proprietary service base (community reverse engineering).
WHOOP_SERVICE = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
CHAR_CMD_TO_STRAP = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
CHAR_CMD_FROM_STRAP = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
CHAR_EVENTS_FROM_STRAP = "61080004-8d6d-82b8-614a-1c8cb0f8dcc6"
CHAR_DATA_FROM_STRAP = "61080005-8d6d-82b8-614a-1c8cb0f8dcc6"
CHAR_MEMFAULT = "61080007-8d6d-82b8-614a-1c8cb0f8dcc6"

# WHOOP 5.0 / MG: same characteristic layout (0002/0003/0004/0005/0007)
# under a different base UUID, observed on a band with serial 5AMxxxxxxx.
WHOOP_SERVICE_MG = "fd4b0001-cce1-4033-93ce-002d5875f58a"
CHAR_CMD_TO_STRAP_MG = "fd4b0002-cce1-4033-93ce-002d5875f58a"
CHAR_CMD_FROM_STRAP_MG = "fd4b0003-cce1-4033-93ce-002d5875f58a"
CHAR_EVENTS_FROM_STRAP_MG = "fd4b0004-cce1-4033-93ce-002d5875f58a"
CHAR_DATA_FROM_STRAP_MG = "fd4b0005-cce1-4033-93ce-002d5875f58a"
CHAR_MEMFAULT_MG = "fd4b0007-cce1-4033-93ce-002d5875f58a"

WHOOP_SERVICES = (WHOOP_SERVICE, WHOOP_SERVICE_MG)
CMD_TO_STRAP_CHARS = (CHAR_CMD_TO_STRAP, CHAR_CMD_TO_STRAP_MG)

HR_SERVICE = "0000180d-0000-1000-8000-00805f9b34fb"
CHAR_HR_MEASUREMENT = "00002a37-0000-1000-8000-00805f9b34fb"
CHAR_BATTERY_LEVEL = "00002a19-0000-1000-8000-00805f9b34fb"

NOTIFY_CHARS = {
    CHAR_CMD_FROM_STRAP: "CMD",
    CHAR_EVENTS_FROM_STRAP: "EVENTS",
    CHAR_DATA_FROM_STRAP: "DATA",
    CHAR_MEMFAULT: "MEMFAULT",
    CHAR_CMD_FROM_STRAP_MG: "CMD",
    CHAR_EVENTS_FROM_STRAP_MG: "EVENTS",
    CHAR_DATA_FROM_STRAP_MG: "DATA",
    CHAR_MEMFAULT_MG: "MEMFAULT",
    CHAR_HR_MEASUREMENT: "HR",
}

# --- Packet types and commands ----------------------------------------------

PACKET_TYPE_COMMAND = 0x23
PACKET_TYPE_REALTIME = 0x28
PACKET_TYPE_HISTORICAL = 0x2F
PACKET_TYPE_METADATA = 0x31

PACKET_TYPES = {
    0x23: "COMMAND",
    0x24: "COMMAND_RESPONSE",
    0x28: "REALTIME_DATA",
    0x2F: "HISTORICAL_DATA",
    0x30: "EVENT",
    0x31: "METADATA",
}

# METADATA (0x31) sub-events, at body[1]. HISTORY_END marks the end of a
# batch of HISTORICAL_DATA records and must be acked with command 0x17
# before the strap sends the next batch; HISTORY_COMPLETE means drained.
METADATA_TYPES = {
    0x01: "HISTORY_START",
    0x02: "HISTORY_END",
    0x03: "HISTORY_COMPLETE",
}

# Command bytes observed on the 4.0. Destructive commands (0x19 erase,
# 0x1D reboot) are intentionally omitted.
KNOWN_COMMANDS = {
    0x03: "recording control (payload 01=start, 00=stop)",
    0x0E: "HR broadcast toggle (payload 01=on, 00=off)",
    0x16: "trigger history download (payload empty)",
    0x17: "ack history batch (payload 01 + 8 id bytes from HISTORY_END)",
    0x24: "get string from device",
    0x42: "set alarm (payload: flag + unix ts u32 LE)",
    0x4C: "get device name",
    0x60: "enter high-frequency sync (5.0/MG, speeds up history download)",
    0x73: "enable channel 1 (payload 01)",
    0x74: "enable channel 2 (payload 01)",
}


def crc8(data: bytes) -> int:
    """CRC-8, poly 0x07, init 0, MSB-first. Used for the header length bytes."""
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) & 0xFF) ^ 0x07 if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def crc32_whoop(data: bytes) -> int:
    """Reflected CRC-32, init 0, xor-out 0xF43F44AC."""
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xEDB88320 if crc & 1 else crc >> 1
    return crc ^ CRC32_XOR_OUT


def crc16_modbus(data: bytes) -> int:
    """CRC-16/MODBUS (poly 0x8005 reflected, init 0xFFFF). MG frame header."""
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


@dataclass
class Frame:
    packet_type: int
    body: bytes
    crc_ok: bool
    raw: bytes

    @property
    def type_name(self) -> str:
        return PACKET_TYPES.get(self.packet_type, f"UNKNOWN(0x{self.packet_type:02x})")


def build_frame(packet_type: int, body: bytes) -> bytes:
    inner = bytes([packet_type]) + body
    frame = bytes([SOF]) + struct.pack("<H", len(inner) + 4) + b""
    frame += bytes([crc8(frame[1:3])])
    frame += inner
    frame += struct.pack("<I", crc32_whoop(frame))
    return frame


def build_frame_mg(packet_type: int, body: bytes) -> bytes:
    inner = bytes([packet_type]) + body
    if len(inner) % 4:
        inner += b"\x00" * (4 - len(inner) % 4)
    header = bytes([SOF, 0x01]) + struct.pack("<H", len(inner) + 4) + b"\x01\x00"
    header += struct.pack("<H", crc16_modbus(header))
    return header + inner + struct.pack("<I", zlib.crc32(inner))


_seq = 0


def _next_seq(seq: int | None) -> int:
    global _seq
    if seq is None:
        seq = _seq
        _seq = (_seq + 1) & 0xFF
    return seq


def build_command(cmd: int, payload: bytes = b"", seq: int | None = None) -> bytes:
    """Build a 4.0 command frame: type 0x23, body = [seq, cmd, payload]."""
    return build_frame(PACKET_TYPE_COMMAND, bytes([_next_seq(seq), cmd]) + payload)


def build_command_mg(cmd: int, payload: bytes = b"", seq: int | None = None) -> bytes:
    """Build an MG command frame: type 0x23, body = [seq, cmd, 0x01, payload].

    The 0x01 after the command byte is required; its meaning is unclear
    (0x00 has been observed on data-range commands in other captures).
    """
    return build_frame_mg(PACKET_TYPE_COMMAND, bytes([_next_seq(seq), cmd, 0x01]) + payload)


class FrameParser:
    """Reassembles frames from a notification byte stream.

    Bytes that can't be framed (bad SOF, bad header CRC) are skipped one at a
    time and reported via the `garbage` counter. Frames with a bad CRC32 are
    still emitted, flagged with crc_ok=False.
    """

    def __init__(self) -> None:
        self.buf = bytearray()
        self.garbage = 0

    def feed(self, data: bytes) -> list[Frame]:
        self.buf.extend(data)
        frames: list[Frame] = []
        while True:
            frame = self._next_frame()
            if frame is None:
                return frames
            frames.append(frame)

    def _next_frame(self) -> Frame | None:
        buf = self.buf
        while buf:
            if buf[0] != SOF:
                del buf[0]
                self.garbage += 1
                continue
            if len(buf) < 4:
                return None
            length = struct.unpack_from("<H", buf, 1)[0]
            if crc8(bytes(buf[1:3])) != buf[3] or length < 5:
                del buf[0]
                self.garbage += 1
                continue
            total = 4 + length
            if len(buf) < total:
                return None
            raw = bytes(buf[:total])
            del buf[:total]
            expected = struct.unpack("<I", raw[-4:])[0]
            return Frame(
                packet_type=raw[4],
                body=raw[5:-4],
                crc_ok=crc32_whoop(raw[:-4]) == expected,
                raw=raw,
            )
        return None


class MaverickFrameParser:
    """Frame reassembler for the WHOOP 5.0 / MG wire format.

    Same contract as FrameParser: unframeable bytes are skipped and counted
    in `garbage`; frames with a bad CRC-32 are emitted with crc_ok=False.
    """

    def __init__(self) -> None:
        self.buf = bytearray()
        self.garbage = 0

    def feed(self, data: bytes) -> list[Frame]:
        self.buf.extend(data)
        frames: list[Frame] = []
        while True:
            frame = self._next_frame()
            if frame is None:
                return frames
            frames.append(frame)

    def _next_frame(self) -> Frame | None:
        buf = self.buf
        while buf:
            if buf[0] != SOF:
                del buf[0]
                self.garbage += 1
                continue
            if len(buf) < 8:
                return None
            length = struct.unpack_from("<H", buf, 2)[0]
            header_ok = (
                buf[1] == 0x01
                and length >= 5
                and crc16_modbus(bytes(buf[0:6])) == struct.unpack_from("<H", buf, 6)[0]
            )
            if not header_ok:
                del buf[0]
                self.garbage += 1
                continue
            total = 8 + length
            if len(buf) < total:
                return None
            raw = bytes(buf[:total])
            del buf[:total]
            inner = raw[8:-4]
            expected = struct.unpack("<I", raw[-4:])[0]
            return Frame(
                packet_type=inner[0],
                body=inner[1:],
                crc_ok=zlib.crc32(inner) == expected,
                raw=raw,
            )
        return None

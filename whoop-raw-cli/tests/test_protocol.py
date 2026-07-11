"""Protocol framing tests against packets captured from real WHOOP hardware.

The 4.0 alarm packet comes from the community reverse-engineering writeup
and validates end-to-end (header CRC8 and trailer CRC32), so it pins down
the exact framing: SOF, LE length, CRC8 over the length bytes, and CRC32
over frame[0:-4] with xor-out 0xF43F44AC.

The MG packets were captured live from a WHOOP MG (fw 50.40.1.0) and pin
down the Maverick framing: version byte, LE length including the CRC32
trailer, CRC16/MODBUS over the six header bytes, 4-byte-aligned inner
buffer, and a standard zlib CRC32 over the inner buffer only.
"""

import struct

import pytest

from whoop_raw.parse import history_end_ids, parse_frame, parse_hr_measurement
from whoop_raw.protocol import (
    FrameParser,
    MaverickFrameParser,
    build_command,
    build_command_mg,
    build_frame_mg,
    crc8,
    crc16_modbus,
    crc32_whoop,
)

# Set-alarm command captured over the air: seq 0x6d, cmd 0x42,
# payload = 01 + unix ts 0x656536d0 LE + 4 zero bytes.
CAPTURED = bytes.fromhex("aa100057236d4201d036656600000000f62deb81")

# HR-broadcast-on command as accepted by a live MG: seq 0, cmd 0x0e,
# payload 01, inner padded to 8 bytes.
CAPTURED_MG_CMD = bytes.fromhex("aa010c000100271123000e010100000079950dad")
# The MG's response to LINK_VALID (cmd 0x01): body carries the ASCII
# string "There it is." — yes, really.
CAPTURED_MG_RESP = bytes.fromhex(
    "aa011800010022e1240001000154686572652069742069732e000000e4d5efd2"
)


def test_crc8_matches_capture():
    assert crc8(CAPTURED[1:3]) == CAPTURED[3]


def test_crc32_matches_capture():
    assert crc32_whoop(CAPTURED[:-4]) == int.from_bytes(CAPTURED[-4:], "little")


def test_build_command_reproduces_capture():
    pkt = build_command(0x42, bytes.fromhex("01d036656600000000"), seq=0x6D)
    assert pkt == CAPTURED


def test_parser_roundtrip():
    frames = FrameParser().feed(CAPTURED)
    assert len(frames) == 1
    frame = frames[0]
    assert frame.crc_ok
    assert frame.type_name == "COMMAND"
    assert frame.body[0] == 0x6D
    assert frame.body[1] == 0x42
    assert frame.raw == CAPTURED


def test_parser_reassembles_split_and_concatenated_frames():
    parser = FrameParser()
    stream = b"\x00\x17" + CAPTURED + CAPTURED  # leading garbage, two frames
    frames = parser.feed(stream[:15])
    assert frames == []
    frames += parser.feed(stream[15:])
    assert len(frames) == 2
    assert all(f.crc_ok for f in frames)
    assert parser.garbage == 2


def test_parser_flags_bad_crc32():
    corrupted = CAPTURED[:-1] + bytes([CAPTURED[-1] ^ 0xFF])
    frames = FrameParser().feed(corrupted)
    assert len(frames) == 1
    assert not frames[0].crc_ok


def test_parser_skips_bad_header_crc():
    bad = bytearray(CAPTURED)
    bad[3] ^= 0xFF
    parser = FrameParser()
    assert parser.feed(bytes(bad)) == []
    assert parser.garbage > 0


def test_mg_crc16_matches_capture():
    assert crc16_modbus(CAPTURED_MG_CMD[0:6]) == int.from_bytes(CAPTURED_MG_CMD[6:8], "little")


def test_mg_build_command_reproduces_capture():
    assert build_command_mg(0x0E, b"\x01", seq=0) == CAPTURED_MG_CMD


def test_mg_parser_roundtrip():
    frames = MaverickFrameParser().feed(CAPTURED_MG_RESP)
    assert len(frames) == 1
    frame = frames[0]
    assert frame.crc_ok
    assert frame.type_name == "COMMAND_RESPONSE"
    assert frame.body[1] == 0x01  # echoes the command byte
    assert b"There it is." in frame.body
    assert frame.raw == CAPTURED_MG_RESP


def test_mg_parser_reassembles_split_and_concatenated_frames():
    parser = MaverickFrameParser()
    stream = b"\x00\x17" + CAPTURED_MG_CMD + CAPTURED_MG_RESP
    frames = parser.feed(stream[:15])
    assert frames == []
    frames += parser.feed(stream[15:])
    assert len(frames) == 2
    assert all(f.crc_ok for f in frames)
    assert parser.garbage == 2


def test_mg_parser_flags_bad_crc32():
    corrupted = CAPTURED_MG_RESP[:-1] + bytes([CAPTURED_MG_RESP[-1] ^ 0xFF])
    frames = MaverickFrameParser().feed(corrupted)
    assert len(frames) == 1
    assert not frames[0].crc_ok


def test_mg_parser_skips_bad_header_crc():
    bad = bytearray(CAPTURED_MG_CMD)
    bad[6] ^= 0xFF
    parser = MaverickFrameParser()
    assert parser.feed(bytes(bad)) == []
    assert parser.garbage > 0


def test_mg_frames_are_not_parsed_by_40_parser():
    # An MG frame must not alias into a valid 4.0 frame (or vice versa);
    # byte 1 is the version 0x01 on MG but the length LSB on 4.0.
    frames = FrameParser().feed(CAPTURED_MG_CMD)
    assert not any(f.crc_ok for f in frames)


# --- Historical records and the temperature fields ---------------------------
# Synthetic bodies following the whoop-vault K18 layout (empirically found on
# a 5.0): body = [record type, ?, payload], payload = record id u32, unix ts
# u32, sub-sec u16, flags u16 (bit 9 = on-body), ..., temps u16 LE at 58/60/62.


def _k18_body(temp01: int, temp_alt01: int, temp001: int, ts: int, flags: int) -> bytes:
    payload = bytearray(64)
    struct.pack_into("<I", payload, 0, 42)
    struct.pack_into("<I", payload, 4, ts)
    struct.pack_into("<H", payload, 10, flags)
    struct.pack_into("<H", payload, 58, temp01)
    struct.pack_into("<H", payload, 60, temp_alt01)
    struct.pack_into("<H", payload, 62, temp001)
    return bytes([18, 0]) + bytes(payload)


def test_parse_historical_k18_skin_temperature():
    body = _k18_body(331, 330, 3312, ts=1_720_000_000, flags=0x0200)
    frame = MaverickFrameParser().feed(build_frame_mg(0x2F, body))[0]
    parsed = parse_frame(frame)
    assert parsed["record"] == "K18"
    assert parsed["unix_ts"] == 1_720_000_000
    assert parsed["on_body"] is True
    assert parsed["skin_temp_c"] == 33.1
    assert parsed["skin_temp_hp_c"] == 33.12


def test_parse_historical_non_k18_has_no_temperature():
    body = bytes([1, 0]) + _k18_body(331, 330, 3312, ts=1_720_000_000, flags=0)[2:]
    frame = MaverickFrameParser().feed(build_frame_mg(0x2F, body))[0]
    parsed = parse_frame(frame)
    assert parsed["record"] == "K1"
    assert parsed["on_body"] is False
    assert "skin_temp_hp_c" not in parsed


def test_parse_metadata_history_end_and_ack_ids():
    ids = bytes(range(8))
    body = bytes([0x05, 0x02]) + bytes(10) + ids
    frame = MaverickFrameParser().feed(build_frame_mg(0x31, body))[0]
    assert parse_frame(frame)["meta"] == "HISTORY_END"
    # the parser pads the inner buffer to a multiple of 4; ids must survive
    assert history_end_ids(frame.body) == ids


def test_history_end_ids_ignores_other_metadata():
    frame = MaverickFrameParser().feed(build_frame_mg(0x31, bytes([0x05, 0x03]) + bytes(18)))[0]
    assert parse_frame(frame)["meta"] == "HISTORY_COMPLETE"
    assert history_end_ids(frame.body) is None


@pytest.mark.parametrize(
    "hexdata,expected",
    [
        # uint8 HR, no extras
        ("003c", {"bpm": 60}),
        # uint16 HR
        ("01f400", {"bpm": 244}),
        # uint8 HR + two RR intervals (1024 units = 1000 ms)
        ("103c00040002", {"bpm": 60, "rr_intervals_ms": [1000, 500]}),
        # sensor contact supported + detected, energy expended
        ("0e3c1900", {"bpm": 60, "sensor_contact": True, "energy_kj": 25}),
    ],
)
def test_parse_hr_measurement(hexdata, expected):
    assert parse_hr_measurement(bytes.fromhex(hexdata)) == expected

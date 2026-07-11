# whoop-raw-cli

Terminal app that connects to a WHOOP band (4.0 / 5.0 / MG) over Bluetooth LE
and streams raw data — live heart rate, proprietary protocol frames, or full
hex dumps of everything the band sends.

**For study and fun purposes only.** This is a hobby project for poking at
your own band and learning how its BLE protocol works — not a medical device,
not a WHOOP replacement, and not something to build anything serious on.

WHOOP has no official device API. This speaks two community-reverse-engineered
BLE protocols: the WHOOP 4.0 framing, and the WHOOP 5.0 / MG "Maverick"
framing (verified against a live MG, firmware 50.40.1.0). It also reads the
standard Bluetooth Heart Rate service the band exposes when HR Broadcast is
on. Proprietary frames that don't checksum are still shown (flagged `CRC!?`)
rather than dropped — if the firmware drifts, you'll see it, not miss it.

## Setup

```bash
cd whoop-raw-cli
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
```

macOS: the first run will trigger a Bluetooth permission prompt for your
terminal app (System Settings → Privacy & Security → Bluetooth). Grant it,
then re-run.

## Usage

```bash
whoop-raw scan                      # find your band (shows address + RSSI)
whoop-raw hr --broadcast on         # live heart rate, enabling broadcast itself
whoop-raw hr                        # live heart rate (broadcast already on)
whoop-raw temp                      # skin temperature (drains history records)
whoop-raw listen --log raw.jsonl    # subscribe to everything, dump raw frames
whoop-raw services                  # dump the GATT table
whoop-raw commands                  # list known proprietary command bytes
whoop-raw send 4c                   # send "get device name", print responses
whoop-raw listen --broadcast on     # enable HR broadcast via the protocol
```

All commands take `--address <uuid>` to skip scanning (on macOS the address is
a CoreBluetooth UUID, not a MAC). `--log` writes JSON lines: timestamp, source
characteristic, raw hex, and any parsed fields.

### Getting a connection

- **`hr` shows nothing:** run `whoop-raw hr --broadcast on` — it flips HR
  Broadcast via the proprietary channel, no app needed. (Or enable it in the
  WHOOP app: Device Settings → HR Broadcast.) The band serves HR to one
  receiver at a time.
- **Band never appears in `scan`:** it's connected to your phone and not
  advertising. Turn off your phone's Bluetooth for a minute.

## Protocol summary

Same five-characteristic layout on both generations, different base UUID:

| Characteristic | 4.0 prefix | 5.0/MG prefix | Direction |
|---|---|---|---|
| CMD_TO_STRAP | `61080002` | `fd4b0002` | write commands (MG: with response!) |
| CMD_FROM_STRAP | `61080003` | `fd4b0003` | notify: command responses |
| EVENTS_FROM_STRAP | `61080004` | `fd4b0004` | notify: events |
| DATA_FROM_STRAP | `61080005` | `fd4b0005` | notify: sensor data |
| MEMFAULT | `61080007` | `fd4b0007` | notify: fault logs |

Full UUIDs: `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` (4.0),
`fd4b0001-cce1-4033-93ce-002d5875f58a` (5.0/MG).

**4.0 frame:** `0xAA` · length u16 LE · CRC-8 of the length bytes · packet
type · body · CRC-32 (reflected, init 0, xor-out `0xF43F44AC`) over
everything before it.

**5.0/MG "Maverick" frame:** `0xAA` · version `0x01` · length u16 LE
(includes the CRC-32 trailer) · role bytes `0x01 0x00` · CRC-16/MODBUS of
the six header bytes · inner buffer zero-padded to a multiple of 4 ·
standard (zlib) CRC-32 of the inner buffer. The inner buffer is packet type,
then body. MG command frames carry `seq, command, 0x01, args`, and the strap
silently drops writes-without-response and anything in 4.0 framing.

Command frames are type `0x23` on both. The same command bytes appear to
work on both generations (`0x0e` HR-broadcast-toggle confirmed live on an
MG). Both framings are pinned by captured packets in
`tests/test_protocol.py` — the MG's response to `LINK_VALID` (cmd `0x01`)
is the ASCII string `There it is.`, which the firmware authors presumably
left for people doing exactly this.

### Skin temperature

The band does not stream temperature live — it records it (about 1 Hz)
into on-device history. `whoop-raw temp` pulls it out: enter
high-frequency sync (cmd `0x60`, MG only), trigger a history download
(cmd `0x16`), then keep acking each batch — every `HISTORY_END` metadata
packet (type `0x31`, sub-event `0x02`) is answered with cmd `0x17`,
payload `0x01` + the 8 id bytes at body offset 12 — until the strap sends
`HISTORY_COMPLETE`. Temperature lives in "K18" history records
(type `0x2F`, body byte 0 = `18`): u16 LE at record-payload offsets 58
(0.1 °C) and 62 (0.01 °C high-precision). Offsets are from the
whoop-vault project's empirical work on a 5.0; the 4.0 shares the
record framing but its temperature offsets are unverified here. This is
skin temperature, not core body temperature.

Destructive command bytes (`0x19` erase, `0x1D` reboot) are deliberately not
in the known-commands table, but `send` will transmit any byte you give it —
don't fuzz a band you care about.

Sources: [openwhoop](https://github.com/bWanShiTong/openwhoop),
[reverse-engineering-whoop-post](https://github.com/bWanShiTong/reverse-engineering-whoop-post),
[whoop-reader](https://github.com/christianmeurer/whoop-reader),
[whoop-vault](https://github.com/Sophonbot0/whoop-vault) (temperature offsets, history ack loop).
Unofficial; not affiliated with WHOOP.

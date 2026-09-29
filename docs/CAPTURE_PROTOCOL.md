# Deep capture protocol v1

The FPGA accepts a five-byte command on the existing UART RX line:

```text
AA OP REQUEST_ID_H REQUEST_ID_L XOR
```

`XOR` is the bytewise XOR of the preceding four bytes. Operations are `01`
ARM, `02` DOWNLOAD, `03` STATUS, `04` STOP, and `05` VGA SNAPSHOT ARM. ARM snapshots the active
channel, averaging, trigger, calibration, and configuration revision. It then
discards 64 settled focus-channel samples before filling the record. A setting
change invalidates an in-progress or completed record; the host should ARM
again after changing settings.

Normal ARM records 8192 samples at the focus-channel acquisition rate. VGA
SNAPSHOT ARM records 640 samples using the active VGA X1 through X1024
decimation. Its sample-period metadata includes that decimation, allowing the
phone to render the same 576-sample horizontal span as the FPGA VGA plot while
leaving the deeper manual capture mode intact.

Every response is exactly 228 bytes. Bytes 0 through 225 are covered by
CRC-16/CCITT (polynomial `0x1021`, initial value `0xFFFF`), followed by the
big-endian CRC at bytes 226 and 227:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 1 | `0xD6` magic |
| 1 | 1 | Version `0x01` |
| 2 | 1 | Type: `01` status, `02` data, `03` done, `7F` error |
| 3 | 1 | Flags: bit 0 running, 1 complete, 2 valid, 3 triggered, 4 invalid |
| 4..5 | 2 | Request ID |
| 6..7 | 2 | Capture ID |
| 8..9 | 2 | Data block sequence (big-endian) |
| 10..11 | 2 | Total record count |
| 12 | 1 | Focus channel |
| 13 | 1 | Averaging mode |
| 14 | 1 | Trigger mode |
| 15..16 | 2 | Trigger level |
| 17..18 | 2 | Trigger sample index |
| 19..21 | 3 | Sample period in 50 MHz clock cycles |
| 22..25 | 4 | Timestamp of first chronological record, 50 MHz ticks |
| 26 | 1 | Records in this block, zero through 32 |
| 27..30 | 4 | Configuration fingerprint/revision |
| 31..32 | 2 | Full-scale calibration in mV |
| 33 | 1 | Reserved, zero |
| 34..225 | 192 | 32 records, six bytes each |
| 226..227 | 2 | CRC-16/CCITT |

Each record is a 12-bit sample in a big-endian 16-bit word (upper four bits
zero), followed by a big-endian 32-bit acquisition timestamp. DATA blocks are
chronological oldest-to-newest; unused records in the final block are zero.
The trigger sample is at `trigger_index`. A valid 8192-record capture has 256
DATA packets followed by one DONE packet. Timestamps are an absolute wrapping
32-bit 50 MHz counter, so consumers must use unsigned modular subtraction when
calculating intervals across rollover.

Capture responses hold the UART until every byte is accepted. Legacy `D5`
telemetry remains available and is only paused at a complete nine-byte frame
boundary.

## Pico HTTP artifact

The bridge exposes a completed capture through `GET /api/capture/data` only
after all CRC-checked DATA blocks and a valid DONE packet have arrived. The
response is an OCAP v1 artifact with a 64-byte little-endian header followed
by `record_count` six-byte records (`uint32 timestamp`, `uint16 ADC`). The
header offsets are: 0 magic `OCAP`, 4 version, 5 header length, 6 flags, 7
focus channel, 8 record count, 10 record size, 12 sample period, 16 capture
id, 20 trigger index, 24 full-scale mV, 26 reserved/config revision, 28 first
timestamp, 32 config fingerprint, 36 averaging mode, 37 trigger mode, 38
trigger level, 40 request id, 44 sample clock Hz, and 48 raw FPGA flags.
Artifact flags use bit 0 complete, bit 1 triggered, bit 2 gap, and bit 3
stopped. The Pico returns HTTP 409 for incomplete, invalid, or partial data.

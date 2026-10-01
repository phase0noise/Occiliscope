# UART control and telemetry

The FPGA and Pico W use fixed 115200 baud, 8N1 UART. SW8 is reserved. All multibyte values below are big-endian unless
noted. `XX` is the XOR of the preceding bytes in the frame.

## FPGA telemetry

```text
D5 CH AH AL PH PM PL VV XX
```

`CH` is the ADC channel (0-5), `AH:AL` is a 12-bit ADC code, `PH:PM:PL` is the
measured focus-channel sample interval in 50 MHz clock cycles, and `VV` echoes
the confirmed control value (0-99). This frame reports current samples; it is
separate from the timestamped capture transfer in
[CAPTURE_PROTOCOL.md](CAPTURE_PROTOCOL.md).

## Pico commands

| Frame | Fields |
| --- | --- |
| `A5 CC VV XX` | Select one channel `CC` (0-5) and value `VV` (0-99). |
| `A9 MM FF VV XX` | Enable channel mask `MM`, select focus channel `FF`, and set `VV`. `FF` must be enabled in `MM`. |
| `AB` | Request a held copy of the next VGA window for the live phone view. |
| `AC TB RID_H RID_L XX` | Capture a 256-point FFT of the focus channel. `TB` is 0-10; request ID is nonzero. See [FFT protocol](FFT_PROTOCOL.md). |
| `AD` | Cancel an FFT acquisition in progress. |
| `A6 TB VS VP TM LH LL FF XX` | Set VGA timebase, vertical scale and position, trigger, and display options. |
| `A7 MH ML XX` | Set ADC full-scale calibration in millivolts (1000-9999). |
| `A8 GG PP PP PP PP HH HH HH HH EE XX` | Set generator `GG` (0 or 1), period `PP`, high time `HH`, and enable `EE`. Period and high time are 32-bit counts of 50 MHz cycles. |

In the `A6` frame, `TB` is 0-10 for X1-X1024 decimation, `VS` is 0-3 for
1X-8X gain, and `VP` is 0-100 with 50 centered. `TM` is 0 free, 1 rising,
2 falling, or 3 auto rising. `LH:LL` is the 12-bit trigger level. In `FF`, bit
0 enables the grid, bit 1 enables acquisition, bits 3:2 select 10/25/50/75%
pre-trigger position, bit 4 selects single shot, bits 6:5 select 1/4/16/64
sample averaging, and bit 7 enables waveform stabilization.

The Pico sends three copies of channel and VGA control frames. The FPGA applies
settings only after receiving a complete valid frame.

For a serial-console check, send `set 3 42` to the Pico USB serial port at
115200 baud. It should select channel 3 and set the value to 42. The FPGA also
accepts the older ASCII command `set:CCCC:FFFF:GGGG\n`, where `CCCC` is 0000-0005,
`FFFF` is 0000-0099, and `GGGG` is reserved (send 0000). A carriage return
before the newline is allowed. Invalid or incomplete commands leave the
current settings unchanged.

## Live VGA window

`AB` returns a variable-length D7 frame. The VGA continues acquiring and
rendering during transmission. Fields in this frame are little-endian.

| Header offset | Field |
| --- | --- |
| 0–3 | D7, version 1, total frame length (16-bit) |
| 4–7 | Enabled mask, focus channel, timebase, voltage gain |
| 8–11 | Vertical position, trigger mode, trigger position, A6 flags |
| 12–15 | Raw focus sample interval in 50 MHz cycles (24-bit), reserved |
| 16–19 | Full scale in mV (16-bit), column count 288 (16-bit) |
| 20–23 | Frame ID (32-bit) |
| 24–27 | Trigger level (16-bit), valid VGA column count (16-bit) |
| 28 | Bit 0: SW0 manual mode; remaining bits reserved |
| 29–31 | Reserved |

Each column starts with a channel-valid mask, followed by mean, minimum, and
maximum (three 16-bit ADC codes) for each enabled channel in ascending order.
Two adjacent VGA columns form one phone column; invalid history is masked out.
CRC-16/CCITT (initial FFFF, polynomial 1021) covers header and payload; the
final two bytes contain the CRC in little-endian order.

The total size is `34 + 288 * (1 + 6 * enabled_channels)` bytes. The browser
uses the period and timebase to calculate the shared 576-column time span.
`/api/live` keeps live transfer active and returns the most recent complete
frame, or HTTP 202 until the first frame arrives. `/api/live?after=ID` returns
HTTP 204 when that frame is unchanged. D5 telemetry remains available for
status readouts; its UART arrival times do not determine waveform positions.
After the first completed trigger, live requests wait for the next completed
capture rather than exporting an unlocked intermediate window. Free-run keeps
exporting frames normally. UART packets finish before switching between D5,
D6, D7 and FFT D8 streams.

## Manual controls

SW0 up overrides channel selection with all six channels, CH0 measurement
focus, free-run, no averaging, and continuous acquisition. KEY0 increments the
timebase up to X1024; KEY1 decrements it down to X1. The buttons are debounced
for 10 ms. UART timebase commands are ignored while manual mode is active;
voltage gain, position, calibration, and grid commands still apply. SW0 down
restores the phone-selected channel and trigger settings at the current timebase.

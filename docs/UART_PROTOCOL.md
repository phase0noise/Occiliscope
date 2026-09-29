# UART control and telemetry

The FPGA and Pico W use 8N1 UART at 9600 or 115200 baud. `SW8` selects the FPGA
rate; the Pico probes both. All multibyte values below are big-endian unless
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

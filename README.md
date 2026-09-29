# DE10-Lite oscilloscope

Oscilloscope built with a DE10-Lite FPGA and a Raspberry Pi Pico W. The FPGA
samples six ADC inputs, draws a 640x480 VGA display, and sends data over UART.
The Pico W serves a browser view for live traces and triggered captures.

This is an experimental instrument. Check the ADC input range and any external
front end before connecting a signal; the displayed voltage depends on the
calibration setting.

## Hardware and tools

- Terasic DE10-Lite, Raspberry Pi Pico W, VGA monitor
- Two 3.3 V UART wires and a common ground
- Quartus Prime Lite 23.1 for the FPGA
- Arduino IDE with the `arduino-pico` RP2040 core for the Pico W

## Build and connect

1. Open `oscilloscope.qpf` in Quartus and compile, or run
   `powershell -File tools/build_fpga.ps1`. Program the resulting
   `oscilloscope.sof` onto the DE10-Lite. The script writes its output under
   `build/quartus/output_files/`.
2. Open `Arduino/SerialPassthrough22/SerialPassthrough22.ino`. Set `WIFI_NAME`
   and `WIFI_PASSWORD` near the top of the sketch, then upload it to the Pico W.
   The sketch runs the Pico as an access point and prints its address on USB
   serial. The checked-in values are development defaults.
3. Connect Pico GP0 (TX) to DE10-Lite `GPIO[8]` (FPGA RX), Pico GP1 (RX) to
   `GPIO[4]` (FPGA TX), and the board grounds together. Use 3.3 V logic.
4. Connect to the Pico access point and open the address printed on USB serial.
   `SW8` selects 9600 baud when down and 115200 baud when up; the Pico probes
   both rates.

The web page is built into the Pico firmware. After editing files in `web/`,
regenerate `Arduino/SerialPassthrough22/web_page.h` before compiling the sketch:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\web\embed_web.ps1
```

## What it does

- Scans up to six ADC inputs with a separately selected focus channel.
- Draws enabled channels on VGA with per-column mean and min/max traces.
- Captures 8,192 focus-channel samples with 50 MHz timestamps, or 640 samples
  for a VGA-matched snapshot.
- Supports free-run, rising, falling, auto, and single-shot triggering.
- Provides browser cursors, measurements, zoom, CSV export, and PNG capture.
- Drives two configurable square-wave outputs on `GPIO[28]` and `GPIO[30]`.

`SW9` resets the FPGA. `KEY0` and `KEY1` step through focus channels. The six
seven-segment displays show CH0, CH1, and CH2 voltages in three pairs; a
disabled channel's pair is blank. `LEDR[5:0]` shows the enabled channel mask.

The FPGA continues sampling and drawing VGA without a browser. Browser live
telemetry is limited by UART throughput. Triggered records carry FPGA
timestamps; an 8,192-sample transfer takes at least 5.1 seconds at 115200 baud.

## Source map

| Path | Purpose |
| --- | --- |
| `oscilloscope.vhd`, `scope_capture.vhd`, `scope_vga.v` | Top level, capture engine, VGA renderer |
| `slide_adc.v`, `adc_qsys/` | ADC bridge and generated Quartus IP used by the build |
| `oscilloscope.qpf`, `oscilloscope.qsf`, `oscilloscope.sdc` | Quartus project, pins, timing |
| `Arduino/SerialPassthrough22/` | Pico W firmware and embedded web page |
| `web/` | Editable browser page, protocol decoder, and tests |
| `simulation/` | Focused HDL and C++ test benches |

The generated ADC synthesis files and `web_page.h` are checked in because the
Quartus and Arduino builds consume them directly. The latest Quartus programming
files and reports under `build/quartus/output_files/` are also versioned. Build
databases, legacy output folders, and local editor files are ignored.

See [UART control and telemetry](docs/UART_PROTOCOL.md),
[capture format](docs/CAPTURE_PROTOCOL.md), and
[validation notes](docs/VALIDATION.md) for protocol details and checks.

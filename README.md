# DE10-Lite oscilloscope

A six-channel oscilloscope built around a DE10-Lite and a Raspberry Pi Pico W.
The FPGA handles sampling, triggering, timestamped capture, and the 640x480 VGA
display. The Pico W hosts the phone interface and relays its controls to the
FPGA.

This is an experimental instrument. Check the ADC input range and any external
front end before connecting a signal; DE10-Lite supports 5V max

## Hardware and tools

<img width="720" height="1600" alt="1000000149" src="https://github.com/user-attachments/assets/9c41206b-49a3-4473-9a1f-4cd15f81b561" />
<img width="4000" height="3000" alt="unnamed11" src="https://github.com/user-attachments/assets/d149edf8-5ab9-4d9b-9a5c-0ae8a2cb3679" />

## What it does

- Scans up to six ADC inputs with a separately selected focus channel.
- Draws enabled channels on VGA with per-column mean and min/max traces.
- Captures 8,192 focus-channel samples with 50 MHz timestamps, or 640
  mean/min/max columns for a VGA-scale snapshot.
- Links the VGA time-scale slider and total-time dropdown. The phone uses
  the same scale, calculated from the measured FPGA sampling interval.
- Links the voltage slider and volts/div dropdown, with the same gain and
  position on VGA and the phone.
- Streams the displayed VGA window to the phone, including all enabled
  channels and their mean/min/max envelopes.
- Supports free-run, rising, falling, auto, and single-shot triggering.
- Toggles comparison traces with highlighted channel buttons and selects the
  trigger, measurement, and FFT focus with a separate dropdown.
- Captures a 256-point FFT on the FPGA and displays its frequency spectrum on
  the phone, with calibrated amplitude and the measured sampling rate.
- Provides browser cursors, measurements, zoom, CSV export, and PNG capture.
- Drives two configurable square-wave outputs on `GPIO[28]` and `GPIO[30]`.

`SW0` up selects manual mode: all six channels free-run, `KEY0` lengthens
the time window, and `KEY1` shortens it (X1–X1024, one step per press). The
phone follows the hardware scale; voltage controls remain available. SW0 down
returns acquisition control to the phone. `SW9` resets the FPGA. Outside manual
mode, `KEY0` and `KEY1` step through focus channels. The six
seven-segment displays show CH0, CH1, and CH2 voltages in three pairs; a
disabled channel's pair is blank. `LEDR[5:0]` shows the enabled channel mask.

The FPGA continues sampling and drawing VGA without a browser. The browser
opens in Live scope and follows a held copy of the same VGA window. Each phone
column combines two VGA columns, keeping their mean and both peaks. All enabled
channels share one time axis. UART transfer adds a small delay; it does not
change the waveform's sample interval or interrupt VGA acquisition.

The graph has a **VGA snapshot / UART live** toggle. VGA snapshot preserves
the displayed FPGA waveform. UART live rolls individual readings from the
existing telemetry stream, with updates scheduled about 30 times per second.
It is undersampled: its time axis uses Pico receipt timestamps, and fast signals
can alias. Time and voltage controls remain shared with VGA. A small status
packet keeps the phone in sync with manual mode without transferring a whole
waveform. Long raw windows combine readings into bounded min/max buckets.

The linked time controls cover X1 through X1024 decimation. Changing channel
count or averaging changes the available total times. Both controls update
their labels without changing the selected decimation. There is no separate
phone window setting; zoom and pan are available for inspecting a saved record.

Time and voltage dropdowns retain their options during live updates, including
while a menu is open. Triggering detects edges before decimation and starts a
new column at the selected edge. After a triggered record completes, VGA and
the phone keep it visible while the next long acquisition fills. Free-run
continues updating continuously. Long windows still need their actual acquisition
time to collect a complete record; peak envelopes retain signals that span
multiple cycles per pixel.

VGA scans at about 60 Hz. A long time window produces new complete columns
less often; raising the screen refresh rate would not collect them sooner.
Free-run refreshes the rolling window each frame, while triggered mode holds
the previous complete record until the next is ready.

**Capture FPGA FFT** samples the current focus channel independently of VGA.
The FPGA removes the DC offset, applies a Hann window, and runs a scaled
radix-2 FFT. The phone plots 129 bins from DC to Nyquist and reports the DC
offset separately. The default range is up to 10 kHz; selectable ranges use
the nearest available hardware decimation below that limit. **Full bandwidth**
uses the maximum current sample rate; **VGA time scale** follows the time control.
The graph labels its actual frequency range. Bin spacing is the measured sample
rate divided by 256. Peak estimates interpolate between bins, and amplitudes
are V peak. Three fractional bits preserve precision through the FPGA FFT.
The sample averaging setting applies to FFT input too.

A 1 kHz square wave produces a strong fundamental near 1 kHz and smaller odd
harmonics at 3, 5, and 7 kHz within the selected bandwidth. A sine wave produces
one main peak. The Hann window spreads each peak over a few nearby bins.

FFT transfers carry a request ID, calibration, sampling metadata, and CRC.
Changing acquisition settings during capture invalidates that request. Cancel,
timeout, and damaged transfers keep the previous graph. Saved captures and FFT
requests run one at a time. See [FFT protocol](docs/FFT_PROTOCOL.md).

UART transfer at 115200 baud takes about 0.18 seconds for one channel or
0.93 seconds for six. The Pico requests the next window as soon as the current
transfer finishes, and the browser skips duplicate frames. Status updates use
a separate connection; waveform updates continue while that connection recovers.
Saved capture is an optional focus-channel view with zoom, cursors, and CSV;
it supports short envelope snapshots and 8,192-sample deep captures.

Rebuild and program both the FPGA and Pico firmware when updating this revision.
Snapshot packets use v2 mean/min/max records; deep captures retain v1.


## Build and connect

1. Open `oscilloscope.qpf` in Quartus and Program the resulting
   `oscilloscope.sof` onto the DE10-Lite. 
2. Flash `output_files/pico_scope.uf2` to the Pico W using BOOTSEL, or upload
   `firmware/pico_scope/pico_scope.ino` from Arduino IDE. Select **Raspberry Pi
   Pico W**, the **arduino-pico 6.0.0** core, and **133 MHz** CPU speed.
   It creates the **PicoScope** access point with password **picoscope** and
   prints its address on USB serial. The Wi-Fi configuration is unchanged.
3. Connect Pico GP0 (TX) to DE10-Lite `GPIO[8]` (FPGA RX), Pico GP1 (RX) to
   `GPIO[4]` (FPGA TX), and the board grounds together. Use 3.3 V logic.
4. Connect to the Pico access point and open the address printed on USB serial.
   UART runs at a fixed **115200 baud** on both boards; SW8 is reserved.

The web page is built into the Pico firmware. After editing files in `web/`,
regenerate `firmware/pico_scope/web_page.h` before compiling the sketch:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\web\embed_web.ps1
```

`powershell -File tools/build_pico.ps1` embeds the page, compiles with explicit
Pico W / 133 MHz settings, and updates `output_files/pico_scope.uf2`. Pass
`-Port COM5` to upload, or `-Uf2Drive E:\` to copy to a BOOTSEL drive.
The script finds Arduino CLI inside the usual Arduino IDE installation or on
PATH. See [Pico setup](docs/PICO_SETUP.md) for Arduino IDE and UF2 instructions.


## Source map

| Path | Purpose |
| --- | --- |
| `rtl/` | Top level, saved capture, VGA renderer, live phone frames, FFT engine |
| `rtl/slide_adc.v`, `ip/adc_qsys/` | ADC bridge and generated Quartus IP used by the build |
| `oscilloscope.qpf`, `oscilloscope.qsf`, `oscilloscope.sdc` | Quartus project, pins, timing |
| `firmware/pico_scope/` | Pico W firmware and embedded web page |
| `web/` | Editable browser page, protocol decoder, and tests |
| `tests/` | Focused HDL and C++ test benches |

The generated ADC synthesis files and `web_page.h` are checked in because the
Quartus and Arduino builds consume them directly. The latest `.sof` and `.pof`
programming files are included under `output_files/`; reports,
build databases and local editor files are ignored. Pico builds and browser
previews live in `.cache/`, with the flashable Pico image copied to
`output_files/pico_scope.uf2`.

The included programming images were rebuilt from this revision, including
manual mode, trigger improvements, the FFT engine, and the updated phone page.
Program both boards to update the complete instrument.

See [UART control and telemetry](docs/UART_PROTOCOL.md),
[capture format](docs/CAPTURE_PROTOCOL.md), and
[validation notes](docs/VALIDATION.md) for protocol details and checks.


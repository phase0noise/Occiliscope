# Pico W firmware

Use a Raspberry Pi **Pico W** with an RP2040. The supplied UF2 is for this
board. The Arduino sketch and its headers live together in
`firmware/pico_scope/`; keep that folder intact.

## Flash the supplied image

1. Unplug the Pico from USB.
2. Hold BOOTSEL while plugging it back in. Release the button when the
   `RPI-RP2` drive appears.
3. Copy `output_files/pico_scope.uf2` onto that drive. The drive disappears
   when the Pico reboots; this is expected.
4. Connect to **PicoScope**, password **picoscope**, and open
   **http://192.168.42.1**.

Copy the UF2 to the BOOTSEL drive, rather than a normal USB serial port.
A power-only USB cable cannot transfer firmware.

## Build or upload the sketch in Arduino IDE

Install **Raspberry Pi Pico/RP2040/RP2350 by Earle F. Philhower** from Boards
Manager. The release images use core **6.0.0**. If it is not listed, add this
Boards Manager URL in Preferences:

`https://github.com/earlephilhower/arduino-pico/releases/download/global/package_rp2040_index.json`

Open `firmware/pico_scope/pico_scope.ino`, then select:

- Board: **Raspberry Pi Pico W**
- CPU speed: **133 MHz**
- USB stack: **Pico SDK**
- Flash size: **2 MB (no FS)**
- Port: the Pico's COM port

Click Verify to compile and Upload to program it. The embedded browser page is
already included; no separate web files need uploading. Close any other serial
monitor that has the COM port open.

If the port is missing or automatic reset/upload fails, use BOOTSEL. Arduino
IDE can upload while the board is in BOOTSEL mode; copying the supplied UF2 is
also available. Reconnect normally afterward to see its USB serial port.

## Build from PowerShell

From the repository root:

```powershell
powershell -File tools/build_pico.ps1
```

The script finds Arduino CLI on PATH or inside the usual Arduino IDE
installation, embeds the web page, builds the sketch, and replaces
`output_files/pico_scope.uf2`. Its temporary build stays in `.cache/pico/`.
Pass `-ArduinoCli "path/to/arduino-cli.exe"` for another installation.

Build and upload over an existing serial port:

```powershell
powershell -File tools/build_pico.ps1 -Port COM5
```

Or build and copy to a BOOTSEL drive, using its actual drive letter:

```powershell
powershell -File tools/build_pico.ps1 -Uf2Drive E:\
```

The script checks that the selected folder is an RP2040 BOOTSEL drive before
copying. It does not flash a board unless you supply `-Port` or `-Uf2Drive`.

## Connections and startup

Pico GP0 (TX) goes to FPGA GPIO[8], GP1 (RX) to GPIO[4], with a common ground.
UART stays at **115200 baud**. Wi-Fi starts even without the FPGA connected.
USB serial at 115200 prints the AP address and startup messages.

The onboard LED blinks rapidly while Wi-Fi is starting, slowly while Wi-Fi is
ready but no fresh FPGA packets are arriving, and stays on with a live UART link.
If the board never starts after flashing, check that it is a Pico W and repeat
the BOOTSEL copy with the current image. The phone needs the matching FPGA image
for VGA snapshots, hardware status, and FFT; update both boards together.

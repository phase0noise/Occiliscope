# Build notes

The complete project compiled successfully with Quartus Prime Lite 23.1std.1,
including SW0 manual mode, long-scale triggering, live channel streaming, and
the FFT engine with three fractional bits. The build completed with zero errors.
The build script uses the Quartus exit
code and does not turn timing warnings into a separate failure.

The updated Pico firmware compiles with arduino-pico 6.0.0, explicitly targeting
Raspberry Pi Pico W at 133 MHz. The image uses about 24% flash and 56% static
RAM. Browser checks cover
stable time/voltage menus, channel buttons, live traces, saved captures, FFT
snapshot display/cancellation, and desktop/mobile layout. The 21 Node tests
pass. Native C++ checks cover FFT CRC, partial packets, recovery, and error
frames. Numerical checks of the RTL coefficient tables and fixed-point
arithmetic cover DC, coherent and between-bin tones, low-amplitude signals,
a 1 kHz square wave and its odd harmonics, calibrated amplitude, and an
independent DFT. Mobile checks also enforce usable channel button sizes.
No HDL simulator was used. Physical VGA, ADC inputs, and UART wiring have not
been exercised on a board in this session.

## Programming files

- FPGA: `output_files/oscilloscope.sof`
- Flash programming: `output_files/oscilloscope.pof`
- Pico W: `output_files/pico_scope.uf2`

These programming images match the current source. Program both boards.
UART is fixed at 115200 baud. Wi-Fi remains PicoScope / picoscope.

## Development commands

```powershell
powershell -File web/embed_web.ps1
powershell -File tools/build_fpga.ps1
powershell -File tools/build_pico.ps1
npm test
npm run test:browser
python tests/fft_math_test.py
```

Quartus reports stay in `output_files/`; other local build files and browser
previews stay in `.cache/`.

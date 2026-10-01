# Browser page

`index.html` is the page layout, `scope.css` is the styling, `scope.js` is the
application, and `capture_protocol.js` decodes OCAP captures. The Pico firmware
serves these assets from the generated
`firmware/pico_scope/web_page.h` header.

After editing a web file, regenerate the header from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\web\embed_web.ps1
```

The VGA time-scale slider and total-time dropdown control the same X1-X1024
decimation setting. Dropdown entries come from the measured FPGA sampling
interval and the 576-column VGA plot. The phone follows that total time.

The voltage slider and volts/div dropdown select the same gain (1X–8X).
Time and voltage settings apply while sliding and when selecting a dropdown.
Changing channel count or ADC averaging relabels the available time spans.
Options stay in the DOM during updates; labels wait until an open menu closes.
The highlighted CH0-CH5 buttons toggle comparison traces. The separate focus
dropdown selects the trigger, measurements, and FFT input and enables that
channel if needed. Hiding the current focus moves it to another visible channel;
the last visible channel stays enabled.

Live scope polls `/api/live` for coherent copies of the VGA window. All enabled
channels share the FPGA sampling interval. Each of its 288 columns combines
two VGA columns, retaining their mean and extrema. A complete frame replaces
the previous one; the last waveform stays visible during setting changes.
The browser does not draw UART-arrival samples as waveform data. Requests
include the last frame ID so unchanged windows return HTTP 204. SW0 manual
mode makes the phone follow all six channels and the hardware-selected scale.
Completed triggered views stay visible until the next capture is available.

Capture FPGA FFT requests a 256-sample spectrum from the hardware focus channel.
Its dedicated graph plots frequency against V peak, with Hann gain correction.
The default range is up to 10 kHz; narrower ranges improve frequency resolution.
Full bandwidth uses the current maximum sample rate, and VGA time scale follows
the time control. The actual range and bin spacing are reported with the record.
The strongest peak uses interpolation between bins; the plotted bins remain the
FPGA result. DC offset is reported separately. Start, status,
data, and cancel use `/api/fft/start`, `/api/fft/status`, `/api/fft/data`, and
`/api/fft/cancel`. Request IDs and CRC prevent incomplete or stale snapshots from
replacing the last graph. See [FFT protocol](../docs/FFT_PROTOCOL.md).

Saved capture provides optional focus-channel records with zoom, pan, cursors,
and CSV export. Deep captures retain 8,192 raw samples; short snapshots contain
640 mean/min/max columns and use the VGA scale. They are separate acquisitions.

The Pico exposes capture status, arm, stop, download, and data at
`/api/capture/status`, `/api/capture/arm`, `/api/capture/stop`,
`/api/capture/download`, `/api/capture/snapshot`, and `/api/capture/data`. The data endpoint returns a
complete OCAP artifact or HTTP 409 when the record is incomplete or invalid.
See [the capture format](../docs/CAPTURE_PROTOCOL.md) for the wire and file
layouts.

Run decoder tests with Node.js 20 or newer:

```powershell
npm test
```

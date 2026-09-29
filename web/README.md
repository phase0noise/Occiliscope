# Browser page

`index.html` is the page layout, `scope.css` is the styling, `scope.js` is the
application, and `capture_protocol.js` decodes OCAP captures. The Pico firmware
serves these assets from the generated
`Arduino/SerialPassthrough22/web_page.h` header.

After editing a web file, regenerate the header from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\web\embed_web.ps1
```

The browser has a live UART telemetry view and a separate triggered capture
view. Live timing is transport-timed. The capture view uses FPGA timestamps
from the downloaded OCAP file. `PHONE WINDOW` controls only the browser plot;
the VGA time scale controls FPGA decimation. A VGA snapshot captures 640 samples
at the selected FPGA time scale, while a manual deep capture stores 8,192.

The Pico exposes capture status, arm, stop, download, and data at
`/api/capture/status`, `/api/capture/arm`, `/api/capture/stop`,
`/api/capture/download`, and `/api/capture/data`. The data endpoint returns a
complete OCAP artifact or HTTP 409 when the record is incomplete or invalid.
See [the capture format](../docs/CAPTURE_PROTOCOL.md) for the wire and file
layouts.

Run decoder tests with Node.js 20 or newer:

```powershell
node --test web/tests/capture_protocol.test.js
```

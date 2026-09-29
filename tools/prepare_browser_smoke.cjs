// Creates an offline browser harness using the real HTML, CSS and JavaScript.
// Run with Node; open build/browser/smoke.html in Chromium (or headless Chrome).
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const root = path.resolve(__dirname, '..');
const count = 64;
const artifact = Buffer.alloc(64 + count * 6);
artifact.write('OCAP'); artifact[4] = 1; artifact[5] = 64;
artifact[6] = 3; artifact[7] = 0;
artifact.writeUInt16LE(count, 8); artifact.writeUInt16LE(6, 10);
artifact.writeUInt32LE(1000, 12); artifact.writeUInt32LE(7, 16);
artifact.writeUInt32LE(16, 20); artifact.writeUInt16LE(5000, 24);
artifact.writeUInt32LE(0xfffff000, 28); artifact.writeUInt32LE(3, 32);
artifact[36] = 0; artifact[37] = 1; artifact.writeUInt16LE(2048, 38);
artifact.writeUInt32LE(1, 40); artifact.writeUInt32LE(50000000, 44);
artifact.writeUInt32LE(14, 48);
for (let i = 0; i < count; i++) {
  artifact.writeUInt32LE((0xfffff000 + i * 1000) >>> 0, 64 + i * 6);
  artifact.writeUInt16LE(i % 16 < 8 ? 1000 : 3000, 68 + i * 6);
}
const harness = `<script>
window.smokeErrors = [];
addEventListener('error', e => window.smokeErrors.push(e.error && e.error.stack || e.message));
addEventListener('unhandledrejection', e => window.smokeErrors.push(String(e.reason)));
window.EventSource = class { close() {} };
const artifact = Uint8Array.from(${JSON.stringify([...artifact])});
let requested = false, polls = 0, dataReads = 0;
window.fetch = async function(url) {
  const json = value => new Response(JSON.stringify(value), {headers:{'content-type':'application/json'}});
  if (url === '/api/capture/download') { requested = true; return json({sent:true, state:'receiving', complete:false}); }
  if (url === '/api/capture/status') {
    if (requested) polls++;
    const done = requested && polls >= 2;
    return json({state: done ? 'complete' : requested ? 'receiving' : 'ready', complete:done,
      ready:done, downloadable:done, valid:true, fpgaComplete:true, recordCount:64,
      receivedRecords:done ? 64 : 32, records:64, count:64, captureId:7,
      channel:0, fullScaleMv:5000, samplePeriodTicks:1000, clockHz:50000000});
  }
  if (url === '/api/capture/data') {
    dataReads++;
    if (polls < 2) {
      window.smokeErrors.push('Browser requested data before transfer completed');
      return new Response('Capture is not ready', {status:409});
    }
    return new Response(artifact, {headers:{'content-type':'application/octet-stream'}});
  }
  return json({sent:true});
};
addEventListener('load', () => {
  document.getElementById('captureModeButton').click();
  setTimeout(() => document.getElementById('downloadCaptureButton').click(), 50);
  setTimeout(() => {
    const records = document.getElementById('captureRecordText').textContent;
    if (!records.includes('64')) window.smokeErrors.push('Capture record count absent: ' + records);
    if (dataReads !== 1) window.smokeErrors.push('Expected one completed artifact read, got ' + dataReads);
    const result = document.createElement('pre'); result.id = 'smoke-result';
    result.textContent = window.smokeErrors.length ? 'FAIL: ' + window.smokeErrors.join('; ') : 'PASS';
    document.body.appendChild(result);
    document.documentElement.dataset.smoke = window.smokeErrors.length ? 'FAIL' : 'PASS';
  }, 6500);
});
</script>`;
let html = fs.readFileSync(path.join(root, 'web/index.html'), 'utf8');
for (const source of ['capture_protocol.js', 'scope.js']) {
  html = html.replace('<script src="' + source + '"></script>',
    '<script>' + fs.readFileSync(path.join(root, 'web', source), 'utf8') + '\n//# sourceURL=' + source + '\n</script>');
}
html = html.replace('<head>', '<head><base href="' + pathToFileURL(path.join(root, 'web') + path.sep).href + '">' + harness);
const output = path.join(root, 'build/browser');
fs.mkdirSync(output, {recursive:true});
fs.writeFileSync(path.join(output, 'smoke.html'), html);
console.log(path.join(output, 'smoke.html'));

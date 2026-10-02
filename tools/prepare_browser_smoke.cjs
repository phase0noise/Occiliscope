// Creates an offline browser harness using the real HTML, CSS and JavaScript.
// Run with Node; open .cache/browser/smoke.html in Chromium.
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const root = path.resolve(__dirname, '..');
const fftArtifact = fs.readFileSync(path.join(root,'tests/fixtures/fft_snapshot.bin'));
const count = 640, period = 8000;
const artifact = Buffer.alloc(64 + count * 10);
artifact.write('OCAP'); artifact[4] = 2; artifact[5] = 64;
artifact[6] = 3; artifact[7] = 0;
artifact.writeUInt16LE(count, 8); artifact.writeUInt16LE(10, 10);
artifact.writeUInt32LE(period, 12); artifact.writeUInt32LE(7, 16);
artifact.writeUInt32LE(144, 20); artifact.writeUInt16LE(5000, 24);
artifact.writeUInt32LE(0xfffff000, 28); artifact.writeUInt32LE(3, 32);
artifact[36] = 0; artifact[37] = 1; artifact.writeUInt16LE(2048, 38);
artifact.writeUInt32LE(1, 40); artifact.writeUInt32LE(50000000, 44);
artifact.writeUInt32LE(14, 48);
for (let i = 0; i < count; i++) {
  artifact.writeUInt32LE((0xfffff000 + i * period) >>> 0, 64 + i * 10);
  artifact.writeUInt16LE(i % 16 < 8 ? 1000 : 3000, 68 + i * 10);
  artifact.writeUInt16LE(500, 70 + i * 10);
  artifact.writeUInt16LE(3500, 72 + i * 10);
}
const harness = `<script>
window.smokeErrors = [];
addEventListener('error', e => window.smokeErrors.push(e.error && e.error.stack || e.message));
addEventListener('unhandledrejection', e => window.smokeErrors.push(String(e.reason)));
window.EventSource = class { constructor() { window.scopeEvents = this; } close() {} };
const artifact = Uint8Array.from(${JSON.stringify([...artifact])});
let requested = false, polls = 0, dataReads = 0;
let liveId = 0, fftPolls = 0, fftId = 6, fftCancels = 0;
window.fftCancelCheck = false;
const fftArtifact = Uint8Array.from(${JSON.stringify([...fftArtifact])});
function liveArtifact(metadataOnly=false) {
  const mask=[...document.querySelectorAll('.channel-check:checked')].reduce((m,ch)=>m|(1<<ch.value),0);
  const channels=Array.from({length:6},(_,ch)=>ch).filter(ch=>mask&(1<<ch));
  const bytes=new Uint8Array(metadataOnly?34:34+288*(1+6*channels.length)), view=new DataView(bytes.buffer);
  bytes[0]=metadataOnly?0xd9:0xd7;bytes[1]=1;view.setUint16(2,bytes.length,true);
  bytes[4]=mask;bytes[5]=Number(document.getElementById('channel').value);
  bytes[6]=Number(document.getElementById('timebase').value);
  bytes[7]=Number(document.getElementById('vertical').value);bytes[8]=50;bytes[9]=3;bytes[10]=1;bytes[11]=7;
  view.setUint32(12,2000,true);view.setUint16(16,5000,true);view.setUint16(18,288,true);
  view.setUint32(20,++liveId,true);view.setUint16(24,2048,true);view.setUint16(26,576,true);
  let offset=32;
  for(let column=0;column<(metadataOnly?0:288);column++) {
    bytes[offset++]=mask;
    for(const ch of channels) {
      const value=ch===0?(column%32<16?1000:3000):ch===1?Math.round(2048+700*Math.sin(column*Math.PI/16)):700+column*6;
      view.setUint16(offset,value,true);view.setUint16(offset+2,ch===0?500:value-40,true);
      view.setUint16(offset+4,ch===0?3500:value+40,true);offset+=6;
    }
  }
  let crc=0xffff;
  for(let i=0;i<bytes.length-2;i++) {crc^=bytes[i]<<8;for(let bit=0;bit<8;bit++)crc=((crc<<1)^((crc&0x8000)?0x1021:0))&0xffff;}
  view.setUint16(bytes.length-2,crc,true);return bytes;
}
window.scopeRequests = [];
window.fetch = async function(url) {
  window.scopeRequests.push(url);
  const json = value => new Response(JSON.stringify(value), {headers:{'content-type':'application/json'}});
  if (url.startsWith('/api/fft/start')) { fftPolls=0;return json({id:++fftId,timeoutMs:5000}); }
  if (url.startsWith('/api/fft/status')) return json({state:window.fftCancelCheck||++fftPolls<2?'running':'ready'});
  if (url.startsWith('/api/fft/data')) return new Response(fftArtifact);
  if (url.startsWith('/api/fft/cancel')) {fftCancels++;return json({state:'cancelled'});}
  if (url.startsWith('/api/live')) return new Response(liveArtifact(new URL(url,location.href).searchParams.get('raw')==='1'));
  if (url === '/api/capture/download') { requested = true; return json({sent:true, state:'receiving', complete:false}); }
  if (url === '/api/capture/status') {
    if (requested) polls++;
    const done = requested && polls >= 2;
    return json({state: done ? 'complete' : requested ? 'receiving' : 'ready', complete:done,
      ready:done, downloadable:done, valid:true, fpgaReady:true, recordCount:${count},
      receivedRecords:done ? ${count} : 19, records:${count}, count:${count}, captureId:7,
      channel:0, fullScaleMv:5000, samplePeriodTicks:${period}, clockHz:50000000});
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
  const telemetry = (pc,extra={}) => window.scopeEvents.onmessage({data:JSON.stringify({
    pc, fresh:true, pps:1250, packets:100, cmds:0, errors:0, uptime:1000,
    baud:115200, ch:0, vm:1, av:[1000,0,0,0,0,0],...extra
  })});
  window.scopeEvents.onopen();
  telemetry(1000);
  const slider = document.getElementById('timebase'), select = document.getElementById('totalTime');
  slider.value = '5'; slider.dispatchEvent(new Event('input'));
  if (select.value !== '5') window.smokeErrors.push('Slider did not update dropdown');
  slider.dispatchEvent(new Event('change'));
  select.value = '2'; select.dispatchEvent(new Event('change'));
  if (slider.value !== '2') window.smokeErrors.push('Dropdown did not update slider');
  telemetry(2000);
  setInterval(()=>telemetry(2000),300);
  let rawClock=0xffffff00;
  setInterval(()=>{
    if(document.getElementById('rawSourceButton').getAttribute('aria-pressed')!=='true')return;
    rawClock=(rawClock+33000)>>>0;
    const raw=Array.from({length:42},(_,n)=>[n%3,Math.round(2048+700*Math.sin(n*.4)),(41-n)*750]);
    telemetry(2000,{clockUs:rawClock,raw,drops:0});
  },33);
  if (select.value !== '2' || !select.selectedOptions[0].textContent.includes('92.16 ms')) {
    window.smokeErrors.push('Time labels did not follow acquisition interval');
  }
  document.getElementById('captureModeButton').click();
  setTimeout(() => document.getElementById('downloadCaptureButton').click(), 50);
  setTimeout(() => requestAnimationFrame(() => {
    const records = document.getElementById('captureRecordText').textContent;
    if (!records.includes('${count}')) window.smokeErrors.push('Capture record count absent: ' + records);
    if (dataReads !== 1) window.smokeErrors.push('Expected one completed artifact read, got ' + dataReads);
    if (document.getElementById('minText').textContent !== '0.610 V' ||
        document.getElementById('maxText').textContent !== '4.272 V') {
      window.smokeErrors.push('Snapshot envelope peaks were lost');
    }
    if (!document.getElementById('xAxisReadout').textContent.includes('92.16 ms')) {
      window.smokeErrors.push('Phone did not use the VGA total time');
    }
    if (!window.scopeRequests.some(url => url.startsWith('/api/display?') && new URL(url, location.href).searchParams.get('tb') === '2')) {
      window.smokeErrors.push('Dropdown did not send the FPGA timebase');
    }
    for(const ch of [1,2]) {
      const input=document.querySelector('.channel-check[value="'+ch+'"]');
      input.checked=true;input.dispatchEvent(new Event('change'));
    }
    const voltage=document.getElementById('voltsPerDiv');voltage.value='1';voltage.dispatchEvent(new Event('change'));
    if(document.getElementById('vertical').value!=='1')window.smokeErrors.push('Voltage dropdown did not update slider');
    document.getElementById('liveModeButton').click();
    setTimeout(()=>{
    if(document.querySelectorAll('#channelAnalysisBody tr').length!==3)window.smokeErrors.push('Live channels missing');
    if(!document.getElementById('measurementSource').textContent.includes('Live VGA window'))window.smokeErrors.push('Live frame did not render');
    const timeMenu=document.getElementById('totalTime'), savedOptions=[...timeMenu.options];
    timeMenu.focus();
    const focus=document.getElementById('channel');focus.value='1';focus.dispatchEvent(new Event('change'));
    if(focus.value!=='1' || !document.querySelector('.channel-check[value="1"]').checked)
      window.smokeErrors.push('Focus dropdown did not keep CH1 visible');
    setTimeout(()=>document.getElementById('fftButton').click(),100);
    setTimeout(()=>{
      if(savedOptions.some((option,index)=>timeMenu.options[index]!==option))window.smokeErrors.push('Live updates replaced the time menu options');
      if(!document.getElementById('fftStatus').textContent.includes('781.3 Hz'))window.smokeErrors.push('FPGA FFT spectrum did not render');
      const details=document.getElementById('fftDetails').textContent;
      window.fftCancelCheck=true;document.getElementById('fftButton').click();
      setTimeout(()=>document.getElementById('fftButton').click(),50);
      setTimeout(()=>{
        if(fftCancels!==1 || document.getElementById('fftButton').disabled)window.smokeErrors.push('FFT cancel did not complete');
        if(document.getElementById('fftDetails').textContent!==details)window.smokeErrors.push('Cancel cleared the previous spectrum');
        document.getElementById('rawSourceButton').click();
        setTimeout(()=>{
          if(!window.scopeRequests.some(url=>url.startsWith('/api/live?raw=1')))window.smokeErrors.push('UART live did not request compact hardware status');
          if(!document.getElementById('triggerText').textContent.includes('UART') || Number(document.getElementById('samplesText').textContent)<3)window.smokeErrors.push('UART readings did not reach the live graph');
          document.getElementById('snapshotSourceButton').click();
          const result = document.createElement('pre'); result.id = 'smoke-result';
          result.textContent = window.smokeErrors.length ? 'FAIL: ' + window.smokeErrors.join('; ') : 'PASS';
          document.body.appendChild(result);
        },500);
        document.documentElement.dataset.smoke = window.smokeErrors.length ? 'FAIL' : 'PASS';
      },500);
    },850);
    },500);
  }), 6500);
});
</script>`;
let html = fs.readFileSync(path.join(root, 'web/index.html'), 'utf8');
for (const source of ['capture_protocol.js', 'scope.js']) {
  html = html.replace('<script src="' + source + '"></script>',
    '<script>' + fs.readFileSync(path.join(root, 'web', source), 'utf8') + '\n//# sourceURL=' + source + '\n</script>');
}
html = html.replace('<head>', '<head><base href="' + pathToFileURL(path.join(root, 'web') + path.sep).href + '">' + harness);
const output = path.join(root, '.cache/browser');
fs.mkdirSync(output, {recursive:true});
fs.writeFileSync(path.join(output, 'smoke.html'), html);
console.log(path.join(output, 'smoke.html'));

// Checks the offline page in Chromium and saves desktop/mobile previews.
// Requires Node 22+. Pass the Chrome executable as the first argument.
const {spawn} = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');

const root = path.resolve(__dirname, '..');
const output = path.join(root, '.cache/browser');
const chrome = process.argv[2] || process.env.CHROME_PATH ||
  'C:/Program Files/Google/Chrome/Application/chrome.exe';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function main() {
  if (typeof WebSocket !== 'function') throw new Error('The browser check requires Node 22 or newer.');
  fs.mkdirSync(output, {recursive: true});
  const child = spawn(chrome, ['--headless', '--disable-gpu', '--no-first-run',
    '--no-default-browser-check', '--allow-file-access-from-files', '--remote-debugging-port=0',
    '--user-data-dir=' + path.join(output, 'check-profile'), 'about:blank'],
    {windowsHide: true, stdio: ['ignore', 'ignore', 'pipe']});
  let socket, send;
  try {
    const address = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Chrome did not start within 15 seconds.')), 15000);
      let log = '';
      child.once('error', error => {clearTimeout(timeout); reject(error);});
      child.stderr.on('data', data => {
        log += data;
        const match = log.match(/DevTools listening on (ws:\/\/\S+)/);
        if (match) {clearTimeout(timeout); resolve(match[1]);}
      });
    });
    socket = new WebSocket(address);
    await new Promise((resolve, reject) => {
      socket.addEventListener('open', resolve, {once: true});
      socket.addEventListener('error', reject, {once: true});
    });
    let nextId = 0;
    const pending = new Map();
    socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      const request = pending.get(message.id);
      if (!request) return;
      clearTimeout(request.timeout);
      pending.delete(message.id);
      if (message.error) request.reject(new Error(message.error.message));
      else request.resolve(message.result);
    });
    send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
      const id = ++nextId;
      const timeout = setTimeout(() => {
        pending.delete(id); reject(new Error('Chrome request timed out: ' + method));
      }, 10000);
      pending.set(id, {resolve, reject, timeout});
      socket.send(JSON.stringify({id, method, params, sessionId}));
    });
    const {targetId} = await send('Target.createTarget', {url: 'about:blank'});
    const {sessionId} = await send('Target.attachToTarget', {targetId, flatten: true});
    const page = (method, params) => send(method, params, sessionId);
    await send('Target.activateTarget', {targetId});
    await page('Page.enable');
    await page('Emulation.setDeviceMetricsOverride', {width: 1280, height: 1000, deviceScaleFactor: 1, mobile: false});
    await page('Page.navigate', {url: pathToFileURL(path.join(output, 'smoke.html')).href});
    let result = '';
    const deadline = Date.now() + 20000;
    while (!result && Date.now() < deadline) {
      const response = await page('Runtime.evaluate', {
        expression: 'document.getElementById("smoke-result")?.textContent || ""', returnByValue: true
      });
      result = response.result.value || '';
      if (!result) await delay(250);
    }
    if (result !== 'PASS') throw new Error(result || 'Browser check did not finish.');
    for (const [name, width, height, mobile] of [
      ['desktop', 1280, 1000, false], ['mobile', 390, 844, true]
    ]) {
      await page('Emulation.setDeviceMetricsOverride', {width, height, deviceScaleFactor: 1, mobile});
      await delay(200);
      const layout = await page('Runtime.evaluate', {
        expression: 'document.documentElement.scrollWidth > innerWidth', returnByValue: true
      });
      if (layout.result.value) throw new Error(name + ' page overflows horizontally.');
      if(mobile) {
        const badgeLayout=await page('Runtime.evaluate',{
          expression:'(()=>{const badges=[...document.querySelectorAll(".status-row .pill")].map(node=>node.getBoundingClientRect());return Math.max(...badges.map(b=>b.top))-Math.min(...badges.map(b=>b.top))<2})()',returnByValue:true
        });
        if(!badgeLayout.result.value)throw new Error('Phone status badges wrap above 1k packets/sec.');
      }
      const controls = await page('Runtime.evaluate', {
        expression: '[...document.querySelectorAll(".channel-toggle span")].every(button => button.getBoundingClientRect().width >= 60 && button.getBoundingClientRect().height >= 40)', returnByValue: true
      });
      if (!controls.result.value) throw new Error(name + ' channel buttons are too small to tap.');
      const spectrumSize = await page('Runtime.evaluate', {
        expression: 'Math.abs(document.getElementById("fftCanvas").clientHeight - document.getElementById("fftCanvas").height / Math.min(devicePixelRatio || 1, 2)) <= 2', returnByValue: true
      });
      if (!spectrumSize.result.value) throw new Error(name + ' FFT graph stretches its text vertically.');
      const screenshot = await page('Page.captureScreenshot', {format: 'png'});
      fs.writeFileSync(path.join(output, 'scope-' + name + '.png'), Buffer.from(screenshot.data, 'base64'));
    }
    await page('Runtime.evaluate', {expression: 'document.getElementById("fftTitle").scrollIntoView()'});
    await delay(100);
    const spectrum = await page('Page.captureScreenshot', {format: 'png'});
    fs.writeFileSync(path.join(output, 'scope-mobile-fft.png'), Buffer.from(spectrum.data, 'base64'));
    await page('Emulation.setDeviceMetricsOverride', {width:320,height:844,deviceScaleFactor:1,mobile:true});
    const narrow=await page('Runtime.evaluate', {
      expression:'document.documentElement.scrollWidth > innerWidth',returnByValue:true
    });
    if(narrow.result.value)throw new Error('320px phone layout overflows.');
    console.log('PASS: stable controls, snapshots/UART live, saved capture, FFT, 1k packet badges, and mobile layout');
  } finally {
    if (send) await send('Browser.close').catch(() => {});
    if (socket) socket.close();
    child.kill();
  }
}

main().catch(error => {console.error(error.message); process.exitCode = 1;});

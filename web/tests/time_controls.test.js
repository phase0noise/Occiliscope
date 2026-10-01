const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const protocol = require("../capture_protocol.js");

// Exercise the real control handlers without a connected Pico or a browser.
function scopeHarness(options = {}) {
  const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
  const elements = new Map();
  const requests = [];
  const timers = new Map();
  let nextTimer = 0, events;
  function element(value = "") {
    const listeners = new Map();
    return {
      get value(){return String(value);}, set value(next){value=String(next);}, textContent: "", innerHTML: "", checked: false, disabled: false,
      dataset: {}, style: {}, children: [], width: 640, height: 480,
      classList: {add() {}, remove() {}, toggle() {}},
      setAttribute() {},
      addEventListener(type, handler) { listeners.set(type, handler); },
      dispatch(type) { return listeners.get(type)?.({target: this}); },
      replaceChildren(...children) { this.children = children; },
      querySelector() { return element(); },
      getBoundingClientRect() { return {width: 640, height: 480, left: 0}; },
      getContext() { return new Proxy({}, {get: () => () => {}}); }
    };
  }
  for (const tag of html.matchAll(/<[^>]+\bid="([^"]+)"[^>]*>/g)) {
    const item = element(tag[0].match(/\bvalue="([^"]*)"/)?.[1] || "");
    item.checked = /\bchecked\b/.test(tag[0]);
    item.disabled = /\bdisabled\b/.test(tag[0]);
    elements.set(tag[1], item);
  }
  Object.entries({channel: "0", triggerMode: "auto", triggerPosition: "1", acquisitionAverage: "0", snapshotInterval: "750",fftRange:"10000"})
    .forEach(([id, value]) => { elements.get(id).value = value; });
  const channels = Array.from({length: 6}, (_, i) => Object.assign(element(String(i)), {checked: i === 0}));
  const focusButtons=Array.from({length:6},(_,i)=>element(String(i)));
  const panel = element();
  const context = {
    FpgaOscilloscopeProtocol: protocol, console, URLSearchParams,
    performance: {now: () => 2000}, requestAnimationFrame() {},
    setInterval() {},
    setTimeout(callback) { timers.set(++nextTimer, callback); return nextTimer; },
    clearTimeout(id) { timers.delete(id); },
    addEventListener() {}, devicePixelRatio: 1,
    document: {
      getElementById: id => elements.get(id), createElement: () => element(),
      querySelector: selector => selector === ".capture-panel" ? panel : channels[Number(selector.match(/value="(\d)"/)[1])],
      querySelectorAll: selector => selector===".channel-focus"?focusButtons
        : selector.endsWith(":checked") ? channels.filter(ch => ch.checked) : channels
    },
    EventSource: class { constructor() { events = this; } },
    async fetch(url) {
      requests.push(url);
      if(url.startsWith('/api/live') && options.liveFrame)
        return {ok:true,status:200,arrayBuffer:async()=>options.liveFrame};
      return {ok: true, status: url.startsWith('/api/live') ? 202 : 200,
        text: async () => JSON.stringify({sent: true})};
    }
  };
  context.window = context;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../scope.js"), "utf8"), context);
  function telemetry(pc) {
    events.onmessage({data: JSON.stringify({pc, fresh: false, pps: 10, packets: 10,
      cmds: 0, errors: 0, uptime: 1000, baud: 115200, ch: 0, vm: 1, av: [1000,0,0,0,0,0]})});
  }
  return {elements, requests, telemetry, channels, focusButtons, timers, document:context.document};
}

test("slider and total-time dropdown send the same FPGA timebase", async () => {
  const {elements, requests, telemetry} = scopeHarness();
  const slider = elements.get("timebase"), select = elements.get("totalTime");
  assert.equal(select.disabled, false);
  telemetry(800);
  assert.equal(select.disabled, false);
  assert.equal(select.children.length, 11);
  slider.value = "5";
  slider.dispatch("input");
  assert.equal(select.value, "5");
  assert.match(select.children[5].textContent, /294.9 ms/);
  slider.dispatch("change");
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(new URL(requests.at(-1), "http://pico").searchParams.get("tb"), "5");
  select.value = "2";
  select.dispatch("change");
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(slider.value, "2");
  assert.equal(new URL(requests.at(-1), "http://pico").searchParams.get("tb"), "2");
});

test("acquisition changes relabel both controls without sending a different timebase", () => {
  const {elements, requests, telemetry} = scopeHarness();
  telemetry(800);
  elements.get("timebase").value = "4";
  elements.get("timebase").dispatch("input");
  const before = elements.get("totalTime").children[4].textContent;
  telemetry(3200);
  assert.equal(elements.get("totalTime").value, "4");
  assert.notEqual(elements.get("totalTime").children[4].textContent, before);
  assert.match(elements.get("totalTime").children[4].textContent, /589.8 ms/);
  assert.equal(requests.filter(url=>url.startsWith('/api/display?')).length, 0);
});

test("voltage dropdown and slider share the FPGA gain", async () => {
  const {elements, requests} = scopeHarness();
  const slider=elements.get("vertical"), select=elements.get("voltsPerDiv");
  slider.value="3";slider.dispatch("input");
  assert.equal(select.value,"3");assert.equal(select.children[3].textContent,"78.125 mV/div");
  slider.dispatch("change");await new Promise(resolve=>setImmediate(resolve));
  assert.equal(new URL(requests.at(-1),"http://pico").searchParams.get("scale"),"3");
  select.value="1";select.dispatch("change");await new Promise(resolve=>setImmediate(resolve));
  assert.equal(slider.value,"1");
  assert.equal(new URL(requests.at(-1),"http://pico").searchParams.get("scale"),"1");
});

function hardwareFrame({manual, mask, focus, timebase, id}) {
  const count=Array.from({length:6},(_,ch)=>ch).filter(ch=>mask&(1<<ch)).length;
  const bytes=new Uint8Array(34+288*(1+6*count)), view=new DataView(bytes.buffer);
  bytes[0]=0xd7;bytes[1]=1;view.setUint16(2,bytes.length,true);
  bytes[4]=mask;bytes[5]=focus;bytes[6]=timebase;bytes[7]=1;bytes[8]=50;
  bytes[9]=manual?0:3;bytes[10]=1;bytes[11]=7;bytes[28]=manual?1:0;
  view.setUint32(12,4800,true);view.setUint16(16,5000,true);
  view.setUint16(18,288,true);view.setUint32(20,id,true);
  view.setUint16(24,2048,true);
  let crc=0xffff;
  for(let i=0;i<bytes.length-2;i++){
    crc^=bytes[i]<<8;
    for(let bit=0;bit<8;bit++)crc=((crc<<1)^((crc&0x8000)?0x1021:0))&0xffff;
  }
  view.setUint16(bytes.length-2,crc,true);return bytes;
}

test("SW0 manual frames follow hardware time and restore phone controls on exit", async()=>{
  const options={liveFrame:hardwareFrame({manual:true,mask:63,focus:0,timebase:3,id:1})};
  const {elements,channels,timers,requests}=scopeHarness(options);
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(elements.get("runBadge").textContent,"MANUAL");
  assert.equal(elements.get("timebase").value,"3");
  assert.equal(elements.get("totalTime").value,"3");
  assert.equal(elements.get("totalTime").disabled,true);
  assert.ok(channels.every(ch=>ch.checked&&ch.disabled));
  async function receive(frame){
    options.liveFrame=frame;
    const [id,poll]=[...timers].find(([,callback])=>callback.name==="pollLiveFrame");
    timers.delete(id);await poll();
  }
  await receive(hardwareFrame({manual:true,mask:63,focus:0,timebase:4,id:2}));
  assert.equal(elements.get("timebase").value,"4");
  assert.equal(elements.get("totalTime").value,"4");
  await receive(hardwareFrame({manual:false,mask:3,focus:1,timebase:4,id:3}));
  assert.equal(elements.get("runBadge").textContent,"RUN");
  assert.equal(elements.get("totalTime").disabled,false);
  assert.equal(elements.get("channel").value,"1");
  assert.deepEqual(channels.map(ch=>ch.checked),[true,true,false,false,false,false]);
  assert.ok(channels.every(ch=>!ch.disabled));
  assert.equal(requests.filter(url=>url.startsWith('/api/display?')).length,0);
});


test("updates preserve both dropdown option nodes while a native menu is open",()=>{
  const harness=scopeHarness(),{elements,telemetry,document}=harness;
  telemetry(800);
  const time=elements.get("totalTime"),voltage=elements.get("voltsPerDiv");
  const timeNodes=[...time.children],voltageNodes=[...voltage.children];
  const label=time.children[2].textContent;
  document.activeElement=time;telemetry(3200);
  assert.equal(time.children[2].textContent,label);
  timeNodes.forEach((node,index)=>assert.equal(time.children[index],node));
  document.activeElement=null;time.dispatch("blur");
  assert.notEqual(time.children[2].textContent,label);
  document.activeElement=voltage;
  elements.get("vertical").dispatch("input");
  voltageNodes.forEach((node,index)=>assert.equal(voltage.children[index],node));
});
test("comparison buttons toggle traces independently of the focus dropdown",async()=>{
  const {elements,channels,requests}=scopeHarness();
  channels[1].checked=true;channels[1].dispatch("change");
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(elements.get("channel").value,"0");
  let query=new URL(requests.at(-1),"http://pico").searchParams;
  assert.equal(query.get("focus"),"0");assert.equal(query.get("mask"),"3");
  elements.get("channel").value="1";elements.get("channel").dispatch("change");
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(elements.get("channel").value,"1");
  assert.deepEqual(channels.map(ch=>ch.checked),[true,true,false,false,false,false]);
  channels[1].checked=false;channels[1].dispatch("change");
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(elements.get("channel").value,"0");
  query=new URL(requests.at(-1),"http://pico").searchParams;
  assert.equal(query.get("focus"),"0");assert.equal(query.get("mask"),"1");
  channels[0].checked=false;channels[0].dispatch("change");
  assert.equal(channels[0].checked,true);
  elements.get("channel").value="3";elements.get("channel").dispatch("change");
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(channels[3].checked,true);
  query=new URL(requests.at(-1),"http://pico").searchParams;
  assert.equal(query.get("focus"),"3");assert.equal(query.get("mask"),"9");
});

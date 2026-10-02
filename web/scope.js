(() => {
  "use strict";
  const CaptureProtocol = globalThis.FpgaOscilloscopeProtocol;
  if (!CaptureProtocol) throw new Error("Capture protocol helper is unavailable.");
  // The live view uses FPGA columns with one shared axis for all channels.
  const ADC_MAX = 4095, ADC_COUNTS = 4096, CAPACITY = 512;
  const TRACE_COLORS = ["#53efff","#ffd166","#70e000","#ff70a6","#9b8cff","#ff8c42"];
  let fullScaleMv = 5000, measuredSampleCycles = 0, labeledSampleCycles = 0;
  const traces = Array.from({length:6},()=>({values:new Uint16Array(CAPACITY),lows:new Uint16Array(CAPACITY),highs:new Uint16Array(CAPACITY),times:new Float64Array(CAPACITY),head:0,count:0,latest:0}));
  let paused = false, drawNeeded = true;
  let lastEventAt = 0, connected = false;
  let lastNetworkAt = 0, lastFetchedFrameId = null;
  let viewMode = "live", captureRecord = null, captureStatusTimer = 0;
  let liveFrame = null, lastLiveFrameAt = 0;
  let captureViewport = {startSec: 0, endSec: 1};
  let captureCursorA = null, captureCursorB = null;
  let pointerState = null;
  let autoSnapshotTimer = 0, autoSnapshotRunning = false, autoSnapshotGeneration = 0;
  let manualMode = false, boardFrameKnown = false;
  let timeOptionsPeriod = 0, timeOptionsKnown = false;
  let fftSnapshot=null, fftBusy=false, fftCancelRequested=false;
  let phoneSource="snapshot", rawClock=null, rawTimeMs=0, rawViewTimeMs=0, rawWindowMs=0;
  const rawBuckets=Array.from({length:6},()=>({id:null,sum:0,count:0}));

  const $ = id => document.getElementById(id);
  const canvas = $("scope"), ctx = canvas.getContext("2d", {alpha:false});
  // Match the original FPGA design: 4096 ADC codes span calibrated full scale.

  const volts = raw => raw * fullScaleMv / (ADC_COUNTS * 1000);
  const formatVolts = raw => volts(raw).toFixed(3) + " V";
  const pad4 = value => String(value).padStart(4, "0");

  function formatAxisTime(seconds, precision) {
    const absolute = Math.abs(seconds);
    if (precision && absolute > 0) {
      const scale = absolute < 0.001 ? 1000000 : absolute < 1 ? 1000 : 1;
      const unit = scale === 1000000 ? " us" : scale === 1000 ? " ms" : " s";
      return Number((seconds * scale).toPrecision(precision)) + unit;
    }
    if (absolute < 0.0000005) return "0";
    if (absolute < 0.001) return (seconds * 1000000).toFixed(absolute < 0.00001 ? 1 : 0) + " us";
    if (absolute < 1) return (seconds * 1000).toFixed(absolute < 0.01 ? 1 : 0) + " ms";
    return seconds.toFixed(absolute < 10 ? 2 : 1) + " s";
  }

  function selectedPhoneWindowMs() {
    return vgaWindowForTimebase(Number($("timebase").value)) * 1000;
  }

  function updateXAxisReadout(windowSeconds) {
    $("xAxisReadout").textContent = formatAxisTime(windowSeconds, 4) + " window · " + formatAxisTime(windowSeconds / 10, 4) + "/div";
  }

  function vgaWindowForTimebase(timebase){
    if(measuredSampleCycles<=0)return 0;
    return measuredSampleCycles*(2**timebase)*576/50000000;
  }

  function setVgaTimebaseForWindow(seconds){
    if(measuredSampleCycles<=0)return;
    $("timebase").value=String(CaptureProtocol.selectVgaTimebase(seconds,measuredSampleCycles).timebase);
    updateVgaTimeControl(false);
  }

  function updateVgaTimeControl(sendToFpga=false){
    const timebase=Math.max(0,Math.min(10,Math.round(Number($("timebase").value)||0)));
    $("timebase").value=String(timebase);
    $("vgaTimebaseValue").textContent=`X${2**timebase}`;
    const options = CaptureProtocol.vgaTimeOptions(measuredSampleCycles || 800);
    const select = $("totalTime");
    select.disabled = manualMode;
    if (select.children.length !== 11) {
      select.replaceChildren(...options.map(option => {
        const element = document.createElement("option");
        element.value = String(option.timebase);
        return element;
      }));
    }
    const period = measuredSampleCycles || 800, known = measuredSampleCycles > 0;
    // Keep native menus intact while open and avoid relabeling ADC jitter.
    if (document.activeElement !== select && (!timeOptionsPeriod || known !== timeOptionsKnown ||
        Math.abs(period-timeOptionsPeriod) > Math.max(2,timeOptionsPeriod*0.005))) {
      options.forEach((option,index)=>{
        select.children[index].textContent = known
          ? `${formatAxisTime(option.seconds,4)} (${formatAxisTime(option.seconds/10,4)}/div)`
          : `X${option.decimation} — labels update on connection`;
      });
      timeOptionsPeriod=period;timeOptionsKnown=known;
    }
    if(select.value!==String(timebase))select.value=String(timebase);
    const windowSeconds=vgaWindowForTimebase(timebase),actual=$("vgaWindowActual");
    if (!captureRecord) captureViewport = {startSec: 0, endSec: windowSeconds || 1};
    actual.textContent=windowSeconds>0
      ? `${formatAxisTime(windowSeconds, 4)} total · ${formatAxisTime(windowSeconds/10, 4)}/div`
      : "Shared by VGA and phone";
    drawNeeded = true;
    if(sendToFpga)applyDisplaySettings();
  }

  function setPill(element, state, text) {
    element.classList.remove("ok", "bad");
    if (state) element.classList.add(state);
    element.querySelector("span").textContent = text;
  }

  function pushSample(channel,value,low=value,high=value,timestamp=performance.now()) {
    const trace=traces[channel];
    trace.values[trace.head]=value;trace.lows[trace.head]=low;trace.highs[trace.head]=high;
    trace.times[trace.head]=timestamp;trace.latest=value;
    trace.head=(trace.head+1)%CAPACITY;if(trace.count<CAPACITY)trace.count++;
  }

  function indexAt(trace,logicalIndex) {
    return (trace.head-trace.count+logicalIndex+CAPACITY)%CAPACITY;
  }

  function enabledChannels(){return [...document.querySelectorAll(".channel-check:checked")].map(input=>Number(input.value));}
  function channelMask(){return enabledChannels().reduce((mask,ch)=>mask|(1<<ch),0);}
  function updateChannelButtons(){
    drawNeeded=true;
  }
  function clearSamples() {
    for(const trace of traces){trace.head=0;trace.count=0;}
    for(const bucket of rawBuckets){bucket.id=null;bucket.sum=0;bucket.count=0;}
    drawNeeded=true;
  }
  function appendRawBatch(data) {
    const batch=CaptureProtocol.decodeRawBatch(data,rawClock,rawTimeMs);
    if(batch.reset)clearSamples();
    rawClock=batch.clockUs;rawTimeMs=batch.timeMs;
    const windowMs=selectedPhoneWindowMs();
    if(!paused&&Math.abs(windowMs-rawWindowMs)>Math.max(.01,rawWindowMs*.005)) {
      clearSamples();rawWindowMs=windowMs;
    }
    const bucketMs=Math.max(0.001,windowMs/(CAPACITY-1));
    if(!paused)for(const sample of batch.samples) {
      if(!(channelMask()&(1<<sample.channel)))continue;
      const trace=traces[sample.channel],bucket=rawBuckets[sample.channel];
      const id=Math.floor(sample.timeMs/bucketMs);
      if(bucket.id!==id) {
        bucket.id=id;bucket.sum=sample.adc;bucket.count=1;
        pushSample(sample.channel,sample.adc,sample.adc,sample.adc,sample.timeMs);
      } else {
        bucket.sum+=sample.adc;bucket.count++;
        const index=(trace.head-1+CAPACITY)%CAPACITY;
        trace.values[index]=Math.round(bucket.sum/bucket.count);
        trace.lows[index]=Math.min(trace.lows[index],sample.adc);
        trace.highs[index]=Math.max(trace.highs[index],sample.adc);
        trace.times[index]=sample.timeMs;trace.latest=sample.adc;
      }
    }
    if(!paused){rawViewTimeMs=rawTimeMs;drawNeeded=true;}
    $("measurementSource").textContent="UART live · undersampled ADC readings · "+(batch.drops?`${batch.drops} readings skipped by Wi-Fi`:"time uses Pico receipt timestamps");
  }
  function setPhoneSource(next) {
    phoneSource=next==="raw"?"raw":"snapshot";
    lastFetchedFrameId=null;rawClock=null;rawTimeMs=0;rawViewTimeMs=0;rawWindowMs=0;clearSamples();
    for(const [id,mode] of [["snapshotSourceButton","snapshot"],["rawSourceButton","raw"]]) {
      const selected=phoneSource===mode;
      $(id).classList.toggle("active",selected);$(id).setAttribute("aria-pressed",String(selected));
    }
    $("phoneSourceHint").textContent=phoneSource==="raw"?"Undersampled · fast updates":"Same window as the VGA display";
    if(phoneSource==="snapshot"&&liveFrame)for(let ch=0;ch<6;ch++)for(const point of liveFrame.traces[ch])
      pushSample(ch,point.adc,point.low,point.high,point.timeMs);
    drawNeeded=true;
  }

  function resizeCanvas() {
    const rect = canvas.getBoundingClientRect();
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    const width = Math.max(320, Math.round(rect.width * ratio));
    const height = Math.max(240, Math.round(rect.height * ratio));
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width; canvas.height = height; drawNeeded = true;
    }
  }

  function analyzeLiveTrace(trace, range) {
    let count=0,min=ADC_MAX,max=0,sum=0,sumSquares=0;
    const samples=[];
    for(let i=0;i<trace.count;i++){
      const j=indexAt(trace,i),time=trace.times[j];
      if(time<range.start||time>range.end)continue;
      const value=trace.values[j];
      min=Math.min(min,trace.lows[j]);max=Math.max(max,trace.highs[j]);
      sum+=value;sumSquares+=value*value;count++;samples.push({time,value});
    }
    if(!count)return {count:0,min:null,max:null,peakToPeak:null,average:null,rms:null,frequencyHz:null,periodMs:null,dutyPercent:null};
    const peakToPeak=max-min;
    if(samples.length<3||peakToPeak<Math.max(12,ADC_MAX*0.005))return {count,min,max,peakToPeak,average:sum/count,rms:Math.sqrt(sumSquares/count),frequencyHz:null,periodMs:null,dutyPercent:null};
    const midpoint=(min+max)/2,hysteresis=Math.max(2,peakToPeak*0.1);
    const low=midpoint-hysteresis,high=midpoint+hysteresis,crossings=[];
    let highState=samples[0].value>=midpoint,highDuration=0,totalDuration=0;
    for(let i=1;i<samples.length;i++){
      const elapsed=samples[i].time-samples[i-1].time;
      if(elapsed>0){totalDuration+=elapsed;if(highState)highDuration+=elapsed;}
      if(highState&&samples[i].value<=low)highState=false;
      else if(!highState&&samples[i].value>=high){highState=true;crossings.push(samples[i].time);}
    }
    const periods=[];
    for(let i=1;i<crossings.length;i++)if(crossings[i]>crossings[i-1])periods.push(crossings[i]-crossings[i-1]);
    periods.sort((a,b)=>a-b);
    const periodMs=periods.length>=2?periods[Math.floor(periods.length/2)]:null;
    return {count,min,max,peakToPeak,average:sum/count,rms:Math.sqrt(sumSquares/count),frequencyHz:periodMs?1000/periodMs:null,periodMs,dutyPercent:totalDuration>0?100*highDuration/totalDuration:null};
  }

  function analysisVoltage(value) { return value===null?"--":volts(value).toFixed(3)+" V"; }

  function renderLiveChannelAnalysis(range) {
    const focus=Number($("channel").value);
    $("channelAnalysisBody").innerHTML=enabledChannels().map(ch=>{
      const trace=traces[ch],measurement=analyzeLiveTrace(trace,range),focusLabel=ch===focus?'<span class="focus-tag">FOCUS</span>':'';
      return `<tr class="${ch===focus?"focus":""}"><td><span class="channel-key" style="--channel:${TRACE_COLORS[ch]}">CH${ch}</span>${focusLabel}</td>`+
        `<td>${trace.count?analysisVoltage(trace.latest):"--"}</td><td>${analysisVoltage(measurement.min)}</td><td>${analysisVoltage(measurement.max)}</td>`+
        `<td>${analysisVoltage(measurement.peakToPeak)}</td><td>${analysisVoltage(measurement.average)}</td><td>${analysisVoltage(measurement.rms)}</td>`+
        `<td>${formatFrequencyHz(measurement.frequencyHz)}</td></tr>`;
    }).join("")||'<tr><td colspan="8">No channels enabled.</td></tr>';
  }

  function drawScope() {
    if (viewMode === "capture") {
      drawCaptureScope();
      return;
    }
    resizeCanvas();
    const w = canvas.width, h = canvas.height, dpr = Math.min(window.devicePixelRatio || 1, 2);
    const left = 66*dpr, right = 18*dpr, top = 56*dpr, bottom = 38*dpr;
    const plotW = w-left-right, plotH = h-top-bottom;
    ctx.fillStyle = "#03070b"; ctx.fillRect(0,0,w,h);

    ctx.lineWidth = 1; ctx.strokeStyle = "#172738"; ctx.beginPath();
    for (let x=0; x<=10; x++) { const px=left+plotW*x/10; ctx.moveTo(px,top); ctx.lineTo(px,top+plotH); }
    for (let y=0; y<=8; y++) { const py=top+plotH*y/8; ctx.moveTo(left,py); ctx.lineTo(left+plotW,py); }
    if ($("gridEnable").checked) ctx.stroke();
    ctx.strokeStyle="#2b455d"; ctx.beginPath();
    ctx.moveTo(left,top+plotH/2); ctx.lineTo(left+plotW,top+plotH/2);
    ctx.moveTo(left+plotW/2,top); ctx.lineTo(left+plotW/2,top+plotH); ctx.stroke();

    const raw=phoneSource==="raw";
    const windowMs = !raw&&liveFrame ? liveFrame.windowMs : selectedPhoneWindowMs();
    if (!(windowMs > 0)) return;
    const triggerMode = $("triggerMode").value;
    const triggerRaw = Number($("triggerLevel").value);
    const pretrigger=[0.10,0.25,0.50,0.75][Number($("triggerPosition").value)];
    const focus=Number($("channel").value),focusTrace=traces[focus];
    const enabled=enabledChannels();

    const range=raw?{start:rawViewTimeMs-windowMs,end:rawViewTimeMs}:{start:0,end:windowMs};
    let min=ADC_MAX, max=0, visible=0;
    for(let i=0;i<focusTrace.count;i++){const j=indexAt(focusTrace,i),t=focusTrace.times[j];if(t>=range.start&&t<=range.end){if(focusTrace.lows[j]<min)min=focusTrace.lows[j];if(focusTrace.highs[j]>max)max=focusTrace.highs[j];visible++;}}
    if (!visible) { min=0; max=ADC_MAX; }
    const scale=1<<Number($("vertical").value);
    const center=2048+(Number($("verticalPosition").value)-50)*32;
    let yMin=center-2048/scale,yMax=center+2048/scale;

    const yOf = v => top + Math.max(0,Math.min(plotH,plotH-(v-yMin)*plotH/(yMax-yMin)));
    if(!raw&&triggerMode!=="free" && triggerRaw>=yMin && triggerRaw<=yMax){ const ty=yOf(triggerRaw); ctx.setLineDash([6*dpr,5*dpr]);ctx.strokeStyle="#ffc85799";ctx.beginPath();ctx.moveTo(left,ty);ctx.lineTo(left+plotW,ty);ctx.stroke();ctx.setLineDash([]); }
    if(!raw&&triggerMode!=="free"){const tx=left+plotW*pretrigger;ctx.setLineDash([4*dpr,5*dpr]);ctx.strokeStyle="#ffc85766";ctx.beginPath();ctx.moveTo(tx,top);ctx.lineTo(tx,top+plotH);ctx.stroke();ctx.setLineDash([]);}

    ctx.font=`500 ${12*dpr}px ui-monospace,monospace`;ctx.fillStyle="#c4d4e5";ctx.textAlign="right";
    for(let y=0;y<=4;y++){const raw=yMax-(yMax-yMin)*y/4;ctx.fillText(volts(raw).toFixed(2)+"V",left-6*dpr,top+plotH*y/4+3*dpr);}
    const timeTicks=plotW/dpr<500?4:8;
    for(let x=0;x<=timeTicks;x++){ctx.textAlign=x===0?"left":x===timeTicks?"right":"center";const relative=raw||triggerMode==="free"?(x/timeTicks-1):(x/timeTicks-pretrigger);const seconds=windowMs*relative/1000;ctx.fillText(formatAxisTime(seconds),left+plotW*x/timeTicks,h-12*dpr);}
    updateXAxisReadout(windowMs / 1000);

    $("traceLegend").innerHTML=enabled.map(ch=>`<span class="trace-chip" style="color:${TRACE_COLORS[ch]}">CH${ch} ${traces[ch].count?volts(traces[ch].latest).toFixed(2)+"V":"--"}${ch===focus?" · FOCUS":""}</span>`).join("");
    for(const ch of enabled){
      const trace=traces[ch];if(trace.count<2)continue;
      const pixelColumns=Math.max(1,Math.floor(plotW/dpr));
      const bucketMin=new Float32Array(pixelColumns),bucketMax=new Float32Array(pixelColumns);
      bucketMin.fill(Infinity);bucketMax.fill(-Infinity);let pointCount=0;
      for(let i=0;i<trace.count;i++){
        const j=indexAt(trace,i),t=trace.times[j];if(t<range.start||t>range.end)continue;
        const column=Math.max(0,Math.min(pixelColumns-1,Math.floor((t-range.start)*pixelColumns/windowMs)));
        bucketMin[column]=Math.min(bucketMin[column],trace.lows[j]);bucketMax[column]=Math.max(bucketMax[column],trace.highs[j]);pointCount++;
      }
      ctx.lineJoin="round";ctx.lineCap="round";
      if (liveFrame||raw) {
        ctx.beginPath();
        for(let i=0;i<trace.count;i++){
          const j=indexAt(trace,i),t=trace.times[j];if(t<range.start||t>range.end)continue;
          const x=left+(t-range.start)*plotW/windowMs;
          ctx.moveTo(x,yOf(trace.lows[j]));ctx.lineTo(x,yOf(trace.highs[j]));
        }
        ctx.strokeStyle=TRACE_COLORS[ch]+"44";ctx.lineWidth=1*dpr;ctx.stroke();
      }
      if(pointCount<=pixelColumns*1.5){
        ctx.beginPath();let started=false;
        for(let i=0;i<trace.count;i++){const j=indexAt(trace,i),t=trace.times[j];if(t<range.start||t>range.end)continue;const x=left+(t-range.start)*plotW/windowMs,y=yOf(trace.values[j]);if(!started){ctx.moveTo(x,y);started=true;}else ctx.lineTo(x,y);}
        ctx.strokeStyle=TRACE_COLORS[ch];ctx.lineWidth=(ch===focus?1.6:1.15)*dpr;ctx.stroke();
      }else{
        // At dense time ranges, one min/max envelope per physical pixel
        // prevents aliased scribbles while retaining narrow edges and peaks.
        ctx.beginPath();for(let x=0;x<pixelColumns;x++)if(bucketMin[x]!==Infinity){const px=left+(x+0.5)*dpr;ctx.moveTo(px,yOf(bucketMax[x]));ctx.lineTo(px,yOf(bucketMin[x]));}
        ctx.strokeStyle=TRACE_COLORS[ch];ctx.lineWidth=(ch===focus?1.6:1.1)*dpr;ctx.stroke();
      }
    }

    const measurement=analyzeLiveTrace(focusTrace,range);
    $("voltageText").textContent=focusTrace.count?`CH${focus}  ${formatVolts(focusTrace.latest)}`:"Waiting for signal";
    $("rawText").textContent=focusTrace.count?"ADC "+pad4(focusTrace.latest):"";
    $("minText").textContent=measurement.count?formatVolts(measurement.min):"--";$("maxText").textContent=measurement.count?formatVolts(measurement.max):"--";
    $("ppText").textContent=measurement.count?volts(measurement.peakToPeak).toFixed(3)+" V":"--";$("avgText").textContent=measurement.count?formatVolts(measurement.average):"--";
    $("rmsText").textContent=measurement.count?formatVolts(measurement.rms):"--";
    $("frequencyText").textContent=formatFrequencyHz(measurement.frequencyHz);
    $("periodText").textContent=measurement.periodMs?formatPeriodSeconds(measurement.periodMs/1000):"--";
    $("dutyText").textContent=measurement.dutyPercent===null?"-- %":measurement.dutyPercent.toFixed(1)+" %";
    $("samplesText").textContent=String(traces.reduce((total,trace)=>total+trace.count,0));
    $("triggerText").textContent=raw?(paused?"UART · HOLD":"UART · LIVE"):(paused?"HOLD · ":"LIVE · ")+triggerMode.toUpperCase();
    renderLiveChannelAnalysis(range);
  }

  function formatCaptureRate(hz) {
    if (!(hz > 0)) return "--";
    if (hz >= 1000000) return (hz / 1000000).toFixed(3) + " MS/s";
    if (hz >= 1000) return (hz / 1000).toFixed(3) + " kS/s";
    return hz.toFixed(2) + " S/s";
  }

  function formatFrequencyHz(hz) {
    if (!(hz > 0)) return "-- Hz";
    if (hz >= 1000000) return (hz / 1000000).toFixed(3) + " MHz";
    if (hz >= 1000) return (hz / 1000).toFixed(3) + " kHz";
    return hz.toFixed(hz < 10 ? 3 : 2) + " Hz";
  }

  function formatPeriodSeconds(seconds) {
    if (!(seconds > 0)) return "--";
    return formatAxisTime(seconds);
  }

  function formatCaptureDuration(seconds) {
    if (!(seconds >= 0)) return "--";
    if (seconds < 1) return (seconds * 1000).toFixed(3) + " ms";
    return seconds.toFixed(seconds < 10 ? 3 : 2) + " s";
  }

  function formatCaptureVolts(raw) {
    return CaptureProtocol.valueToVolts(raw, captureRecord ? captureRecord.fullScaleMv : fullScaleMv).toFixed(3) + " V";
  }

  function setCapturePanelState(state, message) {
    const panel = document.querySelector(".capture-panel");
    if (panel) panel.dataset.state = state;
    if (message !== undefined) $("captureStatus").textContent = message;
    $("captureStateText").textContent = state;
  }

  function renderCaptureMeta(status) {
    const source = status || {};
    const record = captureRecord;
    const count = record ? record.recordCount : Number(source.recordCount || source.records || source.received || 0);
    const periodTicks = Number(source.samplePeriodTicks || source.period || 0);
    const rate = record ? record.sampleRateHz : Number(source.sampleRateHz || source.sampleRate || (periodTicks > 0 ? 50000000 / periodTicks : 0));
    const duration = record ? record.durationSec : Number(source.durationSec || source.duration || (count > 1 && periodTicks > 0 ? (count - 1) * periodTicks / 50000000 : 0));
    const trigger = record && record.triggerIndex !== null
      ? String(record.triggerIndex) + " / " + record.focusChannel
      : source.triggerIndex !== undefined ? String(source.triggerIndex) : source.trigger !== undefined ? String(source.trigger) : "--";
    const triggerMode = record ? record.triggerMode : source.triggerMode;
    const triggerLevel = record ? record.triggerLevel : source.triggerLevel;
    const modeNames = ["free", "rising", "falling", "auto"];
    const triggerSetup = triggerMode === null || triggerMode === undefined ? "--" :
      (modeNames[Number(triggerMode)] || String(triggerMode)) +
      (triggerLevel !== null && triggerLevel !== undefined && Number.isFinite(Number(triggerLevel)) ? " @ " + CaptureProtocol.valueToVolts(triggerLevel, record ? record.fullScaleMv : fullScaleMv).toFixed(3) + " V" : "");
    const averaging = record ? (record.averaging === null ? null : record.averaging) : source.averaging;
    const averageNames = ["none", "4x", "16x", "64x"];
    const fingerprint = record && record.configFingerprint !== null ? record.configFingerprint : source.configFingerprint;
    $("captureRecordText").textContent = count > 0 ? count.toLocaleString() + (record && record.truncated ? " (truncated)" : "") : "--";
    $("captureRateText").textContent = formatCaptureRate(rate);
    $("captureDurationText").textContent = duration > 0 ? formatCaptureDuration(duration) : "--";
    $("captureTriggerText").textContent = trigger;
    $("captureTriggerSetupText").textContent = triggerSetup;
    $("captureAverageText").textContent = averaging === null || averaging === undefined ? "--" : (averageNames[Number(averaging)] || String(averaging));
    $("captureConfigText").textContent = fingerprint === null || fingerprint === undefined ? "--" : "0x" + Number(fingerprint).toString(16).padStart(8, "0");
    $("captureQualityText").textContent = record
      ? (record.complete ? (record.hasGap ? "complete, timestamp gap" : "complete") : "incomplete")
      : (source.error || source.valid === false ? "error" : source.complete ? "complete" : "--");
  }

  function updateCaptureCursorReadout(measurement) {
    const element = $("captureCursorReadout");
    if (!captureRecord || viewMode !== "capture") {
      element.hidden = true;
      return;
    }
    element.hidden = false;
    const sampleA = captureCursorA === null ? null : nearestCaptureSample(captureRecord, captureCursorA);
    const sampleB = captureCursorB === null ? null : nearestCaptureSample(captureRecord, captureCursorB);
    const a = sampleA ? formatCaptureDuration(sampleA.timeSec) + " / " + formatCaptureVolts(sampleA.adc) : "--";
    const b = sampleB ? formatCaptureDuration(sampleB.timeSec) + " / " + formatCaptureVolts(sampleB.adc) : "--";
    const delta = captureCursorA !== null && captureCursorB !== null
      ? Math.abs(captureCursorB - captureCursorA) : null;
    const voltsDelta = measurement && measurement.valid && sampleA && sampleB
      ? CaptureProtocol.valueToVolts(sampleB.adc-sampleA.adc,captureRecord.fullScaleMv) : null;
    element.textContent = delta === null
      ? "Cursor A " + a + " | Cursor B --"
      : "A " + a + " | B " + b + " | dt " + formatCaptureDuration(delta) + " | 1/dt " + formatFrequencyHz(delta>0?1/delta:null) + " | dV " + (voltsDelta === null ? "--" : voltsDelta.toFixed(4) + " V");
  }

  function nearestCaptureSample(record, time) {
    let best = null, distance = Infinity;
    for (const sample of record.validSamples) {
      const nextDistance = Math.abs(sample.timeSec-time);
      if(nextDistance<distance){distance=nextDistance;best=sample;}
    }
    return best;
  }

  function resetCaptureViewport() {
    if (captureRecord) { fitCaptureToVgaWindow(); return; }
    const end = captureRecord && captureRecord.durationSec > 0 ? captureRecord.durationSec : 1;
    captureViewport = {startSec: 0, endSec: end};
    captureCursorA = null;
    captureCursorB = null;
    drawNeeded = true;
  }

  function fitCaptureToVgaWindow() {
    if (!captureRecord) return;
    const pretrigger = [0.10,0.25,0.50,0.75][Number($("triggerPosition").value)];
    const vgaSpanSeconds = vgaWindowForTimebase(Number($("timebase").value)) || captureRecord.durationSec;
    const viewport = CaptureProtocol.viewportForWindow(
      captureRecord, vgaSpanSeconds, pretrigger);
    captureViewport = {startSec: viewport.startSec, endSec: viewport.endSec};
    captureCursorA = null;
    captureCursorB = null;
    drawNeeded = true;
  }

  function setViewMode(mode) {
    viewMode = mode === "capture" ? "capture" : "live";
    const live = viewMode === "live";
    $("liveModeButton").classList.toggle("active", live);
    $("captureModeButton").classList.toggle("active", !live);
    $("liveModeButton").setAttribute("aria-selected", String(live));
    $("captureModeButton").setAttribute("aria-selected", String(!live));
    $("captureCursorReadout").hidden = live || !captureRecord;
    $("phoneSource").hidden=!live;
    $("measurementSource").textContent = live
      ? "Live VGA window · all enabled channels · mean and peak envelope"
      : "Saved focus capture · acquisition timestamps and peak envelope";
    if (!live && captureRecord) renderCaptureMeta();
    drawNeeded = true;
    if (!live) pollCaptureStatus();
  }

  async function readCaptureResponse(response) {
    const text = await response.text();
    let body = text;
    try { body = text ? JSON.parse(text) : {}; } catch (_) {}
    if (!response.ok) {
      const detail = typeof body === "string" ? body : (body.error || body.message || response.statusText);
      throw new Error(detail || "HTTP " + response.status);
    }
    return body;
  }

  async function captureAction(path) {
    const response = await fetch(path, {method: "GET", cache: "no-store"});
    return readCaptureResponse(response);
  }

  function captureState(status) {
    return String(status && (status.state || status.status || (status.ready ? "ready" : "idle"))).toLowerCase();
  }

  function captureProgress(status) {
    if (!status) return "";
    const sent = Number(status.bytesSent || status.sentBytes || 0);
    const total = Number(status.bytesTotal || status.totalBytes || 0);
    const percent = Number(status.percent);
    if (total > 0) return " (" + sent.toLocaleString() + "/" + total.toLocaleString() + " bytes)";
    if (Number.isFinite(percent) && percent >= 0) return " (" + percent.toFixed(0) + "%)";
    return "";
  }

  async function pollCaptureStatus() {
    try {
      const response = await fetch("/api/capture/status", {cache: "no-store"});
      if (response.status === 404) {
        if (viewMode === "capture") setCapturePanelState("error", "Capture status endpoint is unavailable on this bridge.");
        return null;
      }
      const status = await readCaptureResponse(response);
      const state = captureState(status);
      const active = ["capturing", "armed", "running", "receiving", "transferring", "downloading"].includes(state);
      const ready = Boolean(status.dataReady || status.downloadable || status.captureReady ||
        status.complete || state === "ready" || state === "complete");
      setCapturePanelState(active ? "capturing" : state === "error" || state === "stopped" || (status.complete && status.valid === false) ? "error" : ready ? "ready" : "idle",
        status.message || status.detail || (state === "stopped" ? "Capture stopped before a complete validated record was available." : active ? "FPGA capture in progress" + captureProgress(status) : undefined));
      renderCaptureMeta(status);
      if (viewMode === "capture" && active) {
        window.clearTimeout(captureStatusTimer);
        captureStatusTimer = window.setTimeout(pollCaptureStatus, 1200);
      }
      return status;
    } catch (error) {
      if (viewMode === "capture") setCapturePanelState("error", "Capture status: " + error.message);
      return null;
    }
  }

  function checkSnapshotGeneration(generation) {
    if (generation !== undefined && generation !== autoSnapshotGeneration) {
      throw new Error("Snapshot settings changed.");
    }
  }

  function invalidateWaveform(preserveRecord = false) {
    if(phoneSource==="raw"&&!preserveRecord)clearSamples();
    autoSnapshotGeneration++;
    if (!preserveRecord) captureRecord = null;
    if (!captureRecord) captureViewport = {
      startSec: 0, endSec: vgaWindowForTimebase(Number($("timebase").value)) || 1
    };
    drawNeeded = true;
    window.clearTimeout(autoSnapshotTimer);
    if ($("autoSnapshot").checked) scheduleAutoSnapshot(300);
  }

  async function waitForCaptureReady(initialStatus, generation) {
    const deadline = Date.now() + 120000;
    let status = initialStatus || null;
    while (Date.now() < deadline) {
      checkSnapshotGeneration(generation);
      const state = captureState(status);
      if (status && (status.dataReady || status.downloadable || status.captureReady ||
          status.complete || state === "ready" || state === "complete")) return status;
      if (state === "error") throw new Error(status.message || status.error || "Capture transfer failed.");
      const response = await fetch("/api/capture/status", {cache: "no-store"});
      if (response.status === 404) throw new Error("Capture status endpoint is unavailable on this bridge.");
      status = await readCaptureResponse(response);
      const nextState = captureState(status);
      if (nextState === "error") throw new Error(status.message || status.error || "Capture transfer failed.");
      setCapturePanelState("capturing", (status.message || "Waiting for complete FPGA record") + captureProgress(status));
      renderCaptureMeta(status);
      await new Promise(resolve => window.setTimeout(resolve, 1000));
    }
    throw new Error("Capture did not become downloadable within 120 seconds.");
  }

  async function waitForFpgaCapture(initialStatus, generation) {
    const snapshotDurationMs = generation === undefined ? 0 :
      selectedPhoneWindowMs() * 640 / CaptureProtocol.VGA_PLOT_SAMPLES;
    const deadline = Date.now() + Math.max(120000, snapshotDurationMs + 60000);
    let status = initialStatus || null;
    while (Date.now() < deadline) {
      checkSnapshotGeneration(generation);
      const state = captureState(status);
      if (status && (status.fpgaReady || status.dataReady || status.downloadable || status.complete)) return status;
      if (status && (state === "idle" || state === "error" || state === "stopped")) {
        throw new Error(state === "idle" ? "Arm a capture before downloading it." : (status.message || status.error || "FPGA capture failed."));
      }
      const response = await fetch("/api/capture/status", {cache: "no-store"});
      status = await readCaptureResponse(response);
      renderCaptureMeta(status);
      setCapturePanelState("capturing", status.fpgaReady ? "FPGA record is ready." : "Waiting for the FPGA trigger and record...");
      await new Promise(resolve => window.setTimeout(resolve, 750));
    }
    throw new Error("FPGA capture did not complete within its acquisition timeout.");
  }

  async function armTriggeredCapture() {
    if ($("autoSnapshot").checked) { $("autoSnapshot").checked = false; toggleAutoSnapshots(); }
    setViewMode("capture");
    setCapturePanelState("capturing", "Arming FPGA capture...");
    $("armCaptureButton").disabled = true;
    try {
      await captureAction("/api/capture/arm");
      captureRecord = null;
      resetCaptureViewport();
      setCapturePanelState("capturing", "FPGA capture armed; waiting for trigger.");
      renderCaptureMeta();
      pollCaptureStatus();
    } catch (error) {
      setCapturePanelState("error", "Arm failed: " + error.message);
    } finally {
      $("armCaptureButton").disabled = false;
    }
  }

  async function stopTriggeredCapture() {
    if ($("autoSnapshot").checked) { $("autoSnapshot").checked = false; toggleAutoSnapshots(); }
    setViewMode("capture");
    setCapturePanelState("capturing", "Requesting capture stop...");
    try {
      await captureAction("/api/capture/stop");
      setCapturePanelState("capturing", "Stop acknowledged; waiting for bridge to finalize the record.");
      pollCaptureStatus();
    } catch (error) {
      setCapturePanelState("error", "Stop failed: " + error.message);
    }
  }

  async function decodeCaptureResponse(response) {
    const contentType = response.headers.get("content-type") || "";
    if (!response.ok) return readCaptureResponse(response);
    if (contentType.includes("application/json")) return readCaptureResponse(response);
    return CaptureProtocol.decodeCapture(await response.arrayBuffer(), {fullScaleMv});
  }

  async function downloadTriggeredCapture() {
    if ($("autoSnapshot").checked) { $("autoSnapshot").checked = false; toggleAutoSnapshots(); }
    setViewMode("capture");
    setCapturePanelState("capturing", "Requesting FPGA record; this can take a while at 9600 baud.");
    $("downloadCaptureButton").disabled = true;
    try {
      const statusResponse = await fetch("/api/capture/status", {cache: "no-store"});
      const fpgaStatus = await waitForFpgaCapture(await readCaptureResponse(statusResponse));
      if (fpgaStatus.dataReady || fpgaStatus.downloadable || fpgaStatus.complete) {
        const dataResponse = await fetch("/api/capture/data", {cache: "no-store"});
        if (!dataResponse.ok) await readCaptureResponse(dataResponse);
        captureRecord = CaptureProtocol.decodeCapture(await dataResponse.arrayBuffer(), {fullScaleMv});
        resetCaptureViewport();
        renderCaptureMeta();
        setCapturePanelState("ready", "Complete FPGA record loaded.");
        drawNeeded = true;
        return;
      }
      const downloadResponse = await fetch("/api/capture/download", {cache: "no-store"});
      const contentType = downloadResponse.headers.get("content-type") || "";
      let downloadResult;
      if (contentType.includes("application/json")) {
        downloadResult = await readCaptureResponse(downloadResponse);
      } else {
        downloadResult = await decodeCaptureResponse(downloadResponse);
      }
      if (downloadResult && downloadResult.samples) {
        captureRecord = downloadResult;
      } else {
        const readyStatus = await waitForCaptureReady(downloadResult);
        const dataResponse = await fetch("/api/capture/data", {cache: "no-store"});
        if (!dataResponse.ok) await readCaptureResponse(dataResponse);
        captureRecord = CaptureProtocol.decodeCapture(await dataResponse.arrayBuffer(), {fullScaleMv});
        captureRecord.bridgeStatus = readyStatus;
        if (readyStatus.triggerMode !== undefined || readyStatus.mode !== undefined) captureRecord.triggerMode = readyStatus.triggerMode !== undefined ? readyStatus.triggerMode : readyStatus.mode;
        if (readyStatus.triggerLevel !== undefined) captureRecord.triggerLevel = readyStatus.triggerLevel;
        if (readyStatus.averaging !== undefined) captureRecord.averaging = readyStatus.averaging;
        if (readyStatus.configFingerprint !== undefined || readyStatus.configuration !== undefined) captureRecord.configFingerprint = readyStatus.configFingerprint !== undefined ? readyStatus.configFingerprint : readyStatus.configuration;
      }
      resetCaptureViewport();
      renderCaptureMeta();
      const quality = captureRecord.complete && captureRecord.metadataValid
        ? (captureRecord.hasGap ? "Downloaded with timestamp gap." : "Complete FPGA record downloaded.")
        : "Record metadata or completion flag is invalid; measurements are limited.";
      setCapturePanelState(captureRecord.complete && captureRecord.metadataValid ? "ready" : "error", quality);
      drawNeeded = true;
    } catch (error) {
      setCapturePanelState("error", "Download failed: " + error.message);
    } finally {
      $("downloadCaptureButton").disabled = false;
    }
  }

  function setSnapshotStatus(text, state) {
    const element = $("snapshotStatus");
    element.textContent = text;
    element.className = "muted" + (state ? " " + state : "");
  }

  async function takeManualSnapshot() {
    if(autoSnapshotRunning)return;
    if($("autoSnapshot").checked){$("autoSnapshot").checked=false;toggleAutoSnapshots();}
    const generation = autoSnapshotGeneration;
    autoSnapshotRunning=true;setViewMode("capture");
    $("manualSnapshotButton").disabled=true;$("mobileSnapshotButton").disabled=true;
    setCapturePanelState("capturing","Arming a VGA-sized FPGA snapshot...");
    setSnapshotStatus("Capturing 640 timestamped focus-channel samples...","good");
    try{
      const armed=await captureAction("/api/capture/snapshot");
      let ready=await waitForFpgaCapture(armed, generation);
      if(!(ready.dataReady||ready.downloadable||ready.complete)){
        setSnapshotStatus("FPGA snapshot ready; transferring it to the phone...","good");
        ready=await readCaptureResponse(await fetch("/api/capture/download",{cache:"no-store"}));
        ready=await waitForCaptureReady(ready, generation);
      }
      const dataResponse=await fetch("/api/capture/data",{cache:"no-store"});
      if(!dataResponse.ok)await readCaptureResponse(dataResponse);
      const record = CaptureProtocol.decodeCapture(await dataResponse.arrayBuffer(),{fullScaleMv});
      checkSnapshotGeneration(generation);
      captureRecord = record;
      captureRecord.bridgeStatus=ready;fitCaptureToVgaWindow();renderCaptureMeta();
      setCapturePanelState("ready","VGA-matched FPGA snapshot loaded.");
      setSnapshotStatus("Snapshot "+(captureRecord.captureId||"")+" is ready. Tap the plot for cursors or use Save image.","good");
      drawNeeded=true;
    }catch(error){
      if (generation === autoSnapshotGeneration) {
        setCapturePanelState("error","Snapshot failed: "+error.message);
        setSnapshotStatus("Snapshot error: "+error.message,"error");
      }
    }finally{
      autoSnapshotRunning=false;$("manualSnapshotButton").disabled=false;$("mobileSnapshotButton").disabled=false;
    }
  }

  function scheduleAutoSnapshot(delay) {
    window.clearTimeout(autoSnapshotTimer);
    if (!$("autoSnapshot").checked) return;
    const generation = autoSnapshotGeneration;
    autoSnapshotTimer = window.setTimeout(() => runAutoSnapshot(generation), delay);
  }

  async function runAutoSnapshot(generation) {
    if (autoSnapshotRunning || generation !== autoSnapshotGeneration || !$("autoSnapshot").checked) return;
    if (paused || !connected || !(measuredSampleCycles > 0) || settingsBusy || displayBusy) {
      scheduleAutoSnapshot(500);
      return;
    }
    autoSnapshotRunning = true;
    setViewMode("capture");
    setSnapshotStatus("Arming a timestamped FPGA snapshot...", "good");
    try {
      const armed = await captureAction("/api/capture/snapshot");
      const fpgaReady = await waitForFpgaCapture(armed, generation);
      if (generation !== autoSnapshotGeneration || !$("autoSnapshot").checked) return;
      let ready = fpgaReady;
      if (!(ready.dataReady || ready.downloadable || ready.complete)) {
        setSnapshotStatus("FPGA VGA record ready; transferring the short snapshot...", "good");
        ready = await readCaptureResponse(await fetch("/api/capture/download", {cache: "no-store"}));
        ready = await waitForCaptureReady(ready, generation);
      }
      if (generation !== autoSnapshotGeneration || !$("autoSnapshot").checked) return;
      const dataResponse = await fetch("/api/capture/data", {cache: "no-store"});
      if (!dataResponse.ok) await readCaptureResponse(dataResponse);
      const record = CaptureProtocol.decodeCapture(await dataResponse.arrayBuffer(), {fullScaleMv});
      checkSnapshotGeneration(generation);
      captureRecord = record;
      captureRecord.bridgeStatus = ready;
      fitCaptureToVgaWindow();
      renderCaptureMeta();
      setCapturePanelState("ready", "Automatic FPGA snapshot loaded.");
      setSnapshotStatus("Showing FPGA snapshot " + (captureRecord.captureId || "") + ". Next capture is scheduled.", "good");
      drawNeeded = true;
    } catch (error) {
      if (generation === autoSnapshotGeneration) {
        setCapturePanelState("error", "Automatic snapshot failed: " + error.message);
        setSnapshotStatus("Snapshot error: " + error.message, "error");
      }
    } finally {
      autoSnapshotRunning = false;
      if ($("autoSnapshot").checked) {
        scheduleAutoSnapshot(Number($("snapshotInterval").value) || 1500);
      }
    }
  }

  function toggleAutoSnapshots() {
    autoSnapshotGeneration++;
    window.clearTimeout(autoSnapshotTimer);
    if ($("autoSnapshot").checked) {
      setSnapshotStatus("Starting automatic FPGA snapshots. Only the focus channel is captured.", "good");
      setViewMode("capture");
      scheduleAutoSnapshot(0);
    } else {
      setSnapshotStatus("Automatic refresh off. The last FPGA waveform stays visible.");
    }
  }

  function exportCaptureCsv() {
    if (!captureRecord) {
      setCapturePanelState("error", "Download a triggered record before exporting it.");
      return;
    }
    const csv = CaptureProtocol.csvForCapture(captureRecord, captureViewport);
    const blob = new Blob([csv], {type: "text/csv"});
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = "fpga-oscilloscope-capture-" + (captureRecord.captureId || "record") + ".csv";
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  function capturePointerTime(clientX) {
    const rect = canvas.getBoundingClientRect();
    const pixelScale = rect.width / canvas.width * Math.min(window.devicePixelRatio || 1, 2);
    const fraction = Math.max(0, Math.min(1, (clientX - rect.left - 66 * pixelScale) / (rect.width - 84 * pixelScale)));
    return captureViewport.startSec + fraction * (captureViewport.endSec - captureViewport.startSec);
  }

  function captureXForTime(timeSec, width) {
    const span = captureViewport.endSec - captureViewport.startSec;
    return span > 0 ? (timeSec - captureViewport.startSec) * width / span : 0;
  }

  function setCaptureCursor(timeSec) {
    if (captureCursorA === null || (captureCursorA !== null && captureCursorB !== null)) captureCursorA = timeSec;
    else captureCursorB = timeSec;
    drawNeeded = true;
  }

  function updateCaptureMeasurements() {
    if (!captureRecord) {
      ["minText", "maxText", "ppText", "avgText", "rmsText"].forEach(id => $(id).textContent = "--");
      $("frequencyText").textContent = "-- Hz";
      $("periodText").textContent = "--";
      $("dutyText").textContent = "-- %";
      $("measurementSource").textContent = "Waiting for an FPGA waveform. Automatic snapshots follow the VGA settings.";
      $("channelAnalysisBody").innerHTML = '<tr><td colspan="8">No FPGA capture loaded.</td></tr>';
      updateCaptureCursorReadout(null);
      return null;
    }
    const measurement = CaptureProtocol.measureRecord(captureRecord, captureViewport);
    const invalid = value => value === null || value === undefined || !Number.isFinite(value);
    $("minText").textContent = measurement.valid ? formatCaptureVolts(measurement.min) : "--";
    $("maxText").textContent = measurement.valid ? formatCaptureVolts(measurement.max) : "--";
    $("ppText").textContent = measurement.valid ? formatCaptureVolts(measurement.peakToPeak) : "--";
    $("avgText").textContent = measurement.valid ? formatCaptureVolts(measurement.average) : "--";
    $("rmsText").textContent = measurement.valid ? formatCaptureVolts(measurement.rms) : "--";
    $("frequencyText").textContent = invalid(measurement.frequencyHz) ? "-- Hz" : formatFrequencyHz(measurement.frequencyHz);
    $("periodText").textContent = invalid(measurement.periodSec) ? "--" : formatPeriodSeconds(measurement.periodSec);
    $("dutyText").textContent = invalid(measurement.dutyPercent) ? "-- %" : measurement.dutyPercent.toFixed(1) + " %";
    $("measurementSource").textContent = measurement.reason
      ? "FPGA timestamps; " + measurement.reason
      : recordMeasurementSource();
    const channel=captureRecord.focusChannel,color=TRACE_COLORS[channel]||TRACE_COLORS[0];
    const show=value=>measurement.valid&&value!==null?formatCaptureVolts(value):"--";
    const visibleLast=captureRecord.validSamples.reduce((last,sample)=>sample.timeSec>=captureViewport.startSec&&sample.timeSec<=captureViewport.endSec?sample:last,null);
    $("channelAnalysisBody").innerHTML=`<tr class="focus"><td><span class="channel-key" style="--channel:${color}">CH${channel}</span><span class="focus-tag">FPGA CAPTURE</span></td>`+
      `<td>${visibleLast?formatCaptureVolts(visibleLast.adc):"--"}</td>`+
      `<td>${show(measurement.min)}</td><td>${show(measurement.max)}</td><td>${show(measurement.peakToPeak)}</td><td>${show(measurement.average)}</td><td>${show(measurement.rms)}</td>`+
      `<td>${measurement.frequencyHz?measurement.frequencyHz.toFixed(3)+" Hz":"--"}</td></tr>`;
    updateCaptureCursorReadout(measurement);
    return measurement;
  }

  function recordMeasurementSource() {
    return captureRecord.envelope
      ? "FPGA snapshot: mean trace with min/max envelope. Average and RMS use column means."
      : "FPGA capture: measurements use acquisition timestamps and valid samples.";
  }

  function drawCaptureScope() {
    resizeCanvas();
    const w = canvas.width, h = canvas.height, dpr = Math.min(window.devicePixelRatio || 1, 2);
    const left = 66 * dpr, right = 18 * dpr, top = 56 * dpr, bottom = 38 * dpr;
    const plotW = w - left - right, plotH = h - top - bottom;
    ctx.fillStyle = "#03070b"; ctx.fillRect(0, 0, w, h);
    ctx.lineWidth = 1; ctx.strokeStyle = "#172738"; ctx.beginPath();
    for (let x = 0; x <= 10; x++) { const px = left + plotW * x / 10; ctx.moveTo(px, top); ctx.lineTo(px, top + plotH); }
    for (let y = 0; y <= 8; y++) { const py = top + plotH * y / 8; ctx.moveTo(left, py); ctx.lineTo(left + plotW, py); }
    if ($("gridEnable").checked) ctx.stroke();
    const record = captureRecord;
    const span = captureViewport.endSec - captureViewport.startSec;
    let min = ADC_MAX, max = 0;
    const visible = record ? record.samples.filter(sample =>
      sample.valid && sample.timeSec >= captureViewport.startSec && sample.timeSec <= captureViewport.endSec) : [];
    for (const sample of visible) { min = Math.min(min, sample.low); max = Math.max(max, sample.high); }
    if (!visible.length) { min = 0; max = ADC_MAX; }
    const scale = 1 << Number($("vertical").value);
    const center = 2048 + (Number($("verticalPosition").value) - 50) * 32;
    const yMin = center - 2048 / scale, yMax = center + 2048 / scale;
    const yOf = value => top + plotH - (value - yMin) * plotH / (yMax - yMin);
    ctx.strokeStyle = "#2b455d"; ctx.beginPath();
    ctx.moveTo(left, top + plotH / 2); ctx.lineTo(left + plotW, top + plotH / 2);
    ctx.moveTo(left + plotW / 2, top); ctx.lineTo(left + plotW / 2, top + plotH); ctx.stroke();
    ctx.font = "500 " + String(12 * dpr) + "px ui-monospace,monospace"; ctx.fillStyle = "#c4d4e5"; ctx.textAlign = "right";
    for (let y = 0; y <= 4; y++) {
      const raw = yMax - (yMax - yMin) * y / 4;
      ctx.fillText(CaptureProtocol.valueToVolts(raw, record ? record.fullScaleMv : fullScaleMv).toFixed(2) + "V", left - 6 * dpr, top + plotH * y / 4 + 3 * dpr);
    }
    const triggerSample = record && record.triggered && record.triggerMode !== 0 && Number.isInteger(record.triggerIndex)
      ? record.samples[record.triggerIndex] : null;
    const axisOrigin = triggerSample ? triggerSample.timeSec : captureViewport.startSec;
    const timeTicks=plotW/dpr<500?4:8;
    for (let x = 0; x <= timeTicks; x++) {
      ctx.textAlign=x===0?"left":x===timeTicks?"right":"center";
      const t = captureViewport.startSec + span * x / timeTicks;
      ctx.fillText(formatAxisTime(t - axisOrigin), left + plotW * x / timeTicks, h - 12 * dpr);
    }
    updateXAxisReadout(span);
    if (record) {
      if (triggerSample && triggerSample.timeSec >= captureViewport.startSec && triggerSample.timeSec <= captureViewport.endSec) {
        const triggerX = left + captureXForTime(triggerSample.timeSec, plotW);
        ctx.setLineDash([4 * dpr, 5 * dpr]); ctx.strokeStyle = "#ffc85788";
        ctx.beginPath(); ctx.moveTo(triggerX, top); ctx.lineTo(triggerX, top + plotH); ctx.stroke(); ctx.setLineDash([]);
      }
      ctx.strokeStyle = TRACE_COLORS[record.focusChannel] || TRACE_COLORS[0];
      ctx.lineWidth = 1.7 * dpr;
      ctx.save();
      ctx.beginPath(); ctx.rect(left, top, plotW, plotH); ctx.clip();
      const pixelColumns = Math.max(1, Math.floor(plotW / dpr));
      const dense = visible.length > pixelColumns * 1.5;
      if (record.envelope && !dense) {
        ctx.globalAlpha = 0.25;
        ctx.lineWidth = dpr;
        ctx.beginPath();
        for (const sample of visible) {
          const x = left + captureXForTime(sample.timeSec, plotW);
          ctx.moveTo(x, yOf(sample.low)); ctx.lineTo(x, yOf(sample.high));
        }
        ctx.stroke();
        ctx.globalAlpha = 1;
      }
      if (!dense) {
        ctx.lineWidth = 1.7 * dpr;
        ctx.beginPath();
        let started = false;
        let previous = null;
        for (const sample of visible) {
          const x = left + captureXForTime(sample.timeSec, plotW);
          const y = yOf(sample.adc);
          if (!started || (previous && sample.ticks - previous.ticks > record.expectedTicks * 1.5)) {
            ctx.moveTo(x, y); started = true;
          } else ctx.lineTo(x, y);
          previous = sample;
        }
        ctx.stroke();
      } else {
        const bucketMin = new Float32Array(pixelColumns), bucketMax = new Float32Array(pixelColumns);
        const bucketSum = new Float64Array(pixelColumns), bucketCount = new Uint32Array(pixelColumns);
        bucketMin.fill(Infinity); bucketMax.fill(-Infinity);
        for (const sample of visible) {
          const column = Math.max(0, Math.min(pixelColumns - 1,
            Math.floor((sample.timeSec - captureViewport.startSec) * pixelColumns / span)));
          bucketMin[column] = Math.min(bucketMin[column], sample.low);
          bucketMax[column] = Math.max(bucketMax[column], sample.high);
          bucketSum[column] += sample.adc;
          bucketCount[column]++;
        }
        ctx.globalAlpha = 0.25;
        ctx.lineWidth = dpr;
        ctx.beginPath();
        for (let column = 0; column < pixelColumns; column++) {
          if (bucketMin[column] === Infinity) continue;
          const x = left + (column + 0.5) * dpr;
          ctx.moveTo(x, yOf(bucketMax[column]));
          ctx.lineTo(x, yOf(bucketMin[column]));
        }
        ctx.stroke();
        ctx.globalAlpha = 1;
        ctx.lineWidth = 1.7 * dpr;
        ctx.beginPath();
        let previousColumn = -2;
        for (let column = 0; column < pixelColumns; column++) {
          if (!bucketCount[column]) continue;
          const x = left + (column + 0.5) * dpr;
          const y = yOf(bucketSum[column] / bucketCount[column]);
          if (column === previousColumn + 1) ctx.lineTo(x, y);
          else ctx.moveTo(x, y);
          previousColumn = column;
        }
        ctx.stroke();
      }
      ctx.restore();
      for (const gap of record.gaps) {
        const sample = record.samples[gap.after];
        if (!sample || sample.timeSec < captureViewport.startSec || sample.timeSec > captureViewport.endSec) continue;
        const x = left + captureXForTime(sample.timeSec, plotW);
        ctx.setLineDash([3 * dpr, 4 * dpr]); ctx.strokeStyle = "#ff6474aa";
        ctx.beginPath(); ctx.moveTo(x, top); ctx.lineTo(x, top + plotH); ctx.stroke(); ctx.setLineDash([]);
      }
      for (const [cursor, color, label] of [[captureCursorA, "#35e5ff", "A"], [captureCursorB, "#ffc857", "B"]]) {
        if (cursor === null || cursor < captureViewport.startSec || cursor > captureViewport.endSec) continue;
        const x = left + captureXForTime(cursor, plotW);
        ctx.setLineDash([5 * dpr, 4 * dpr]); ctx.strokeStyle = color; ctx.beginPath();
        ctx.moveTo(x, top); ctx.lineTo(x, top + plotH); ctx.stroke(); ctx.setLineDash([]);
        ctx.fillStyle = color; ctx.textAlign = "center"; ctx.fillText(label + " " + formatCaptureDuration(cursor), x, top + 12 * dpr);
      }
    }
    $("traceLegend").innerHTML = record
      ? "<span class=\"trace-chip\" style=\"color:" + (TRACE_COLORS[record.focusChannel] || TRACE_COLORS[0]) + "\">CH" + record.focusChannel + " FPGA CAPTURE</span>"
      : "<span class=\"trace-chip\">No capture loaded</span>";
    $("triggerText").textContent = record ? (record.triggerMode === 0 ? "FREE" : record.triggered ? "TRIGGERED" : "CAPTURE") : "WAITING";
    $("voltageText").textContent = record && visible.length ? "CH" + record.focusChannel + "  " + formatCaptureVolts(visible[visible.length - 1].adc) : "-- V";
    $("rawText").textContent = record && visible.length ? "FPGA tick " + (visible[visible.length - 1].tick >>> 0) : "No valid sample";
    updateCaptureMeasurements();
  }
  function animationFrame() { if(drawNeeded){drawScope();drawNeeded=false;} requestAnimationFrame(animationFrame); }

  function clampInput(element, maximum) {
    const value = Math.round(Number(element.value));
    if (!Number.isFinite(value)) throw new Error("Enter a numeric value.");
    const result = Math.max(0,Math.min(maximum,value)); element.value=result; return result;
  }

  let settingsBusy=false, settingsAgain=false;
  async function applySettings() {
    if(manualMode)return;
    updateChannelButtons();
    if(settingsBusy){settingsAgain=true;return;}
    invalidateWaveform();
    const button=$("applyButton"), status=$("commandStatus");
    settingsBusy=true;button.disabled=true;
    do {
      settingsAgain=false;
      try {
        const ch=clampInput($("channel"),5);
        const focusCheck=document.querySelector(`.channel-check[value="${ch}"]`);focusCheck.checked=true;
        const mask=channelMask(),selected=enabledChannels();
        status.className="command-status";status.textContent=`Starting ${selected.length}-channel acquisition...`;
        const response=await fetch(`/api/channels?mask=${mask}&focus=${ch}&value=0`,{cache:"no-store"});
        const text=await response.text(); if(!response.ok)throw new Error(text||`HTTP ${response.status}`);
        $("channelTitle").textContent=selected.length>1?selected.join("/"):ch;
        $("enabledLive").textContent=selected.map(channel=>"CH"+channel).join("/");
        status.className="command-status good";status.textContent=`Comparing ${selected.map(channel=>"CH"+channel).join(", ")}; CH${ch} is the measurement focus.`;

      } catch(error) { status.className="command-status error";status.textContent=error.message; }
    } while(settingsAgain);
    settingsBusy=false;button.disabled=false;
  }

  let displayBusy=false, displayAgain=false;
  async function applyDisplaySettings(preserveRecord = false) {
    if(displayBusy){displayAgain=true;return;}
    invalidateWaveform(preserveRecord === true);
    displayBusy=true;
    do {
      displayAgain=false;
      const mode={free:0,rising:1,falling:2,auto:3}[$("triggerMode").value];
      const query=new URLSearchParams({
        tb:$("timebase").value,scale:$("vertical").value,
        pos:$("verticalPosition").value,trig:String(mode),
        level:$("triggerLevel").value,grid:$("gridEnable").checked?"1":"0",
        run:paused?"0":"1",tpos:$("triggerPosition").value,
        single:$("singleShot").checked?"1":"0",avg:$("acquisitionAverage").value,
        stable:$("stabilizeWave").checked?"1":"0"
      });
      try {
        const response=await fetch(`/api/display?${query}`,{cache:"no-store"});
        const text=await response.text();if(!response.ok)throw new Error(text||`HTTP ${response.status}`);
      } catch(error) {
        const status=$("commandStatus");status.className="command-status error";
        status.textContent="VGA setting failed: "+error.message;
      }
    } while(displayAgain);
    displayBusy=false;
  }

  async function rearmCapture(){
    paused=true;await applyDisplaySettings();paused=false;await applyDisplaySettings();
    $("pauseButton").textContent="Pause";$("runBadge").textContent="RUN";$("runBadge").classList.remove("paused");
  }

  function autoSetup(){
    const samples=[];
    if (captureRecord && captureRecord.focusChannel === Number($("channel").value)) {
      for (const sample of captureRecord.validSamples) {
        if (sample.timeSec >= captureViewport.startSec && sample.timeSec <= captureViewport.endSec) {
          samples.push({v: sample.adc, t: sample.timeMs});
        }
      }
    } else {
      const trace = traces[Number($("channel").value)], count = trace.count;
      const newest = count ? trace.times[indexAt(trace,count-1)] : 0;
      const windowStart = newest - selectedPhoneWindowMs();
      for(let i=0;i<count;i++){const j=indexAt(trace,i);if(trace.times[j]>=windowStart)samples.push({v:trace.values[j],t:trace.times[j]});}
    }
    if(samples.length<24){const status=$("commandStatus");status.className="command-status error";status.textContent="Auto setup needs at least 24 focus-channel samples.";return;}
    const sorted=samples.map(sample=>sample.v).sort((a,b)=>a-b);
    const low=sorted[Math.floor((sorted.length-1)*0.02)],high=sorted[Math.ceil((sorted.length-1)*0.98)];
    const span=Math.max(16,high-low),center=Math.round((low+high)/2);
    const armLevel=center-span*0.08,fireLevel=center+span*0.08,crossings=[];let armed=false;
    for(const sample of samples){if(sample.v<=armLevel)armed=true;else if(armed&&sample.v>=fireLevel){crossings.push(sample.t);armed=false;}}
    let period=0;
    if(crossings.length>=3){const periods=[];for(let i=1;i<crossings.length;i++)periods.push(crossings[i]-crossings[i-1]);periods.sort((a,b)=>a-b);const median=periods[Math.floor(periods.length/2)];const valid=periods.filter(value=>value>median*0.65&&value<median*1.35);if(valid.length)period=valid.reduce((a,b)=>a+b,0)/valid.length;}
    let scale=0;for(let candidate=1;candidate<=3;candidate++)if(span<0.70*(4096>>candidate))scale=candidate;
    const position=Math.max(0,Math.min(100,Math.round(50+(center-2048)/32)));
    $("vertical").value=String(scale);updateScaleLabels();$("verticalPosition").value=String(position);$("positionValue").textContent=position+"%";
    const level=Math.max(0,Math.min(4095,center));$("triggerLevel").value=String(level);$("triggerValue").textContent=formatVolts(level);$("triggerMode").value="auto";$("stabilizeWave").checked=true;
    if(period>0){
      if(measuredSampleCycles>0)setVgaTimebaseForWindow(Math.min(1,period*3/1000));
    }
    paused=false;$("pauseButton").textContent="Pause";$("mobileRunButton").textContent="Pause";$("runBadge").textContent="RUN";$("runBadge").classList.remove("paused");drawNeeded=true;applyDisplaySettings();
    const status=$("commandStatus");status.className="command-status good";status.textContent=period>0?`Auto setup: ${(1000/period).toFixed(2)} Hz, three cycles across the VGA plot.`:"Amplitude and center set; no repeating period detected.";
  }

  async function applyGenerator(number){
    const unit=$("gen"+number+"Unit").value,scale={Hz:1,kHz:1000,MHz:1000000}[unit];
    let frequency;
    try{frequency=CaptureProtocol.frequencyToHertz($("gen"+number+"Frequency").value,unit);}catch(error){const status=$("commandStatus");status.className="command-status error";status.textContent=error.message;return;}
    const duty=clampInput($("gen"+number+"Duty"),100),enable=$("gen"+number+"Enable").checked;
    $("gen"+number+"Frequency").value=String(Number((frequency/scale).toPrecision(7)));
    try{const response=await fetch(`/api/generator?ch=${number-1}&freq=${frequency}&duty=${duty}&enable=${enable?1:0}`,{cache:"no-store"});const text=await response.text();if(!response.ok)throw new Error(text||`HTTP ${response.status}`);const status=$("commandStatus");status.className="command-status good";status.textContent=`GPIO[${number===1?28:30}] ${enable?"ON":"OFF"}: ${Number((frequency/scale).toPrecision(7))} ${unit}, ${duty}% duty.`;}
    catch(error){const status=$("commandStatus");status.className="command-status error";status.textContent="Generator failed: "+error.message;}
  }

  function formatGeneratorActual(number,hertz,duty,enabled){
    if(!enabled)return `GPIO[${number===1?28:30}] OFF`;
    const unit=$("gen"+number+"Unit").value,scale={Hz:1,kHz:1000,MHz:1000000}[unit];
    return `GPIO[${number===1?28:30}]: ${Number((hertz/scale).toPrecision(7))} ${unit} · ${duty}%`;
  }

  async function applyCalibration() {
    const button=$("calibrateButton"),status=$("commandStatus");
    try {
      button.disabled=true;
      const mv=clampInput($("fullScaleMv"),9999);
      if(mv<1000)throw new Error("Full scale must be 1000-9999 mV.");
      const response=await fetch(`/api/calibration?mv=${mv}`,{cache:"no-store"});
      const text=await response.text();if(!response.ok)throw new Error(text||`HTTP ${response.status}`);
      fullScaleMv=mv;invalidateWaveform();updateScaleLabels();drawNeeded=true;
      $("triggerValue").textContent=formatVolts(Number($("triggerLevel").value));
      status.className="command-status good";status.textContent=`Voltage full scale set to ${(mv/1000).toFixed(3)} V.`;
    }catch(error){status.className="command-status error";status.textContent=error.message;}
    finally{button.disabled=false;}
  }

  function updateScaleLabels(){
    const scale=Math.max(0,Math.min(3,Math.round(Number($("vertical").value)||0)));
    $("vertical").value=String(scale);
    const mv=fullScaleMv/(8*(1<<scale));
    const voltageLabel = value => value>=1000 ? `${Number((value/1000).toFixed(4))} V/div`
      : `${Number(value.toFixed(3))} mV/div`;
    $("verticalScaleValue").textContent=voltageLabel(mv);
    const select=$("voltsPerDiv");
    if(select.children.length!==4)select.replaceChildren(...Array.from({length:4},(_,index)=>{
      const option=document.createElement("option");option.value=String(index);return option;
    }));
    if(document.activeElement!==select)Array.from(select.children).forEach((option,index)=>{
      const label=voltageLabel(fullScaleMv/(8*(1<<index)));
      if(option.textContent!==label)option.textContent=label;
    });
    if(select.value!==String(scale))select.value=String(scale);
  }

  function exportCsv() {
    const enabled=enabledChannels();let origin=Infinity,rows=[];
    for(const ch of enabled){const trace=traces[ch];if(trace.count)origin=Math.min(origin,trace.times[indexAt(trace,0)]);}
    if(!Number.isFinite(origin))return;
    for(const ch of enabled){const trace=traces[ch];for(let i=0;i<trace.count;i++){const j=indexAt(trace,i);rows.push([trace.times[j],ch,trace.values[j],trace.lows[j],trace.highs[j]]);}}
    rows.sort((a,b)=>a[0]-b[0]);let csv="time_ms,channel,adc,low,high,volts\n";
    for(const row of rows)csv+=(row[0]-origin).toFixed(6)+","+row[1]+","+row[2]+","+row[3]+","+row[4]+","+volts(row[2]).toFixed(5)+"\n";
    const blob=new Blob([csv],{type:"text/csv"}),url=URL.createObjectURL(blob),a=document.createElement("a");
    a.href=url;a.download=`scope-channels-${enabled.join("-")}.csv`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }

  async function saveScopeImage(){
    drawScope();
    const ratio=Math.min(window.devicePixelRatio||1,2),header=Math.round(76*ratio),footer=Math.round(62*ratio);
    const output=document.createElement("canvas");output.width=canvas.width;output.height=canvas.height+header+footer;
    const out=output.getContext("2d",{alpha:false});
    out.fillStyle="#07101a";out.fillRect(0,0,output.width,output.height);
    out.fillStyle="#e5edf5";out.font=`700 ${18*ratio}px ui-monospace,monospace`;out.fillText("FPGA Oscilloscope",16*ratio,27*ratio);
    out.fillStyle="#8495a9";out.font=`${11*ratio}px ui-monospace,monospace`;
    const focus=Number($("channel").value),channels=enabledChannels().map(ch=>"CH"+ch).join(", ");
    out.fillText(`${viewMode==="capture"?"FPGA capture":"Live monitor"} | Focus CH${focus} | ${channels||"No channels"}`,16*ratio,48*ratio);
    out.fillText(`${$("xAxisReadout").textContent} | ${new Date().toLocaleString()}`,16*ratio,65*ratio);
    out.drawImage(canvas,0,header);
    out.fillStyle="#e5edf5";out.font=`700 ${11*ratio}px ui-monospace,monospace`;
    out.fillText(`MIN ${$("minText").textContent}   MAX ${$("maxText").textContent}   P-P ${$("ppText").textContent}   AVG ${$("avgText").textContent}`,16*ratio,header+canvas.height+25*ratio);
    out.fillText(`RMS ${$("rmsText").textContent}   FREQ ${$("frequencyText").textContent}   PERIOD ${$("periodText").textContent}   DUTY ${$("dutyText").textContent}`,16*ratio,header+canvas.height+47*ratio);
    const blob=await new Promise(resolve=>output.toBlob(resolve,"image/png"));
    if(!blob)throw new Error("This browser could not create the scope image.");
    const stamp=new Date().toISOString().replace(/[:.]/g,"-");
    const file=new File([blob],`fpga-oscilloscope-${stamp}.png`,{type:"image/png"});
    if(navigator.share&&navigator.canShare&&navigator.canShare({files:[file]})){
      try{await navigator.share({files:[file],title:"FPGA Oscilloscope snapshot"});return;}catch(error){if(error&&error.name==="AbortError")return;}
    }
    const url=URL.createObjectURL(blob),link=document.createElement("a");link.href=url;link.download=file.name;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }

  function zoomCapture(factor, centerSec) {
    if(viewMode!=="capture"||!captureRecord)return;
    const span=captureViewport.endSec-captureViewport.startSec,duration=captureRecord.durationSec||span;
    const minimum=Math.max(1e-9,(captureRecord.expectedTicks||1)/(captureRecord.clockHz||50000000));
    const nextSpan=Math.max(Math.min(duration,span*factor),minimum);
    const center=Number.isFinite(centerSec)?centerSec:captureViewport.startSec+span/2;
    const fraction=span>0?(center-captureViewport.startSec)/span:0.5;
    const nextStart=Math.max(0,Math.min(Math.max(0,duration-nextSpan),center-fraction*nextSpan));
    captureViewport={startSec:nextStart,endSec:nextStart+nextSpan};drawNeeded=true;
  }

  function togglePause(){
    paused=!paused;
    const label=paused?"Resume":"Pause";
    $("pauseButton").textContent=label;$("mobileRunButton").textContent=label;
    $("runBadge").textContent=paused?"HOLD":"RUN";$("runBadge").classList.toggle("paused",paused);applyDisplaySettings(paused);
  }

  const source = new EventSource("/events");
  function markConnected(){lastNetworkAt=performance.now();connected=true;setPill($("wifiPill"),"ok","Pico W connected");}
  source.onopen=markConnected;
  source.onerror=()=>{
    if(!lastNetworkAt||performance.now()-lastNetworkAt>2500){connected=false;setPill($("wifiPill"),"bad","Reconnecting...");}
  };
  source.onmessage=event=>{
    try {
      const d=JSON.parse(event.data);lastEventAt=performance.now();
      markConnected();
      if(Number.isFinite(d.pc)&&d.pc>0){
        measuredSampleCycles=d.pc;
        if(!labeledSampleCycles||Math.abs(measuredSampleCycles-labeledSampleCycles)>Math.max(2,labeledSampleCycles*0.005)){labeledSampleCycles=measuredSampleCycles;updateVgaTimeControl(false);}
      }
      setPill($("uartPill"),d.fresh?"ok":"",""+(d.fresh?"FPGA streaming":"Waiting for FPGA"));
      $("rateText").textContent=(d.pps>=1000?(d.pps/1000).toFixed(1)+"k":d.pps)+" pkt/s";$("packetsText").textContent=d.packets.toLocaleString();
      $("commandsText").textContent=d.cmds.toLocaleString();
      $("errorsText").textContent=d.errors;$("uptimeText").textContent=Math.floor(d.uptime/1000)+" s";
      $("baudText").textContent=d.baud.toLocaleString();$("footerBaud").textContent=d.baud.toLocaleString()+" baud";
      $("gen1Actual").textContent=formatGeneratorActual(1,d.g0hz,d.g0d,d.g0e);
      $("gen2Actual").textContent=formatGeneratorActual(2,d.g1hz,d.g1d,d.g1e);
      $("channelLive").textContent="CH"+$("channel").value;
      const focus=Number($("channel").value),focusRaw=Array.isArray(d.av)?d.av[focus]:d.latest;
      if((d.vm&(1<<focus))&&!(phoneSource==="raw"&&paused)){$("voltageText").textContent=`CH${focus}  ${formatVolts(focusRaw)}`;$("rawText").textContent="ADC "+pad4(focusRaw);}
      if(Array.isArray(d.av))for(let ch=0;ch<3;ch++){
        const active=Boolean(d.vm&(1<<ch)),pair=$("hexCh"+ch),readout=$("previewCh"+ch);
        pair.classList.toggle("disabled",!active);
        readout.textContent=active&&Number.isFinite(d.av[ch])?volts(d.av[ch]).toFixed(1)+" V":"--";
      }
      // Do not overwrite the channel select here. Data arrives about every
      // 40 ms and used to force the control back before Apply could be tapped.
      const selected=enabledChannels();$("channelTitle").textContent=selected.join("/");$("enabledLive").textContent=selected.map(channel=>"CH"+channel).join("/");
      if(phoneSource==="raw"&&viewMode==="live"&&Array.isArray(d.raw))appendRawBatch(d);
    } catch(error) { console.warn("Bad scope event",error); }
  };


  $("liveModeButton").addEventListener("click", () => {
    if ($("autoSnapshot").checked) { $("autoSnapshot").checked = false; toggleAutoSnapshots(); }
    setViewMode("live");
    // Leave a waiting/deep capture so it cannot occupy the live UART stream.
    captureAction("/api/capture/stop").catch(error=>{
      $("commandStatus").textContent="Could not stop saved capture: "+error.message;
    });
  });
  $("captureModeButton").addEventListener("click", () => setViewMode("capture"));
  $("armCaptureButton").addEventListener("click", armTriggeredCapture);
  $("stopCaptureButton").addEventListener("click", stopTriggeredCapture);
  $("downloadCaptureButton").addEventListener("click", downloadTriggeredCapture);
  $("manualSnapshotButton").addEventListener("click",takeManualSnapshot);
  $("mobileSnapshotButton").addEventListener("click",takeManualSnapshot);
  $("exportCaptureButton").addEventListener("click", exportCaptureCsv);
  $("resetCaptureViewButton").addEventListener("click", resetCaptureViewport);
  $("autoSnapshot").addEventListener("change", toggleAutoSnapshots);
  $("snapshotInterval").addEventListener("change", () => {
    if ($("autoSnapshot").checked && !autoSnapshotRunning) scheduleAutoSnapshot(0);
  });

  canvas.addEventListener("pointerdown", event => {
    if (viewMode !== "capture" || !captureRecord) return;
    canvas.setPointerCapture(event.pointerId);
    const time = capturePointerTime(event.clientX);
    const span = captureViewport.endSec - captureViewport.startSec;
    const cursorDistance = Math.max(span * 0.03, 0.000001);
    const nearA = captureCursorA !== null && Math.abs(time - captureCursorA) <= cursorDistance;
    const nearB = captureCursorB !== null && Math.abs(time - captureCursorB) <= cursorDistance;
    pointerState = {id: event.pointerId, mode: nearA ? "cursorA" : nearB ? "cursorB" : "pan", startX: event.clientX, startStart: captureViewport.startSec, startEnd: captureViewport.endSec};
    if (pointerState.mode === "pan") event.preventDefault();
  });
  canvas.addEventListener("pointermove", event => {
    if (!pointerState || pointerState.id !== event.pointerId || viewMode !== "capture") return;
    const rect = canvas.getBoundingClientRect();
    const span = pointerState.startEnd - pointerState.startStart;
    if (pointerState.mode === "cursorA" || pointerState.mode === "cursorB") {
      const time = capturePointerTime(event.clientX);
      if (pointerState.mode === "cursorA") captureCursorA = time; else captureCursorB = time;
    } else {
      const shift = (event.clientX - pointerState.startX) / rect.width * span;
      const duration = captureRecord ? captureRecord.durationSec : pointerState.startEnd;
      const nextStart = Math.max(0, Math.min(Math.max(0, duration - span), pointerState.startStart - shift));
      captureViewport.startSec = nextStart;
      captureViewport.endSec = nextStart + span;
    }
    drawNeeded = true;
    event.preventDefault();
  });
  canvas.addEventListener("pointerup", event => {
    if (!pointerState || pointerState.id !== event.pointerId) return;
    if (pointerState.mode === "pan" && Math.abs(event.clientX - pointerState.startX) < 5) setCaptureCursor(capturePointerTime(event.clientX));
    pointerState = null;
    if (canvas.hasPointerCapture(event.pointerId)) canvas.releasePointerCapture(event.pointerId);
  });
  canvas.addEventListener("pointercancel", () => { pointerState = null; });
  canvas.addEventListener("wheel", event => {
    if (viewMode !== "capture" || !captureRecord) return;
    event.preventDefault();
    const factor = event.deltaY < 0 ? 0.8 : 1.25;
    zoomCapture(factor,capturePointerTime(event.clientX));
  }, {passive: false});

  $("applyButton").addEventListener("click",applySettings);
  $("snapshotSourceButton").addEventListener("click",()=>setPhoneSource("snapshot"));
  $("rawSourceButton").addEventListener("click",()=>setPhoneSource("raw"));
  $("autoButton").addEventListener("click",autoSetup);
  $("channel").addEventListener("change",()=>{
    if(manualMode)return;
    document.querySelector(`.channel-check[value="${$("channel").value}"]`).checked=true;
    applySettings();
  });
  document.querySelectorAll(".channel-check").forEach(input=>input.addEventListener("change",()=>{
    if(!channelMask()){input.checked=true;const status=$("commandStatus");status.className="command-status error";status.textContent="Keep at least one channel enabled.";return;}
    if (!document.querySelector(`.channel-check[value="${$("channel").value}"]`).checked)
      $("channel").value=String(enabledChannels()[0]);
    applySettings();
  }));
  $("pauseButton").addEventListener("click",togglePause);
  $("mobileRunButton").addEventListener("click",togglePause);
  $("mobileAutoButton").addEventListener("click",autoSetup);
  const imageAction=()=>saveScopeImage().catch(error=>{const status=$("commandStatus");status.className="command-status error";status.textContent="Image export failed: "+error.message;});
  $("saveImageButton").addEventListener("click",imageAction);
  $("mobileImageButton").addEventListener("click",imageAction);
  $("captureZoomInButton").addEventListener("click",()=>zoomCapture(0.5));
  $("captureZoomOutButton").addEventListener("click",()=>zoomCapture(2));
  $("clearButton").addEventListener("click",()=>{clearSamples();invalidateWaveform();});
  $("exportButton").addEventListener("click",exportCsv);
  $("calibrateButton").addEventListener("click",applyCalibration);
  $("rearmButton").addEventListener("click",rearmCapture);
  $("gen1Apply").addEventListener("click",()=>applyGenerator(1));$("gen2Apply").addEventListener("click",()=>applyGenerator(2));
  $("gen1Duty").addEventListener("input",event=>$("gen1DutyValue").textContent=event.target.value+"%");$("gen2Duty").addEventListener("input",event=>$("gen2DutyValue").textContent=event.target.value+"%");
  $("resetViewButton").addEventListener("click",()=>{$("timebase").value="0";updateVgaTimeControl(false);$("vertical").value="0";updateScaleLabels();$("verticalPosition").value="50";$("triggerMode").value="auto";$("triggerLevel").value="2048";$("triggerPosition").value="1";$("acquisitionAverage").value="0";$("stabilizeWave").checked=false;$("singleShot").checked=false;$("gridEnable").checked=true;$("triggerValue").textContent=formatVolts(2048);$("positionValue").textContent="50%";drawNeeded=true;applyDisplaySettings();});
  let scaleSendTimer=0;
  function scheduleDisplaySettings(){clearTimeout(scaleSendTimer);scaleSendTimer=setTimeout(()=>applyDisplaySettings(),120);}
  $("timebase").addEventListener("input",()=>{updateVgaTimeControl(false);scheduleDisplaySettings();});
  $("timebase").addEventListener("change",()=>{clearTimeout(scaleSendTimer);updateVgaTimeControl(true);});
  $("vertical").addEventListener("input",()=>{updateScaleLabels();drawNeeded=true;scheduleDisplaySettings();});
  $("voltsPerDiv").addEventListener("change",()=>{
    $("vertical").value=$("voltsPerDiv").value;updateScaleLabels();applyDisplaySettings();
  });
  ["vertical","triggerMode","triggerPosition","acquisitionAverage","stabilizeWave","singleShot","gridEnable"].forEach(id=>$(id).addEventListener("change",()=>{clearTimeout(scaleSendTimer);drawNeeded=true;applyDisplaySettings();}));
  $("totalTime").addEventListener("change",()=>{
    $("timebase").value = $("totalTime").value;
    updateVgaTimeControl(true);
  });
  $("totalTime").addEventListener("blur",()=>updateVgaTimeControl(false));
  $("voltsPerDiv").addEventListener("blur",updateScaleLabels);
  $("triggerLevel").addEventListener("input",event=>{$("triggerValue").textContent=formatVolts(Number(event.target.value));drawNeeded=true;});
  $("triggerLevel").addEventListener("change",applyDisplaySettings);
  $("verticalPosition").addEventListener("input",event=>{$("positionValue").textContent=event.target.value+"%";drawNeeded=true;});
  $("verticalPosition").addEventListener("change",applyDisplaySettings);
  window.addEventListener("resize",()=>{drawNeeded=true;drawFft();});
  setInterval(()=>{const now=performance.now(),last=Math.max(lastEventAt,lastLiveFrameAt),age=last?now-last:Infinity;$("ageText").textContent=Number.isFinite(age)?Math.round(age)+" ms":"never";if(connected&&age>2000)setPill($("uartPill"),"bad","FPGA timeout");},500);
  function followHardwareFrame(frame) {
    const changed = manualMode !== frame.manualMode;
    manualMode = frame.manualMode;
    if (!boardFrameKnown || manualMode || changed) {
      clearTimeout(scaleSendTimer);
      document.querySelectorAll(".channel-check").forEach(input=>{
        input.checked=Boolean(frame.mask & (1<<Number(input.value)));
      });
      $("channel").value=String(frame.focus);
      $("timebase").value=String(frame.timebase);
      if (!boardFrameKnown || changed) {
        $("vertical").value=String(frame.scale);
        $("verticalPosition").value=String(frame.position);
        $("gridEnable").checked=frame.grid;
      }
      $("triggerMode").value=["free","rising","falling","auto"][frame.trigger];
      $("triggerPosition").value=String(frame.triggerPosition);
      $("triggerLevel").value=String(frame.triggerLevel);
      $("acquisitionAverage").value=String(frame.averaging);
      $("singleShot").checked=frame.singleShot;
      $("stabilizeWave").checked=frame.stabilize;
      paused=!frame.running;
      $("pauseButton").textContent=paused?"Resume":"Pause";
      $("mobileRunButton").textContent=paused?"Resume":"Pause";
      $("runBadge").textContent=manualMode?"MANUAL":paused?"HOLD":"RUN";
      $("runBadge").classList.toggle("paused",paused);
      $("channelTitle").textContent=enabledChannels().join("/");
      $("enabledLive").textContent=enabledChannels().map(ch=>"CH"+ch).join("/");
      $("positionValue").textContent=frame.position+"%";
      $("triggerValue").textContent=formatVolts(frame.triggerLevel);
      const status=$("commandStatus");status.className="command-status good";
      status.textContent=manualMode
        ? "SW0 manual: all channels live. KEY0 = longer window; KEY1 = shorter."
        : "Phone controls active. SW0 up enables manual mode.";
      ["timebase","totalTime","channel","applyButton","triggerMode","triggerLevel",
        "triggerPosition","acquisitionAverage","stabilizeWave","singleShot",
        "pauseButton","mobileRunButton","autoButton","rearmButton","resetViewButton"]
        .forEach(id=>$(id).disabled=manualMode);
      document.querySelectorAll(".channel-check").forEach(input=>input.disabled=manualMode);
      updateChannelButtons();
    }
    boardFrameKnown=true;
  }
  async function pollLiveFrame() {
    let controller=null, timeout=0;
    try {
      // Waveforms keep updating while EventSource reconnects independently.
      if (!document.hidden && viewMode === "live" && !settingsBusy && !displayBusy) {
        if(typeof AbortController!=="undefined"){
          controller=new AbortController();timeout=setTimeout(()=>controller.abort(),2500);
        }
        const requestedSource=phoneSource;
        const path=`/api/live?raw=${requestedSource==="raw"?1:0}`+(lastFetchedFrameId===null?"":`&after=${lastFetchedFrameId}`);
        const response=await fetch(path,{cache:"no-store",...(controller?{signal:controller.signal}:{})});
        if(response.ok)markConnected();
        if (response.status===200) {
          const frame=CaptureProtocol.decodeLiveFrame(await response.arrayBuffer());
          if(requestedSource!==phoneSource)return;
          lastFetchedFrameId=frame.id;
          followHardwareFrame(frame);
          fullScaleMv=frame.fullScaleMv;measuredSampleCycles=frame.samplePeriodCycles;
          updateScaleLabels();updateVgaTimeControl(false);
          // A frame in transit may precede the latest control change. Keep
          // displaying the last complete window until the new settings arrive.
          if (phoneSource==="snapshot"&&!frame.metadataOnly&&frame.mask===channelMask() && frame.focus===Number($("channel").value) &&
              frame.timebase===Number($("timebase").value) &&
              frame.averaging===Number($("acquisitionAverage").value) &&
              (!liveFrame || frame.id!==liveFrame.id)) {
            liveFrame=frame;lastLiveFrameAt=performance.now();
            fullScaleMv=frame.fullScaleMv;measuredSampleCycles=frame.samplePeriodCycles;
            setPill($("uartPill"),"ok","FPGA streaming");
            clearSamples();
            for(let ch=0;ch<6;ch++)for(const point of frame.traces[ch])
              pushSample(ch,point.adc,point.low,point.high,point.timeMs);
            updateScaleLabels();updateVgaTimeControl(false);drawNeeded=true;
          }
        } else if (response.status!==202 && response.status!==204) throw new Error("Live waveform unavailable. Update both FPGA and Pico firmware.");
        if (liveFrame&&phoneSource==="snapshot") {
          const age=Math.round(performance.now()-lastLiveFrameAt);
          $("measurementSource").textContent=`Live VGA window · ${enabledChannels().length} channels · updated ${age} ms ago`;
        }
      }
    } catch(error) {
      $("measurementSource").textContent=error.message;
      if(!lastNetworkAt||performance.now()-lastNetworkAt>2500){connected=false;setPill($("wifiPill"),"bad","Reconnecting...");}
    } finally {clearTimeout(timeout);setTimeout(pollLiveFrame,phoneSource==="raw"?200:40);}
  }
  function frequencyLabel(hz) {
    return hz>=1000 ? `${Number((hz/1000).toPrecision(4))} kHz` : `${Number(hz.toPrecision(4))} Hz`;
  }
  function drawFft() {
    const canvas=$("fftCanvas"),context=canvas.getContext("2d",{alpha:false});
    const ratio=Math.min(window.devicePixelRatio||1,2),rect=canvas.getBoundingClientRect();
    canvas.width=Math.max(320,Math.round(rect.width*ratio));canvas.height=Math.round(240*ratio);
    context.setTransform(ratio,0,0,ratio,0,0);
    const width=canvas.width/ratio,height=240,left=66,right=width-18,top=22,bottom=height-48;
    context.fillStyle="#050b12";context.fillRect(0,0,width,height);
    context.font="500 12px ui-monospace,monospace";context.fillStyle="#c4d4e5";
    if(!fftSnapshot){context.fillText("Capture FFT to show the spectrum",16,110);return;}
    const maximum=Math.max(0.01,...fftSnapshot.bins.map(bin=>bin.amplitudeVolts))*1.15;
    context.strokeStyle="#193044";context.lineWidth=1;
    const frequencyTicks=width<500?2:4;
    for(let tick=0;tick<=4;tick++) {
      const y=bottom-(bottom-top)*tick/4;
      context.beginPath();context.moveTo(left,y);context.lineTo(right,y);context.stroke();
      context.fillStyle="#c4d4e5";context.textAlign="right";
      context.fillText((maximum*tick/4).toFixed(maximum<0.1?3:2),left-8,y+4);
    }
    for(let tick=0;tick<=frequencyTicks;tick++) {
      const x=left+(right-left)*tick/frequencyTicks;
      context.beginPath();context.moveTo(x,top);context.lineTo(x,bottom);context.stroke();
      context.textAlign=tick===0?"left":tick===frequencyTicks?"right":"center";
      context.fillText(frequencyLabel(fftSnapshot.nyquistHz*tick/frequencyTicks),x,bottom+20);
    }
    context.fillStyle="#c4d4e5";context.textAlign="left";context.fillText("V peak",8,14);
    context.textAlign="center";context.fillText("Frequency",(left+right)/2,height-4);
    context.strokeStyle=TRACE_COLORS[fftSnapshot.focus];context.lineWidth=1.6;
    context.beginPath();fftSnapshot.bins.forEach((bin,index)=>{
      const x=left+(right-left)*index/128,y=bottom-(bottom-top)*bin.amplitudeVolts/maximum;
      if(index===0)context.moveTo(x,y);else context.lineTo(x,y);
    });context.stroke();
    if(fftSnapshot.peak) {
      const peak=fftSnapshot.peak,x=left+(right-left)*peak.frequencyHz/fftSnapshot.nyquistHz;
      context.setLineDash([3,4]);context.strokeStyle="#ffd166";
      context.beginPath();context.moveTo(x,top);context.lineTo(x,bottom);context.stroke();context.setLineDash([]);
      context.fillStyle="#ffd166";context.textAlign="right";
      context.fillText(frequencyLabel(peak.frequencyHz),right,15);
    }
  }
  async function captureFft() {
    if(fftBusy){fftCancelRequested=true;$("fftButton").disabled=true;return;}
    fftBusy=true;fftCancelRequested=false;
    const button=$("fftButton"),status=$("fftStatus");
    button.textContent="Cancel FFT";$("fftRange").disabled=true;
    status.className="command-status";status.textContent="Capturing the focus channel on the FPGA...";
    let id=0,complete=false;
    const request=async path=>{
      const controller=typeof AbortController!=="undefined"?new AbortController():null;
      const timer=controller?setTimeout(()=>controller.abort(),3500):0;
      try {
        const response=await fetch(path,{cache:"no-store",...(controller?{signal:controller.signal}:{})});
        if(!response.ok)throw new Error(await response.text()||`HTTP ${response.status}`);
        return path.startsWith("/api/fft/data") ? await response.arrayBuffer() : await response.json();
      } finally {clearTimeout(timer);}
    };
    try {
      if(settingsBusy||displayBusy)throw new Error("Wait for the current acquisition setting to finish, then capture FFT.");
      const range=$("fftRange").value;
      if(!(measuredSampleCycles>0))throw new Error("Wait for FPGA sampling data before capturing FFT.");
      const sampleRate=50000000/measuredSampleCycles;
      const tb=range==="vga" ? Number($("timebase").value) : range==="raw" ? 0
        : Math.max(0,Math.min(10,Math.ceil(Math.log2(sampleRate/(2*Number(range))))));
      const started=await request(`/api/fft/start?tb=${tb}`);id=started.id;
      const deadline=performance.now()+started.timeoutMs+2000;
      while(performance.now()<deadline) {
        if(fftCancelRequested){await request(`/api/fft/cancel?id=${id}`);id=0;status.textContent="FFT cancelled. The last snapshot is kept.";return;}
        const state=await request(`/api/fft/status?id=${id}`);
        if(state.state==="error"||state.state==="cancelled")throw new Error(state.error||"FFT cancelled.");
        if(state.state==="ready") {
          const snapshot=CaptureProtocol.decodeFftFrame(await request(`/api/fft/data?id=${id}`));
          if(snapshot.id!==id)throw new Error("FFT request changed. Capture again.");
          fftSnapshot=snapshot;complete=true;drawFft();
          const peak=snapshot.peak;
          status.className="command-status good";
          status.textContent=`CH${snapshot.focus} snapshot`+(peak?` · peak ≈ ${frequencyLabel(peak.frequencyHz)} · ${peak.amplitudeVolts.toFixed(3)} V peak`:" · no clear AC peak");
          $("fftDetails").textContent=`${frequencyLabel(snapshot.sampleRateHz)} sample rate · ${frequencyLabel(snapshot.binWidthHz)} per bin · ${snapshot.durationMs.toFixed(2)} ms record · DC ${snapshot.dcVolts.toFixed(3)} V. Hann window; DC removed. Signals above ${frequencyLabel(snapshot.nyquistHz)} alias into this range.`;
          return;
        }
        status.textContent="FPGA capture / FFT in progress. The live scope keeps running.";
        await new Promise(resolve=>setTimeout(resolve,200));
      }
      throw new Error("FFT timed out. Check the FPGA image and capture again.");
    } catch(error) {
      status.className="command-status error";status.textContent=error.message;
    } finally {
      if(id&&!complete)try{await request(`/api/fft/cancel?id=${id}`);}catch{}
      fftBusy=false;button.disabled=false;button.textContent="Capture FPGA FFT";$("fftRange").disabled=false;
    }
  }
  $("fftButton").addEventListener("click",captureFft);
  drawFft();setViewMode("live");pollLiveFrame();
  updateChannelButtons();updateScaleLabels();updateVgaTimeControl(false);resizeCanvas();animationFrame();
})();

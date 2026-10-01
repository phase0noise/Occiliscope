/* Pure capture artifact helpers. This file has no DOM or framework dependencies. */
(function (root, factory) {
  const api = factory();
  if (root) root.FpgaOscilloscopeProtocol = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const HEADER_BYTES = 64;
  const RECORD_BYTES = 6;
  const MAX_RECORDS = 8192;
  const FORMAT_VERSION = 1;
  const ENVELOPE_VERSION = 2;
  const ENVELOPE_RECORD_BYTES = 10;
  const VGA_PLOT_SAMPLES = 576;

  function vgaTimeOptions(samplePeriodCycles) {
    const cycles = Number(samplePeriodCycles);
    if (!Number.isFinite(cycles) || cycles <= 0) return [];
    return Array.from({length: 11}, (_, timebase) => ({
      timebase,
      decimation: 2 ** timebase,
      seconds: cycles * VGA_PLOT_SAMPLES * (2 ** timebase) / 50000000
    }));
  }

  function decodeLiveFrame(input) {
    const bytes = bytesOf(input);
    if (bytes.length < 34 || bytes[0] !== 0xd7 || bytes[1] !== 1 ||
        u16(bytes,2) !== bytes.length) throw new Error("Incomplete VGA frame.");
    let crc = 0xffff;
    for (let i=0; i<bytes.length-2; i++) {
      crc ^= bytes[i] << 8;
      for (let bit=0; bit<8; bit++) crc = ((crc << 1) ^ ((crc & 0x8000) ? 0x1021 : 0)) & 0xffff;
    }
    if (crc !== u16(bytes,bytes.length-2)) throw new Error("VGA frame checksum failed.");
    const mask=bytes[4], channels=[];
    for (let ch=0; ch<6; ch++) if (mask & (1<<ch)) channels.push(ch);
    const columns=u16(bytes,18), period=u16(bytes,12)+(bytes[14]<<16);
    if (!mask || mask>63 || !(mask & (1<<bytes[5])) || bytes[5]>5 ||
        columns!==288 || !period || bytes[6]>10 || bytes[7]>3 || bytes[8]>100 ||
        bytes[9]>3 || bytes[10]>3 || u16(bytes,16)<1000 || u16(bytes,16)>9999 ||
        u16(bytes,26)>576 || bytes.length!==34+columns*(1+6*channels.length))
      throw new Error("Invalid VGA frame settings.");
    const traces=Array.from({length:6},()=>[]);
    const intervalSeconds=period*(2**bytes[6])/50000000;
    let offset=32;
    for (let column=0; column<columns; column++) {
      const valid=bytes[offset++];
      for (const ch of channels) {
        const adc=u16(bytes,offset), low=u16(bytes,offset+2), high=u16(bytes,offset+4);
        offset+=6;
        if (!(valid & (1<<ch))) continue;
        if (low>adc || adc>high || high>4095) throw new Error("Invalid VGA waveform column.");
        traces[ch].push({adc,low,high,timeMs:(2*column+0.5)*intervalSeconds*1000});
      }
    }
    return {id:u16(bytes,20)+u16(bytes,22)*65536, mask, focus:bytes[5],
      timebase:bytes[6], scale:bytes[7], position:bytes[8], trigger:bytes[9],
      triggerPosition:bytes[10], averaging:(bytes[11]>>5)&3,
      running:Boolean(bytes[11]&2), singleShot:Boolean(bytes[11]&16),
      grid:Boolean(bytes[11]&1), stabilize:Boolean(bytes[11]&128),
      triggerLevel:u16(bytes,24), manualMode:Boolean(bytes[28]&1),
      samplePeriodCycles:period, fullScaleMv:u16(bytes,16),
      windowMs:576*intervalSeconds*1000, traces};
  }
  const ADC_MAX = 4095;
  function decodeFftFrame(input) {
    const bytes=bytesOf(input);
    if(bytes.length!==550 || bytes[0]!==0xd8 || bytes[1]!==1 || u16(bytes,2)!==550)
      throw new Error("Incomplete FPGA FFT snapshot.");
    let crc=0xffff;
    for(let i=0;i<548;i++){
      crc^=bytes[i]<<8;
      for(let bit=0;bit<8;bit++)crc=((crc<<1)^((crc&0x8000)?0x1021:0))&0xffff;
    }
    if(crc!==u16(bytes,548))throw new Error("FFT checksum failed. Capture again.");
    if(bytes[4]!==1)throw new Error("FPGA FFT acquisition was invalid. Capture again.");
    const id=u32(bytes,8),period=u32(bytes,12),fullScaleMv=u16(bytes,16);
    const elapsedTicks=u32(bytes,20),dcMean=u16(bytes,24),gain=u16(bytes,26)/32768;
    if(!id || id>65535 || bytes[5]>5 || bytes[6]!==8 || bytes[7]>10 || !period ||
        fullScaleMv<1000 || fullScaleMv>9999 || u16(bytes,18)!==256 ||
        !elapsedTicks || Math.abs(elapsedTicks-period*255)>127 || dcMean>4095 ||
        u16(bytes,26)!==16320 || u16(bytes,28)!==129 || bytes[30]!==1 ||
        (bytes[31]!==0 && bytes[31]!==3))
      throw new Error("Invalid FFT sampling metadata.");
    const sampleRateHz=50000000/period,binWidthHz=sampleRateHz/256;
    const fractionalScale=2**bytes[31];
    const bins=Array.from({length:129},(_,index)=>{
      const power=u32(bytes,32+4*index);
      if(power>33554432*fractionalScale*fractionalScale)throw new Error("FFT amplitude exceeds the ADC range.");
      const amplitudeVolts=Math.sqrt(power)/fractionalScale*(index===0||index===128?1:2)/gain*fullScaleMv/4096000;
      return {index,frequencyHz:index*binWidthHz,power,amplitudeVolts};
    });
    let peak=bins[1];
    for(const bin of bins.slice(2))if(bin.power>peak.power)peak=bin;
    peak=peak.power>16*fractionalScale*fractionalScale ? {...peak,binFrequencyHz:peak.frequencyHz} : null;
    // Estimate a tone between bins using the Hann main lobe in log magnitude.
    // This refines a peak readout; the graph retains the original FPGA bins.
    if(peak && peak.index>1 && peak.index<127) {
      const a=Math.log(Math.max(bins[peak.index-1].amplitudeVolts,1e-12));
      const b=Math.log(Math.max(peak.amplitudeVolts,1e-12));
      const c=Math.log(Math.max(bins[peak.index+1].amplitudeVolts,1e-12));
      const denominator=a-2*b+c;
      const offset=denominator<0 ? Math.max(-0.5,Math.min(0.5,0.5*(a-c)/denominator)) : 0;
      peak.frequencyHz=(peak.index+offset)*binWidthHz;
      peak.amplitudeVolts=Math.exp(b-0.25*(a-c)*offset);
    }
    return {id,focus:bytes[5],timebase:bytes[7],sampleRateHz,binWidthHz,
      nyquistHz:sampleRateHz/2,durationMs:elapsedTicks/50000,
      dcVolts:dcMean*fullScaleMv/4096000,bins,peak};
  }
  const FLAG_COMPLETE = 1;
  const FLAG_TRIGGERED = 2;
  const FLAG_GAP = 4;
  const FLAG_STOPPED = 8;

  function selectVgaTimebase(requestSeconds, samplePeriodCycles, plotSamples) {
    const requested = Number(requestSeconds);
    const cycles = Number(samplePeriodCycles);
    const samples = plotSamples === undefined ? 576 : Number(plotSamples);
    if (!Number.isFinite(requested) || requested <= 0) throw new RangeError("VGA window must be positive.");
    if (!Number.isFinite(cycles) || cycles <= 0) throw new RangeError("FPGA sample period is unavailable.");
    if (!Number.isFinite(samples) || samples <= 0) throw new RangeError("Plot width must be positive.");
    const baseWindowSeconds = cycles * samples / 50000000;
    const ideal = Math.log2(requested / baseWindowSeconds);
    const timebase = Math.max(0, Math.min(10, Math.round(ideal)));
    const actualWindowSeconds = baseWindowSeconds * (2 ** timebase);
    return {
      timebase,
      decimation: 2 ** timebase,
      actualWindowSeconds,
      minimumWindowSeconds: baseWindowSeconds,
      maximumWindowSeconds: baseWindowSeconds * 1024,
      limited: ideal < 0 ? "minimum" : ideal > 10 ? "maximum" : null
    };
  }

  function frequencyToHertz(value, unit) {
    const scales = {Hz: 1, kHz: 1000, MHz: 1000000};
    const numeric = Number(value), scale = scales[unit];
    if (!Number.isFinite(numeric) || numeric <= 0 || !scale) throw new RangeError("Generator frequency and unit are invalid.");
    return Math.max(1, Math.min(2000000, Math.round(numeric * scale)));
  }

  function bytesOf(input) {
    if (input instanceof Uint8Array) return input;
    if (input instanceof ArrayBuffer) return new Uint8Array(input);
    if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    if (Array.isArray(input)) return Uint8Array.from(input);
    throw new TypeError("Capture data must be an ArrayBuffer or byte array.");
  }

  function u16(bytes, offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  function u32(bytes, offset) {
    return (bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24)) >>> 0;
  }

  function readAscii(bytes, offset, length) {
    let text = "";
    for (let i = 0; i < length; i++) text += String.fromCharCode(bytes[offset + i]);
    return text;
  }

  /*
   * Convert a sequence of uint32 hardware ticks to monotonic ticks. Unsigned
   * subtraction makes the normal 32-bit wrap unambiguous and keeps the raw
   * timestamp available for export and diagnostics.
   */
  function unwrapTicks(rawTicks) {
    const raw = Array.from(rawTicks, value => Number(value) >>> 0);
    const unwrapped = [];
    let total = 0;
    let previous = null;
    for (const tick of raw) {
      if (previous === null) {
        total = tick;
      } else {
        total += (tick - previous) >>> 0;
      }
      unwrapped.push(total);
      previous = tick;
    }
    return unwrapped;
  }

  function median(values) {
    const sorted = values.filter(Number.isFinite).slice().sort((a, b) => a - b);
    if (!sorted.length) return 0;
    const middle = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
  }

  function findGaps(samples, expectedTicks) {
    const deltas = [];
    for (let i = 1; i < samples.length; i++) {
      const delta = samples[i].ticks - samples[i - 1].ticks;
      if (delta > 0) deltas.push(delta);
    }
    const expected = Number(expectedTicks) > 0 ? Number(expectedTicks) : median(deltas);
    const gaps = [];
    if (!(expected > 0)) return { expectedTicks: 0, gaps };
    for (let i = 1; i < samples.length; i++) {
      const delta = samples[i].ticks - samples[i - 1].ticks;
      if (!(delta > expected * 1.5)) continue;
      gaps.push({
        before: i - 1,
        after: i,
        missing: Math.max(1, Math.round(delta / expected) - 1),
        fromTicks: samples[i - 1].ticks,
        toTicks: samples[i].ticks,
        deltaTicks: delta
      });
    }
    return { expectedTicks: expected, gaps };
  }

  function viewportForWindow(record, requestedSpanSec, pretriggerFraction) {
    const duration = Math.max(0, Number(record && record.durationSec) || 0);
    const requested = Math.max(0, Number(requestedSpanSec) || duration);
    const span = Math.min(duration, requested || duration);
    const fraction = Math.max(0, Math.min(1, Number(pretriggerFraction) || 0));
    const triggerSample = record && record.triggered && record.triggerMode !== 0 && Number.isInteger(record.triggerIndex)
      ? record.samples[record.triggerIndex] : null;
    const triggerSec = triggerSample && Number.isFinite(triggerSample.timeSec)
      ? triggerSample.timeSec : null;
    let startSec;
    if (triggerSec !== null) startSec = triggerSec - span * fraction;
    else startSec = duration - span;
    startSec = Math.max(0, Math.min(Math.max(0, duration - span), startSec));
    return {startSec, endSec: startSec + span, triggerSec};
  }

  function decodeCapture(input, options) {
    const bytes = bytesOf(input);
    const opts = options || {};
    if (bytes.length < HEADER_BYTES) throw new Error("Capture is shorter than its 64-byte header.");
    const magic = readAscii(bytes, 0, 4);
    if (magic !== "OCAP") throw new Error("Unsupported capture magic.");
    const version = bytes[4];
    if (version !== FORMAT_VERSION && version !== ENVELOPE_VERSION) throw new Error("Unsupported capture format version " + version + ".");
    const headerBytes = bytes[5];
    if (headerBytes < HEADER_BYTES || headerBytes > bytes.length) throw new Error("Invalid capture header length.");
    const flags = bytes[6];
    const focusChannel = bytes[7];
    const declaredRecords = u16(bytes, 8);
    const recordBytes = u16(bytes, 10) || RECORD_BYTES;
    const envelope = version === ENVELOPE_VERSION;
    if (recordBytes !== (envelope ? ENVELOPE_RECORD_BYTES : RECORD_BYTES)) throw new Error("Unsupported capture record size.");
    if (declaredRecords > MAX_RECORDS) throw new Error("Capture record count exceeds the supported maximum.");
    const samplePeriodTicks = u32(bytes, 12);
    const captureId = u32(bytes, 16);
    const triggerIndexRaw = u32(bytes, 20);
    const fullScaleMv = u16(bytes, 24);
    const configRevision = u16(bytes, 26);
    const firstTick = u32(bytes, 28);
    const configFingerprint = u32(bytes, 32);
    const averageMode = bytes[36];
    const triggerMode = bytes[37];
    const triggerLevel = u16(bytes, 38);
    const requestId = u32(bytes, 40);
    const artifactClockHz = u32(bytes, 44);
    const rawFlags = u32(bytes, 48);
    const availableRecords = Math.floor((bytes.length - headerBytes) / recordBytes);
    const recordCount = declaredRecords;
    const truncated = recordCount > availableRecords;
    if (truncated) throw new Error("Capture artifact is truncated: header declares " + declaredRecords + " records but only " + availableRecords + " are present.");
    const triggerIndexValid = triggerIndexRaw === 0xffffffff || triggerIndexRaw < declaredRecords;
    const focusChannelValid = focusChannel < 6;
    const fullScaleValid = fullScaleMv >= 1000 && fullScaleMv <= 9999;
    const metadataErrors = [];
    if (!focusChannelValid) metadataErrors.push("focus channel is out of range");
    if (!triggerIndexValid) metadataErrors.push("trigger index is out of range");
    if (!fullScaleValid) metadataErrors.push("full-scale calibration is out of range");
    const clockHz = Number(opts.clockHz || opts.sampleClockHz || artifactClockHz || 50000000);
    const rawTicks = [];
    const rawAdc = [];
    for (let i = 0; i < recordCount; i++) {
      const offset = headerBytes + i * recordBytes;
      rawTicks.push(u32(bytes, offset));
      rawAdc.push(u16(bytes, offset + 4));
    }
    if (rawTicks.length && rawTicks[0] !== firstTick) metadataErrors.push("first acquisition tick does not match the first record");
    const ticks = unwrapTicks(rawTicks);
    const firstUnwrapped = ticks.length ? ticks[0] : firstTick;
    const samples = rawAdc.map((adc, index) => {
      const offset = headerBytes + index * recordBytes;
      const low = envelope ? u16(bytes, offset + 6) : adc;
      const high = envelope ? u16(bytes, offset + 8) : adc;
      return {
        index,
        tick: rawTicks[index],
        ticks: ticks[index] - firstUnwrapped,
        timeSec: (ticks[index] - firstUnwrapped) / clockHz,
        timeMs: (ticks[index] - firstUnwrapped) * 1000 / clockHz,
        adc,
        low,
        high,
        valid: adc <= ADC_MAX && low <= adc && high >= adc && high <= ADC_MAX
      };
    });
    const gapInfo = findGaps(samples, samplePeriodTicks);
    const gaps = gapInfo.gaps;
    const hasGap = (flags & FLAG_GAP) !== 0 || gaps.length > 0;
    const validSamples = samples.filter(sample => sample.valid);
    const durationSec = samples.length > 1 ? samples[samples.length - 1].timeSec : 0;
    const measuredPeriodTicks = gapInfo.expectedTicks;
    const sampleRateHz = measuredPeriodTicks > 0 ? clockHz / measuredPeriodTicks : 0;
    return {
      format: "OCAP",
      version,
      envelope,
      headerBytes,
      recordBytes,
      bytes: bytes.length,
      flags,
      complete: (flags & FLAG_COMPLETE) !== 0 && !truncated,
      triggered: (flags & FLAG_TRIGGERED) !== 0,
      stopped: (flags & FLAG_STOPPED) !== 0,
      hasGap,
      truncated,
      focusChannel,
      metadataValid: metadataErrors.length === 0,
      metadataErrors,
      declaredRecords,
      recordCount,
      validCount: validSamples.length,
      samplePeriodTicks,
      sampleRateHz,
      clockHz,
      captureId,
      triggerIndex: triggerIndexRaw === 0xffffffff ? null : triggerIndexRaw,
      fullScaleMv: fullScaleValid ? fullScaleMv : Number(opts.fullScaleMv || 5000),
      configRevision,
      configFingerprint,
      averageMode,
      averaging: averageMode,
      triggerMode,
      triggerLevel,
      requestId,
      rawFlags,
      firstTick,
      durationSec,
      samples,
      validSamples,
      gaps,
      expectedTicks: gapInfo.expectedTicks
    };
  }

  function valueToVolts(adc, fullScaleMv) {
    return Number(adc) * Number(fullScaleMv || 5000) / 4096000;
  }

  function measureRecord(record, range) {
    const start = range && Number.isFinite(range.startSec) ? range.startSec : -Infinity;
    const end = range && Number.isFinite(range.endSec) ? range.endSec : Infinity;
    const selected = record.samples.filter(sample =>
      sample.valid && sample.timeSec >= start && sample.timeSec <= end);
    const artifactValid = record.metadataValid !== false && record.complete !== false &&
      record.validCount === record.recordCount;
    const result = {
      valid: selected.length > 0 && artifactValid,
      count: selected.length,
      min: null,
      max: null,
      peakToPeak: null,
      average: null,
      rms: null,
      frequencyHz: null,
      periodSec: null,
      dutyPercent: null,
      reason: "",
      hasGap: record.gaps.some(gap => {
        const t = record.samples[gap.after] && record.samples[gap.after].timeSec;
        return t >= start && t <= end;
      })
    };
    if (!selected.length) {
      result.reason = "No valid ADC samples in the selected window.";
      return result;
    }
    const values = selected.map(sample => sample.adc);
    result.min = Math.min(...selected.map(sample => sample.low));
    result.max = Math.max(...selected.map(sample => sample.high));
    result.peakToPeak = result.max - result.min;
    result.average = values.reduce((sum, value) => sum + value, 0) / values.length;
    result.rms = Math.sqrt(values.reduce((sum, value) => sum + value * value, 0) / values.length);
    if (!artifactValid) {
      result.reason = (record.metadataErrors && record.metadataErrors.length)
        ? "Invalid capture metadata: " + record.metadataErrors.join(", ") + "."
        : "Capture is incomplete or contains invalid ADC values; measurements are suppressed.";
      result.valid = false;
      return result;
    }
    if (selected.length < 8) {
      result.reason = "At least eight valid samples are required for timing measurements.";
      result.valid = true;
      return result;
    }
    if (result.hasGap) {
      result.reason = "Timestamp gap detected; timing measurements are suppressed.";
      result.valid = true;
      return result;
    }
    if (result.peakToPeak < Math.max(12, ADC_MAX * 0.005)) {
      result.reason = "Signal amplitude is too small for a reliable frequency estimate.";
      return result;
    }
    const midpoint = (result.min + result.max) / 2;
    const hysteresis = Math.max(2, (result.max - result.min) * 0.10);
    const lowThreshold = midpoint - hysteresis;
    const highThreshold = midpoint + hysteresis;
    const crossings = [];
    let armed = false;
    for (let i = 1; i < selected.length; i++) {
      if (selected[i].adc <= lowThreshold) armed = true;
      if (armed && selected[i].adc >= highThreshold) {
        crossings.push(selected[i].timeSec);
        armed = false;
      }
    }
    if (crossings.length < 2) {
      result.reason = "Record is too short for a reliable frequency estimate.";
      return result;
    }
    const periods = [];
    for (let i = 1; i < crossings.length; i++) {
      const period = crossings[i] - crossings[i - 1];
      if (period > 0) periods.push(period);
    }
    if (!periods.length) {
      result.reason = "Timestamp spacing is insufficient for a frequency estimate.";
      return result;
    }
    const period = median(periods);
    const stable = periods.filter(value => value >= period * 0.65 && value <= period * 1.35);
    const sampleIntervals = [];
    for (let i = 1; i < selected.length; i++) {
      const interval = selected[i].timeSec - selected[i - 1].timeSec;
      if (interval > 0) sampleIntervals.push(interval);
    }
    const sampleInterval = median(sampleIntervals);
    if (stable.length < 2 || !(sampleInterval > 0) || period / sampleInterval < 8 ||
        selected[selected.length - 1].timeSec - selected[0].timeSec < period * 1.5) {
      result.reason = "Record is too short for a reliable frequency estimate.";
      result.valid = true;
      return result;
    }
    result.periodSec = stable.reduce((sum, value) => sum + value, 0) / stable.length;
    result.frequencyHz = 1 / result.periodSec;
    const firstCycle = crossings[0], lastCycle = crossings[crossings.length - 1];
    let highDuration = 0, totalDuration = 0;
    for (let i = 1; i < selected.length; i++) {
      const left = selected[i - 1], right = selected[i];
      const segmentStart = Math.max(firstCycle, left.timeSec);
      const segmentEnd = Math.min(lastCycle, right.timeSec);
      if (segmentEnd <= segmentStart) continue;
      const duration = segmentEnd - segmentStart;
      totalDuration += duration;
      if (left.adc >= midpoint) highDuration += duration;
    }
    result.dutyPercent = totalDuration > 0 ? 100 * highDuration / totalDuration : null;
    return result;
  }

  function csvForCapture(record, range) {
    const measurement = measureRecord(record, range);
    const lines = [
      "# FPGA Oscilloscope capture",
      "# format=" + record.format + " version=" + record.version,
      "# capture_id=" + record.captureId,
      "# focus_channel=" + record.focusChannel,
      "# records=" + record.recordCount + " valid=" + record.validCount,
      "# sample_rate_hz=" + (record.sampleRateHz || 0),
      "# clock_hz=" + record.clockHz,
      "# full_scale_mv=" + record.fullScaleMv,
      "# trigger_mode=" + (record.triggerMode || "unknown"),
      "# trigger_level=" + (record.triggerLevel === undefined ? "unknown" : record.triggerLevel),
      "# averaging=" + (record.averaging === undefined ? "unknown" : record.averaging),
      "# config_fingerprint=" + (record.configFingerprint || "unknown"),
      "# triggered=" + record.triggered,
      "# complete=" + record.complete,
      "# gaps=" + record.gaps.length,
      "# measurement_valid=" + measurement.valid,
      "time_ms,channel,tick,adc,volts,valid,low,high"
    ];
    for (const sample of record.samples) {
      lines.push([
        sample.timeMs.toFixed(6),
        record.focusChannel,
        sample.tick >>> 0,
        sample.adc,
        valueToVolts(sample.adc, record.fullScaleMv).toFixed(6),
        sample.valid ? "1" : "0",
        sample.low,
        sample.high
      ].join(","));
    }
    return lines.join("\n") + "\n";
  }

  return {
    HEADER_BYTES,
    RECORD_BYTES,
    MAX_RECORDS,
    FORMAT_VERSION,
    ENVELOPE_VERSION,
    ENVELOPE_RECORD_BYTES,
    VGA_PLOT_SAMPLES,
    vgaTimeOptions,
    decodeLiveFrame,
    decodeFftFrame,
    FLAG_COMPLETE,
    FLAG_TRIGGERED,
    FLAG_GAP,
    FLAG_STOPPED,
    selectVgaTimebase,
    frequencyToHertz,
    unwrapTicks,
    findGaps,
    viewportForWindow,
    decodeCapture,
    measureRecord,
    valueToVolts,
    csvForCapture
  };
});

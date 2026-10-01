const test = require("node:test");
const assert = require("node:assert/strict");
const protocol = require("../capture_protocol.js");

function put16(bytes, offset, value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >>> 8) & 0xff;
}

function put32(bytes, offset, value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >>> 8) & 0xff;
  bytes[offset + 2] = (value >>> 16) & 0xff;
  bytes[offset + 3] = (value >>> 24) & 0xff;
}

function fixture(options) {
  const opts = options || {};
  const ticks = opts.ticks || [];
  const bytes = new Uint8Array(64 + ticks.length * 6);
  bytes.set([0x4f, 0x43, 0x41, 0x50], 0);
  bytes[4] = 1;
  bytes[5] = 64;
  bytes[6] = opts.flags === undefined ? protocol.FLAG_COMPLETE : opts.flags;
  bytes[7] = opts.channel === undefined ? 2 : opts.channel;
  put16(bytes, 8, ticks.length);
  put16(bytes, 10, 6);
  put32(bytes, 12, opts.periodTicks === undefined ? 1000 : opts.periodTicks);
  put32(bytes, 16, opts.captureId || 17);
  put32(bytes, 20, opts.triggerIndex === undefined ? 32 : opts.triggerIndex);
  put16(bytes, 24, opts.fullScaleMv || 5000);
  put16(bytes, 26, opts.configRevision || 4);
  put32(bytes, 28, opts.firstTick === undefined ? ticks[0] || 0 : opts.firstTick);
  put32(bytes, 32, opts.configFingerprint === undefined ? 0x12345678 : opts.configFingerprint);
  bytes[36] = opts.averageMode === undefined ? 2 : opts.averageMode;
  bytes[37] = opts.triggerMode === undefined ? 1 : opts.triggerMode;
  put16(bytes, 38, opts.triggerLevel === undefined ? 2048 : opts.triggerLevel);
  put32(bytes, 40, opts.requestId === undefined ? 7 : opts.requestId);
  put32(bytes, 44, 1000000);
  put32(bytes, 48, 0);
  for (let i = 0; i < ticks.length; i++) {
    const offset = 64 + i * 6;
    put32(bytes, offset, ticks[i]);
    put16(bytes, offset + 4, opts.values ? opts.values[i] : 2048);
  }
  return bytes;
}

test("unwraps a 32-bit FPGA timestamp wrap", () => {
  const values = protocol.unwrapTicks([0xfffffff0, 0x10, 0x30]);
  assert.deepEqual(values, [0xfffffff0, 0x100000010, 0x100000030]);
});

test("decodes a complete fixture and measures timestamped samples", () => {
  const ticks = Array.from({length: 128}, (_, index) => index * 1000);
  const values = ticks.map((_, index) => (Math.floor(index / 16) % 2) ? 3500 : 500);
  const record = protocol.decodeCapture(fixture({ticks, values}), {clockHz: 1000000});
  assert.equal(record.metadataValid, true);
  assert.equal(record.complete, true);
  assert.equal(record.recordCount, 128);
  assert.equal(record.sampleRateHz, 1000);
  assert.equal(record.durationSec, 0.127);
  const measurement = protocol.measureRecord(record);
  assert.equal(measurement.valid, true);
  assert.ok(Math.abs(measurement.frequencyHz - (1000 / 32)) < 0.01);
  assert.ok(Math.abs(measurement.dutyPercent - 50) < 1);
});

test("suppresses timing measurements across a timestamp gap", () => {
  const ticks = Array.from({length: 128}, (_, index) => index < 64 ? index * 1000 : index * 1000 + 12000);
  const values = ticks.map((_, index) => (Math.floor(index / 16) % 2) ? 3500 : 500);
  const record = protocol.decodeCapture(fixture({ticks, values, flags: protocol.FLAG_COMPLETE | protocol.FLAG_GAP}), {clockHz: 1000000});
  const measurement = protocol.measureRecord(record);
  assert.equal(record.hasGap, true);
  assert.equal(measurement.frequencyHz, null);
  assert.match(measurement.reason, /gap/i);
});

test("does not report noise as a signal frequency", () => {
  const ticks = Array.from({length: 128}, (_, index) => index * 1000);
  const values = ticks.map((_, index) => 2048 + (index % 5) - 2);
  const record = protocol.decodeCapture(fixture({ticks, values}), {clockHz: 1000000});
  const measurement = protocol.measureRecord(record);
  assert.equal(measurement.valid, true);
  assert.equal(measurement.frequencyHz, null);
  assert.equal(measurement.dutyPercent, null);
  assert.match(measurement.reason, /amplitude/i);
});

test("marks inconsistent metadata invalid and rejects truncation", () => {
  const ticks = [1000, 2000, 3000];
  const badHeader = protocol.decodeCapture(fixture({ticks, firstTick: 999}), {clockHz: 1000000});
  assert.equal(badHeader.metadataValid, false);
  assert.equal(protocol.measureRecord(badHeader).valid, false);
  const badFocusBytes = fixture({ticks});
  badFocusBytes[7] = 6;
  assert.equal(protocol.decodeCapture(badFocusBytes).metadataValid, false);
  const badTriggerBytes = fixture({ticks});
  put32(badTriggerBytes, 20, ticks.length);
  assert.equal(protocol.decodeCapture(badTriggerBytes).metadataValid, false);
  const badCount = fixture({ticks: []});
  put16(badCount, 8, protocol.MAX_RECORDS + 1);
  assert.throws(() => protocol.decodeCapture(badCount), /record count/i);
  assert.throws(() => protocol.decodeCapture(fixture({ticks: ticks.slice(0, 2)}).slice(0, 64 + 6), {clockHz: 1000000}), /truncated/i);
});

test("exports capture metadata and raw FPGA timestamps", () => {
  const ticks = Array.from({length: 16}, (_, index) => index * 1000);
  const record = protocol.decodeCapture(fixture({ticks}), {clockHz: 1000000});
  const csv = protocol.csvForCapture(record);
  assert.match(csv, /# capture_id=17/);
  assert.match(csv, /# sample_rate_hz=1000/);
  assert.match(csv, /time_ms,channel,tick,adc,volts,valid/);
  assert.equal(record.averageMode, 2);
  assert.equal(record.triggerMode, 1);
  assert.equal(record.configFingerprint, 0x12345678);
});

test("frames a phone window around the FPGA trigger position", () => {
  const ticks = Array.from({length: 1001}, (_, index) => index * 1000);
  const record = protocol.decodeCapture(fixture({ticks, triggerIndex: 400, flags: protocol.FLAG_COMPLETE | protocol.FLAG_TRIGGERED}), {clockHz: 1000000});
  const viewport = protocol.viewportForWindow(record, 0.1, 0.25);
  assert.ok(Math.abs(viewport.startSec - 0.375) < 1e-12);
  assert.ok(Math.abs(viewport.endSec - 0.475) < 1e-12);
  assert.ok(Math.abs(viewport.triggerSec - 0.4) < 1e-12);
});

test("clamps a phone window to the available capture", () => {
  const ticks = Array.from({length: 51}, (_, index) => index * 1000);
  const record = protocol.decodeCapture(fixture({ticks, flags: protocol.FLAG_COMPLETE, triggerIndex: 0xffffffff}), {clockHz: 1000000});
  assert.deepEqual(protocol.viewportForWindow(record, 1, 0.25), {startSec: 0, endSec: 0.05, triggerSec: null});
});

test("maps a requested FPGA VGA window to the closest hardware timebase", () => {
  const baseWindow = 250 * 576 / 50000000;
  const exact = protocol.selectVgaTimebase(baseWindow * 32, 250);
  assert.equal(exact.timebase, 5);
  assert.equal(exact.decimation, 32);
  assert.ok(Math.abs(exact.actualWindowSeconds - baseWindow * 32) < 1e-15);
  assert.equal(protocol.selectVgaTimebase(1e-12, 250).limited, "minimum");
  assert.equal(protocol.selectVgaTimebase(1000, 250).limited, "maximum");
});

test("converts selected generator units to bounded FPGA hertz", () => {
  assert.equal(protocol.frequencyToHertz(250, "Hz"), 250);
  assert.equal(protocol.frequencyToHertz(12.5, "kHz"), 12500);
  assert.equal(protocol.frequencyToHertz(1.25, "MHz"), 1250000);
  assert.equal(protocol.frequencyToHertz(3, "MHz"), 2000000);
  assert.throws(() => protocol.frequencyToHertz(1, "rpm"), /invalid/i);
});

test("lists every hardware time scale using the measured acquisition interval", () => {
  const options = protocol.vgaTimeOptions(800);
  assert.equal(options.length, 11);
  assert.equal(options[0].seconds, 0.009216);
  assert.equal(options[10].seconds, 9.437184);
  for (const option of options) {
    assert.equal(protocol.selectVgaTimebase(option.seconds, 800).timebase, option.timebase);
  }
  assert.equal(protocol.vgaTimeOptions(3200)[4].seconds, options[4].seconds * 4);
  assert.deepEqual(protocol.vgaTimeOptions(0), []);
});

function envelopeFixture() {
  const ticks = Array.from({length: 128}, (_, index) => index * 1000);
  const values = ticks.map((_, index) => Math.floor(index / 16) % 2 ? 3000 : 1000);
  const original = fixture({ticks, values, triggerIndex: 32});
  const bytes = new Uint8Array(64 + ticks.length * 10);
  bytes.set(original.subarray(0, 64));
  bytes[4] = protocol.ENVELOPE_VERSION;
  put16(bytes, 10, 10);
  ticks.forEach((tick, index) => {
    const offset = 64 + index * 10;
    put32(bytes, offset, tick);
    put16(bytes, offset + 4, values[index]);
    put16(bytes, offset + 6, 500);
    put16(bytes, offset + 8, 3500);
  });
  return bytes;
}

test("snapshot envelopes retain peaks while measurements use the mean trace", () => {
  const record = protocol.decodeCapture(envelopeFixture());
  assert.equal(record.envelope, true);
  assert.equal(record.validCount, 128);
  const measurement = protocol.measureRecord(record);
  assert.equal(measurement.min, 500);
  assert.equal(measurement.max, 3500);
  assert.equal(measurement.average, 2000);
  assert.equal(measurement.peakToPeak, 3000);
  assert.match(protocol.csvForCapture(record), /valid,low,high/);
});

test("rejects malformed snapshot sizes and marks invalid envelopes", () => {
  const bytes = envelopeFixture();
  put16(bytes, 64 + 6, 2000); // minimum exceeds the mean
  const record = protocol.decodeCapture(bytes);
  assert.equal(record.samples[0].valid, false);
  assert.equal(protocol.measureRecord(record).valid, false);
  put16(bytes, 10, 6);
  assert.throws(() => protocol.decodeCapture(bytes), /record size/i);
});


function fftFixture() {
  return new Uint8Array(require("node:fs").readFileSync(require("node:path").join(__dirname,"../../tests/fixtures/fft_snapshot.bin")));
}
function fftChecksum(bytes) {
  let crc=0xffff;
  for(let i=0;i<548;i++){
    crc^=bytes[i]<<8;
    for(let bit=0;bit<8;bit++)crc=((crc<<1)^((crc&0x8000)?0x1021:0))&0xffff;
  }
  put16(bytes,548,crc);return bytes;
}
test("FPGA FFT snapshot preserves measured frequency, DC and calibrated amplitude",()=>{
  const snapshot=protocol.decodeFftFrame(fftFixture());
  assert.equal(snapshot.focus,1);assert.equal(snapshot.id,7);
  assert.equal(snapshot.bins.length,129);assert.equal(snapshot.sampleRateHz,12500);
  assert.ok(Math.abs(snapshot.peak.frequencyHz-781.25)<1);assert.equal(snapshot.dcVolts,2.5);
  assert.ok(Math.abs(snapshot.peak.amplitudeVolts-1.25)<0.025);
  assert.equal(snapshot.nyquistHz,6250);assert.equal(snapshot.durationMs,20.4);
});
test("FFT rejects truncated, corrupted, failed and inconsistent snapshots",()=>{
  assert.throws(()=>protocol.decodeFftFrame(fftFixture().slice(0,-1)),/Incomplete/);
  const corrupted=fftFixture();corrupted[90]^=128;
  assert.throws(()=>protocol.decodeFftFrame(corrupted),/checksum/);
  const failed=fftFixture();failed[4]=4;fftChecksum(failed);
  assert.throws(()=>protocol.decodeFftFrame(failed),/invalid/);
  const changed=fftFixture();put32(changed,12,8000);fftChecksum(changed);
  assert.throws(()=>protocol.decodeFftFrame(changed),/metadata/);
  const precision=fftFixture();precision[31]=7;fftChecksum(precision);
  assert.throws(()=>protocol.decodeFftFrame(precision),/metadata/);
});

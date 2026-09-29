#include <Arduino.h>
#include <WiFi.h>
#include <stdio.h>
#include <string.h>

#include "capture_protocol.h"

#if __has_include(<hardware/watchdog.h>)
#include <hardware/watchdog.h>
#define HAS_RP2040_WATCHDOG 1
#else
#define HAS_RP2040_WATCHDOG 0
#endif

// ============================================================
// Configuration
// ============================================================

constexpr char WIFI_NAME[] = "PicoScope";
constexpr char WIFI_PASSWORD[] = "picoscope";

constexpr uint8_t FPGA_UART_TX_PIN = 0;  // Pico GP0 -> FPGA GPIO[8]
constexpr uint8_t FPGA_UART_RX_PIN = 1;  // Pico GP1 <- FPGA GPIO[4]
constexpr uint32_t GENERATOR_MAX_HZ = 2000000;
constexpr uint32_t FPGA_UART_BAUD_HIGH = 115200;
constexpr uint32_t FPGA_UART_BAUD_LOW = 9600;
constexpr uint32_t UART_BAUD_SCAN_MS = 700;

constexpr uint16_t ADC_MAX_COUNT = 4095;
constexpr float ADC_FULL_SCALE_VOLTS = 5.0f;
constexpr uint8_t ADC_CHANNEL_COUNT = 6;

// Deliver up to 100 phone samples/s at 115200 baud for a responsive trace.
// At 9600 baud the newest available FPGA sample is repeated between packets.
constexpr uint32_t SSE_INTERVAL_MS = 10;
constexpr uint8_t RAW_SAMPLE_QUEUE_SIZE = 96;
constexpr uint8_t RAW_SAMPLES_PER_EVENT = 24;
constexpr uint32_t SSE_KEEPALIVE_MS = 5000;
constexpr uint32_t SSE_STALL_TIMEOUT_MS = 2000;

constexpr uint32_t HTTP_READ_TIMEOUT_MS = 1200;
constexpr uint32_t HTTP_WRITE_TIMEOUT_MS = 3000;
constexpr size_t HTTP_REQUEST_LINE_SIZE = 192;
constexpr size_t HTTP_RESPONSE_SIZE = 512;
constexpr size_t HTTP_MAX_HEADER_BYTES = 1024;
constexpr size_t HTTP_WRITE_CHUNK = 768;

constexpr size_t UART_LINE_SIZE = 32;
constexpr uint8_t UART_COMMAND_REPEATS = 3;

constexpr uint32_t WIFI_RETRY_MS = 5000;
constexpr uint32_t UART_ACTIVE_TIMEOUT_MS = 1500;
constexpr uint32_t UART_LINE_TIMEOUT_MS = 100;
constexpr uint16_t FPGA_VALUE_MAX = 99;

constexpr uint32_t CAPTURE_TRANSFER_TIMEOUT_MS = 2500;
constexpr uint32_t CAPTURE_CONTROL_TIMEOUT_MS = 1500;
constexpr uint32_t CAPTURE_STATUS_INTERVAL_MS = 1000;
constexpr uint16_t CAPTURE_RECORD_CAPACITY = OcciliCapture::MAX_RECORDS;
constexpr uint16_t CAPTURE_ARTIFACT_BYTES = OcciliCapture::ARTIFACT_BYTES;

// Set to 1 only for short debugging sessions. Continuous USB mirroring can
// stall a sketch when no serial monitor is consuming the USB buffer.
#define DEBUG_UART_ECHO 0

// ============================================================
// Fixed-size runtime state
// ============================================================

WiFiServer webServer(80);
WiFiClient eventClient;
WiFiClient httpClient;

struct Telemetry {
  uint16_t value;
  uint8_t confirmedChannel;
  uint16_t adcLatest;
  uint32_t samplePeriodCycles;
  uint32_t packetCount;
  uint32_t packetsPerSecond;
  uint32_t lastPacketMillis;
  uint32_t invalidLineCount;
  bool valid;
};

Telemetry telemetry = {};

char uartLine[UART_LINE_SIZE] = {};
size_t uartLineLength = 0;
bool uartDiscardLine = false;
uint8_t binaryTelemetry[9] = {};
uint8_t binaryTelemetryIndex = 0;
uint32_t uartLastByteMillis = 0;
uint32_t lastTelemetryDebugMillis = 0;

constexpr size_t USB_COMMAND_SIZE = 32;
char usbCommand[USB_COMMAND_SIZE] = {};
size_t usbCommandLength = 0;

uint32_t packetRateWindowStart = 0;
uint32_t packetRateWindowCount = 0;

uint32_t commandsSent = 0;
uint32_t activeFpgaBaud = FPGA_UART_BAUD_HIGH;
uint32_t lastBaudSwitchMillis = 0;
bool fpgaBaudLocked = false;

bool wifiReady = false;
bool webServerStarted = false;
uint32_t nextWifiRetryMillis = 0;

bool ledState = false;
uint32_t nextLedChangeMillis = 0;

enum HttpState : uint8_t {
  HTTP_IDLE,
  HTTP_READING,
  HTTP_SENDING
};

HttpState httpState = HTTP_IDLE;
char httpRequestLine[HTTP_REQUEST_LINE_SIZE] = {};
size_t httpRequestLength = 0;
size_t httpCurrentLineLength = 0;
size_t httpHeaderBytes = 0;
bool httpRequestLineComplete = false;
bool httpRequestOverflow = false;
uint32_t httpLastProgressMillis = 0;

char httpResponse[HTTP_RESPONSE_SIZE] = {};
size_t httpResponseLength = 0;
size_t httpResponseOffset = 0;
const char* httpBody = nullptr;
size_t httpBodyLength = 0;
size_t httpBodyOffset = 0;
bool httpPromoteToEvents = false;
char captureStatusBody[HTTP_RESPONSE_SIZE] = {};

char sseMessage[1600] = {};
size_t sseMessageLength = 0;
uint32_t lastSseSendMillis = 0;
uint32_t lastSseProgressMillis = 0;
uint32_t sseDisconnectCount = 0;

struct GeneratorState {
  uint8_t gpioIndex;
  uint32_t requestedHz;
  uint32_t actualHz;
  uint8_t dutyPercent;
  bool enabled;
};

GeneratorState generators[2] = {
    {28, 1000, 1000, 50, false},
    {30, 1000, 1000, 50, false}
};

struct ChannelBucket {
  uint32_t sum;
  uint16_t count;
  uint16_t low;
  uint16_t high;
  uint16_t latest;
  bool valid;
};

ChannelBucket channelBuckets[ADC_CHANNEL_COUNT] = {};

struct RawPhoneSample {
  uint16_t adc;
  uint16_t deltaUs;
  uint8_t channel;
};

RawPhoneSample rawSampleQueue[RAW_SAMPLE_QUEUE_SIZE] = {};
uint8_t rawSampleHead = 0;
uint8_t rawSampleTail = 0;
uint8_t rawSampleCount = 0;
uint32_t previousRawSampleMicros = 0;
bool rawSampleClockValid = false;
uint32_t rawSampleDropped = 0;

// The frozen capture is kept in one bounded artifact buffer.  Keeping the
// header and records together means HTTP can stream it directly without a
// second 49 KiB staging copy, and the buffer is never modified once complete.
uint8_t captureArtifact[CAPTURE_ARTIFACT_BYTES] = {};

enum CaptureState : uint8_t {
  CAPTURE_IDLE,
  CAPTURE_ARMED,
  CAPTURE_RECEIVING,
  CAPTURE_COMPLETE,
  CAPTURE_STOPPED,
  CAPTURE_ERROR
};

CaptureState captureState = CAPTURE_IDLE;
OcciliCapture::FrameParser captureFrameParser;
uint32_t captureRequestId = 0;
uint32_t captureCaptureId = 0;
uint32_t captureLastControlId = 0;
uint32_t captureLastControlMillis = 0;
uint16_t captureExpectedRecords = 0;
uint16_t captureReceivedRecords = 0;
uint16_t captureExpectedSequence = 0;
uint16_t captureFocusChannel = 0;
uint32_t captureSamplePeriod = 0;
uint32_t captureStartTick = 0;
uint32_t captureTriggerIndex = 0xffffffffUL;
uint16_t captureFullScaleMv = 5000;
uint16_t captureConfigRevision = 0;
uint32_t captureConfigFingerprint = 0;
uint16_t captureFpgaRequestId = 0;
uint8_t captureAverageMode = 0;
uint8_t captureTriggerMode = 0;
uint16_t captureTriggerLevel = 0;
uint8_t captureRawFlags = 0;
uint8_t captureFlags = 0;
uint32_t captureWireFrames = 0;
uint32_t captureWireCrcErrors = 0;
uint32_t captureWireSequenceErrors = 0;
uint32_t captureWireDropped = 0;
uint32_t captureLastByteMillis = 0;
bool captureControlInFlight = false;
bool captureDownloadRequested = false;
bool captureFrozen = false;
uint8_t captureLastControlType = 0;
bool captureFpgaReady = false;
bool captureMetadataLocked = false;
uint32_t captureLastStatusRequestMillis = 0;

bool configureGenerator(uint8_t index, uint32_t frequencyHz,
                        uint8_t dutyPercent, bool enabled) {
  if (index >= 2 || frequencyHz < 1 || frequencyHz > GENERATOR_MAX_HZ ||
      dutyPercent > 100) return false;
  GeneratorState& generator = generators[index];
  uint32_t periodCycles = (50000000UL + frequencyHz / 2) / frequencyHz;
  if (periodCycles < 25) periodCycles = 25;
  uint32_t highCycles = static_cast<uint32_t>(
      (static_cast<uint64_t>(periodCycles) * dutyPercent + 50) / 100);
  uint8_t packet[12] = {0xA8, index,
      static_cast<uint8_t>(periodCycles >> 24), static_cast<uint8_t>(periodCycles >> 16),
      static_cast<uint8_t>(periodCycles >> 8), static_cast<uint8_t>(periodCycles),
      static_cast<uint8_t>(highCycles >> 24), static_cast<uint8_t>(highCycles >> 16),
      static_cast<uint8_t>(highCycles >> 8), static_cast<uint8_t>(highCycles),
      static_cast<uint8_t>(enabled ? 1 : 0), 0};
  for (uint8_t i=0;i<11;i++) packet[11]^=packet[i];
  for (uint8_t repeat=0;repeat<UART_COMMAND_REPEATS;repeat++)
    if (Serial1.write(packet,sizeof(packet))!=sizeof(packet)) return false;
  Serial1.flush();commandsSent++;
  generator.requestedHz = frequencyHz;
  generator.dutyPercent = dutyPercent;
  generator.enabled = enabled;
  generator.actualHz = enabled ? 50000000UL / periodCycles : 0;
  return true;
}

// ============================================================
// Browser application
// ============================================================

#include "web_page.h"

// ============================================================
// Utility helpers
// ============================================================

bool timeReached(uint32_t now, uint32_t target) {
  return static_cast<int32_t>(now - target) >= 0;
}

bool startsWith(const char* text, const char* prefix) {
  return strncmp(text, prefix, strlen(prefix)) == 0;
}

bool parseFourDigits(const char* text, uint16_t& value) {
  uint16_t result = 0;
  for (uint8_t index = 0; index < 4; index++) {
    const char character = text[index];
    if (character < '0' || character > '9') {
      return false;
    }
    result = static_cast<uint16_t>(result * 10U + static_cast<uint16_t>(character - '0'));
  }
  value = result;
  return true;
}

bool readQueryValue32(const char* request, const char* key, uint32_t maximum, uint32_t& value) {
  const char* query = strchr(request, '?');
  // The first request-line space is between "GET" and the URL. Search for
  // the URL-ending space only after locating '?', otherwise every valid query
  // is incorrectly rejected as appearing beyond the request boundary.
  const char* requestEnd = query == nullptr ? nullptr : strchr(query, ' ');
  if (query == nullptr || requestEnd == nullptr) {
    return false;
  }

  const size_t keyLength = strlen(key);
  const char* cursor = query + 1;
  while (cursor < requestEnd) {
    const char* equals = static_cast<const char*>(memchr(cursor, '=', static_cast<size_t>(requestEnd - cursor)));
    if (equals == nullptr) {
      return false;
    }
    const char* valueEnd = equals + 1;
    while (valueEnd < requestEnd && *valueEnd != '&') {
      valueEnd++;
    }

    if (static_cast<size_t>(equals - cursor) == keyLength && strncmp(cursor, key, keyLength) == 0) {
      if (equals + 1 == valueEnd) {
        return false;
      }
      uint32_t parsed = 0;
      for (const char* digit = equals + 1; digit < valueEnd; digit++) {
        if (*digit < '0' || *digit > '9') {
          return false;
        }
        parsed = parsed * 10UL + static_cast<uint32_t>(*digit - '0');
        if (parsed > maximum) {
          return false;
        }
      }
      value = parsed;
      return true;
    }
    cursor = valueEnd < requestEnd ? valueEnd + 1 : requestEnd;
  }
  return false;
}

bool readQueryValue(const char* request, const char* key, uint16_t maximum, uint16_t& value) {
  uint32_t parsed = 0;
  if (!readQueryValue32(request, key, maximum, parsed)) return false;
  value = static_cast<uint16_t>(parsed);
  return true;
}

// ============================================================
// UART receive and command queue
// ============================================================

void acceptFpgaSample(uint16_t value,uint8_t confirmedChannel,uint16_t adc,
                      uint32_t samplePeriodCycles) {
  telemetry.value=value;telemetry.confirmedChannel=confirmedChannel;
  telemetry.adcLatest=adc;
  if(samplePeriodCycles>0)telemetry.samplePeriodCycles=samplePeriodCycles;
  telemetry.packetCount++;telemetry.lastPacketMillis=millis();telemetry.valid=true;
  fpgaBaudLocked=true;packetRateWindowCount++;

  const uint32_t now=millis();
  if(now-lastTelemetryDebugMillis>=1000){
    lastTelemetryDebugMillis=now;
    Serial.print("FPGA -> PICO  VALUE=");Serial.print(value);
    Serial.print("  CHANNEL=");Serial.print(confirmedChannel);
    Serial.print("  ADC=");Serial.print(adc);
    Serial.print("  SAMPLE_CYCLES=");Serial.println(samplePeriodCycles);
  }

  ChannelBucket& bucket=channelBuckets[confirmedChannel];
  if(bucket.count==0){bucket.sum=adc;bucket.count=1;bucket.low=adc;bucket.high=adc;}
  else if(bucket.count<64){bucket.sum+=adc;bucket.count++;if(adc<bucket.low)bucket.low=adc;if(adc>bucket.high)bucket.high=adc;}
  else{bucket.sum=adc;bucket.count=1;bucket.low=adc;bucket.high=adc;}
  bucket.latest=adc;bucket.valid=true;

  const uint32_t sampleMicros=micros();
  const uint32_t elapsedUs=rawSampleClockValid?sampleMicros-previousRawSampleMicros:0;
  previousRawSampleMicros=sampleMicros;rawSampleClockValid=true;
  if(rawSampleCount==RAW_SAMPLE_QUEUE_SIZE){
    rawSampleTail=static_cast<uint8_t>((rawSampleTail+1U)%RAW_SAMPLE_QUEUE_SIZE);
    rawSampleCount--;
    rawSampleDropped++;
  }
  rawSampleQueue[rawSampleHead]={adc,static_cast<uint16_t>(elapsedUs>65535U?65535U:elapsedUs),confirmedChannel};
  rawSampleHead=static_cast<uint8_t>((rawSampleHead+1U)%RAW_SAMPLE_QUEUE_SIZE);rawSampleCount++;
}

void parseFpgaLine(const char* line, size_t length) {
  // Exact FPGA packet: data:FFFF:GGGG:AAAA
  if (length != 19 || memcmp(line, "data:", 5) != 0 || line[9] != ':' || line[14] != ':') {
    telemetry.invalidLineCount++;
    return;
  }

  uint16_t value = 0;
  uint16_t confirmedChannel = 0;
  uint16_t adc = 0;
  if (!parseFourDigits(line + 5, value) || !parseFourDigits(line + 10, confirmedChannel) ||
      !parseFourDigits(line + 15, adc) || value > FPGA_VALUE_MAX ||
      confirmedChannel >= ADC_CHANNEL_COUNT || adc > ADC_MAX_COUNT) {
    telemetry.invalidLineCount++;
    return;
  }

  acceptFpgaSample(value,static_cast<uint8_t>(confirmedChannel),adc,0);
}

static const char* captureStateName() {
  switch (captureState) {
    case CAPTURE_ARMED: return "armed";
    case CAPTURE_RECEIVING: return "receiving";
    case CAPTURE_COMPLETE: return "complete";
    case CAPTURE_STOPPED: return "stopped";
    case CAPTURE_ERROR: return "error";
    default: return "idle";
  }
}

void writeCaptureArtifactHeader() {
  uint8_t* header = captureArtifact;
  header[0] = 'O'; header[1] = 'C'; header[2] = 'A'; header[3] = 'P';
  header[4] = 1;
  header[5] = static_cast<uint8_t>(OcciliCapture::ARTIFACT_HEADER_BYTES);
  header[6] = captureFlags;
  header[7] = static_cast<uint8_t>(captureFocusChannel);
  OcciliCapture::writeU16LE(header + 8, captureReceivedRecords);
  OcciliCapture::writeU16LE(header + 10, OcciliCapture::RECORD_BYTES);
  OcciliCapture::writeU32LE(header + 12, captureSamplePeriod);
  OcciliCapture::writeU32LE(header + 16, captureCaptureId);
  OcciliCapture::writeU32LE(header + 20, captureTriggerIndex);
  OcciliCapture::writeU16LE(header + 24, captureFullScaleMv);
  OcciliCapture::writeU16LE(header + 26, captureConfigRevision);
  uint32_t firstTick = 0;
  if (captureReceivedRecords > 0) {
    firstTick = OcciliCapture::readU32LE(
        captureArtifact + OcciliCapture::ARTIFACT_HEADER_BYTES);
  }
  OcciliCapture::writeU32LE(header + 28, firstTick);
  // Extended metadata keeps the artifact self-describing when the web UI is
  // used without the live settings page.
  OcciliCapture::writeU32LE(header + 32, captureConfigFingerprint);
  header[36] = captureAverageMode;
  header[37] = captureTriggerMode;
  OcciliCapture::writeU16LE(header + 38, captureTriggerLevel);
  OcciliCapture::writeU32LE(header + 40, captureFpgaRequestId);
  OcciliCapture::writeU32LE(header + 44, 50000000UL);
  header[48] = captureRawFlags;
  for (uint8_t index = 49; index < OcciliCapture::ARTIFACT_HEADER_BYTES; ++index) {
    header[index] = 0;
  }
}

void rejectCapture(const char* reason) {
  captureFlags |= 0x04U;
  captureState = CAPTURE_ERROR;
  captureFrozen = false;
  captureControlInFlight = false;
  captureDownloadRequested = false;
  Serial.print("Capture rejected: "); Serial.println(reason);
}

void acceptCapturePacket(const uint8_t* packet, void*) {
  const uint8_t type = packet[2];
  const uint8_t flags = packet[3];
  const uint16_t requestId = OcciliCapture::readU16BE(packet + 4);
  const uint16_t captureId = OcciliCapture::readU16BE(packet + 6);
  const uint16_t sequence = OcciliCapture::readU16BE(packet + 8);
  const uint16_t totalRecords = OcciliCapture::readU16BE(packet + 10);
  const uint8_t channel = packet[12];
  const uint8_t recordsInBlock = packet[26];

  // D6 packets carry only a 16-bit request id. A stale response from a
  // previous download must never append to the current frozen artifact.
  if (captureFpgaRequestId != 0 && requestId != captureFpgaRequestId) return;
  if (type == OcciliCapture::FRAME_ERROR) {
    captureDownloadRequested = false;
    rejectCapture("FPGA capture error");
    return;
  }
  if (channel >= ADC_CHANNEL_COUNT || recordsInBlock > OcciliCapture::BLOCK_RECORDS ||
      (type != OcciliCapture::FRAME_STATUS && totalRecords == 0) ||
      totalRecords > CAPTURE_RECORD_CAPACITY) {
    rejectCapture("D6 metadata is out of range");
    return;
  }

  const uint8_t averageMode = packet[13];
  const uint8_t triggerMode = packet[14];
  const uint16_t triggerLevel = OcciliCapture::readU16BE(packet + 15);
  uint32_t triggerIndex = OcciliCapture::readU16BE(packet + 17);
  const uint32_t samplePeriod = (static_cast<uint32_t>(packet[19]) << 16) |
                                (static_cast<uint32_t>(packet[20]) << 8) |
                                static_cast<uint32_t>(packet[21]);
  const uint32_t firstTick = OcciliCapture::readU32BE(packet + 22);
  const uint32_t configFingerprint = OcciliCapture::readU32BE(packet + 27);
  const uint16_t fullScaleMv = OcciliCapture::readU16BE(packet + 31);
  if (fullScaleMv < 1000 || fullScaleMv > 9999) {
    rejectCapture("D6 calibration metadata is invalid");
    return;
  }
  if ((flags & OcciliCapture::FLAG_TRIGGERED) == 0 && triggerIndex == 0) {
    triggerIndex = 0xffffffffUL;
  }

  captureRawFlags = flags;
  captureFpgaRequestId = requestId;
  captureCaptureId = captureId;
  captureLastByteMillis = millis();
  captureControlInFlight = false;

  if (type == OcciliCapture::FRAME_STATUS) {
    captureExpectedRecords = totalRecords;
    captureFocusChannel = channel;
    captureAverageMode = averageMode;
    captureTriggerMode = triggerMode;
    captureTriggerLevel = triggerLevel;
    captureTriggerIndex = triggerIndex;
    captureSamplePeriod = samplePeriod;
    captureStartTick = firstTick;
    captureConfigFingerprint = configFingerprint;
    captureFullScaleMv = fullScaleMv;
    captureConfigRevision = 0;
    captureMetadataLocked = false;
    if (captureLastControlType == OcciliCapture::COMMAND_STOP) {
      captureState = CAPTURE_STOPPED;
      captureFrozen = false;
      captureFpgaReady = false;
    } else if ((flags & OcciliCapture::FLAG_INVALID) != 0) {
      rejectCapture("FPGA reported an invalid capture");
    } else if ((flags & OcciliCapture::FLAG_COMPLETE) != 0 &&
               (flags & OcciliCapture::FLAG_VALID) != 0) {
      // This is device readiness only. The Pico artifact becomes complete
      // after a separate DOWNLOAD and every DATA block has passed checks.
      captureState = CAPTURE_ARMED;
      captureFrozen = false;
      captureFpgaReady = true;
    } else {
      captureState = CAPTURE_ARMED;
      captureFrozen = false;
      captureFpgaReady = false;
    }
    return;
  }

  if ((flags & OcciliCapture::FLAG_COMPLETE) == 0 ||
      (flags & OcciliCapture::FLAG_VALID) == 0 ||
      (flags & OcciliCapture::FLAG_INVALID) != 0) {
    rejectCapture("D6 data is not marked complete and valid");
    return;
  }

  if (!captureMetadataLocked) {
    if (captureExpectedRecords != 0 && captureExpectedRecords != totalRecords) {
      rejectCapture("D6 record count changed during download");
      return;
    }
    captureExpectedRecords = totalRecords;
    captureFocusChannel = channel;
    captureAverageMode = averageMode;
    captureTriggerMode = triggerMode;
    captureTriggerLevel = triggerLevel;
    captureTriggerIndex = triggerIndex;
    captureSamplePeriod = samplePeriod;
    captureStartTick = firstTick;
    captureConfigFingerprint = configFingerprint;
    captureFullScaleMv = fullScaleMv;
    captureConfigRevision = 0;
    captureMetadataLocked = true;
  } else if (captureExpectedRecords != totalRecords || captureFocusChannel != channel ||
             captureAverageMode != averageMode || captureTriggerMode != triggerMode ||
             captureTriggerLevel != triggerLevel || captureTriggerIndex != triggerIndex ||
             captureSamplePeriod != samplePeriod || captureConfigFingerprint != configFingerprint ||
             captureFullScaleMv != fullScaleMv) {
    rejectCapture("D6 metadata changed during download");
    return;
  }

  if (type == OcciliCapture::FRAME_DATA) {
    if (captureFrozen || captureState == CAPTURE_IDLE || captureState == CAPTURE_STOPPED ||
        sequence != captureExpectedSequence || recordsInBlock == 0 ||
        captureReceivedRecords + recordsInBlock > captureExpectedRecords) {
      ++captureWireSequenceErrors;
      captureFlags |= 0x04U;
      return;
    }
    for (uint8_t index = 0; index < recordsInBlock; ++index) {
      const uint8_t* wireRecord = packet + OcciliCapture::HEADER_BYTES +
                                   static_cast<size_t>(index) * OcciliCapture::RECORD_BYTES;
      uint8_t* fileRecord = captureArtifact + OcciliCapture::ARTIFACT_HEADER_BYTES +
                            static_cast<size_t>(captureReceivedRecords + index) *
                                OcciliCapture::RECORD_BYTES;
      const uint16_t sample = OcciliCapture::readU16BE(wireRecord);
      const uint32_t tick = OcciliCapture::readU32BE(wireRecord + 2);
      if (sample > ADC_MAX_COUNT) {
        rejectCapture("D6 sample is outside the 12-bit ADC range");
        return;
      }
      OcciliCapture::writeU32LE(fileRecord, tick);
      OcciliCapture::writeU16LE(fileRecord + 4, sample);
    }
    captureReceivedRecords = static_cast<uint16_t>(captureReceivedRecords + recordsInBlock);
    captureExpectedSequence = static_cast<uint16_t>(sequence + 1U);
    captureState = CAPTURE_RECEIVING;
    captureFrozen = false;
    return;
  }

  if (type == OcciliCapture::FRAME_DONE) {
    // scope_capture keeps the final DATA block sequence in the DONE header;
    // accept either that repeated sequence or the next logical number.
    const bool doneSequence = sequence == captureExpectedSequence ||
                               (captureExpectedSequence != 0 &&
                                sequence + 1U == captureExpectedSequence);
    if (!doneSequence || captureReceivedRecords != captureExpectedRecords ||
        (flags & OcciliCapture::FLAG_COMPLETE) == 0 ||
        (flags & OcciliCapture::FLAG_VALID) == 0 ||
        (flags & OcciliCapture::FLAG_INVALID) != 0) {
      rejectCapture("D6 DONE did not match the received record set");
      return;
    }
    captureFlags = 0x01U;
    if ((flags & OcciliCapture::FLAG_TRIGGERED) != 0) captureFlags |= 0x02U;
    writeCaptureArtifactHeader();
    captureFrozen = true;
    captureState = CAPTURE_COMPLETE;
    Serial.print("Capture complete: "); Serial.print(captureReceivedRecords);
    Serial.println(" records");
    return;
  }

}

bool sendCaptureControl(uint8_t type, uint32_t requestId) {
  uint8_t command[5] = {
      OcciliCapture::COMMAND_MAGIC, type,
      static_cast<uint8_t>(requestId >> 8), static_cast<uint8_t>(requestId), 0
  };
  command[4] = static_cast<uint8_t>(command[0] ^ command[1] ^ command[2] ^ command[3]);
  if (Serial1.write(command, sizeof(command)) != sizeof(command)) return false;
  Serial1.flush();
  commandsSent++;
  captureLastControlId = requestId;
  captureLastControlType = type;
  captureLastControlMillis = millis();
  captureControlInFlight = true;
  return true;
}

uint32_t nextCaptureRequestId() {
  ++captureRequestId;
  if (captureRequestId == 0) ++captureRequestId;
  // The FPGA wire id is 16 bits; avoid zero so the stale-response guard is
  // active across the wrap of the Pico-side monotonic request counter.
  if ((captureRequestId & 0xffffUL) == 0) ++captureRequestId;
  return captureRequestId;
}

bool armCapture(bool vgaSnapshot = false) {
  if (captureState == CAPTURE_ARMED || captureState == CAPTURE_RECEIVING) return true;
  const uint32_t id = nextCaptureRequestId();
  captureState = CAPTURE_ARMED;
  captureFrozen = false;
  captureDownloadRequested = false;
  captureControlInFlight = false;
  captureExpectedRecords = 0;
  captureReceivedRecords = 0;
  captureExpectedSequence = 0;
  captureFlags = 0;
  captureLastControlType = 0;
  captureRawFlags = 0;
  captureConfigFingerprint = 0;
  captureFpgaRequestId = static_cast<uint16_t>(id);
  captureFpgaReady = false;
  captureMetadataLocked = false;
  captureLastStatusRequestMillis = 0;
  captureWireSequenceErrors = 0;
  captureWireDropped = 0;
  captureLastByteMillis = 0;
  captureFrameParser.reset();
  return sendCaptureControl(vgaSnapshot ? OcciliCapture::COMMAND_VGA_SNAPSHOT :
                            OcciliCapture::COMMAND_ARM, id);
}

bool requestCaptureDownload() {
  if (captureState == CAPTURE_COMPLETE) return true;
  if (captureState == CAPTURE_STOPPED || captureState == CAPTURE_IDLE ||
      (!captureFpgaReady && captureState == CAPTURE_ERROR)) return false;
  if (captureDownloadRequested) return true;
  const uint32_t id = captureRequestId == 0 ? nextCaptureRequestId() : captureRequestId;
  captureFrameParser.reset();
  captureReceivedRecords = 0;
  captureExpectedSequence = 0;
  captureFlags = 0;
  captureFrozen = false;
  captureState = CAPTURE_ARMED;
  captureMetadataLocked = false;
  captureLastByteMillis = 0;
  const bool sent = sendCaptureControl(OcciliCapture::COMMAND_DOWNLOAD, id);
  captureDownloadRequested = sent;
  return sent;
}

bool stopCapture() {
  if (captureState == CAPTURE_IDLE || captureState == CAPTURE_STOPPED) return true;
  const uint32_t id = captureRequestId == 0 ? nextCaptureRequestId() : captureRequestId;
  const bool sent = sendCaptureControl(OcciliCapture::COMMAND_STOP, id);
  captureControlInFlight = false;
  captureState = CAPTURE_STOPPED;
  captureFrozen = false;
  captureFpgaReady = false;
  captureDownloadRequested = false;
  return sent;
}

void serviceCaptureProtocol() {
  const uint32_t now = millis();
  captureWireFrames = captureFrameParser.frames();
  captureWireCrcErrors = captureFrameParser.badCrc();
  if ((captureState == CAPTURE_RECEIVING || captureState == CAPTURE_ARMED) &&
      captureLastByteMillis != 0 &&
      now - captureLastByteMillis > CAPTURE_TRANSFER_TIMEOUT_MS) {
    captureFrameParser.reset();
    rejectCapture("capture transfer timed out");
  }
  if (captureControlInFlight &&
      now - captureLastControlMillis > CAPTURE_CONTROL_TIMEOUT_MS &&
      captureState == CAPTURE_ARMED) {
    captureControlInFlight = false;
  }
  // The FPGA does not push a completion event. Poll it while armed so the
  // browser can learn when a frozen record is ready for DOWNLOAD.
  if (captureState == CAPTURE_ARMED && !captureFpgaReady &&
      !captureControlInFlight &&
      now - captureLastStatusRequestMillis >= CAPTURE_STATUS_INTERVAL_MS) {
    captureLastStatusRequestMillis = now;
    sendCaptureControl(OcciliCapture::COMMAND_STATUS, captureRequestId);
  }
}

void setFpgaBaud(uint32_t baud) {
  Serial1.end();
  Serial1.setTX(FPGA_UART_TX_PIN);
  Serial1.setRX(FPGA_UART_RX_PIN);
  Serial1.begin(baud, SERIAL_8N1);
  activeFpgaBaud = baud;
  lastBaudSwitchMillis = millis();
  uartLineLength = 0;
  uartDiscardLine = false;
  binaryTelemetryIndex = 0;
  captureFrameParser.reset();
  captureLastByteMillis = 0;
  Serial.print("FPGA UART probing "); Serial.print(baud); Serial.println(" baud");
}

void serviceFpgaAutoBaud() {
  // A capture transfer is a contiguous binary stream.  Re-probing the UART
  // while telemetry happens to be quiet would split that stream and make the
  // frozen record unverifiable.
  if (captureState == CAPTURE_ARMED || captureState == CAPTURE_RECEIVING) return;
  const uint32_t now = millis();
  const bool fresh = telemetry.valid && now - telemetry.lastPacketMillis <= UART_ACTIVE_TIMEOUT_MS;
  if (fresh) return;
  if (fpgaBaudLocked) {
    fpgaBaudLocked = false;
    telemetry.valid = false;
    lastBaudSwitchMillis = now - UART_BAUD_SCAN_MS;
  }
  if (now - lastBaudSwitchMillis >= UART_BAUD_SCAN_MS) {
    setFpgaBaud(activeFpgaBaud == FPGA_UART_BAUD_HIGH ?
                FPGA_UART_BAUD_LOW : FPGA_UART_BAUD_HIGH);
  }
}

void readFpgaUart() {
  const uint32_t now = millis();
  if (captureFrameParser.active() && captureLastByteMillis != 0 &&
      now - captureLastByteMillis > UART_LINE_TIMEOUT_MS) {
    captureFrameParser.clearPartial();
    if (captureState == CAPTURE_RECEIVING) rejectCapture("D6 frame timed out");
  }
  if ((uartLineLength > 0 || uartDiscardLine || binaryTelemetryIndex > 0) &&
      now - uartLastByteMillis > UART_LINE_TIMEOUT_MS) {
    uartLineLength = 0;
    uartDiscardLine = false;
    binaryTelemetryIndex = 0;
    telemetry.invalidLineCount++;
  }
  while (Serial1.available() > 0) {
    const uint8_t incomingByte=static_cast<uint8_t>(Serial1.read());
    const char incoming=static_cast<char>(incomingByte);
    uartLastByteMillis = millis();

#if DEBUG_UART_ECHO
    if (Serial.availableForWrite() > 0) {
      Serial.write(static_cast<uint8_t>(incoming));
    }
#endif

    // A D6 byte inside the nine-byte D5 telemetry packet belongs to that
    // packet. Once D5 has started, let the legacy parser consume all nine
    // bytes before looking for a capture frame again.
    const bool captureWasIdle = !captureFrameParser.active();
    if (binaryTelemetryIndex == 0 &&
        captureFrameParser.feed(incomingByte, acceptCapturePacket, nullptr)) {
      if (captureWasIdle) {
        uartLineLength = 0;
        uartDiscardLine = false;
      }
      fpgaBaudLocked = true;
      captureLastByteMillis = millis();
      continue;
    }

    if(binaryTelemetryIndex>0||incomingByte==0xD5){
      if(binaryTelemetryIndex==0){binaryTelemetry[0]=incomingByte;binaryTelemetryIndex=1;continue;}
      binaryTelemetry[binaryTelemetryIndex++]=incomingByte;
      if(binaryTelemetryIndex==sizeof(binaryTelemetry)){
        uint8_t checksum=0;for(uint8_t index=0;index<8;index++)checksum^=binaryTelemetry[index];
        const uint8_t channel=binaryTelemetry[1];
        const uint16_t adc=static_cast<uint16_t>((binaryTelemetry[2]&0x0fU)<<8)|binaryTelemetry[3];
        const uint32_t period=(static_cast<uint32_t>(binaryTelemetry[4])<<16)|
            (static_cast<uint32_t>(binaryTelemetry[5])<<8)|binaryTelemetry[6];
        const uint8_t value=binaryTelemetry[7];
        if(checksum==binaryTelemetry[8]&&channel<ADC_CHANNEL_COUNT&&adc<=ADC_MAX_COUNT&&value<=FPGA_VALUE_MAX&&period>0){
          acceptFpgaSample(value,channel,adc,period);binaryTelemetryIndex=0;
        }else{
          telemetry.invalidLineCount++;
          binaryTelemetryIndex=incomingByte==0xD5?1:0;
          if(binaryTelemetryIndex)binaryTelemetry[0]=0xD5;
        }
      }
      continue;
    }

    if (incoming == '\r') {
      continue;
    }
    if (incoming == '\n') {
      if (!uartDiscardLine && uartLineLength > 0) {
        uartLine[uartLineLength] = '\0';
        parseFpgaLine(uartLine, uartLineLength);
      } else if (uartDiscardLine) {
        telemetry.invalidLineCount++;
      }
      uartLineLength = 0;
      uartDiscardLine = false;
      continue;
    }
    if (uartDiscardLine) {
      continue;
    }
    if (uartLineLength < UART_LINE_SIZE - 1) {
      uartLine[uartLineLength++] = incoming;
    } else {
      uartLineLength = 0;
      uartDiscardLine = true;
    }
  }
}

bool sendFpgaSettings(uint8_t channel, uint16_t value, bool verbose=true) {
  if (channel >= ADC_CHANNEL_COUNT || value > FPGA_VALUE_MAX) {
    return false;
  }

  const uint8_t packet[] = {
      0xA5, channel, static_cast<uint8_t>(value),
      static_cast<uint8_t>(0xA5U ^ channel ^ static_cast<uint8_t>(value))
  };

  if(verbose) {
    Serial.print("PICO -> FPGA  bytes: A5 ");
    if(channel<0x10)Serial.print('0');Serial.print(channel,HEX);Serial.print(' ');
    if(value<0x10)Serial.print('0');Serial.print(value,HEX);Serial.print(' ');
    if(packet[3]<0x10)Serial.print('0');Serial.print(packet[3],HEX);
    Serial.print("  (channel=");Serial.print(channel);Serial.print(", VALUE=");Serial.print(value);Serial.println(')');
  }

  // Block until three checked packets physically leave GP0 (about 13 ms).
  for (uint8_t repeat = 0; repeat < UART_COMMAND_REPEATS; repeat++) {
    const size_t sent = Serial1.write(packet, sizeof(packet));
    if (sent != sizeof(packet)) {
      Serial.print("PICO UART WRITE ERROR: wrote "); Serial.print(sent);
      Serial.print(" of "); Serial.println(sizeof(packet));
      return false;
    }
  }
  Serial1.flush();
  if(verbose)Serial.println("PICO -> FPGA  transmission complete (3 copies)");
  commandsSent++;

  return true;
}

bool setChannelSelection(uint8_t mask, uint8_t focus, uint16_t value) {
  mask &= 0x3f;
  if (mask == 0 || focus >= ADC_CHANNEL_COUNT || value > FPGA_VALUE_MAX) return false;
  mask |= static_cast<uint8_t>(1U << focus);
  uint8_t packet[5]={0xA9,mask,focus,static_cast<uint8_t>(value),0};
  for(uint8_t index=0;index<4;index++)packet[4]^=packet[index];
  for(uint8_t repeat=0;repeat<UART_COMMAND_REPEATS;repeat++)
    if(Serial1.write(packet,sizeof(packet))!=sizeof(packet))return false;
  Serial1.flush();commandsSent++;
  return true;
}

bool sendFpgaDisplaySettings(uint8_t timebase, uint8_t scale,
                             uint8_t position, uint8_t triggerMode,
                             uint16_t triggerLevel, bool grid, bool run,
                             uint8_t triggerPosition, bool singleShot,
                             uint8_t averageMode, bool stabilize) {
  if (timebase > 10 || scale > 3 || position > 100 || triggerMode > 3 ||
      triggerLevel > ADC_MAX_COUNT || triggerPosition > 3 || averageMode > 3) {
    return false;
  }
  const uint8_t flags = (grid ? 0x01U : 0x00U) | (run ? 0x02U : 0x00U) |
      static_cast<uint8_t>(triggerPosition << 2) | (singleShot ? 0x10U : 0x00U) |
      static_cast<uint8_t>(averageMode << 5) | (stabilize ? 0x80U : 0x00U);
  uint8_t packet[] = {
      0xA6, timebase, scale, position, triggerMode,
      static_cast<uint8_t>(triggerLevel >> 8),
      static_cast<uint8_t>(triggerLevel), flags, 0
  };
  uint8_t checksum = 0;
  for (size_t index = 0; index < sizeof(packet) - 1; index++) checksum ^= packet[index];
  packet[sizeof(packet) - 1] = checksum;

  for (uint8_t repeat = 0; repeat < UART_COMMAND_REPEATS; repeat++) {
    if (Serial1.write(packet, sizeof(packet)) != sizeof(packet)) return false;
  }
  Serial1.flush();
  commandsSent++;
  Serial.print("VGA -> FPGA  timebase=X"); Serial.print(1U << timebase);
  Serial.print(" vertical=X"); Serial.print(1U << scale);
  Serial.print(" position="); Serial.print(position);
  Serial.print(" trigger="); Serial.print(triggerMode);
  Serial.print(" level="); Serial.print(triggerLevel);
  Serial.print(" grid="); Serial.print(grid ? "on" : "off");
  Serial.print(" run="); Serial.println(run ? "yes" : "hold");
  return true;
}

bool sendFpgaFullScale(uint16_t millivolts) {
  if (millivolts < 1000 || millivolts > 9999) return false;
  uint8_t packet[4] = {
      0xA7, static_cast<uint8_t>(millivolts >> 8),
      static_cast<uint8_t>(millivolts), 0
  };
  packet[3] = packet[0] ^ packet[1] ^ packet[2];
  for (uint8_t repeat = 0; repeat < UART_COMMAND_REPEATS; repeat++) {
    if (Serial1.write(packet, sizeof(packet)) != sizeof(packet)) return false;
  }
  Serial1.flush();
  commandsSent++;
  return true;
}

void processUsbCommand(const char* line) {
  unsigned channel = 0;
  unsigned value = 0;
  const int parsedWithWord = sscanf(line, "set %u %u", &channel, &value);
  const int parsedBare = parsedWithWord == 2 ? 0 : sscanf(line, "%u %u", &channel, &value);
  if (parsedWithWord != 2 && parsedBare != 2) {
    Serial.println("USB command error. Type: set <channel 0-5> <VALUE 0-99>");
    Serial.println("Example: set 3 42");
    return;
  }
  if (channel >= ADC_CHANNEL_COUNT || value > FPGA_VALUE_MAX) {
    Serial.println("USB command out of range: channel 0-5, VALUE 0-99");
    return;
  }

  Serial.print("USB command accepted: channel="); Serial.print(channel);
  Serial.print(" VALUE="); Serial.println(value);
  if (!setChannelSelection(static_cast<uint8_t>(1U<<channel),static_cast<uint8_t>(channel),static_cast<uint16_t>(value))) {
    Serial.println("USB command UART transmission failed");
  }
}

void serviceUsbCommands() {
  while (Serial.available() > 0) {
    const char incoming = static_cast<char>(Serial.read());
    if (incoming == '\r') continue;
    if (incoming == '\n') {
      if (usbCommandLength > 0) {
        usbCommand[usbCommandLength] = '\0';
        processUsbCommand(usbCommand);
        usbCommandLength = 0;
      }
      continue;
    }
    if (usbCommandLength < USB_COMMAND_SIZE - 1) {
      usbCommand[usbCommandLength++] = incoming;
    } else {
      usbCommandLength = 0;
      Serial.println("USB command too long; discarded");
    }
  }
}

void updatePacketRate() {
  const uint32_t now = millis();
  const uint32_t elapsed = now - packetRateWindowStart;
  if (elapsed < 1000) {
    return;
  }
  telemetry.packetsPerSecond = elapsed > 0
      ? static_cast<uint32_t>((packetRateWindowCount * 1000UL) / elapsed)
      : 0;
  packetRateWindowCount = 0;
  packetRateWindowStart = now;
}

// ============================================================
// Incremental HTTP server
// ============================================================

void resetHttpState(bool stopClient) {
  if (stopClient && httpClient) {
    httpClient.stop();
  }
  httpClient = WiFiClient();
  httpState = HTTP_IDLE;
  httpRequestLength = 0;
  httpCurrentLineLength = 0;
  httpHeaderBytes = 0;
  httpRequestLineComplete = false;
  httpRequestOverflow = false;
  httpResponseLength = 0;
  httpResponseOffset = 0;
  httpBody = nullptr;
  httpBodyLength = 0;
  httpBodyOffset = 0;
  httpPromoteToEvents = false;
}

void queueSmallResponse(int statusCode, const char* statusText, const char* contentType,
                        const char* body) {
  const size_t bodyLength = body != nullptr ? strlen(body) : 0;
  const int written = snprintf(
      httpResponse, sizeof(httpResponse),
      "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nCache-Control: no-store\r\n"
      "Connection: close\r\nContent-Length: %lu\r\n\r\n%s",
      statusCode, statusText, contentType, static_cast<unsigned long>(bodyLength),
      body != nullptr ? body : "");

  if (written < 0) {
    resetHttpState(true);
    return;
  }
  httpResponseLength = static_cast<size_t>(written);
  if (httpResponseLength >= sizeof(httpResponse)) {
    httpResponseLength = sizeof(httpResponse) - 1;
  }
  httpResponseOffset = 0;
  httpBody = nullptr;
  httpBodyLength = 0;
  httpBodyOffset = 0;
  httpPromoteToEvents = false;
  httpLastProgressMillis = millis();
  httpState = HTTP_SENDING;
}

void queueWebPage() {
  const int written = snprintf(
      httpResponse, sizeof(httpResponse),
      "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
      "Cache-Control: no-store\r\nConnection: close\r\nContent-Length: %lu\r\n\r\n",
      static_cast<unsigned long>(sizeof(WEB_PAGE) - 1));
  httpResponseLength = written > 0 ? static_cast<size_t>(written) : 0;
  httpResponseOffset = 0;
  httpBody = WEB_PAGE;
  httpBodyLength = sizeof(WEB_PAGE) - 1;
  httpBodyOffset = 0;
  httpPromoteToEvents = false;
  httpLastProgressMillis = millis();
  httpState = HTTP_SENDING;
}

void queueEventStreamHeader() {
  static constexpr char EVENT_HEADER[] =
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
      "Cache-Control: no-cache\r\nConnection: keep-alive\r\n"
      "Access-Control-Allow-Origin: *\r\n\r\nretry: 1000\r\n\r\n";
  memcpy(httpResponse, EVENT_HEADER, sizeof(EVENT_HEADER) - 1);
  httpResponseLength = sizeof(EVENT_HEADER) - 1;
  httpResponseOffset = 0;
  httpBody = nullptr;
  httpBodyLength = 0;
  httpBodyOffset = 0;
  httpPromoteToEvents = true;
  httpLastProgressMillis = millis();
  httpState = HTTP_SENDING;
}

void queueCaptureStatus() {
  const bool complete = captureState == CAPTURE_COMPLETE && captureFrozen;
  const bool valid = complete && (captureFlags & 0x05U) == 0x01U;
  const int bodyLength = snprintf(
      captureStatusBody, sizeof(captureStatusBody),
      "{\"state\":\"%s\",\"complete\":%s,\"valid\":%s,"
      "\"fpgaReady\":%s,\"dataReady\":%s,\"downloadable\":%s,"
      "\"armed\":%s,\"downloading\":%s,\"request\":%lu,"
      "\"capture\":%lu,\"received\":%u,\"expected\":%u,"
      "\"channel\":%u,\"period\":%lu,\"trigger\":%lu,"
      "\"crcErrors\":%lu,\"sequenceErrors\":%lu,"
      "\"dropped\":%lu,\"wireFrames\":%lu,\"format\":1}",
      captureStateName(), complete ? "true" : "false", valid ? "true" : "false",
      captureFpgaReady ? "true" : "false", valid ? "true" : "false",
      valid ? "true" : "false",
      (captureState == CAPTURE_ARMED || captureState == CAPTURE_RECEIVING) ? "true" : "false",
      captureDownloadRequested ? "true" : "false",
      static_cast<unsigned long>(captureRequestId),
      static_cast<unsigned long>(captureCaptureId),
      static_cast<unsigned>(captureReceivedRecords),
      static_cast<unsigned>(captureExpectedRecords),
      static_cast<unsigned>(captureFocusChannel),
      static_cast<unsigned long>(captureSamplePeriod),
      static_cast<unsigned long>(captureTriggerIndex),
      static_cast<unsigned long>(captureWireCrcErrors),
      static_cast<unsigned long>(captureWireSequenceErrors),
      static_cast<unsigned long>(captureWireDropped),
      static_cast<unsigned long>(captureWireFrames));
  if (bodyLength < 0 || bodyLength >= static_cast<int>(sizeof(captureStatusBody))) {
    queueSmallResponse(500, "Internal Server Error", "text/plain", "Capture status is too large.");
    return;
  }
  queueSmallResponse(200, "OK", "application/json", captureStatusBody);
}

void queueCaptureArtifact() {
  const bool valid = captureState == CAPTURE_COMPLETE && captureFrozen &&
                     (captureFlags & 0x05U) == 0x01U;
  if (!valid) {
    queueSmallResponse(409, "Conflict", "application/json",
                       "{\"error\":\"capture is not complete and validated\"}");
    return;
  }
  writeCaptureArtifactHeader();
  const size_t artifactLength = OcciliCapture::ARTIFACT_HEADER_BYTES +
      static_cast<size_t>(captureReceivedRecords) * OcciliCapture::RECORD_BYTES;
  const int written = snprintf(
      httpResponse, sizeof(httpResponse),
      "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
      "Content-Disposition: attachment; filename=occilliscope-capture.ocap\r\n"
      "Cache-Control: no-store\r\nConnection: close\r\nContent-Length: %lu\r\n\r\n",
      static_cast<unsigned long>(artifactLength));
  if (written < 0 || written >= static_cast<int>(sizeof(httpResponse))) {
    queueSmallResponse(500, "Internal Server Error", "text/plain", "Capture response is too large.");
    return;
  }
  httpResponseLength = static_cast<size_t>(written);
  httpResponseOffset = 0;
  httpBody = reinterpret_cast<const char*>(captureArtifact);
  httpBodyLength = artifactLength;
  httpBodyOffset = 0;
  httpPromoteToEvents = false;
  httpLastProgressMillis = millis();
  httpState = HTTP_SENDING;
}

void routeHttpRequest() {
  if (httpRequestOverflow) {
    queueSmallResponse(414, "URI Too Long", "text/plain", "Request line is too long.");
    return;
  }

  if (startsWith(httpRequestLine, "GET /api/capture/status")) {
    queueCaptureStatus();
    return;
  }
  if (startsWith(httpRequestLine, "GET /api/capture/snapshot")) {
    if (!armCapture(true)) {
      queueSmallResponse(503, "Service Unavailable", "application/json",
                         "{\"error\":\"VGA snapshot command could not be sent\"}");
      return;
    }
    queueCaptureStatus();
    return;
  }
  if (startsWith(httpRequestLine, "GET /api/capture/arm")) {
    if (!armCapture()) {
      queueSmallResponse(503, "Service Unavailable", "application/json",
                         "{\"error\":\"capture arm command could not be sent\"}");
      return;
    }
    queueCaptureStatus();
    return;
  }
  if (startsWith(httpRequestLine, "GET /api/capture/download")) {
    if (!requestCaptureDownload()) {
      queueSmallResponse(409, "Conflict", "application/json",
                         "{\"error\":\"capture is not armed or complete\"}");
      return;
    }
    queueCaptureStatus();
    return;
  }
  if (startsWith(httpRequestLine, "GET /api/capture/stop")) {
    if (!stopCapture()) {
      queueSmallResponse(503, "Service Unavailable", "application/json",
                         "{\"error\":\"capture stop command could not be sent\"}");
      return;
    }
    queueCaptureStatus();
    return;
  }
  if (startsWith(httpRequestLine, "GET /api/capture/data")) {
    queueCaptureArtifact();
    return;
  }

  if (startsWith(httpRequestLine, "GET /api/channels?")) {
    uint16_t mask=0,focus=0,value=0;
    if(!readQueryValue(httpRequestLine,"mask",63,mask)||mask==0||
       !readQueryValue(httpRequestLine,"focus",ADC_CHANNEL_COUNT-1,focus)||
       !readQueryValue(httpRequestLine,"value",FPGA_VALUE_MAX,value)) {
      queueSmallResponse(400,"Bad Request","text/plain","Use mask=1..63, focus=0..5, value=0..99.");return;
    }
    if(!setChannelSelection(static_cast<uint8_t>(mask),static_cast<uint8_t>(focus),value)) {
      queueSmallResponse(503,"Service Unavailable","text/plain","FPGA UART transmission failed.");return;
    }
    queueSmallResponse(200,"OK","application/json","{\"scanning\":true}");return;
  }

  if (startsWith(httpRequestLine, "GET /api/set?")) {
    uint16_t channel = 0;
    uint16_t value = 0;
    if (!readQueryValue(httpRequestLine, "ch", ADC_CHANNEL_COUNT - 1, channel) ||
        !readQueryValue(httpRequestLine, "value", FPGA_VALUE_MAX, value)) {
      Serial.print("HTTP SET rejected: "); Serial.println(httpRequestLine);
      queueSmallResponse(400, "Bad Request", "text/plain",
                         "Use ch=0..5 and value=0..99.");
      return;
    }
    Serial.print("HTTP SET received: channel="); Serial.print(channel);
    Serial.print(" VALUE="); Serial.println(value);
    if (!setChannelSelection(static_cast<uint8_t>(1U<<channel),static_cast<uint8_t>(channel),value)) {
      queueSmallResponse(503, "Service Unavailable", "text/plain",
                         "FPGA UART transmission failed. Try again.");
      return;
    }
    queueSmallResponse(200, "OK", "application/json", "{\"sent\":true}");
    return;
  }

  if (startsWith(httpRequestLine, "GET /api/display?")) {
    uint16_t timebase=0, scale=0, position=0, trigger=0;
    uint16_t level=0, grid=0, run=0, triggerPosition=0, singleShot=0, averageMode=0, stabilize=0;
    if (!readQueryValue(httpRequestLine,"tb",10,timebase) ||
        !readQueryValue(httpRequestLine,"scale",3,scale) ||
        !readQueryValue(httpRequestLine,"pos",100,position) ||
        !readQueryValue(httpRequestLine,"trig",3,trigger) ||
        !readQueryValue(httpRequestLine,"level",ADC_MAX_COUNT,level) ||
        !readQueryValue(httpRequestLine,"grid",1,grid) ||
        !readQueryValue(httpRequestLine,"run",1,run) ||
        !readQueryValue(httpRequestLine,"tpos",3,triggerPosition) ||
        !readQueryValue(httpRequestLine,"single",1,singleShot) ||
        !readQueryValue(httpRequestLine,"avg",3,averageMode) ||
        !readQueryValue(httpRequestLine,"stable",1,stabilize)) {
      queueSmallResponse(400,"Bad Request","text/plain","Invalid VGA display settings.");
      return;
    }
    if (!sendFpgaDisplaySettings(timebase,scale,position,trigger,level,grid!=0,run!=0,
                                 triggerPosition,singleShot!=0,averageMode,stabilize!=0)) {
      queueSmallResponse(503,"Service Unavailable","text/plain","FPGA UART transmission failed.");
      return;
    }
    queueSmallResponse(200,"OK","application/json","{\"sent\":true}");
    return;
  }

  if (startsWith(httpRequestLine, "GET /api/generator?")) {
    uint16_t channel=0, duty=0, enable=0;
    uint32_t frequency=0;
    if (!readQueryValue(httpRequestLine,"ch",1,channel) ||
        !readQueryValue32(httpRequestLine,"freq",GENERATOR_MAX_HZ,frequency) || frequency < 1 ||
        !readQueryValue(httpRequestLine,"duty",100,duty) ||
        !readQueryValue(httpRequestLine,"enable",1,enable)) {
      queueSmallResponse(400,"Bad Request","text/plain","Use generator ch=0..1, freq=1..2000000, duty=0..100, enable=0..1.");
      return;
    }
    if (!configureGenerator(static_cast<uint8_t>(channel),frequency,
                            static_cast<uint8_t>(duty),enable!=0)) {
      queueSmallResponse(503,"Service Unavailable","text/plain","Generator configuration failed.");
      return;
    }
    queueSmallResponse(200,"OK","application/json","{\"applied\":true}");
    return;
  }

  if (startsWith(httpRequestLine, "GET /api/calibration?")) {
    uint16_t fullScaleMv = 0;
    if (!readQueryValue(httpRequestLine, "mv", 9999, fullScaleMv) ||
        fullScaleMv < 1000) {
      queueSmallResponse(400,"Bad Request","text/plain","Full scale must be 1000-9999 mV.");
      return;
    }
    if (!sendFpgaFullScale(fullScaleMv)) {
      queueSmallResponse(503,"Service Unavailable","text/plain","FPGA UART transmission failed.");
      return;
    }
    queueSmallResponse(200,"OK","text/plain","Voltage calibration sent.");
    return;
  }

  if (startsWith(httpRequestLine, "GET /events ")) {
    queueEventStreamHeader();
    return;
  }
  if (startsWith(httpRequestLine, "GET / ") ||
      startsWith(httpRequestLine, "GET /index.html ")) {
    queueWebPage();
    return;
  }
  if (startsWith(httpRequestLine, "GET /favicon.ico ")) {
    queueSmallResponse(204, "No Content", "text/plain", "");
    return;
  }
  queueSmallResponse(404, "Not Found", "text/plain", "Not found.");
}

void serviceHttpReader() {
  if (!httpClient.connected() && httpClient.available() == 0) {
    resetHttpState(true);
    return;
  }
  const uint32_t now = millis();
  if (now - httpLastProgressMillis > HTTP_READ_TIMEOUT_MS) {
    queueSmallResponse(408, "Request Timeout", "text/plain", "Request timed out.");
    return;
  }

  size_t budget = 256;
  while (budget > 0 && httpClient.available() > 0) {
    const int incoming = httpClient.read();
    if (incoming < 0) {
      break;
    }
    budget--;
    httpHeaderBytes++;
    httpLastProgressMillis = now;

    if (httpHeaderBytes > HTTP_MAX_HEADER_BYTES) {
      queueSmallResponse(431, "Request Header Fields Too Large", "text/plain",
                         "HTTP headers are too large.");
      return;
    }

    const char character = static_cast<char>(incoming);
    if (character == '\r') {
      continue;
    }
    if (character == '\n') {
      if (!httpRequestLineComplete) {
        httpRequestLine[httpRequestLength] = '\0';
        httpRequestLineComplete = true;
      } else if (httpCurrentLineLength == 0) {
        routeHttpRequest();
        return;
      }
      httpCurrentLineLength = 0;
      continue;
    }

    httpCurrentLineLength++;
    if (!httpRequestLineComplete) {
      if (httpRequestLength < sizeof(httpRequestLine) - 1) {
        httpRequestLine[httpRequestLength++] = character;
      } else {
        httpRequestOverflow = true;
      }
    }
  }
}

void promoteHttpClientToEvents() {
  if (eventClient) {
    eventClient.stop();
  }
  eventClient = httpClient;
  eventClient.setNoDelay(true);
  eventClient.setSync(false);
  eventClient.setTimeout(50);
  httpClient = WiFiClient();
  httpState = HTTP_IDLE;
  httpRequestLength = 0;
  httpCurrentLineLength = 0;
  httpHeaderBytes = 0;
  httpRequestLineComplete = false;
  httpRequestOverflow = false;
  httpResponseLength = 0;
  httpResponseOffset = 0;
  httpBody = nullptr;
  httpBodyLength = 0;
  httpBodyOffset = 0;
  httpPromoteToEvents = false;
  lastSseSendMillis = 0;
  lastSseProgressMillis = millis();
  sseMessageLength = 0;
}

void serviceHttpWriter() {
  if (!httpClient.connected()) {
    resetHttpState(true);
    return;
  }
  const uint32_t now = millis();
  if (now - httpLastProgressMillis > HTTP_WRITE_TIMEOUT_MS) {
    resetHttpState(true);
    return;
  }

  const char* source = nullptr;
  size_t remaining = 0;
  bool sendingHeader = httpResponseOffset < httpResponseLength;
  if (sendingHeader) {
    source = httpResponse + httpResponseOffset;
    remaining = httpResponseLength - httpResponseOffset;
  } else if (httpBody != nullptr && httpBodyOffset < httpBodyLength) {
    source = httpBody + httpBodyOffset;
    remaining = httpBodyLength - httpBodyOffset;
  } else {
    if (httpPromoteToEvents) {
      promoteHttpClientToEvents();
    } else {
      resetHttpState(true);
    }
    return;
  }

  int writable = httpClient.availableForWrite();
  if (writable <= 0) {
    return;
  }
  size_t chunk = remaining;
  if (chunk > HTTP_WRITE_CHUNK) chunk = HTTP_WRITE_CHUNK;
  if (chunk > static_cast<size_t>(writable)) chunk = static_cast<size_t>(writable);
  const size_t sent = httpClient.write(reinterpret_cast<const uint8_t*>(source), chunk);
  if (sent == 0) {
    return;
  }
  if (sendingHeader) httpResponseOffset += sent;
  else httpBodyOffset += sent;
  httpLastProgressMillis = now;
}

void serviceHttp() {
  if (!wifiReady) {
    return;
  }
  if (httpState == HTTP_IDLE) {
    WiFiClient incoming = webServer.accept();
    if (incoming) {
      httpClient = incoming;
      httpClient.setNoDelay(true);
      httpClient.setSync(false);
      httpClient.setTimeout(50);
      httpState = HTTP_READING;
      httpRequestLength = 0;
      httpCurrentLineLength = 0;
      httpHeaderBytes = 0;
      httpRequestLineComplete = false;
      httpRequestOverflow = false;
      httpLastProgressMillis = millis();
    }
    return;
  }
  if (httpState == HTTP_READING) serviceHttpReader();
  else if (httpState == HTTP_SENDING) serviceHttpWriter();
}

// ============================================================
// Nonblocking server-sent events
// ============================================================

void closeEventClient() {
  if (eventClient) {
    eventClient.stop();
  }
  eventClient = WiFiClient();
  sseMessageLength = 0;
  sseDisconnectCount++;
}

void prepareTelemetryEvent(uint32_t now) {
  uint16_t average[ADC_CHANNEL_COUNT]={},low[ADC_CHANNEL_COUNT]={},high[ADC_CHANNEL_COUNT]={};
  uint8_t newMask=0,validMask=0;
  for(uint8_t channel=0;channel<ADC_CHANNEL_COUNT;channel++) {
    ChannelBucket& bucket=channelBuckets[channel];
    if(bucket.valid)validMask|=static_cast<uint8_t>(1U<<channel);
    if(bucket.count>0) {
      average[channel]=static_cast<uint16_t>((bucket.sum+bucket.count/2U)/bucket.count);
      low[channel]=bucket.low;high[channel]=bucket.high;newMask|=static_cast<uint8_t>(1U<<channel);
      bucket.sum=0;bucket.count=0;
    } else {
      average[channel]=bucket.latest;low[channel]=bucket.latest;high[channel]=bucket.latest;
    }
  }

  const bool fresh = telemetry.valid && (now - telemetry.lastPacketMillis <= UART_ACTIVE_TIMEOUT_MS);
  int written = snprintf(
      sseMessage, sizeof(sseMessage),
      "data:{\"av\":[%u,%u,%u,%u,%u,%u],\"lo\":[%u,%u,%u,%u,%u,%u],"
      "\"hi\":[%u,%u,%u,%u,%u,%u],\"nm\":%u,\"vm\":%u,\"sp\":[",
      average[0],average[1],average[2],average[3],average[4],average[5],
      low[0],low[1],low[2],low[3],low[4],low[5],
      high[0],high[1],high[2],high[3],high[4],high[5],newMask,validMask);
  if(written<=0||written>=static_cast<int>(sizeof(sseMessage))){sseMessageLength=0;return;}

  size_t length=static_cast<size_t>(written);
  uint8_t queued=rawSampleCount<RAW_SAMPLES_PER_EVENT?rawSampleCount:RAW_SAMPLES_PER_EVENT;
  uint8_t tail=rawSampleTail;
  for(uint8_t index=0;index<queued;index++){
    const RawPhoneSample& sample=rawSampleQueue[tail];
    const int added=snprintf(sseMessage+length,sizeof(sseMessage)-length,"%s%u,%u,%u",
        index==0?"":",",static_cast<unsigned>(sample.channel),
        static_cast<unsigned>(sample.adc),static_cast<unsigned>(sample.deltaUs));
    if(added<=0||added>=static_cast<int>(sizeof(sseMessage)-length)){sseMessageLength=0;return;}
    length+=static_cast<size_t>(added);
    tail=static_cast<uint8_t>((tail+1U)%RAW_SAMPLE_QUEUE_SIZE);
  }

  written=snprintf(
      sseMessage+length,sizeof(sseMessage)-length,
      "],\"latest\":%u,\"value\":%u,\"ch\":%u,\"pc\":%lu,\"packets\":%lu,\"pps\":%lu,"
      "\"cmds\":%lu,\"errors\":%lu,\"dropped\":%lu,\"uptime\":%lu,\"baud\":%lu,\"fresh\":%s,"
      "\"g0e\":%s,\"g0hz\":%lu,\"g0d\":%u,\"g1e\":%s,\"g1hz\":%lu,\"g1d\":%u}\n\n",
      static_cast<unsigned>(telemetry.adcLatest),
      static_cast<unsigned>(telemetry.value),
      static_cast<unsigned>(telemetry.confirmedChannel),
      static_cast<unsigned long>(telemetry.samplePeriodCycles),
      static_cast<unsigned long>(telemetry.packetCount),
      static_cast<unsigned long>(telemetry.packetsPerSecond),
      static_cast<unsigned long>(commandsSent),
      static_cast<unsigned long>(telemetry.invalidLineCount),
      static_cast<unsigned long>(rawSampleDropped),
       static_cast<unsigned long>(now), static_cast<unsigned long>(activeFpgaBaud),
       fresh ? "true" : "false", generators[0].enabled ? "true" : "false",
       static_cast<unsigned long>(generators[0].actualHz), static_cast<unsigned>(generators[0].dutyPercent),
       generators[1].enabled ? "true" : "false",
       static_cast<unsigned long>(generators[1].actualHz), static_cast<unsigned>(generators[1].dutyPercent));
  if(written<=0||written>=static_cast<int>(sizeof(sseMessage)-length)){sseMessageLength=0;return;}
  sseMessageLength=length+static_cast<size_t>(written);
  rawSampleTail=tail;rawSampleCount=static_cast<uint8_t>(rawSampleCount-queued);
}

void serviceEvents() {
  if (!eventClient) {
    return;
  }
  if (!eventClient.connected()) {
    closeEventClient();
    return;
  }

  const uint32_t now = millis();
  if (sseMessageLength == 0 && now - lastSseSendMillis >= SSE_INTERVAL_MS && telemetry.valid) {
    prepareTelemetryEvent(now);
  }

  if (sseMessageLength > 0) {
    if (eventClient.availableForWrite() >= static_cast<int>(sseMessageLength)) {
      const size_t sent = eventClient.write(
          reinterpret_cast<const uint8_t*>(sseMessage), sseMessageLength);
      if (sent != sseMessageLength) {
        closeEventClient();
        return;
      }
      sseMessageLength = 0;
      lastSseSendMillis = now;
      lastSseProgressMillis = now;
    } else if (now - lastSseProgressMillis > SSE_STALL_TIMEOUT_MS) {
      closeEventClient();
    }
    return;
  }

  if (now - lastSseSendMillis >= SSE_KEEPALIVE_MS) {
    static constexpr char KEEPALIVE[] = ": keepalive\n\n";
    if (eventClient.availableForWrite() >= static_cast<int>(sizeof(KEEPALIVE) - 1)) {
      eventClient.write(reinterpret_cast<const uint8_t*>(KEEPALIVE), sizeof(KEEPALIVE) - 1);
      lastSseSendMillis = now;
      lastSseProgressMillis = now;
    }
  }
}

// ============================================================
// Wi-Fi, status LED, setup, and loop
// ============================================================

void tryStartWifi() {
  const uint32_t now = millis();
  if (wifiReady || !timeReached(now, nextWifiRetryMillis)) {
    return;
  }
  nextWifiRetryMillis = now + WIFI_RETRY_MS;
  Serial.println("Starting Pico W access point...");
  WiFi.setTimeout(1000);
  if (!WiFi.softAP(WIFI_NAME, WIFI_PASSWORD)) {
    Serial.println("Wi-Fi AP start failed; retry scheduled.");
    return;
  }
  wifiReady = true;
  if (!webServerStarted) {
    webServer.begin();
    webServer.setNoDelay(true);
    webServerStarted = true;
  }
  Serial.print("Network: "); Serial.println(WIFI_NAME);
  Serial.print("Open: http://"); Serial.println(WiFi.softAPIP());
}

void setLed(bool on) {
  if (on == ledState) return;
  ledState = on;
  digitalWrite(LED_BUILTIN, on ? HIGH : LOW);
}

void updateStatusLed() {
  const uint32_t now = millis();
  const bool uartFresh = telemetry.valid && (now - telemetry.lastPacketMillis <= UART_ACTIVE_TIMEOUT_MS);
  if (wifiReady && uartFresh) {
    setLed(true);
    nextLedChangeMillis = now + 1000;
    return;
  }
  const uint32_t interval = wifiReady ? 500 : 125;
  if (timeReached(now, nextLedChangeMillis)) {
    setLed(!ledState);
    nextLedChangeMillis = now + interval;
  }
}

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  setLed(false);
  Serial.begin(115200);
  setFpgaBaud(FPGA_UART_BAUD_HIGH);
  delay(200);

  Serial.println();
  Serial.println("DE10-Lite FPGA Oscilloscope bridge");
#if HAS_RP2040_WATCHDOG
  if (watchdog_caused_reboot()) {
    Serial.println("Previous restart was caused by the watchdog.");
  }
  // Arm this before starting Wi-Fi so a rare CYW43 startup lockup also
  // recovers automatically.
  watchdog_enable(8000, true);
#endif
  packetRateWindowStart = millis();
  nextWifiRetryMillis = millis();
  tryStartWifi();
  Serial.println("FPGA RX: data:FFFF:GGGG:AAAA");
  Serial.println("Pico TX command: A5 CHANNEL VALUE CHECKSUM (3 copies)");
  Serial.println("Capture protocol: AA commands / D6 fixed CRC16 packets; artifact: OCAP v1");
  Serial.println("Serial Monitor command: set <channel 0-5> <VALUE 0-99>");
  Serial.println("Example: set 3 42");
  Serial.print("ADC full scale: "); Serial.print(ADC_FULL_SCALE_VOLTS, 3); Serial.println(" V");

}

void loop() {
#if HAS_RP2040_WATCHDOG
  watchdog_update();
#endif
  readFpgaUart();
  serviceCaptureProtocol();
  serviceFpgaAutoBaud();
  serviceUsbCommands();
  updatePacketRate();
  serviceHttp();
  serviceEvents();
  tryStartWifi();
  updateStatusLed();
  yield();
}

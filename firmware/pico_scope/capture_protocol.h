#pragma once

// Fixed-width capture protocol shared by the Pico bridge and native tests.
// Legacy D5 telemetry remains a separate nine-byte stream. Capture commands
// use AA and FPGA responses use fixed 228-byte D6 packets, so a long transfer
// cannot be mistaken for telemetry or an ASCII line.

#include <stddef.h>
#include <stdint.h>

namespace OcciliCapture {

constexpr uint8_t COMMAND_MAGIC = 0xAA;
constexpr uint8_t FRAME_MAGIC = 0xD6;
constexpr uint8_t FRAME_VERSION = 1;
constexpr uint8_t ENVELOPE_VERSION = 2;

constexpr uint8_t FRAME_STATUS = 0x01;
constexpr uint8_t FRAME_DATA = 0x02;
constexpr uint8_t FRAME_DONE = 0x03;
constexpr uint8_t FRAME_ERROR = 0x7f;

constexpr uint8_t COMMAND_ARM = 0x01;
constexpr uint8_t COMMAND_DOWNLOAD = 0x02;
constexpr uint8_t COMMAND_STATUS = 0x03;
constexpr uint8_t COMMAND_STOP = 0x04;
constexpr uint8_t COMMAND_VGA_SNAPSHOT = 0x05;

constexpr uint16_t BLOCK_RECORDS = 32;
constexpr uint16_t RECORD_BYTES = 6; // uint16 sample + uint32 timestamp on wire
constexpr uint16_t ENVELOPE_RECORD_BYTES = 10;
constexpr uint16_t ENVELOPE_BLOCK_RECORDS = 19;
constexpr uint16_t MAX_SNAPSHOT_RECORDS = 640;
constexpr uint16_t MAX_RECORDS = 8192;
constexpr uint16_t HEADER_BYTES = 34;
constexpr uint16_t DATA_BYTES = BLOCK_RECORDS * RECORD_BYTES;
constexpr uint16_t CRC_OFFSET = HEADER_BYTES + DATA_BYTES;
constexpr uint16_t FRAME_BYTES = CRC_OFFSET + 2;

constexpr uint8_t FLAG_RUNNING = 0x01;
constexpr uint8_t FLAG_COMPLETE = 0x02;
constexpr uint8_t FLAG_VALID = 0x04;
constexpr uint8_t FLAG_TRIGGERED = 0x08;
constexpr uint8_t FLAG_INVALID = 0x10;

inline uint16_t readU16LE(const uint8_t* p) {
  return static_cast<uint16_t>(p[0]) |
         static_cast<uint16_t>(static_cast<uint16_t>(p[1]) << 8);
}

inline uint16_t readU16BE(const uint8_t* p) {
  return static_cast<uint16_t>(static_cast<uint16_t>(p[0]) << 8) |
         static_cast<uint16_t>(p[1]);
}

inline uint32_t readU32LE(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) |
         (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

inline uint32_t readU32BE(const uint8_t* p) {
  return (static_cast<uint32_t>(p[0]) << 24) |
         (static_cast<uint32_t>(p[1]) << 16) |
         (static_cast<uint32_t>(p[2]) << 8) |
         static_cast<uint32_t>(p[3]);
}

inline void writeU16BE(uint8_t* p, uint16_t value) {
  p[0] = static_cast<uint8_t>(value >> 8);
  p[1] = static_cast<uint8_t>(value);
}

inline void writeU16LE(uint8_t* p, uint16_t value) {
  p[0] = static_cast<uint8_t>(value);
  p[1] = static_cast<uint8_t>(value >> 8);
}

inline void writeU32LE(uint8_t* p, uint32_t value) {
  p[0] = static_cast<uint8_t>(value);
  p[1] = static_cast<uint8_t>(value >> 8);
  p[2] = static_cast<uint8_t>(value >> 16);
  p[3] = static_cast<uint8_t>(value >> 24);
}

// Both wire formats start with mean ADC and timestamp. Snapshot v2 adds
// the lowest and highest ADC codes observed within that time column.
inline bool copyRecord(const uint8_t* wire, uint8_t* artifact, bool envelope) {
  const uint16_t mean = readU16BE(wire);
  const uint16_t low = envelope ? readU16BE(wire + 6) : mean;
  const uint16_t high = envelope ? readU16BE(wire + 8) : mean;
  if (mean > 4095 || low > mean || high < mean || high > 4095) return false;
  writeU32LE(artifact, readU32BE(wire + 2));
  writeU16LE(artifact + 4, mean);
  if (envelope) {
    writeU16LE(artifact + 6, low);
    writeU16LE(artifact + 8, high);
  }
  return true;
}

// CRC-16/CCITT-FALSE, polynomial 0x1021, initial value 0xffff. D6 packet
// CRC covers bytes 0 through 225 and is stored big endian at 226..227.
inline uint16_t crc16(const uint8_t* data, size_t length) {
  uint16_t crc = 0xffff;
  for (size_t i = 0; i < length; ++i) {
    crc ^= static_cast<uint16_t>(data[i]) << 8;
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc & 0x8000) != 0
          ? static_cast<uint16_t>((crc << 1) ^ 0x1021)
          : static_cast<uint16_t>(crc << 1);
    }
  }
  return crc;
}

class FrameParser {
 public:
  using Callback = void (*)(const uint8_t* packet, void* context);

  FrameParser() { reset(); }

  void reset() {
    index_ = 0;
    badCrc_ = 0;
    badSync_ = 0;
    frames_ = 0;
  }

  void clearPartial() { index_ = 0; }
  bool active() const { return index_ != 0; }

  // Returns true when the byte is part of a D6 packet. A false return means
  // the caller may pass it to the legacy D5/ASCII parser.
  bool feed(uint8_t byte, Callback callback, void* context) {
    if (index_ == 0) {
      if (byte != FRAME_MAGIC) {
        ++badSync_;
        return false;
      }
      packet_[index_++] = byte;
      return true;
    }

    packet_[index_++] = byte;
    if (index_ < FRAME_BYTES) return true;

    const uint16_t expected = readU16BE(packet_ + CRC_OFFSET);
    const uint16_t actual = crc16(packet_, CRC_OFFSET);
    if ((packet_[1] == FRAME_VERSION || packet_[1] == ENVELOPE_VERSION) && expected == actual) {
      ++frames_;
      if (callback != nullptr) callback(packet_, context);
    } else {
      ++badCrc_;
      // If a byte was lost, the next D6 often lands at the end of this
      // 228-byte window. Preserve a plausible suffix so the next byte can
      // complete it. The version/type check avoids locking onto D6 in data.
      uint16_t suffix = 0;
      for (uint16_t candidate = 1; candidate < FRAME_BYTES; ++candidate) {
        const bool hasVersion = candidate + 1 < FRAME_BYTES;
        const bool plausibleVersion = !hasVersion || packet_[candidate + 1] == FRAME_VERSION ||
            packet_[candidate + 1] == ENVELOPE_VERSION;
        const bool hasType = candidate + 2 < FRAME_BYTES;
        const uint8_t candidateType = hasType ? packet_[candidate + 2] : 0;
        const bool plausibleType = !hasType || candidateType == FRAME_STATUS ||
            candidateType == FRAME_DATA || candidateType == FRAME_DONE ||
            candidateType == FRAME_ERROR;
        if (packet_[candidate] == FRAME_MAGIC && plausibleVersion && plausibleType) {
          suffix = static_cast<uint16_t>(FRAME_BYTES - candidate);
          for (uint16_t index = 0; index < suffix; ++index) {
            packet_[index] = packet_[candidate + index];
          }
          break;
        }
      }
      index_ = suffix;
      return true;
    }
    index_ = 0;
    return true;
  }

  uint32_t frames() const { return frames_; }
  uint32_t badCrc() const { return badCrc_; }
  uint32_t badSync() const { return badSync_; }

 private:
  uint16_t index_ = 0;
  uint8_t packet_[FRAME_BYTES] = {};
  uint32_t badCrc_ = 0;
  uint32_t badSync_ = 0;
  uint32_t frames_ = 0;
};

// Browser artifact constants. Unlike the wire packet, the downloaded OCAP
// file is little endian and stores records as uint32 tick followed by uint16
// ADC sample, matching the web decoder and allowing direct Pico streaming.
// Header layout: 0..3 magic, 4 version, 5 header bytes, 6 flags, 7 channel,
// 8..9 record count, 10..11 record bytes, 12..15 sample period ticks,
// 16..19 capture id, 20..23 trigger index, 24..25 full-scale mV,
// 26..27 reserved/config revision, 28..31 first tick, 32..35 config
// fingerprint, 36 average mode, 37 trigger mode, 38..39 trigger level,
// 40..43 request id, 44..47 sample clock Hz, 48..51 raw FPGA flags,
// 52..63 reserved. Records begin at byte 64.
constexpr uint16_t ARTIFACT_HEADER_BYTES = 64;
constexpr uint32_t ARTIFACT_BYTES =
    static_cast<uint32_t>(ARTIFACT_HEADER_BYTES) +
    static_cast<uint32_t>(MAX_RECORDS) * RECORD_BYTES;

}  // namespace OcciliCapture

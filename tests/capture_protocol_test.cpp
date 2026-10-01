#include "../firmware/pico_scope/capture_protocol.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <vector>

using namespace OcciliCapture;

struct SeenFrame {
  uint8_t type = 0;
  uint16_t sequence = 0;
};

static void onFrame(const uint8_t* packet, void* context) {
  auto* frames = static_cast<std::vector<SeenFrame>*>(context);
  SeenFrame frame;
  frame.type = packet[2];
  frame.sequence = readU16BE(packet + 8);
  frames->push_back(frame);
}

static std::vector<uint8_t> makePacket(uint8_t type, uint16_t sequence,
                                       uint16_t records = 0) {
  std::vector<uint8_t> packet(FRAME_BYTES, 0);
  packet[0] = FRAME_MAGIC;
  packet[1] = FRAME_VERSION;
  packet[2] = type;
  packet[3] = FLAG_VALID;
  writeU16BE(&packet[4], 7);
  writeU16BE(&packet[6], 3);
  writeU16BE(&packet[8], sequence);
  writeU16BE(&packet[10], records == 0 ? 32 : records);
  packet[12] = 2;
  packet[13] = 1;
  packet[14] = 1;
  packet[15] = 0x08;
  packet[16] = 0x00;
  packet[17] = 0x00;
  packet[18] = 0x20;
  packet[19] = 0x00;
  packet[20] = 0x01;
  packet[21] = 0xf4;
  packet[26] = type == FRAME_DATA ? static_cast<uint8_t>(records == 0 ? 32 : records) : 0;
  for (uint8_t index = 0; index < packet[26]; ++index) {
    const size_t offset = HEADER_BYTES + static_cast<size_t>(index) * RECORD_BYTES;
    writeU16BE(&packet[offset], static_cast<uint16_t>(100 + index));
    packet[offset + 2] = 0;
    packet[offset + 3] = 0;
    packet[offset + 4] = static_cast<uint8_t>(index);
    packet[offset + 5] = static_cast<uint8_t>(index + 1);
  }
  const uint16_t checksum = crc16(packet.data(), CRC_OFFSET);
  writeU16BE(&packet[CRC_OFFSET], checksum);
  return packet;
}

static void feed(FrameParser& parser, const std::vector<uint8_t>& bytes,
                 std::vector<SeenFrame>& frames) {
  for (const uint8_t byte : bytes) parser.feed(byte, onFrame, &frames);
}

// Model the bridge's D5 guard: once D5 starts a nine-byte telemetry frame,
// D6 bytes inside its payload are not offered to the capture parser.
static void feedWithD5Guard(FrameParser& parser, const std::vector<uint8_t>& bytes,
                            std::vector<SeenFrame>& frames) {
  uint8_t d5Index = 0;
  for (const uint8_t byte : bytes) {
    if (d5Index != 0) {
      ++d5Index;
      if (d5Index == 9) d5Index = 0;
      continue;
    }
    if (byte == 0xD5) {
      d5Index = 1;
      continue;
    }
    parser.feed(byte, onFrame, &frames);
  }
}

int main() {
  FrameParser parser;
  std::vector<SeenFrame> frames;
  const auto valid = makePacket(FRAME_DATA, 12);
  feed(parser, valid, frames);
  assert(frames.size() == 1 && frames[0].type == FRAME_DATA && frames[0].sequence == 12);

  // A D6-looking byte in a valid D5 packet must remain telemetry data.
  std::vector<uint8_t> d5 = {0xD5, 0x02, 0x00, 0xD6, 0x01, 0x03, 0x04, 0x05, 0x06};
  feedWithD5Guard(parser, d5, frames);
  assert(frames.size() == 1);

  // A corrupted packet is rejected and a following complete packet recovers.
  auto corrupt = makePacket(FRAME_STATUS, 13);
  corrupt[100] ^= 0x80;
  feed(parser, corrupt, frames);
  assert(parser.badCrc() >= 1);
  feed(parser, makePacket(FRAME_DONE, 14), frames);
  assert(frames.size() == 2 && frames[1].type == FRAME_DONE);

  // Dropping one byte leaves the next packet's D6 at the window edge; the
  // parser retains it and completes the next packet as soon as bytes resume.
  std::vector<uint8_t> dropped;
  const auto first = makePacket(FRAME_DATA, 20);
  dropped.insert(dropped.end(), first.begin(), first.begin() + 1);
  dropped.insert(dropped.end(), first.begin() + 2, first.end());
  const auto afterDrop = makePacket(FRAME_DONE, 21);
  dropped.insert(dropped.end(), afterDrop.begin(), afterDrop.end());
  feed(parser, dropped, frames);
  assert(frames.size() == 3 && frames[2].sequence == 21);

  // Oversized/incomplete input never becomes a valid frame; the caller can
  // clear the partial state after its inter-byte timeout.
  parser.clearPartial();
  std::vector<uint8_t> partial(valid.begin(), valid.begin() + 40);
  feed(parser, partial, frames);
  assert(frames.size() == 3);
  parser.clearPartial();

  // Snapshot v2 keeps the packet length and CRC, adding min/max per column.
  auto snapshot = makePacket(FRAME_DATA, 3, ENVELOPE_BLOCK_RECORDS);
  snapshot[1] = ENVELOPE_VERSION;
  writeU16BE(snapshot.data() + CRC_OFFSET, crc16(snapshot.data(), CRC_OFFSET));
  feed(parser, snapshot, frames);
  assert(frames.size() == 4 && frames.back().sequence == 3);
  uint8_t wire[10] = {0x07, 0xd0, 0xff, 0xff, 0xff, 0xf0, 0x01, 0xf4, 0x0d, 0xac};
  uint8_t artifact[10] = {};
  assert(copyRecord(wire, artifact, true));
  assert(readU32LE(artifact) == 0xfffffff0);
  assert(readU16LE(artifact + 4) == 2000);
  assert(readU16LE(artifact + 6) == 500);
  assert(readU16LE(artifact + 8) == 3500);
  wire[6] = 0x08; // Minimum above mean is invalid.
  assert(!copyRecord(wire, artifact, true));
  assert(copyRecord(wire, artifact, false));

  printf("PASS: D6 v1/v2 CRC, envelopes, D5 guard, resynchronization, and timeout\n");
  return 0;
}

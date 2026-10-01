#pragma once
#include <stdint.h>
#include <stddef.h>
#include "capture_protocol.h"

namespace OcciliFft {
constexpr size_t FRAME_BYTES = 550;
inline bool validFrame(const uint8_t* frame) {
  using namespace OcciliCapture;
  if(frame[0]!=0xd8 || frame[1]!=1 || readU16LE(frame+2)!=FRAME_BYTES ||
     crc16(frame,FRAME_BYTES-2)!=readU16LE(frame+FRAME_BYTES-2) ||
     frame[5]>=6 || frame[6]!=8 || frame[7]>10 ||
     readU32LE(frame+8)==0 || readU32LE(frame+8)>65535 ||
     readU16LE(frame+16)<1000 || readU16LE(frame+16)>9999 ||
     readU16LE(frame+18)!=256 || readU16LE(frame+24)>4095 ||
     readU16LE(frame+26)!=16320 || readU16LE(frame+28)!=129 || frame[30]!=1 ||
     (frame[31]!=0 && frame[31]!=3))
    return false;
  const uint8_t flags=frame[4];
  if(flags!=1 && flags!=2 && flags!=4 && flags!=8 && flags!=16) return false;
  return flags!=1 || (readU32LE(frame+12)>0 && readU32LE(frame+20)>0);
}
class FrameParser {
 public:
  bool active() const { return index_!=0; }
  void clear() { index_=0; }
  // The outer UART demultiplexer calls this only outside D5/D6/D7 packets.
  template<class Callback> void feed(uint8_t byte,Callback callback) {
    if(!index_ && byte!=0xd8) return;
    bytes_[index_++]=byte;
    if(index_==4 && (bytes_[1]!=1 || OcciliCapture::readU16LE(bytes_+2)!=FRAME_BYTES)) {
      index_=0;callback(nullptr);return;
    }
    if(index_==FRAME_BYTES) {
      index_=0;callback(validFrame(bytes_)?bytes_:nullptr);
    }
  }
 private:
  uint8_t bytes_[FRAME_BYTES]={};
  size_t index_=0;
};
}

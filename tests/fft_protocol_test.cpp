#include "../firmware/pico_scope/fft_protocol.h"
#include <assert.h>
#include <fstream>
#include <iterator>
#include <vector>
#include <stdio.h>
int main(int argc,char** argv) {
  assert(argc==2);
  std::ifstream input(argv[1],std::ios::binary);
  std::vector<uint8_t> frame((std::istreambuf_iterator<char>(input)),{});
  assert(frame.size()==OcciliFft::FRAME_BYTES && OcciliFft::validFrame(frame.data()));
  OcciliFft::FrameParser parser;int accepted=0,rejected=0;
  auto receive=[&](const uint8_t* packet){if(packet)++accepted;else ++rejected;};
  parser.feed(0,receive);assert(!parser.active());
  for(uint8_t byte:frame)parser.feed(byte,receive);
  assert(accepted==1 && rejected==0 && !parser.active());
  frame[250]^=1;
  for(uint8_t byte:frame)parser.feed(byte,receive);
  assert(accepted==1 && rejected==1 && !parser.active());
  frame[250]^=1;
  for(size_t i=0;i<270;++i)parser.feed(frame[i],receive);
  assert(parser.active());parser.clear();assert(!parser.active());
  for(uint8_t byte:frame)parser.feed(byte,receive);
  assert(accepted==2 && rejected==1);
  frame[4]=2;
  OcciliCapture::writeU16LE(frame.data()+548,OcciliCapture::crc16(frame.data(),548));
  assert(OcciliFft::validFrame(frame.data()));
  puts("FFT parser passed: valid, corrupt, partial, recovery and FPGA error frames.");
}

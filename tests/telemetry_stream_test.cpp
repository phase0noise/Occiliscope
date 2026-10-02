#include "../firmware/pico_scope/telemetry_stream.h"
#include <assert.h>
#include <stdio.h>
int main() {
  OcciliStream::SampleQueue queue;OcciliStream::Sample sample;
  assert(!queue.pop(sample));
  for(unsigned i=0;i<80;++i)queue.push(i%6,1000+i,0xfffffff0u+i*100);
  assert(queue.dropped()==16);
  for(unsigned i=16;i<80;++i) {
    assert(queue.pop(sample));assert(sample.channel==i%6&&sample.adc==1000+i);
    assert(0xfffffff0u+8000u-sample.micros==(80-i)*100);
  }
  assert(!queue.pop(sample));queue.clear();assert(queue.dropped()==0);
  puts("UART live queue passed: order, bounded overflow, timestamps and reset.");
}

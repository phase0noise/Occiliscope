#pragma once
#include <stdint.h>
#include <stddef.h>

namespace OcciliStream {
struct Sample { uint32_t micros; uint16_t adc; uint8_t channel; };
// Keep a bounded recent batch when Wi-Fi falls behind. Timestamp subtraction
// is unsigned so the Pico micros() wrap does not create a backwards axis.
class SampleQueue {
 public:
  static constexpr size_t CAPACITY=64;
  void clear() { head_=0; count_=0; dropped_=0; }
  void push(uint8_t channel,uint16_t adc,uint32_t micros) {
    if(count_==CAPACITY) { head_=(head_+1)%CAPACITY; --count_; ++dropped_; }
    samples_[(head_+count_)%CAPACITY]={micros,adc,channel}; ++count_;
  }
  bool pop(Sample& sample) {
    if(!count_)return false;
    sample=samples_[head_];head_=(head_+1)%CAPACITY;--count_;return true;
  }
  uint32_t dropped() const { return dropped_; }
 private:
  Sample samples_[CAPACITY]={};
  size_t head_=0,count_=0;
  uint32_t dropped_=0;
};
}

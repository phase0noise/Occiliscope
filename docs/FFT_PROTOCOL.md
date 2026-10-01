# FPGA FFT snapshots

The independent `rtl/scope_fft.v` engine samples 256 points from the same
averaged focus-channel stream used by VGA. It selects every `2^TB`-th sample,
subtracts the rounded record mean, applies a symmetric Hann window, and runs
an eight-stage radix-2 FFT. Every stage divides by two, so complex outputs are
`8*FFT(windowed ADC counts)/256`, retaining three fractional bits throughout
the working complex values. Input, working complex values, and power bins
use separate synchronous RAMs. Butterflies share a fixed set of multipliers
and serialize their two writes. VGA acquisition keeps running.

## Commands

`AC TB RID_H RID_L XX` starts a snapshot when the engine is idle. `TB` is 0-10;
the request ID is 1-65535, big-endian. `XX` XORs the preceding four bytes.
`AD` cancels a capture in progress. The Pico sends one start command per request.
The engine measures intervals with its 50 MHz counter; a 2-second absence of
raw samples, a configuration change, or interval jitter above 3.125% (minimum
8 cycles) invalidates the result. Cancel returns the original request ID.

## D8 response

Responses are exactly 550 bytes. All multibyte fields are little-endian.

| Offset | Field |
| --- | --- |
| 0-3 | D8, version 1, total length 550 (16-bit) |
| 4 | Status: 1 valid, 2 config changed, 4 sample gap, 8 timeout, 16 cancelled |
| 5-7 | Focus channel, FFT log2 length (8), timebase |
| 8-11 | Request ID (32-bit; upper 16 bits zero) |
| 12-15 | Rounded mean sample interval in 50 MHz cycles |
| 16-19 | Full scale in mV (16-bit), sample count 256 (16-bit) |
| 20-23 | Elapsed cycles from first to last sample |
| 24-27 | Rounded DC mean ADC code (16-bit), Hann coherent gain Q15 (16320) |
| 28-31 | Bin count 129 (16-bit), window ID 1 (Hann), fractional bits (3; older images use 0) |
| 32-547 | 129 unsigned 32-bit powers: `real[k]^2 + imag[k]^2`, bins 0-128 |
| 548-549 | CRC-16/CCITT-FALSE, initial FFFF, polynomial 1021 |

CRC covers bytes 0-547. Invalid results have zero power payloads. UART
arbitration completes the current packet before starting another stream.
The Pico checks framing, CRC and metadata before publishing an artifact.

For sample period `P`, sample rate is `50,000,000/P`; bin `k` has frequency
`k * sample_rate/256`. Let `G=16320/32768`. Peak amplitude in volts is
`sqrt(power[k]) / 2^fractional_bits * 2/G * full_scale_mv/4,096,000` for bins 1-127; DC and Nyquist
use a factor of 1 instead of 2. The browser reports the removed DC mean
separately. A three-bin quadratic fit in log magnitude estimates the strongest
peak's frequency and amplitude between bins; the graph retains the original
bin magnitudes. This is an estimate, not a change to the transform's resolution.
The gain is a rounded
approximation for the quantized Hann coefficients. Fixed-point rounding sets
a small noise floor; bin spacing limits frequency resolution. Inputs above
half the selected sample rate alias into the spectrum. A square wave contains
its fundamental and odd harmonics, rather than a single spectral line.

The phone defaults to a range up to 10 kHz and selects `TB` from the measured
focus-channel rate. Narrower ranges, full bandwidth, and VGA time scale are
available. The returned timestamps determine the actual graph axis.

Peak estimation follows [quadratic interpolation of spectral peaks](https://dsprelated.com/freebooks/sasp/Quadratic_Interpolation_Spectral_Peaks.html).
See [Analog Devices' square-wave Fourier series](https://wiki.analog.com/university/tools/m1k/alice/desk-top-advanced-guide) for the harmonic pattern.

## Phone endpoints

- `/api/fft/start?tb=0` returns HTTP 202 with `id` and `timeoutMs`.
- `/api/fft/status?id=ID` returns `running`, `ready`, `error`, or `cancelled`.
- `/api/fft/data?id=ID` returns the checked D8 frame when ready, otherwise 409.
- `/api/fft/cancel?id=ID` cancels that request. Stale IDs return 409.

The Pico holds one immutable completed artifact. New FFT requests and saved
captures are mutually exclusive; live frame requests continue during FFT.
The phone keeps its prior spectrum on cancellation, timeout, or bad data.
The waveform graph remains available during the FFT acquisition.

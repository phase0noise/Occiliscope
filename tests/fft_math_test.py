from pathlib import Path
import math,re,cmath,struct,sys
root=Path(__file__).resolve().parents[1]
source=(root/'rtl/scope_fft.v').read_text()
def table(name):
    block=source.split('function '+('' if name=='hann' else 'signed ')+'[15:0] '+name+';')[1].split('endfunction')[0]
    return {int(index):int(value.replace("16'sd",'').replace("16'd",'')) for index,value in re.findall(r"7'd(\d+): \w+=(-?16's?d\d+);",block)}
hann=table('hann');cosine=table('twiddle_cos');sine=table('twiddle_sin')
assert len(hann)==len(cosine)==len(sine)==128
window=[hann[n if n<128 else 255-n] for n in range(256)]
assert abs(sum(window)/256-16320)<1

def transform(samples):
    dc=(sum(samples)+128)>>8
    real=[0]*256;imag=[0]*256
    for n,sample in enumerate(samples):
        index=int(f'{n:08b}'[::-1],2)
        real[index]=(sample-dc)*window[n]>>12
    for stage in range(1,9):
        half=1<<(stage-1)
        for base in range(0,256,half*2):
            for offset in range(half):
                a=base+offset;b=a+half;k=offset<<(8-stage)
                tr=(real[b]*cosine[k]-imag[b]*sine[k])>>15
                ti=(real[b]*sine[k]+imag[b]*cosine[k])>>15
                ar,ai=real[a],imag[a]
                real[a]=(ar+tr)>>1;imag[a]=(ai+ti)>>1
                real[b]=(ar-tr)>>1;imag[b]=(ai-ti)>>1
    return dc,[real[k]*real[k]+imag[k]*imag[k] for k in range(129)]

def tone(bin,amplitude=1024,phase=0):
    return [round(2048+amplitude*math.sin(2*math.pi*bin*n/256+phase)) for n in range(256)]
for bin in (3,16,57,110,127):
    samples=tone(bin);dc,power=transform(samples)
    peak=max(range(1,129),key=lambda k:power[k])
    assert peak==bin,(bin,peak)
    corrected=2*math.sqrt(power[peak])/8/(16320/32768)
    assert abs(corrected-1024)<20,(bin,corrected)
    expected=[complex(sum((samples[n]-dc)*window[n]/32768*cmath.exp(-2j*math.pi*k*n/256) for n in range(256)))/256 for k in range(129)]
    assert max(abs(math.sqrt(power[k])/8-abs(expected[k])) for k in range(129))<1
def peak_estimate(power):
    k=max(range(1,129),key=lambda k:power[k])
    a,b,c=[math.log(max(math.sqrt(power[j]),1e-9)) for j in (k-1,k,k+1)]
    return k+max(-.5,min(.5,.5*(a-c)/(a-2*b+c)))
# Noncoherent input: the peak should track a tone between the discrete bins.
for bin in (3.2,16.37,57.45,110.1):
    _,power=transform(tone(bin))
    assert abs(peak_estimate(power)-bin)<.03,(bin,peak_estimate(power))
# 1 kHz square wave sampled at 16 kHz: fundamental and odd harmonics.
square=[3072 if math.sin(2*math.pi*16*(n+.25)/256)>0 else 1024 for n in range(256)]
_,power=transform(square)
assert max(range(1,129),key=lambda k:power[k])==16
assert power[16]>power[48]>power[80]>power[112]
assert max(power[k] for k in (32,64,96,128))<power[16]*.001
# Preserve a low-level tone rather than losing it at each scaled stage.
_,power=transform(tone(16,amplitude=16))
assert abs(2*math.sqrt(power[16])/8/(16320/32768)-16)<1
_,power=transform([2048]*256);assert max(power)==0
samples=tone(16);dc,power=transform(samples)
frame=bytearray(550)
frame[0:8]=bytes([0xd8,1,0x26,2,1,1,8,0])
struct.pack_into('<IIHHIHHH',frame,8,7,4000,5000,256,4000*255,dc,16320,129)
frame[30]=1;frame[31]=3
for k,value in enumerate(power):struct.pack_into('<I',frame,32+4*k,value)
crc=0xffff
for byte in frame[:-2]:
    crc^=byte<<8
    for _ in range(8):crc=((crc<<1)^(0x1021 if crc&0x8000 else 0))&0xffff
struct.pack_into('<H',frame,548,crc)
fixture=root/'tests/fixtures/fft_snapshot.bin'
if '--write-fixture' in sys.argv:fixture.write_bytes(frame)
assert fixture.read_bytes()==frame, 'FFT fixture differs from the coefficient arithmetic'
print('FFT arithmetic passed: DC, tones, 1 kHz square/odd harmonics, between-bin peaks, low amplitudes and independent DFT.')

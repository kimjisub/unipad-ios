# Ogg Opus audio fixtures

These generated tones contain no third-party recordings. The short files are
0.5 seconds long after Opus pre-skip and final trimming. Decode output is 48 kHz
regardless of the input rate stored in the header.

Generated with FFmpeg and its libopus encoder:

```sh
ffmpeg -f lavfi -i 'sine=frequency=440:duration=0.5:sample_rate=48000' -ac 2 -c:a libopus -b:a 64k -f ogg opus-tone.ogg
ffmpeg -f lavfi -i 'sine=frequency=440:duration=0.5:sample_rate=24000' -ac 1 -c:a libopus -b:a 32k -f ogg opus-mono.ogg
ffmpeg -f lavfi -i 'sine=frequency=440:duration=0.5:sample_rate=48000' -af 'pan=5.1|FL=c0|FR=c0|FC=c0|LFE=0*c0|BL=c0|BR=c0' -c:a libopus -mapping_family 1 -b:a 96k -f ogg opus-surround.ogg
ffmpeg -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 601 -c:a libopus -b:a 6k -f ogg opus-overlong.ogg
```

The overlong silence must be rejected before PCM allocation. Decoder tests
also concatenate the mono and stereo streams, corrupt seeded bytes and cut
files short. The engine test records its actual mixer output as `opus-mixer.wav`;
the silent companion sound only lets the pre-fix engine finish loading the pack.

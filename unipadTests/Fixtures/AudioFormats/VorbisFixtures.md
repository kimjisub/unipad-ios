# Vorbis short-tail fixture

`vorbis-short-tail.ogg` is derived entirely from the original generated
440 Hz stereo tone in `vorbis-tone.ogg` (libvorbis 1.3.7, 44,100 Hz).
It contains no third-party recording.

To reproduce it, keep the three header packets and the first nine audio
packets of `vorbis-tone.ogg`, then append two copies of its first audio
packet. Put the identification header on page 0 (beginning of stream),
the other two headers on page 1, and all audio on page 2 (end of stream).
Use stream serial 1, consecutive page sequence numbers, granules 0, 0,
and 8,448 respectively, and recompute each Ogg page CRC.

The audio block sizes are 256, eight blocks of 2,048, then 256 and 256.
Their overlap produces 8,448 frames. Tests lower only the final granule
and recompute the CRC to cover trimming by 256, 257, 280, 2,048 and
2,049 frames. Trimming through one long block is accepted; trimming
more is rejected. Decoder tests also require the accepted frame count
and nonzero samples, so admission and the reference decoder agree.

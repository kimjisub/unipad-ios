// Test-only tool for the LED timing tests (unipadTests/LedTiming) that ci/virtual-launchpad.sh
// builds and runs inside an iOS Simulator. It never ships.
//
// usage: virtual-launchpad <name> <seconds> <out-file>
//
// Publishes a MIDI source and destination called <name> in the simulator's MIDI server, as a USB
// Launchpad does, so the app connects to it. Every message the app sends arrives here and becomes one
// line "<seconds> <byte> <byte> ..." in <out-file>: the seconds are mach_absolute_time at arrival,
// the clock CACurrentMediaTime reads in the app. Creating these endpoints needs the audio background
// mode, which the app does not declare; this process carries its own Info.plist that does.
#include <CoreMIDI/CoreMIDI.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static FILE *out;
static double secondsPerTick;

static void readProc(const MIDIPacketList *list, void *ref, void *src) {
    double now = (double)mach_absolute_time() * secondsPerTick;
    const MIDIPacket *packet = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; i++) {
        fprintf(out, "%.6f", now);
        for (UInt16 j = 0; j < packet->length; j++) fprintf(out, " %02X", packet->data[j]);
        fputc('\n', out);
        packet = MIDIPacketNext(packet);
    }
    fflush(out);
}

static CFStringRef cfs(const char *s) { return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8); }

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: virtual-launchpad <name> <seconds> <out-file>\n");
        return 2;
    }
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    secondsPerTick = (double)timebase.numer / timebase.denom / 1e9;
    out = fopen(argv[3], "w");
    if (!out) {
        perror(argv[3]);
        return 1;
    }

    MIDIClientRef client = 0;
    MIDIEndpointRef source = 0, destination = 0;
    OSStatus status = MIDIClientCreate(cfs("UniPad virtual Launchpad"), NULL, NULL, &client);
    if (status == noErr) status = MIDISourceCreate(client, cfs(argv[1]), &source);
    if (status == noErr) status = MIDIDestinationCreate(client, cfs(argv[1]), readProc, NULL, &destination);
    if (status != noErr) {
        fprintf(stderr, "creating the MIDI endpoints failed: %d\n", (int)status);
        return 1;
    }
    printf("ready: %s for %s s, arrivals in %s\n", argv[1], argv[2], argv[3]);
    fflush(stdout);

    useconds_t remaining = (useconds_t)(atof(argv[2]) * 1e6);
    while (remaining > 0) {
        useconds_t step = remaining < 100000 ? remaining : 100000;
        usleep(step);
        remaining -= step;
    }
    MIDIEndpointDispose(destination);
    MIDIEndpointDispose(source);
    MIDIClientDispose(client);
    fclose(out);
    return 0;
}

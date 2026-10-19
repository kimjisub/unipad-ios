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
#include <signal.h>
#include <math.h>
#include <string.h>
#include <limits.h>

static double secondsPerTick;
static volatile sig_atomic_t stopped;
static void stop(int sig) { (void)sig; stopped = 1; }

static OSStatus sendNote(MIDIEndpointRef source, FILE *sent, Byte note, Byte velocity) {
    MIDIPacketList list;
    MIDIPacket *packet = MIDIPacketListInit(&list);
    Byte bytes[] = {0x90, note, velocity};
    MIDIPacketListAdd(&list, sizeof(list), packet, 0, sizeof(bytes), bytes);
    double now = (double)mach_absolute_time() * secondsPerTick;
    OSStatus status = MIDIReceived(source, &list);
    fprintf(sent, "%.6f 90 %02X %02X\n", now, note, velocity);
    fflush(sent);
    return status;
}

static FILE *out;

static void readProc(const MIDIPacketList *list, void *ref, void *src) {
    (void)ref;
    (void)src;
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
    // simctl-spawned processes are parented by the simulator's launchd, not simctl.
    // Report the actual collector PID before exec so the caller can stop it directly.
    if (argc == 2 && strcmp(argv[1], "--log") == 0) {
        const char *root = getenv("SIMULATOR_ROOT");
        char executable[PATH_MAX];
        if (!root || snprintf(executable, sizeof(executable), "%s/usr/bin/log", root) >= (int)sizeof(executable)) return 2;
        printf("collector: pid=%d\n", getpid());
        fflush(stdout);
        alarm(300);
        execl(executable, "log", "stream", "--level", "info", "--style", "compact", "--predicate",
              "process == \"unipad\" AND (category == \"AnalyticsLocal\" OR category == \"MIDI\")", NULL);
        perror("starting log collector");
        return 1;
    }
    if (argc != 4 && argc != 6) {
        fprintf(stderr, "usage: virtual-launchpad <name> <seconds> <out-file> [<signal-file> <sent-file>]\n");
        return 2;
    }
    double duration = atof(argv[2]);
    if (!isfinite(duration) || duration <= 0 || duration > 3600) return 2;
    printf("started: pid=%d\n", getpid());
    fflush(stdout);
    signal(SIGTERM, stop);
    signal(SIGINT, stop);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    secondsPerTick = (double)timebase.numer / timebase.denom / 1e9;
    out = fopen(argv[3], "w");
    if (!out) {
        perror(argv[3]);
        return 1;
    }
    FILE *sent = argc == 6 ? fopen(argv[5], "w") : NULL;
    if (argc == 6 && !sent) { perror(argv[5]); fclose(out); return 1; }

    MIDIClientRef client = 0;
    MIDIEndpointRef source = 0, destination = 0;
    OSStatus status = MIDIClientCreate(cfs("UniPad virtual Launchpad"), NULL, NULL, &client);
    if (status == noErr) status = MIDISourceCreate(client, cfs(argv[1]), &source);
    if (status == noErr) status = MIDIDestinationCreate(client, cfs(argv[1]), readProc, NULL, &destination);
    if (status != noErr) {
        fprintf(stderr, "creating the MIDI endpoints failed: %d\n", (int)status);
        return 1;
    }
    printf("ready: pid=%d %s for %s s, arrivals in %s\n", getpid(), argv[1], argv[2], argv[3]);
    fflush(stdout);

    double deadline = (double)mach_absolute_time() * secondsPerTick + duration;
    int next = 0;
    double nextAt = 0;
    int result = 0;
    while (!stopped && (double)mach_absolute_time() * secondsPerTick < deadline) {
        double now = (double)mach_absolute_time() * secondsPerTick;
        if (sent && next < 4 && access(argv[4], F_OK) == 0 && now >= nextAt) {
            // Note-on velocity zero is the MK2 driver's release message.
            if (sendNote(source, sent, next < 2 ? 81 : 82, next % 2 == 0 ? 127 : 0) != noErr) {
                fprintf(stderr, "MIDIReceived failed at step %d\n", next);
                result = 1;
                break;
            }
            next++;
            nextAt = now + 0.3;
        }
        usleep(10000);
    }
    MIDIEndpointDispose(destination);
    MIDIEndpointDispose(source);
    MIDIClientDispose(client);
    fclose(out);
    if (sent) fclose(sent);
    return result;
}

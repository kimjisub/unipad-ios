// Test-only tool for unipadTests/MidiInputPathTests that ci/midi-input-tests.sh builds and runs inside
// an iOS Simulator. It never ships.
//
// usage: virtual-midi-device <seconds> <folder>
//
// Publishes MIDI devices in the simulator's MIDI server as a USB one appears, on request of the tests.
// The tests append commands to <folder>/commands, one per line; each one done is acknowledged with a
// line "<number> ok" or "<number> error <status>" in <folder>/acks:
//   open <name>       publish a source and a destination called <name>, replacing any open ones
//   send <hex words>  send the Universal MIDI Packet words (MIDI 1.0 protocol) as one event packet
//   close             remove the open source and destination
// Every MIDI 1.0 channel message the app sends to the destination becomes one line "<status> <data1>
// <data2>" in hex in <folder>/arrivals. Creating endpoints needs the audio background mode, which the
// app and its test host do not declare; this process carries its own Info.plist that does.
#include <CoreMIDI/CoreMIDI.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopped;
static void stop(int sig) { (void)sig; stopped = 1; }

static FILE *arrivals;
static pthread_mutex_t arrivalsLock = PTHREAD_MUTEX_INITIALIZER;
static MIDIClientRef client;
static MIDIEndpointRef source, destination;

static CFStringRef cfs(const char *s) { return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8); }

static void receive(const MIDIEventList *list, void *refCon) {
    (void)refCon;
    pthread_mutex_lock(&arrivalsLock);
    const MIDIEventPacket *packet = &list->packet[0];
    for (UInt32 i = 0; i < list->numPackets; i++) {
        for (UInt32 w = 0; w < packet->wordCount; w++) {
            UInt32 word = packet->words[w];
            if (word >> 28 == 0x2) fprintf(arrivals, "%02X %02X %02X\n", (word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF);
        }
        packet = MIDIEventPacketNext(packet);
    }
    fflush(arrivals);
    pthread_mutex_unlock(&arrivalsLock);
}

static void closeDevice(void) {
    if (source) MIDIEndpointDispose(source);
    if (destination) MIDIEndpointDispose(destination);
    source = destination = 0;
}

static OSStatus openDevice(const char *name) {
    closeDevice();
    CFStringRef cfName = cfs(name);
    OSStatus status = MIDISourceCreateWithProtocol(client, cfName, kMIDIProtocol_1_0, &source);
    if (status == noErr) {
        status = MIDIDestinationCreateWithProtocol(client, cfName, kMIDIProtocol_1_0, &destination,
                                                   ^(const MIDIEventList *list, void *refCon) { receive(list, refCon); });
    }
    CFRelease(cfName);
    return status;
}

static OSStatus sendWords(char *hex) {
    if (!source) return -1;
    UInt32 words[256];
    UInt32 count = 0;
    for (char *field = strtok(hex, " "); field && count < 256; field = strtok(NULL, " ")) {
        words[count++] = (UInt32)strtoul(field, NULL, 16);
    }
    if (count == 0) return -1;
    Byte buffer[sizeof(MIDIEventList) + sizeof(words)];
    MIDIEventList *list = (MIDIEventList *)buffer;
    MIDIEventPacket *packet = MIDIEventListInit(list, kMIDIProtocol_1_0);
    packet = MIDIEventListAdd(list, sizeof(buffer), packet, 0, count, words);
    if (!packet) return -2;
    return MIDIReceivedEventList(source, list);
}

static OSStatus run(char *line) {
    line[strcspn(line, "\r\n")] = 0;
    if (strncmp(line, "open ", 5) == 0) return openDevice(line + 5);
    if (strncmp(line, "send ", 5) == 0) return sendWords(line + 5);
    if (strcmp(line, "close") == 0) { closeDevice(); return noErr; }
    return -3;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: virtual-midi-device <seconds> <folder>\n");
        return 2;
    }
    double duration = atof(argv[1]);
    if (!isfinite(duration) || duration <= 0 || duration > 3600) return 2;
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/arrivals", argv[2]);
    arrivals = fopen(path, "w");
    char acksPath[PATH_MAX], commandsPath[PATH_MAX];
    snprintf(acksPath, sizeof(acksPath), "%s/acks", argv[2]);
    snprintf(commandsPath, sizeof(commandsPath), "%s/commands", argv[2]);
    FILE *acks = fopen(acksPath, "w");
    if (!arrivals || !acks) {
        perror(argv[2]);
        return 1;
    }
    signal(SIGTERM, stop);
    signal(SIGINT, stop);
    OSStatus status = MIDIClientCreate(cfs("UniPad virtual MIDI device"), NULL, NULL, &client);
    if (status != noErr) {
        fprintf(stderr, "creating the MIDI client failed: %d\n", (int)status);
        return 1;
    }
    printf("ready: pid=%d for %s s, commands in %s\n", getpid(), argv[1], commandsPath);
    fflush(stdout);

    time_t deadline = time(NULL) + (time_t)duration;
    long done = 0;
    char line[4096];
    while (!stopped && time(NULL) < deadline) {
        FILE *commands = fopen(commandsPath, "r");
        if (commands) {
            long number = 0;
            while (fgets(line, sizeof(line), commands)) {
                // A line still being written has no newline yet; it is read again on the next pass.
                if (!strchr(line, '\n')) break;
                if (++number <= done) continue;
                status = run(line);
                if (status == noErr) fprintf(acks, "%ld ok\n", number);
                else fprintf(acks, "%ld error %d\n", number, (int)status);
                fflush(acks);
                done = number;
            }
            fclose(commands);
        }
        usleep(5000);
    }
    closeDevice();
    MIDIClientDispose(client);
    fclose(acks);
    fclose(arrivals);
    return 0;
}

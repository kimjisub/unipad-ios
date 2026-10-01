#!/usr/bin/env python3
"""Run the resolved upstream dictionary in an isolated, offline macOS process.

Usage: python3 unipadTests/check_google_utilities.py CHECKOUT --revision 8.1.3
       python3 unipadTests/check_google_utilities.py CHECKOUT

The only replacement is a stderr logging sink; dictionary code is unmodified.
No Firebase SDK, app, network client, or exception handler is loaded.
Temporary files belong to PAPERCLIP_RUN_SCRATCH_DIR (or PAPERCLIP_SCRATCH_DIR).
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


HARNESS = r'''
#import <Foundation/Foundation.h>
#import "GoogleUtilities/Network/Public/GoogleUtilities/GULMutableDictionary.h"
#import "GoogleUtilities/Logger/Public/GoogleUtilities/GULLogger.h"

NSString *const kGULLogSubsystem = @"offline-regression";
GULLoggerService kGULLoggerNetwork = @"dictionary";
void GULOSLogWarning(NSString *subsystem, GULLoggerService category, BOOL force,
                     NSString *code, NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  fprintf(stderr, "%s: %s\n", code.UTF8String, message.UTF8String);
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    GULMutableDictionary *d = [[GULMutableDictionary alloc] init];
    [d setObject:@"kept" forKey:@"existing"];
    NSString *mode = [NSString stringWithUTF8String:argv[1]];
    if ([mode isEqualToString:@"nil-set"]) {
      [d setObject:@"ignored" forKey:nil];
    } else if ([mode isEqualToString:@"nil-subscript"]) {
      [d setObject:@"ignored" forKeyedSubscript:nil];
    }
    // A synchronous read drains the internal serial write queue before checking.
    if (d.count != 1 || ![[d objectForKey:@"existing"] isEqual:@"kept"]) return 1;
    [d removeAllObjects];
    [d setObject:@"one" forKey:@"normal"];
    if (![[d objectForKey:@"normal"] isEqual:@"one"] || d.count != 1) return 2;
    [d setObject:@"two" forKeyedSubscript:@"normal"];
    if (![[d objectForKeyedSubscript:@"normal"] isEqual:@"two"]) return 3;
    [d removeObjectForKey:@"normal"];
    if ([d objectForKey:@"normal"] != nil || d.count != 0) return 4;
    // Empty strings are valid keys. The reported crash concerns nil keys.
    [d setObject:@"empty-string" forKey:@""];
    if (![[d objectForKey:@""] isEqual:@"empty-string"]) return 5;
    [d setObject:nil forKeyedSubscript:@""];
    if (d.count != 0) return 6;
    [d setObject:@"value" forKey:@"another"];
    [d removeAllObjects];
    if (d.dictionary.count != 0) return 7;
    printf("PASS: %s; normal and empty-string keys preserved\n", argv[1]);
  }
  return 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--revision", help="Compile dictionary source at an old tag for reproduction")
    args = parser.parse_args()
    root = args.checkout.resolve()
    scratch = os.environ.get("PAPERCLIP_RUN_SCRATCH_DIR") or os.environ["PAPERCLIP_SCRATCH_DIR"]
    path = "GoogleUtilities/Network/GULMutableDictionary.m"
    source = (subprocess.check_output(["git", "-C", str(root), "show", f"{args.revision}:{path}"])
              if args.revision else (root / path).read_bytes())
    revision = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", args.revision or "HEAD"]
    ).decode().strip()
    if not args.revision:
        project = Path(__file__).resolve().parents[1]
        lock = project / "unipad.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        pin = next(p for p in json.loads(lock.read_text())["pins"] if p["identity"] == "googleutilities")
        if revision != pin["state"]["revision"]:
            raise SystemExit("Checkout does not match the app's resolved GoogleUtilities revision")
        committed = subprocess.check_output(["git", "-C", str(root), "show", f"{revision}:{path}"])
        if source != committed:
            raise SystemExit("Dictionary source has local changes; test the unmodified upstream source")
    print(f"revision: {revision}; dictionary SHA-256: {hashlib.sha256(source).hexdigest()}", flush=True)
    with tempfile.TemporaryDirectory(prefix="dictionary-", dir=scratch) as folder:
        folder = Path(folder)
        (folder / "dictionary.m").write_bytes(source)
        (folder / "main.m").write_text(HARNESS)
        binary = folder / "check"
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fmodules", "-framework", "Foundation",
                        "-I", str(root), str(folder / "dictionary.m"), str(folder / "main.m"),
                        "-o", str(binary)], check=True)
        failed = False
        for mode in ["normal", "nil-set", "nil-subscript"]:
            result = subprocess.run([str(binary), mode], capture_output=True, text=True, timeout=10)
            print(f"{args.revision or 'resolved checkout'} {mode}: exit {result.returncode}", flush=True)
            print(result.stdout + result.stderr, end="", flush=True)
            failed |= result.returncode != 0
        raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()

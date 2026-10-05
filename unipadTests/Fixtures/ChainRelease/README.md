# Approved chain-release fixtures

Archive bytes and the six cases' inputs and expected outputs match UniPad web
commit `388bff2b20bdb997bd0892f2bdb6968c89dfeee9`,
`meta/unipack-conformance/chain-release-v1/`. Unrelated provenance and historical
summary metadata is omitted from expectations.json; the scenarios are unchanged.
The manifest records the hashes of the archives, expectations, and pack contents.
`ChainReleaseTests.testApprovedFixtureBytesMatchSourceRevision` checks the fixture
hashes against pinned values and the manifest.

The six cases use the production parser, screen model, and audio engine. Input steps
are performed synchronously; asynchronous checkpoints wait for the real pack chain move
or real finite-completion callbacks with a 120-second silence limit. The internal callback
delivery hook holds each completion until its approved checkpoint, so a delayed main queue
cannot consume another checkpoint's completion early. Normal Debug and Release playback
leave the hook unset and deliver callbacks immediately. A separate delayed-observation test replays
unchanged CR-005 with 400 ms observation pauses. This checks completion order and release
ownership, not the exact audible lifetime of a sample. Nominal `atMs` labels describe
corpus order, not a measurement of exact wall-clock timing on a simulator. Audio player
IDs and pressed lights are observations, not listening or real simultaneous fingers.

`ChainReleaseUITests.testOneFingerThroughPackChainMoveAndRelease` requires `delayed.uni`
to be extracted directly into an immediate folder under the installed app's
`Documents/UniPack` before launch. The optional general UI suite reports a missing fixture
as skipped, with an explicit reason. Required chain-release verification must stage the
unchanged archive and confirm that the test passed with zero skips. Direct staging checks
player entry and the one-finger path; it does not check ZIP import, physical fingers or sound.

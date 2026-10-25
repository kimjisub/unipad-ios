# External import regression fixtures

Normal.zip, Missing.zip and Broken.zip cover the three outcomes of opening a
pack from outside the app. Normal is a playable silent pack titled
`External Import - Normal`; Missing references `missing.wav` without including
it; Broken is an invalid ZIP. BesideReadme holds Normal's files in a `Pack/`
folder, titled `External Import - Beside Readme`, with a `readme.txt` next to
that folder at the top of the archive.

WindowsPaths uses backslashes for ZIP folders beneath `Faded...`, a backslash
in the keySound path, a short quiet 440 Hz WAV, and a red LED command. It opens
as `Archive Paths`. EmptyWebsite is a valid pack with an empty `website=` line;
its detail panel must not show a website button.
SchemeLessWebsite uses `website=example.invalid`; it must open that HTTPS
destination in Safari without requiring a live website to load.

`ExternalFileImportTests` opens the bundled files with `XCUIApplication.open`
so iOS delivers a document URL through the normal external import route. Each
test uses a new empty isolated library and local Firebase mode. The picker
comparison uses the existing generated `ReleaseFixture` and closes its result
before opening the external file. No real service or manual fixture copy is
needed. Release checks can run this class instead of adding another external
import test.

Opus.zip maps its first pad to a half-second 440 Hz stereo Ogg Opus tone.
The second pad uses silence so the pack can still open without Opus support.
The UI test records import and pad interaction; SoundEngineDecodingTests
separately requires nonzero PCM at the actual mixer output.

RectangularLights.uni, RectangularFeedback.uni and PressedLight.uni are generated
8x8, one-chain packs with a 100 ms silent WAV on the first pad. The two light
packs repeat an explicit green `00FF00` light until release. The rectangular
packs set `squareButton=false`; PressedLight keeps square pads.
`PlaybackLightsUITests` checks default lights and feedback, then feedback's
priority over pack lights. Its timed screenshots must finish while the pad is
still held. The fixtures contain no recordings or third-party artwork.

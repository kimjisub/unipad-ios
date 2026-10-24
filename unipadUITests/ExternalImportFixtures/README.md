# External import regression fixtures

Normal.zip, Missing.zip and Broken.zip cover the three outcomes of opening a
pack from outside the app. Normal is a playable silent pack titled
`External Import - Normal`; Missing references `missing.wav` without including
it; Broken is an invalid ZIP. BesideReadme holds Normal's files in a `Pack/`
folder, titled `External Import - Beside Readme`, with a `readme.txt` next to
that folder at the top of the archive.

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

# External import regression fixtures

Normal.zip, Missing.zip and Broken.zip cover the three outcomes of opening a
pack from outside the app. Normal is a playable silent pack titled
`External Import - Normal`; Missing references `missing.wav` without including
it; Broken is an invalid ZIP.

`ExternalFileImportTests` opens the bundled files with `XCUIApplication.open`
so iOS delivers a document URL through the normal external import route. Each
test uses a new empty isolated library and local Firebase mode. The picker
comparison uses the existing generated `ReleaseFixture` and closes its result
before opening the external file. No real service or manual fixture copy is
needed. Release checks can run this class instead of adding another external
import test.

# External import regression fixtures

These are the unchanged Normal.zip, Missing.zip and Broken.zip from JIS-307's
QA evidence (attachment 64076cf3-4bea-4993-966f-9dde07dd3ebf).
Normal is a playable silent pack titled `JIS307 - Normal`; Missing references
`missing.wav` without including it; Broken is an invalid ZIP.

`ExternalFileImportTests` opens the bundled files with `XCUIApplication.open`
so iOS delivers a document URL through the normal external import route. Each
test uses a new empty isolated library and local Firebase mode. The picker
comparison uses the existing generated `ReleaseFixture` and closes its result
before opening the external file. No real service or manual fixture copy is
needed. JIS-279 can include this class in the release feature plan instead of
adding another external import test.

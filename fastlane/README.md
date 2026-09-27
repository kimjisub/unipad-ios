fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios verify_auth

```sh
[bundle exec] fastlane ios verify_auth
```

Check the App Store Connect API key actually authenticates and can see the app.

### ios build_only

```sh
[bundle exec] fastlane ios build_only
```

Compile the Release configuration without signing/exporting (compile verification).

### ios deploy

```sh
[bundle exec] fastlane ios deploy
```

Archive, sign, and upload to TestFlight (or App Store review). Pass target:testflight|appstore.

### ios submit

```sh
[bundle exec] fastlane ios submit
```

Submit an already-processed TestFlight build for App Store review as a phased release. Pass build_number:N (and version:X.Y.Z if the xcodeproj is behind).

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).

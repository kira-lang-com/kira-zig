# Exports

Export commands:

```bash
kira export apple
kira export macos
kira export ios
kira export tvos
kira export visionos
kira export windows
kira export android
kira export web
kira export linux
```

Targets are optional inside a Kira project. Profiles are selected with `--profile debug|profiler|release`; Web accepts `--surface dom`.

Apple export writes a merged workspace:

```text
exports/apple/
  KiraApp.xcworkspace
  KiraApp.xcodeproj
  Shared/
    KiraRuntime/
    KiraLiveClient/
    KiraBundleLoader/
    Assets.xcassets/
  macOS/
  iOS/
  tvOS/
  visionOS/
```

The generated project includes macOS, iOS, tvOS, and visionOS targets/schemes for Debug, Profiler, and Release. The macOS/iOS scaffolds build with Xcode command-line tools; device installation still requires valid user signing/provisioning.

Web export writes `index.html`, `kira-browser-ffi.generated.js`, `kira-wasm.js`, `kira-app.wasm`, and `manifest.json`.

Windows export writes a Visual Studio/CMake Presets scaffold. Linux export writes a CMake/Ninja scaffold. Android export writes a Gradle scaffold and intentionally does not install Android Studio. Command-line SDK/Gradle/NDK setup can be installed separately and validated without changing the Android Studio exception.

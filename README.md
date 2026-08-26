# FloatKit

I moved from Linux to macOS and missed the option to keep a window above other
windows. FloatKit brings that feature to macOS without changing System
Integrity Protection.

FloatKit is good enough for my own use, but it has limits. macOS does not let
one app raise another app's window directly. FloatKit works around this by
showing a live copy of the pinned window. Large windows may have some delay or
small visual glitches.

I do not know Swift. I built this app with Codex and tested each change. The
longer record of agent-led performance work is in
[`docs/AGENT-PERFORMANCE-NOTES.md`](docs/AGENT-PERFORMANCE-NOTES.md).

There are some obvious graphical bugs that I can probably iron-out, but they
don't impact usability and I am currently fed up of being QA for Codex.

## Use

- Click the pin in the menu bar to pin or unpin the focused window.
- Click the button beside it to minimise all visible windows.
- Press Control-Option-Command-M to minimise all visible windows.
- Right-click the pin to unpin all windows or quit FloatKit.
- If the pin becomes a warning triangle, right-click it to open the missing
  macOS permission.

## Permissions

FloatKit needs two macOS permissions:

- **Accessibility** lets it find windows and use their controls.
- **Screen & System Audio Recording** lets it show a live copy of a pinned
  window.

Grant both when macOS asks. After enabling Screen Recording, quit and reopen
FloatKit.

## How it works

FloatKit uses Accessibility to find the focused window. It uses
ScreenCaptureKit to place a live mirror above other windows. Clicks pass through
to the real window.

When the pinned app is focused, FloatKit shows the real window and stops its
mirror. When focus moves away, the mirror returns. Capture size follows the
display scale so text stays sharp on Retina screens.

## Build

```sh
./build-app.sh
```

The result is written to `build/FloatKit.app`.

## Install or update

```sh
./install-app.sh
```

This command:

1. Builds FloatKit.
2. Stops FloatKit and its old name, WindowTools.
3. Installs `/Applications/FloatKit.app`.
4. Moves `/Applications/WindowTools.app` to the Trash if it still exists.
5. Opens FloatKit.

Use `./install-app.sh --no-launch` if you do not want it to open.

## Testing

Run the host regression tests after installing the app:

```sh
./run-regression-tests.sh
```

This checks pinning, moving, resizing, window controls, input, minimise and
restore, Retina capture, custom title bars, borderless windows, and cleanup.
Temporary test apps and processes are removed at the end.

Other focused tests are available:

- `./run-visual-regression-tests.sh` compares screenshots and sharpness.
- `./run-textedit-visual-regression-tests.sh` checks the real TextEdit window.
- `./run-sharpness-mutation-test.sh` proves the tests reject a forced blurry
  capture.

### Test in a disposable VM

The VM tests use [Tart](https://tart.run/) on Apple Silicon. They need Homebrew
and about 100 GB of free space.

Set them up once:

```sh
./setup-code-signing.sh
./VM/bootstrap.sh
./install-visual-oracle.sh
```

Enable **FloatKit Visual Oracle** in **System Settings → Privacy & Security →
Screen & System Audio Recording**, then run `./install-visual-oracle.sh` again
to check the permission.

Run all VM tests:

```sh
./VM/run-tests.sh
```

Run only the functional tests:

```sh
FLOATKIT_SKIP_VISUAL=1 ./VM/run-tests.sh
```

Each run creates a temporary VM clone and deletes it afterward. Results are
saved under `VM/artifacts/<run-id>/`. See [`VM/README.md`](VM/README.md) for
configuration and troubleshooting.

Remove abandoned test VMs with:

```sh
./VM/clean.sh
```

Add `--base` to also remove the downloaded base image.

## Local code signing

FloatKit uses a local signing identity named `FloatKit Local Code Signing`.
This stable identity helps macOS remember its permissions after a rebuild.

Create it once on a new Mac:

```sh
./setup-code-signing.sh
```

macOS may ask for the login password or Keychain approval. The script deletes
its temporary private files when it finishes.

Check the identity and a build with:

```sh
security find-identity -v -p codesigning
codesign --verify --deep --strict --verbose=2 build/FloatKit.app
codesign -d -r- build/FloatKit.app
```

To use another identity for one build:

```sh
FLOATKIT_CODESIGN_IDENTITY="Certificate Name" ./build-app.sh
```

If you move from an ad-hoc build to the stable identity, reset the old
permissions once:

```sh
tccutil reset Accessibility io.github.theautoscaler.floatkit
tccutil reset ScreenCapture io.github.theautoscaler.floatkit
./install-app.sh
```

If Screen Recording appears enabled but FloatKit cannot capture a window,
reset it and add the exact installed app again:

```sh
tccutil reset ScreenCapture io.github.theautoscaler.floatkit
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

Then add `/Applications/FloatKit.app` in System Settings and reopen it.

## Origins and licences

FloatKit began with the MIT-licensed
[PinWindow](https://github.com/justwy/PinWindow) project. Its notice is in
`THIRD-PARTY-LICENSES/PinWindow.txt`.

The keep-above icon comes from KDE's
[Breeze Icons](https://invent.kde.org/frameworks/breeze-icons) project. Its
notice is in `THIRD-PARTY-LICENSES/Breeze-Icons.txt`.

FloatKit is licensed under Apache-2.0.

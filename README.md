# FloatKit

After moving from Linux to macOS, I missed KDE/GNOME's always-on-top window
pinning and convenient minimise-all controls. Other macOS applications provide
similar features, but some require compromises to the machine's security
posture, such as partially disabling System Integrity Protection.

FloatKit is an imperfect attempt to restore that behaviour without weakening
macOS security. It is good enough for my own use, but the ScreenCaptureKit-based
architecture has unavoidable limits: maximised windows can have some latency,
and occasional visual or animation artifacts remain.

FloatKit began with the MIT-licensed
[PinWindow](https://github.com/justwy/PinWindow) implementation and substantially
extends it with interactive controls, native focused-window presentation,
minimise-all behaviour, sharper rendering, and automated regression coverage.
FloatKit is licensed under Apache-2.0. Its keep-above icon is adapted from
KDE's [Breeze Icons](https://invent.kde.org/frameworks/breeze-icons) theme and
is isolated in `Sources/FloatKit/BreezeKeepAboveIcon.swift` under
LGPL-3.0-or-later. Its source and licence notice, along with the PinWindow MIT
notice, are retained in `THIRD-PARTY-LICENSES`.

I do not know Swift. This application was built with Codex through iterative
“vibe coding”, with me acting as its QA tester.

A small macOS menu-bar utility that toggles “always on top” for the currently
focused window.

## Use

- Left-click the pin in the menu bar to pin or unpin the focused window.
- Click the minimize button beside it to minimize all visible windows.
- Press Control-Option-Command-M to minimize all visible windows globally.
- Right-click it to unpin every tracked window or quit.
- Grant Accessibility permission when macOS asks.
- If the pin changes to a warning triangle, right-click it to open whichever
  macOS privacy pane still needs attention.

FloatKit uses Accessibility to identify and track the focused window. Since
modern macOS does not allow one process to change another process's window
level, FloatKit uses ScreenCaptureKit to display a live floating mirror of
each pinned window. The mirror passes clicks through to the original window.

Grant both Accessibility and Screen Recording permission when macOS asks.
On first launch, FloatKit explicitly requests Screen Recording so its new
bundle identifier is added to **System Settings → Privacy & Security → Screen
& System Audio Recording**. Quit and reopen FloatKit after enabling it.

The mirror requests up to 60 frames per second and matches the destination
display's backing scale so text remains sharp on Retina screens, including
after maximise and restore transitions. Large size transitions refresh the
ScreenCaptureKit window description and recreate its capture surface; ordinary
resizes retain the lightweight in-place path. Explicit source and destination
rectangles prevent ScreenCaptureKit from silently resampling maximized text.
FloatKit's overlay windows use AppKit's transient Spaces behavior, so Mission
Control hides them instead of presenting the source and mirror as two windows.

## Build

```sh
./build-app.sh
```

The app is written to `build/FloatKit.app`.

## Install or update

```sh
./install-app.sh
```

The installer builds the current source, stops any running FloatKit or legacy
WindowTools process, installs the result at `/Applications/FloatKit.app`, and
launches it. If `/Applications/WindowTools.app` remains from before the rename,
the installer moves it to the Trash so macOS cannot restore the obsolete app at
the next login. Pass `--no-launch` when installing for later use.

### Reproducing tests in a disposable VM

The automated environment uses [Tart](https://tart.run/) to test FloatKit in a
fresh macOS VM without changing the host's TCC database or taking control of
its mouse and keyboard. It requires an Apple Silicon Mac, Homebrew, and roughly
100 GB of free space for the Xcode-equipped base image and working room.

From a fresh clone, run the one-time setup:

```sh
./setup-code-signing.sh
./VM/bootstrap.sh
./install-visual-oracle.sh
```

Enable **FloatKit Visual Oracle** in **System Settings → Privacy & Security →
Screen & System Audio Recording**, then rerun `./install-visual-oracle.sh` to
verify the grant. The oracle captures only the Tart window; it never controls
the host pointer or keyboard.

Run the complete suite with:

```sh
./VM/run-tests.sh
```

Each run creates a disposable APFS clone, mounts this repository read-only,
builds FloatKit inside the guest, grants the required permissions only inside
that guest, and runs the functional, Retina sharpness, mutation, fixture, and
TextEdit visual tests. The clone is deleted automatically. Logs, screenshots,
and comparison metrics remain in the printed `VM/artifacts/<run-id>/`
directory.

For a faster functional-only run with no host screenshots:

```sh
FLOATKIT_SKIP_VISUAL=1 ./VM/run-tests.sh
```

Remove abandoned clones with `./VM/clean.sh`, or also remove the downloaded
base image with `./VM/clean.sh --base`. Configuration overrides and diagnostic
modes are documented in [`VM/README.md`](VM/README.md).

### Regression testing

After installing a build in `/Applications`, run the native stress suite:

```sh
./run-regression-tests.sh
```

The suite creates a disposable Cocoa window and, without synthetic cursor
overlays, performs 40 moves, 40 resizes, 10 zoom toggles, and 40 mixed
move/resize operations. It fails if the pin is lost, the
capture fails, the close/minimise/zoom strip is absent, duplicated, or detached,
or any extra FloatKit overlay is visible. After the geometry stress it sends
a second real window is deliberately ordered between the source and its mirror.
The suite sends a real WindowServer click through that obscured mirror, types
into the fixture's text editor, and reads the value back through Accessibility.
It requires proof that FloatKit detected the wrong frontmost hit target and
routed the click to the exact pinned WindowServer window. This catches overlays
that intercept clicks, clicks falling through to another window, and stolen
keyboard focus. It also asserts that
the mirror cannot become key/main, retains rounded clipping, and supplies its
own native shadow when the source window is behind another window. An
in-process rendering assertion checks that the three controls remain separate
red, yellow, and green circular layers above a clipped, horizontally stretched
clean title-bar texture synthesized row-by-row from the correctly oriented top
rows of the undisturbed title-bar area to the right of the controls. The texture
now spans the complete title-bar width, preventing captured document rows from
appearing above the separator; the window title is redrawn with native AppKit
text so it remains sharp. Earlier
versions accidentally sampled bottom document rows because ScreenCaptureKit's
pixel buffer is vertically inverted relative to AppKit, producing the visible
grey rectangle. The separate control panel contains only the interactive
circles and remains transparent. Pixels outside that small top-left strip pass
through unchanged; the repair itself has no capsule mask, so it cannot recreate
the sharing pill's silhouette. The
mirror's own rounded clipping preserves the outer window corner. The checks catch both missing/doubled
traffic lights and the ScreenCaptureKit sharing pill bleeding through. Typing changes most of
the fixture's stationary content; the suite requires a new capture-frame
fingerprint and a healthy renderer, catching mirrors which remain blank or
stale until moved. A separate assertion runs after maximise and restore and
requires both a current title-bar repair and Retina-sized capture buffers, so
an earlier successful pre-zoom check cannot mask a later regression. The
temporary app and test processes are removed automatically.

`run-visual-regression-tests.sh` is a separate, external pixel oracle. It
compares native, pinned, maximised, and restored fixture screenshots for
title-bar differences, control-backdrop differences outside the coloured
traffic lights, body differences, and edge sharpness. The dedicated backdrop
metric prevents a small but obvious grey/pill-shaped rectangle from being
averaged away by the rest of a large window. A separate intrusion metric rejects
document glyphs anywhere outside the bounded native title region. It deliberately
does not use ScreenCaptureKit for the final screenshot: macOS omits FloatKit's
protected `AVSampleBufferDisplayLayer`, which previously let visible pill and
backdrop regressions pass. The external oracle therefore fails closed when its
host process lacks Screen Recording permission; capture failure is never
reported as a visual pass.

The VM also runs `run-textedit-visual-regression-tests.sh` against the real
system TextEdit app. This covers TextEdit's unified document title bar, body
inset, traffic-light backing, separator, and text rasterisation—the composition
that the synthetic fixture previously failed to represent. It captures native
and pinned references both before and after a real zoom action and rejects
maximized text whose measured edge sharpness diverges from native TextEdit.
The deterministic fixture retains long movement/resize/control stress while
TextEdit supplies the exact application-specific pixel reference.

The functional suite launches both a genuinely borderless Cocoa fixture and a
custom-chrome fixture with native close/minimise/zoom actions but no standard
Accessibility title element. Truly borderless windows must receive only the
mirror. Custom-chrome applications such as Spotify and WhatsApp must retain an
interactive control strip while the pill repair remains bounded to that strip
instead of painting a synthetic title bar across the application. The
unpin-all regression requires every mirror and control surface to disappear in
one WindowServer transaction before teardown begins.

Install its reproducible host helper with `./install-visual-oracle.sh`. The
helper source, plist, build, signing, installation, permission preflight, and
Tart integration all live in this repository; see `VM/README.md` for the
one-time Screen Recording grant and rebuild procedure.

`run-sharpness-mutation-test.sh` deliberately forces a `1x` output while
requiring `2x` and succeeds only when the regression suite rejects it. This
prevents ScreenCaptureKit's source-scale metadata from disguising an
undersized delivered buffer as Retina-sharp.

For unattended testing in a disposable macOS Tart VM, including automated
building, permission grants, stress execution, optional host-authorized
framebuffer screenshots, log collection, and VM deletion, see
[`VM/README.md`](VM/README.md). This subsystem is entirely
self-contained under `FloatKit/` and is not part of the workstation setup.

### Local code signing

The build expects a trusted code-signing identity named
`FloatKit Local Code Signing` in the login keychain. This keeps the app's
designated requirement stable across rebuilds, so macOS can retain its
Accessibility and Screen Recording grants. Ad-hoc signing (`codesign -s -`)
does not provide a stable identity on macOS 26: the permission row can appear
enabled while `AXIsProcessTrusted()` returns false after the binary changes.

On a new Mac, create a fresh identity automatically:

```sh
./setup-code-signing.sh
```

The script:

- refuses to create a duplicate if a valid identity with that name exists;
- generates a 3072-bit RSA self-signed certificate valid for ten years;
- restricts the certificate to code signing;
- imports its private key into the login keychain;
- grants `/usr/bin/codesign` access to that key;
- trusts the certificate for code signing and prints its SHA-256 fingerprint.

macOS may ask for the login password or Keychain confirmation while the script
runs. The temporary private key and PKCS#12 archive are created with restrictive
permissions and deleted automatically when the script exits.

Verify the identity and a completed build with:

```sh
security find-identity -v -p codesigning
codesign --verify --deep --strict --verbose=2 build/FloatKit.app
codesign -d -r- build/FloatKit.app
```

To use another identity temporarily:

```sh
FLOATKIT_CODESIGN_IDENTITY="Certificate Name" ./build-app.sh
```

After migrating from an ad-hoc build, remove the stale permission records once,
install and open the newly signed build, then grant both permissions again:

```sh
tccutil reset Accessibility io.github.theautoscaler.floatkit
tccutil reset ScreenCapture io.github.theautoscaler.floatkit
./install-app.sh
```

On macOS 26, Screen Recording can occasionally retain a stale row even when
its switch is on. If pinning stops after installing a rebuilt app, reset that
record, reopen the Screen & System Audio Recording pane, use **Add** to select
the exact `/Applications/FloatKit.app`, and then launch the app:

```sh
tccutil reset ScreenCapture io.github.theautoscaler.floatkit
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
open /Applications/FloatKit.app
```

Do this only after the final build has been copied to `/Applications`.

### Changes made during the performance investigation

- Kept the two intentional menu-bar controls: minimize all and pin. The `E`
  icon seen beside them belongs to Ente Auth, not FloatKit.
- Uses a pixel-aligned custom M5 window/down-arrow for minimize all and an
  adapted KDE Breeze `window-keep-above` shape for pinning. Breeze attribution
  is recorded in `THIRD-PARTY-LICENSES/Breeze-Icons.txt`. The ready state uses
  KDE's double upward chevron. As soon as at least one pin is active, the same
  chevrons become transparent cut-outs inside a full 18×18 template circle.
- Confirmed that BetterTouchTool's pinning implementation also relies on
  ScreenCaptureKit-style window mirroring; it does not expose a supported way
  to elevate another application's real window.
- Abandoned the private SkyLight window-level experiment because it was
  undocumented, fragile, and disrupted the app's macOS privacy identity.
- Increased the mirror request from 30 to 60 frames per second and matched its
  pixel dimensions to the destination display's backing scale, requested
  ScreenCaptureKit's best source resolution, and verified delivered—not merely
  requested—pixel dimensions and scale metadata after zoom/restore.
- Keeps 60 fps for captures up to 1.5 million pixels, uses 30 fps up to five
  million pixels, and 24 fps above that. Movement still displays the real
  native window, while maximized Retina mirrors avoid continuously copying and
  compositing hundreds of millions of pixels per second.
- While a pinned application is active, removes both FloatKit overlays and
  stops ScreenCaptureKit entirely. The exact native window—including its icon,
  title layout, document-edited state, controls, rendering, and input—runs with
  effectively zero FloatKit presentation overhead. Resize and restore handlers
  are forbidden from resurrecting an overlay in this state. Activating another
  application refreshes the floating mirror at its resolution-adaptive rate.
- Keeps the native five-point top and left resize bands outside FloatKit's
  traffic-light hit surface. Activation retains the mirror until WindowServer
  confirms the source is topmost, preventing a blank transition frame.
- Reconstructs inactive document titles from the Accessibility title and
  edited state, left-aligned as `Title — Edited` rather than centering a stale
  title.
- On click-away, presents the last valid mirror frame synchronously and swaps
  it for a verified fresh frame, avoiding a blank active-to-floating handoff.
  The already-visible control strip remains ordered throughout that swap;
  recovery never hides and recreates it between consecutive frames.
- Minimize invalidates capture and control generations; restore rebuilds both
  before revealing them. Traffic-light dots are visual-only so their parent
  action strip remains the hit target after restoration.
- Uses a three-frame ScreenCaptureKit queue so the live mirror and its tiny
  same-frame title-bar repair cannot starve each other during resizing.
- Replaced per-frame title-bar sample arrays and comparison sorts with fixed
  256-bin colour histograms. The repair is still regenerated on every frame,
  preserving transition timing and pixels while removing the allocation-heavy
  O(n log n) work that scaled badly for maximized Retina windows.
- Registered Accessibility movement notifications in the main run loop's
  common modes so they continue to arrive while macOS is tracking a drag.
- Made movement-only synchronization update the overlay's origin without
  triggering a full frame relayout or capture reconfiguration.
- Made move notifications read the window position directly from Accessibility
  and update the overlay in the observer callback, avoiding an extra main-queue
  hop and a full Core Graphics window-list query for every drag update.
- During an actual move or resize, hides the live capture mirror and lets the
  real native window provide the visual feedback. The mirror returns only
  after final geometry settles, avoiding duplicate or orphaned overlays.
- Flushes the compositor transaction immediately after hiding the mirror and
  control strip at the start of a manipulation. This prevents a stale overlay
  from surviving for one frame over a nearby window while the real window has
  already moved.
- After a resize, keeps the mirror hidden until ScreenCaptureKit has delivered
  a newer frame whose pixel dimensions match the settled window geometry. It
  never briefly reveals the old-sized IOSurface stretched, clipped, or blank
  against an overlapping window.
- Classifies Accessibility title elements and native window-control actions
  separately. Truly borderless windows receive neither repair nor controls;
  custom-chrome windows keep interactive replacement traffic lights and use
  only a control-width pill repair instead of a full synthetic title bar.
- Defers ScreenCaptureKit resize reconfiguration until manipulation ends,
  avoiding repeated capture-size changes.
- Reconciles the final frame immediately and again after short settling delays
  so snapping or application size constraints cannot leave a shrunken mirror.
- Treats every Accessibility resize notification as a manipulation session
  instead of depending on notification ordering from the global mouse monitor.
  The session ends on mouse-up or after activity settles, and final geometry is
  read directly from Accessibility rather than a stale window-list snapshot.
- Expands activation detection twelve points beyond the mirror frame so native
  window-edge resizing does not require pixel-perfect pointer placement.
- Runs a temporary 60 Hz Core Graphics geometry watchdog from mouse-down to
  mouse-up near a pinned window. This catches applications that omit or reorder
  resize notifications without synchronously querying their UI thread.
- Performs a low-frequency geometry reconciliation while pinned, ensuring a
  missed event cannot leave a permanently frozen old-size mirror.
- Updates ScreenCaptureKit in place for ordinary resizes. Large maximize or
  restore transitions recreate the source surface because updating a stale
  window filter produces visibly resampled text; the mirror stays hidden until
  the replacement capture is ready.
- Lets native title-bar clicks pass straight through without also activating
  and Accessibility-raising the real window, preventing FloatKit from
  racing the close, minimise, and zoom controls.
- Renders the replacement circles in the same higher-level panel as their hit
  targets and excludes that panel from source-window event routing, preventing
  clicks from reaching ScreenCaptureKit's sharing pill underneath.
- Shows native-style close, minimise, and zoom glyphs across all three circles
  while the pointer is over the control strip.
- Uses one immediate native minimise-button press for both individual and
  minimise-all actions, hiding pinned mirrors first so the Dock animation is
  visible instead of waiting on an unanimated Accessibility state change.
- Requests that ScreenCaptureKit omit presenter-overlay alerts. macOS may still
  replace a captured window's traffic lights with its purple sharing control,
  so FloatKit masks only that title-bar region with one aligned, interactive
  close/minimise/zoom strip wired to the real Accessibility window.
- Keeps a pin dormant while its Accessibility window still exists but is
  temporarily absent from the Core Graphics list, such as while minimised or
  moving between Spaces, and restores the mirror when the window returns.
- Removes the overlay corner radius and shadow whenever a window fills either
  its screen or visible work area, matching macOS's square maximized corners;
  ordinary pinned windows retain their rounded corners and native shadow.
- Orders both overlay surfaces off-screen and flushes that compositor
  transaction before stopping capture or removing observers, so unpinning is
  visually immediate even when focus moves to another application at once.
- Unpin All first hides every tracked overlay, flushes that single compositor
  transaction, and updates menu state; only then does it tear down each
  capture stream and observer, so later windows cannot visibly linger.
- Shows a warning status icon and direct links to the Accessibility and Screen
  Recording settings whenever either permission is unavailable.
- Retries streams that explicitly stop or fail up to three times and
  suspends/resumes captures around system sleep. It does not treat a quiet
  static window as a stalled stream because ScreenCaptureKit may emit no frames
  when content is unchanged.
- Refreshes the live ScreenCaptureKit window snapshot and WindowServer geometry
  before every recovery start. A maximize-time health check can no longer
  restart the original small capture and stretch it across the full screen.
- Reads the window title from the live Accessibility element and observes title
  changes, instead of relying on ScreenCaptureKit's stale or empty title.
- Re-synchronizes pinned windows after wake, display changes, monitor
  disconnection, and Space changes.
- Replaced ad-hoc signing with the stable local code-signing identity above.
- Reset and recreated the Accessibility and Screen Recording grants for the
  installed, certificate-signed application.

To roll back the performance change, restore both
`minimumFrameInterval` values in `main.swift` from 60 to 30 and rebuild. To
remove the local signing identity entirely, delete the certificate and its
private key named `FloatKit Local Code Signing` in Keychain Access; future
builds will fail until another identity is supplied.

The window-mirroring implementation is adapted from the MIT-licensed
[PinWindow](https://github.com/justwy/PinWindow). See
`THIRD-PARTY-LICENSES/PinWindow.txt` for attribution and license terms.

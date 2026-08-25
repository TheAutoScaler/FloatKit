# Agent performance investigation

This document records work carried out by the Codex agent while the user tested
FloatKit. It is an implementation diary, not a user guide. The user reviewed
the visible behaviour and reported regressions throughout the work.

## Main changes made by the agent

- Raised capture requests from 30 to 60 frames per second and matched capture
  size to the destination display's scale.
- Added adaptive capture rates for large windows to reduce copying work.
- Stopped capture while the real pinned window is active.
- Kept native resize edges outside FloatKit's click surfaces.
- Preserved the last valid frame while a new capture starts.
- Rebuilt capture after minimise, restore, large resize, display, Space, and
  wake changes.
- Used a three-frame capture queue so the mirror and title-bar repair do not
  block each other.
- Replaced per-frame colour sorting with fixed histograms.
- Updated overlay position directly during moves and delayed capture resizing
  until a resize ends.
- Hid overlays during moves and resizes so stale frames do not cover nearby
  windows.
- Waited for a correctly sized new frame before showing a resized mirror.
- Added a short geometry watchdog for apps that miss Accessibility events.
- Kept a slower background geometry check as a fallback.
- Used the real window during title-bar actions to avoid racing close, minimise,
  and zoom controls.
- Added replacement traffic-light controls when ScreenCaptureKit shows its
  sharing indicator.
- Limited title-bar repair to the control area for custom-title-bar apps.
- Left truly borderless windows without replacement controls.
- Removed rounded corners and shadows for maximised windows.
- Hid all overlays in one display transaction before unpin teardown.
- Added capture retry, sleep and wake handling, and permission warnings.
- Read live titles through Accessibility instead of stale capture metadata.
- Moved builds from ad-hoc signing to a stable local signing identity.

## Menu-bar choices

The agent kept two menu-bar controls: minimise all and pin. The minimise icon is
a custom window-and-arrow symbol. The pin uses a shape based on KDE Breeze's
keep-above icon. Its licence notice is in
`THIRD-PARTY-LICENSES/Breeze-Icons.txt`.

The `E` icon sometimes seen nearby belongs to Ente Auth, not FloatKit.

## Approaches rejected by the agent

The agent tested a private SkyLight window-level approach, then removed it. The
API was undocumented, fragile, and interfered with macOS privacy identity.

The agent also checked BetterTouchTool's approach. It uses window mirroring too;
it does not provide a supported way to raise another app's real window.

## Regression work added by the agent

The test suite grew to cover geometry stress, window controls, click routing,
keyboard focus, custom title bars, borderless windows, Retina sharpness,
minimise and restore, stale frames, title changes, unpin cleanup, and visual
comparison against TextEdit.

The visual tests use an external screenshot helper because ScreenCaptureKit
does not include FloatKit's protected display layer in its own screenshots.
The mutation test forces a `1x` capture and passes only when the main suite
rejects it.

## Rollback notes

To return capture requests to 30 frames per second, restore the relevant
`minimumFrameInterval` values in `Sources/FloatKit/main.swift` and rebuild.

To remove local signing, delete the certificate and private key named
`FloatKit Local Code Signing` from Keychain Access. Later builds will fail until
another signing identity is supplied.

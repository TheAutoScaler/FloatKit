# Automated FloatKit testing with Tart

This directory is a standalone, disposable macOS VM test environment for
FloatKit. It does not modify the repository's root Homebrew lists, dotfiles,
or workstation bootstrap. The only host-level installation performed by its
bootstrap script is Tart itself.

## Requirements

- An Apple Silicon Mac running macOS 13 or newer.
- Homebrew.
- At least 100 GB of free space for the Xcode-equipped base image (currently
  about 69 GB compressed) and working room. APFS test clones are deleted after
  every run.

The default image is `ghcr.io/cirruslabs/macos-tahoe-xcode:latest`. It includes
the Swift/macOS SDK toolchain, Tart guest agent, and CI image preparation needed
by the test. Never use the TCC script on the host: it is deliberately restricted
to the disposable guest workflow.

## One-time bootstrap

From the `FloatKit` directory:

```sh
./VM/bootstrap.sh
```

This installs Tart from `openai/tools/tart`, downloads the base image when it
is absent, and configures four CPUs, 8 GB RAM, and a 1920x1200 display. Override
settings without editing files, for example:

```sh
FLOATKIT_TART_MEMORY_MB=12288 ./VM/bootstrap.sh
```

## Unattended test run

Build and install the dedicated host framebuffer oracle once:

```sh
./install-visual-oracle.sh
```

On its first run, enable **FloatKit Visual Oracle** in **System Settings →
Privacy & Security → Screen & System Audio Recording**, then rerun the script.
The helper is built from `Tests/VisualOracle/`, signed with the same stable local
identity as FloatKit, and installed at `/Applications/FloatKit Visual
Oracle.app`. It captures only the Tart window requested by PID and performs no
mouse or keyboard actions.

```sh
./VM/run-tests.sh
```

Each invocation runs Tart with `--no-audio` and `--no-clipboard`. A real
graphical framebuffer is required by ScreenCaptureKit, so the runner keeps a
two-pixel sliver of Tart at the far-right screen edge and immediately restores
focus to the previously active app. It does not use VNC, Screen Sharing, the
pointer, keyboard, sound, or clipboard. It then:

1. creates an APFS clone with a unique name;
2. exposes `FloatKit` read-only and a unique artifact directory read-write;
3. waits for Tart's guest agent;
4. copies the source into the guest's local disk;
5. builds and ad-hoc signs the disposable app and fixture;
6. grants Accessibility and Screen Recording in both Tahoe TCC databases and
   seeds Tahoe's separate private-picker-bypass approval only inside the
   SIP-disabled disposable VM (otherwise replayd places a consent dialog over
   the captured framebuffer);
7. runs the native movement, resize, zoom, pin, and control-strip stress suite,
   then proves its Retina assertion rejects a deliberately forced `1x` capture;
8. saves logs and a process listing under `VM/artifacts/`; when the host has
   Screen Recording permission, the external oracle captures Tart's final
   WindowServer framebuffer and compares native/pinned pixels for both the
   deterministic fixture and the real system TextEdit app;
9. stops and deletes the disposable clone, whether the test passes or fails.

The test exits nonzero on failure, so it can be used by another script or CI
job. No manual interaction is expected.

For a functional-only run which never requests host screenshots:

```sh
FLOATKIT_SKIP_VISUAL=1 ./VM/run-tests.sh
```

The external pixel oracle deliberately fails closed unless the process running
`VM/run-tests.sh` has host Screen Recording permission. ScreenCaptureKit is not
used as a fallback because macOS omits FloatKit's protected video layer from
those screenshots.

### Reproducing the visual oracle on another Mac

From a fresh clone of this repository:

```sh
./setup-code-signing.sh
./VM/bootstrap.sh
./install-visual-oracle.sh
./VM/run-tests.sh
```

After the oracle installer opens the privacy pane, enable **FloatKit Visual
Oracle** under **Screen & System Audio Recording**, then rerun
`./install-visual-oracle.sh` once to verify the grant. No permission editing is
needed inside the VM; every disposable clone is prepared automatically by
`VM/guest/grant-tcc.sh`. The oracle uses the authorised helper app to invoke a
single WindowServer window snapshot by Tart PID. It never controls the host
pointer or keyboard.

Successful and failed runs retain the native and pinned PNGs, metric files,
guest logs, and oracle log under the printed `VM/artifacts/<run-id>/` path.
`FLOATKIT_SKIP_CORE=1` runs visual checks only, and
`FLOATKIT_SKIP_GENERIC_VISUAL=1` narrows a diagnostic run to real TextEdit;
neither flag is used by the normal full suite.

## Cleanup

Remove abandoned disposable clones:

```sh
./VM/clean.sh
```

Remove disposable clones and the downloaded base VM:

```sh
./VM/clean.sh --base
```

Artifacts are retained intentionally. Delete `VM/artifacts/` separately when
they are no longer useful.

## Configuration

Defaults are in `VM/config.sh`. Environment variables are preferred for local
overrides:

- `FLOATKIT_TART_IMAGE`
- `FLOATKIT_TART_BASE`
- `FLOATKIT_TART_CPUS`
- `FLOATKIT_TART_MEMORY_MB`
- `FLOATKIT_TART_DISPLAY`
- `FLOATKIT_TART_TIMEOUT`
- `FLOATKIT_TART_KEEP_CACHE=1` to retain downloaded OCI layers; by default
  bootstrap prunes them after creating the usable base VM.

The VM always catches deterministic correctness regressions. With host Screen
Recording granted, its external framebuffer oracle also catches graphical
regressions. Animation
timings inside a virtual display are recorded for comparison between builds,
but they are not a substitute for final performance measurements on physical
hardware.

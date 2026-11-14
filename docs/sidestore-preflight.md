# SideStore physical-device preflight

The simulator cannot validate seven-day provisioning renewal. Run this on the
physical test iPhone and iPad after reconnecting USB, unlocking the device and
trusting the Mac.

## Build an unsigned IPA

```bash
make test
./scripts/package-unsigned-ipa.sh
```

The script performs an unsigned Release device build, validates the IPA ZIP,
and writes:

- `artifacts/Firepick-unsigned-<version>.ipa`
- `artifacts/Firepick-unsigned-<version>.ipa.sha256`

SideStore must perform the final personal-team signing and installation.

Current artifact:

- `artifacts/Firepick-unsigned-0.1.28.ipa` (22 MB)
- SHA-256: `e5352f70857d28c039b0b7c0a8a9c62c7bf1d6a7d8f319db6d5fa71991281dba`
- Archive contains only standard `Payload/Firepick.app` entries.

## Device checks

1. Confirm the device is available:

   ```bash
   xcrun devicectl list devices
   ```

2. Install SideStore Stable, trust its developer certificate, enable Developer
   Mode, and connect LocalDevVPN as documented in `docs/sidestore-install.md`.
3. Import the unsigned IPA in SideStore and keep bundle ID `com.firepick.app`.
4. Verify config, Bridge credentials and library data survive re-signing.
5. Record the initial install time and open SideStore before the seven-day
   expiry to refresh.
6. Repeat with both an iOS 18 and iOS 26 physical device.

## Acceptance observations

- App launches after SideStore re-signing.
- Persisted TVAPP config and Bridge pairing token remain readable.
- Java, Python and QuickJS Bridge calls still work after relaunch.
- MPV hardware decode, PiP, background audio and local-network permission work.
- Automatic or manual SideStore refresh succeeds after seven days.

Current host status: the iPhone 14 Pro `老张` is connected. LocalDevVPN is
active and SideStore `0.7.0` Apple ID login has succeeded. Firepick physical
installation and seven-day renewal remain pending.


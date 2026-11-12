# SideStore onboarding

Each user signs with their own free Apple ID. Never share one signing account
across the group.

## Per device

1. Install **LocalDevVPN** from the App Store:
   <https://apps.apple.com/us/app/localdevvpn/id6755608044>.

   LocalDevVPN is distributed by Coxson Engineering LLC and is available in
   the US storefront, but not the China storefront. Use a legitimate Apple
   Account with access to that storefront for the App Store download. Do not
   use unofficial repackaged IPAs for this VPN.
2. Connect the iPhone/iPad to the shared Mac over USB, trust the computer, and
   unlock the device.
3. Open the official iloader from <https://iloader.app/>.
4. Sign in with that user's Apple ID, select the device, and install
   **SideStore (Stable)**.
5. On the device, trust the developer app under Settings > General > VPN &
   Device Management.
6. Enable Developer Mode under Settings > Privacy & Security, then restart.
7. Connect LocalDevVPN, open SideStore, and sign in with the same Apple ID.
8. Refresh SideStore once from **My Apps**, accepting certificate creation.
9. Import the Firepick IPA and refresh it once.

For an unsigned IPA generated on this host, use
`./scripts/package-unsigned-ipa.sh`. The detailed acceptance checklist is in
`docs/sidestore-preflight.md`.

## Operating constraints

- Free accounts allow three sideloaded apps per device. SideStore and Firepick
  use two.
- Development provisioning expires after roughly seven days. SideStore should
  refresh automatically, but users should open SideStore before expiry.
- A pairing file may expire after an OS update or reset; reconnect iloader to
  repair it.
- Do not use third-party enterprise certificates or leaked signing profiles.

Pilot one iOS 18 and one iOS 26 device for a complete seven-day cycle before
onboarding the remaining users.


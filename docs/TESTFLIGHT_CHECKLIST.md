# TestFlight checklist

The parts of shipping the App Store edition that need the Apple Developer account
holder, in the order they have to happen. Everything that can be done from the
repository is already in place: the entitlements, the privacy manifests, the export
compliance key, the StoreKit test configuration and `scripts/archive-appstore.sh`.

## 1. Identifiers (developer.apple.com → Certificates, Identifiers & Profiles)

- [ ] App ID **`pro.longwave.app`** (explicit), with these capabilities:
  - **App Groups**: `group.pro.longwave`
  - **Foveated Streaming Session** (`com.apple.developer.foveated-streaming-session`)
  - **In-App Purchase** (on by default)
- [ ] App ID **`pro.longwave.app.broadcast`** (explicit) for the ReplayKit extension, with
      **App Groups** `group.pro.longwave` only.
- [ ] The App Group `group.pro.longwave` exists and is assigned to both IDs.

Automatic signing in `archive-appstore.sh` creates the distribution profiles itself,
but it cannot add a capability the App ID lacks.

## 2. App record (App Store Connect → Apps → +)

- [ ] New app: platform **visionOS**, name **Longwave**, bundle ID `pro.longwave.app`,
      primary language English (U.S.), and a SKU of your choice.
- [ ] Privacy Policy URL:
      `https://github.com/illixion/Longwave/blob/main/docs/PRIVACY.md`. This must match
      `PCVRLegal.privacyPolicy` in `Longwave/Views/PCVRPaywallView.swift`. If the
      policy moves to longwave.pro, change both.
- [ ] Category: Utilities (primary). Productivity or Entertainment are reasonable
      secondaries.
- [ ] Age rating questionnaire: every answer "None" / "No", apart from unrestricted
      web access. The Claude sign-in page is an embedded web view limited to Anthropic's
      sign-in domains, so "No" is defensible there too.

## 3. In-app purchases (App Store Connect → the app → Monetization)

Configure these to match `PCVRStore.ProductID` and `Configuration/Longwave.storekit`
exactly:

| Reference name | Product ID | Type | Price | Details |
|---|---|---|---|---|
| PCVR Lifetime | `pro.longwave.pcvr.lifetime` | Non-Consumable | $24.99 (US base) | Display name "PCVR Unlock". Description "Removes the 20-minute PCVR session limit, permanently." |
| PCVR Monthly | `pro.longwave.pcvr.monthly` | Auto-Renewable Subscription | $1.99 / 1 month (US base) | Subscription group **PCVR**, level 1. Display name "PCVR Monthly". Description "Removes the 20-minute PCVR limit while subscribed." |

- [ ] Create the subscription group **PCVR** and give it a localized display name
      (for example "Longwave PCVR").
- [ ] Each product needs a **review screenshot**: the paywall showing both products.
      `scripts/capture-screenshots.sh` (UI test `ScreenshotTests`) takes it in the
      simulator at 3840×2160, along with the App Store screenshots; its header explains
      why the paywall shot needs the test run from Xcode.
- [ ] Each product needs **review notes**. One line is enough, for example "Removes the
      20-minute limit on PCVR sessions. See the app review notes for the hardware
      needed."
- [ ] Family Sharing: off, which matches the StoreKit file. Turning it on is fine, but
      update the paywall copy and `Longwave.storekit` to match.
- [ ] **Paid Apps Agreement**, banking and tax forms signed (Business). Products stay
      "Missing Metadata" or unpurchasable in sandbox until this is done.
- [ ] Submit both products with the first version that uses them. The first IAPs must
      be attached to an app version under review.

## 4. App Privacy (App Store Connect → the app → App Privacy)

These answers follow from the code (see `docs/PRIVACY.md` and
`Longwave/PrivacyInfo.xcprivacy`):

- [ ] **Data collection: "No, we do not collect data from this app."**
  - No analytics, advertising, crash reporting or tracking SDKs are linked.
  - Connections go directly to hosts the user owns, and the developer can't access
    that data.
  - The Claude and GitHub sign-ins are made directly with those services on the
    user's own accounts. The developer isn't a party to them, and Apple's definition
    of "collect" is data the developer or its partners can access.
  - Purchases go through StoreKit.
- [ ] Tracking: **No**.

## 5. Export compliance

`Longwave/Info.plist` sets `ITSAppUsesNonExemptEncryption` to **NO**, so App Store
Connect does not ask on each upload. The reasoning, in case anyone asks:

- All encryption that protects user data comes from the operating system:
  - CryptoKit AES-GCM for the controller bridge;
  - Network.framework TLS/DTLS for the Companion, audio, native-stream and RTSPS links;
  - URLSession/WebKit HTTPS for sign-in;
  - SSH encryption through swift-nio-ssh, whose primitives resolve to CryptoKit on
    Apple platforms.
- The only encryption implemented inside the app is in the VNC client's password
  authentication (DES, and Diffie-Hellman with AES-128 for Apple Remote Desktop
  logins). It is used for authentication only, and is outside Category 5 Part 2.

If App Store Connect ever asks anyway, the matching answers are:

- "Does your app use encryption?" → **Yes**
- "Does your app qualify for any of the exemptions provided in Category 5, Part 2 of
  the U.S. Export Administration Regulations?" → **Yes**
- or, in the newer questionnaire, algorithm type → **"None of the algorithms mentioned
  above"**, since the app uses only encryption within Apple's operating system, plus
  authentication-only encryption.

This is a self-classification made by the account holder. If you conclude that the SSH
protocol layer counts as "standard encryption in addition to the OS", set the key to
YES instead, choose "Standard encryption algorithms", and provide the French
encryption declaration if the app is offered in France.

## 6. Build and upload

- [ ] Make sure `TEAM_ID` in `scripts/build-signing.conf` is the team (or pass `--team`),
      then either sign in to Xcode (Settings → Accounts) with an account on the team, or
      give the script an App Store Connect API key (App Manager role or higher) so it
      runs headless, over SSH included:

  ```sh
  # scripts/build-signing.conf (gitignored)
  ASC_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
  ASC_KEY_ID=XXXXXXXXXX
  ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  ```

  `--api-key`, `--api-key-id` and `--api-issuer` override those per run.
- [ ] Commit everything, then from the repository root:

  ```sh
  scripts/archive-appstore.sh --version 1.0 --dry-run   # settings check only
  scripts/archive-appstore.sh --version 1.0             # archive + signed .ipa in build/appstore/
  scripts/archive-appstore.sh --version 1.0 --upload    # archive + upload to App Store Connect
  ```

  The build number is `git rev-list --count HEAD`, so each new commit on main gets a
  higher number. The script refuses to run if the build settings contain a
  development-only unlock or internal-only condition, or if the archived binary
  contains a string `scripts/check-app-strings.sh` forbids.
- [ ] In TestFlight, wait for processing, then add internal testers. External testing
      needs Beta App Review; paste the text from `docs/APP_REVIEW_NOTES.md`.
- [ ] On device, check that the TestFlight build starts in trial (20-minute sessions),
      that a sandbox purchase unlocks it, and that Restore Purchases works after
      reinstalling.

## 7. Submission

- [ ] Screenshots and an app preview for visionOS.
- [ ] App Review Information:
  - contact details;
  - no demo account, since the app has no accounts;
  - notes from `docs/APP_REVIEW_NOTES.md`;
  - the demo video link.

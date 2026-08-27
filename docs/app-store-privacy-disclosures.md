# App Store privacy disclosures

Prepared for the Strava route-import release on August 27, 2026.

This file is the source-of-truth answer sheet for App Store Connect. It does not
publish or change App Store Connect. Reconfirm the production configuration and
third-party dependencies immediately before submission.

Apple defines data as collected when it is transmitted off the device in a way
that lets the developer or a third party access it for longer than needed to
service a real-time request. Apple also says data processed only on device does
not need to be disclosed. App-level answers must cover every included platform.

References:

- [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Manage app privacy in App Store Connect](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)

Use this public URL for both the App Store Connect privacy-policy field and the
in-app privacy links:

`https://github.com/seichris/open-bike-computer/blob/main/ios-app/PRIVACY_POLICY.md`

Verify that the URL resolves after this release branch is merged and before
submitting the build.

## App Store Connect answers

Select **Yes, we collect data from this app** because the optional offline-map
service stores map request geometry, an installation identifier, map-job and
download history, and any custom saved-map name the rider chooses to sync. If
the rider connects Strava, the service also stores an encrypted Strava athlete
ID and token bundle linked to that installation.

| Data type | Collected | Purpose | Linked to identity | Tracking | Reason |
| --- | --- | --- | --- | --- | --- |
| Precise Location | Yes | App Functionality | Yes | No | An offline-map bounds, polygon, or route-corridor request contains precise coordinates and is stored with the requesting app installation ID so the service can build, recover, and deliver the map. |
| Device ID | Yes | App Functionality | Yes | No | The app creates a random installation ID used to authenticate and scope map jobs. It is not an advertising ID or hardware identifier. |
| User ID | Yes | App Functionality | Yes | No | When the rider optionally connects Strava, Bicino stores the Strava athlete ID and OAuth token bundle encrypted at rest and bound to the random app-installation ID so it can import that rider's routes. |
| Other User Content | Yes | App Functionality | Yes | No | A custom saved-map display name is free-form text that can be synced to the map job so the rider sees the same name when the app recovers that job. |
| Product Interaction | Yes | App Functionality | Yes | No | The service retains installation-linked map-job state, request/status timestamps, and download receipts so the app can list, recover, retry, and explain offline-map requests. Strava may also monitor API usage for a connected athlete under its API Policy. |
| Health | No | — | — | — | HealthKit values and workout routes remain within HealthKit and the rider's paired Watch/iPhone workflow. They are not uploaded to a developer or third-party server. |
| Fitness | No | — | — | — | Cycling workout and sensor values follow the same local-only path. Relaying them to the rider's authenticated bike computer does not make them accessible to the developer. |
| Crash Data / Performance Data | No | — | — | — | The app contains no developer or third-party crash-reporting or performance SDK. Apple-operated diagnostics are not developer collection unless exported to the developer. |

For all five selected types, choose **App Functionality**, **Data Linked to the
User**, and **Not Used for Tracking**. Apple treats linkage through a device or
other identifier as linked even when the app has no account or real-world name.

## Production checks before publishing answers

- Confirm the release build still has no analytics, advertising, crash-report,
  or diagnostic-upload SDK.
- Confirm Health, workout route, and raw workout telemetry are absent from
  backend requests and logs.
- Confirm Watch online-routing origin/destination and returned MapKit route are
  used only for the rider's real-time request, remain absent from Bicino backend
  traffic and logs, and are not written to the offline route store.
- Confirm paired-device coordinate favorites and offline route archives remain
  inside WatchConnectivity/local device storage, and that expired archives and
  rider-requested deletions follow the documented retention behavior.
- Confirm Strava route GPX and metadata are relayed with `Cache-Control:
  private, no-store`, are not persisted by the backend, and are cached on
  iPhone and Watch for no more than seven days from each successful import or
  reload.
- Confirm expiry deletes every API-derived Strava route field and Watch copy,
  leaving only the user/local reload bookmark on iPhone, and that its one-tap
  reload starts a fresh seven-day window.
- Confirm connected iPhones revalidate eligible Strava routes after 24 hours,
  authoritative unavailability purges route data immediately, and transient
  failures preserve an otherwise unexpired offline route.
- Confirm individual deletion removes the matching route and reload bookmark;
  disconnect disables the backend connection immediately, purges every local
  Strava route/bookmark, requests token revocation, and completes exact Watch
  deletion through its durable paired-device acknowledgement path.
- Confirm inactive Strava connections are revoked and deleted after at most 30
  days without an authenticated integration request, and pending revocations
  retain encrypted credentials only for retry and are deleted after success or
  no later than 30 days after disconnection.
- Confirm the backend uses Strava's current Basic-authenticated `/oauth/revoke`
  flow with the encrypted refresh token and does not regress to the legacy
  deauthorization endpoint before its announced retirement.
- Reconfirm that the approved route provider permits every shipped persistence,
  attribution, and non-Apple accessory-display use; do not ship a MapKit export
  path without explicit approval under the current Apple terms.
- Confirm `maps.8o.vc` stores map geometry only for requested map jobs and does
  not repurpose it for analytics, advertising, or tracking.
- Confirm custom map names, job/status timestamps, and download receipts remain
  limited to installation-scoped map listing, recovery, and delivery.
- Confirm reverse-proxy and infrastructure access-log retention. The app
  backend pseudonymizes addresses in its own rate-limit database, but any
  separately retained raw IP address must be evaluated under Apple's current
  guidance and disclosed if required.
- Confirm the production map-job and artifact retention configuration and make
  the public privacy policy match it. The release policy anchors ready-map
  artifact expiry to the immutable completion time at 30 days, begins bounded
  deletion batches during hourly maintenance, and retains installation-scoped
  job records until verified deletion or service decommissioning.
- Confirm scheduled maintenance runs at least hourly, processes the documented
  artifact-deletion batches, and independently deletes expired rate-limit
  pseudonyms even when the API receives no later request.
- Confirm each infrastructure provider processing app data is bound to use it
  only on our instructions and provide the same or equivalent protection stated
  in the public policy.
- Open the privacy-policy link from both iPhone Settings and Watch Settings,
  and confirm the same URL is entered in App Store Connect metadata.
- Review the App Store product-page preview before selecting **Publish**.

## Bundled privacy manifests

`BikeComputer/PrivacyInfo.xcprivacy` declares the precise-location, device-ID,
user-ID, other-user-content, and product-interaction collection above, no
tracking, and the iOS app's required-reason API use.
`BikeComputerWatch/PrivacyInfo.xcprivacy` declares no developer collection or
tracking. HealthKit access itself remains controlled by the entitlement,
permission strings, and system authorization rather than being misrepresented
as server collection.

Apple can change privacy definitions and allowed required-reason API codes.
Validate these files with the shipping Xcode version and Apple's current
documentation for every release.

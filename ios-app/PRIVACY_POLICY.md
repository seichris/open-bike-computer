# Bicino Privacy Policy

Effective date: August 27, 2026

Bicino is a cycling navigation and workout companion. This policy
explains what information the iPhone app, Apple Watch app, compatible bike
computer hardware, and optional offline-map service use.

## Accounts, advertising, and analytics

Bicino does not require an account. We do not sell personal data,
use advertising SDKs, track you across other companies' apps or websites, or
use third-party analytics SDKs.

## Health and fitness

When you explicitly start an outdoor cycling workout in Bike Computer, the
Apple Watch app owns and records that workout. With your Health authorization,
it can read live cycling measurements such as heart rate, active energy,
distance, speed, cycling power, and cadence, and can save one completed workout
and its permitted route to HealthKit.

Live workout information is mirrored through Apple's paired Watch/iPhone
workout connection so it can appear in the iPhone app. If you connect a
compatible bike computer, the iPhone can also relay current workout values over
the existing authenticated local Bluetooth connection. The bike computer keeps
these values in memory only and clears them when the workout returns to idle or
the device restarts.

We do not upload HealthKit workouts, heart rate, energy, cycling sensor values,
or workout routes to our servers. Apple controls HealthKit storage and access.
You can review or delete saved workouts in Apple's Health or Fitness apps and
change Bike Computer's Health access in system settings.

Starting a Bike Computer workout may replace another app's active workout on
Apple Watch. The Bike Computer Watch app shows a warning and requires
confirmation before it tries to start; cancelling that warning does not create
a Bike Computer workout. An iPhone-initiated start instead proceeds directly
after checking for a paired Watch and installed Bike Computer companion because
public APIs do not reveal whether another workout app is active.

## Location

The iPhone app uses location to show your position, calculate cycling routes,
provide turn-by-turn navigation, and track route progress while navigation is
active. The Apple Watch app uses location to drive navigation and send the
current position and guidance to an authenticated compatible bike computer. It
also uses location during an outdoor workout to record the permitted workout
route and to provide speed and elevation when a cycling sensor does not supply
them.

When you explicitly enable online Watch routing and choose a coordinate-backed
favorite, the Watch sends the current coordinate and destination to Apple's
MapKit service for a real-time cycling-route request. The resulting Watch route
is kept only for the active navigation session. Bicino does not upload that
request or route to its own servers. When the setting is off, Watch navigation
uses only a route you previously transferred for offline use and does not make
an online route request.

Saved offline routes and coordinate-backed favorite names and coordinates are
transferred between your paired iPhone and Watch using Apple's WatchConnectivity
service. They remain within the paired app workflow and are not sent to the
Bicino backend. Offline route files enforce their provider retention metadata
and are removed when they expire. You can delete a saved route from the iPhone;
if it is currently active on Watch, deletion finishes when navigation stops.

### Optional Strava route import

If you choose **Import from Strava**, you paste a Strava route URL and connect
your Strava account through Strava's authorization flow. The Bicino service
stores your Strava athlete ID, granted scopes, access token, and refresh token
in encrypted form, linked only to the random Bicino app-installation identifier.
It uses them only to confirm that the requested cycling route belongs to the
connected athlete and to retrieve that route from Strava. The service relays
the route GPX directly to your app with a no-store response and does not persist
the route name, coordinates, distance, instructions, or GPX payload.

Your iPhone and paired Watch may cache a Strava route for no more than seven
days from each successful import or reload. At the deadline they delete all
Strava-supplied route data, including the route name, endpoints, distance,
geometry, steps, and Watch copy. The iPhone may retain only a small local reload
bookmark: the Strava route ID and canonical URL you provided, a Bicino-local
route ID and alias, a revision counter, and local import, reload, validation,
and error timestamps. This bookmark lets you reload the same route with one
tap; a successful reload retrieves a fresh copy and starts a new seven-day
window. You can delete the bookmark at any time.

While connected, Bicino may revalidate a cached route when its last successful
check is more than 24 hours old. A definitive unavailable response deletes the
cached route data immediately; a temporary network or service failure does not
delete an otherwise unexpired route. Disconnecting Strava immediately disables
the connection and removes Bicino's cached Strava routes and reload bookmarks
from the iPhone, with exact Watch deletion delivered through the paired-device
workflow. Bicino also revokes and deletes an unused backend connection after 30
days without an authenticated Strava integration request.

When you disconnect, Bicino asks Strava to revoke the token and deletes the
connection record. If Strava is temporarily unreachable, the connection stays
disabled and the encrypted credential is retained only long enough to retry
revocation; it is deleted after revocation succeeds and in all cases no later
than 30 days after disconnection. Bicino's use of Strava data is also subject
to [Strava's Privacy Policy](https://www.strava.com/legal/privacy).
Strava may monitor and collect usage data generated by Bicino's use of the
Strava API and may use that usage data for internal or external business
purposes as described in the
[Strava API Policy](https://www.strava.com/legal/api_policy).

Most location processing happens on your devices or through Apple system
services such as MapKit. We are not responsible for information Apple processes
under its own privacy policies.

If you request an offline map, the selected map bounds, polygon, or route
corridor is sent to the Bike Computer map service. The service stores that
request geometry with a random app-installation identifier so it can build,
list, recover, and deliver the requested map. It is used only for this app
functionality, not for advertising, analytics, or tracking. Generated map
artifacts reach their retention limit 30 days after a map job becomes ready;
renaming or downloading a map does not extend that period. The next scheduled
maintenance pass marks the job expired and begins deleting eligible,
unreferenced generated artifacts in bounded batches. The standard maintenance
schedule runs hourly. A backlog or a retryable provider failure can require
additional passes to finish physical deletion. The associated job record is
retained after artifact expiry so the app can list, recover, and explain prior
map requests. We retain that installation-scoped record until you request its
deletion or the service is decommissioned.

That job record includes the request and status timestamps and can include a
download receipt (such as artifact format, size, and integrity identifier). If
you give a saved map a custom name, the app can also sync that name to the map
service. This installation-linked history is used to list and recover maps,
keep downloads consistent across retries, and show their current status; it is
not used to analyze how people use the app.

## Installation identifier and network protection

The Bicino service creates a random installation identifier and a high-entropy
credential. These values are not your name, Apple ID, advertising identifier,
or hardware serial number. The service uses them to scope optional map jobs and
Strava connections to one installation and to protect requests and downloads.
It also temporarily stores pseudonymized network-address values to enforce
abuse-prevention rate limits;
raw addresses are not stored in that rate-limit database. At the end of the
applicable rate-limit window, which is no longer than 24 hours, an entry stops
affecting requests. Expired entries are deleted at service startup or by the
scheduled maintenance process; the standard maintenance schedule runs hourly.

## Bluetooth and local network

The app uses Bluetooth to connect to compatible bike computer hardware and
transfer navigation and live workout values. It uses the local network to
transfer offline maps to hardware you connect. This communication operates the
connected device and is not used for tracking.

## Sharing and service providers

We do not share personal data with advertisers or data brokers. Information may
be processed by infrastructure providers only as needed to operate requested
functionality, such as building and delivering an offline map. Workout and
HealthKit information is not sent to those providers. We require service
providers that process information for us to use it only on our instructions
and to provide the same or equivalent privacy protection described in this
policy.

## Your choices

You can use navigation without starting a HealthKit workout. Online Watch
routing is off by default and can be changed only by you in the Watch app. You
can deny or later revoke Health, location, Bluetooth, or local-network access
in system settings, although the related feature will be unavailable or
reduced. You can delete workouts through Apple's Health or Fitness apps.

Strava connection and route import are optional. In iPhone **Settings > Saved
Routes**, you can delete an individual Strava route and its reload bookmark, or
open **Import from Strava** and choose **Disconnect Strava and Delete Data** to
remove all Bicino-held Strava data for this installation. These actions do not
delete or modify your routes on Strava.

To request access to or deletion of offline-map service data, email the contact
below and identify the saved map or map-job ID if available. We may ask for
installation-specific verification before acting so another person cannot
delete your maps. A verified deletion request covers the associated request
geometry, installation identifier, custom map names, job/status history,
download receipts, and any retained artifacts. Revoking a system permission
stops future access by the app but does not itself delete an already saved
Health workout or an existing offline-map job; use the deletion methods above
for those records.

## Contact

For privacy questions or requests, contact:

privacy@bicino.com

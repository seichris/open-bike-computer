# Real Dev test friends

`tools/social-demo` provisions three synthetic riders through Firebase custom
sign-in and the real social API, sends friend requests to your Dev username, and
runs bounded GPS publishers. It is confined to `bicino-dev`, `maps-dev.8o.vc`, and
the existing `bicino-social-dev-social-api-1` container. It cannot select a
production origin or mint an identity for the real rider. Firebase credentials
and short-lived tokens remain inside the Dev container. Its logs and status
contain test identity names and receiving booleans, never actual rider positions,
stats, provider response bodies, or tokens.

Use your existing SSH alias and native **Dev** client configuration:

```sh
tools/social-demo seed --xcconfig /path/to/bicino-dev.xcconfig --target your_dev_username
```

In Bicino Dev, open **Settings → your profile → Friends**, then accept **Demo
Ava**, **Demo Ben**, and **Demo Cleo**. These are real accepted friendships in the
Dev directory. Seed is repeatable: it reuses only its fixed synthetic UIDs and
profiles and does not create duplicate pending requests. It refuses a real
provider binding or an unexpected profile under a demo UID. The runtime Firebase
role needs its existing user-read access; synthetic users are created by custom
sign-in, without granting runtime user-create IAM permissions.

After the social schema-4 deployment and `FRIEND_SHARING` flag are active:

```sh
tools/social-demo run --duration 3600
tools/social-demo status
tools/social-demo stop
```

To give the existing test friends simple pictures, run `tools/social-demo avatars`
on the Mac. It renders the system emoji locally (Ava 🚴, Ben 🚴‍♂️, Cleo 🚴‍♀️) and
uploads them through each synthetic account's ordinary profile-avatar API.
Existing pictures are reported as `retained` on repeat runs. To apply the current
emoji set over an older synthetic picture, use `tools/social-demo avatars --replace`.
Only successful uploads report the applied emoji. No emoji font or image bundle is
distributed with the app. Open Friends again to refresh the pictures.

On the iPhone map, open **Layers → Friends → Friend Marker Size** and choose
Normal (1×), 1.25×, 1.5×, 2×, 2.5× or 3×. One size scales friend pictures
together with their distances and grouped-rider counts, persists on this phone,
and updates the map without restarting. A rider's position stays at the bottom
of its map portrait at every size, and only clipped or off-screen riders move
to the map edge. The previous default (Medium) keeps the normal size; an earlier
Large picture or number choice becomes 1.25×.

The connected bike computer uses the same size on Map, Map + Navigation and
terrain/topographic Map screens. Its map-screen settings in Bicino (each Map or
Map + Navigation screen, or the gear beside it on older screen lists) show the
same **Friends → Friend Marker Size** control. Changing it anywhere changes it
everywhere, and the device keeps the size after a restart. Friend markers and
this control are standard features in both production and developer firmware.
Older production firmware, including the original build 106 release, must be
updated before the bike computer can receive and display friends.

## Filming with riders following you

In **Bicino Dev → Settings → your profile → Friends**, enable your outgoing
location sharing to **Demo Ava**, then keep a live GPS fix. Start the server-side
filming demo from the Mac:

```sh
tools/social-demo run --follow-me --until-stopped
tools/social-demo status
tools/social-demo stop
```

All three riders publish continuously, including Cleo. Ava stays 25 m to your
right, Ben 65 m behind and 12 m to your left, and Cleo 140 m behind and 30 m to
your right. The formation turns with your GPS course; while no course is
available it holds the last direction (north initially). These are geometric
offsets, so markers are not snapped to roads. They follow your live position
without accumulating drift. Your existing Dev app and friend-capable firmware
receive the ordinary friend streams; no app or firmware update is required.

Only Ava's normal, consented friend snapshot supplies your anchor. Its position
stays in process memory, and neither coordinates nor your stats enter operator
logs or status. A fix older than 15 seconds, disabled sharing, or a failed
snapshot read pauses the formation and clears the demo riders' outgoing
streams. Fresh sharing resumes them. `status` reports `following` or
`waiting_for_your_location` for each rider. Turning off your sharing to Ava is
also a convenient way to pause filming from the phone.

`--until-stopped` runs on the Dev server until `stop` or a container replacement,
even after the Mac disconnects. Demo outgoing leases are renewed automatically.
Your phone's normal sharing permission still expires after four hours; enable it
again if filming that long. For a bounded filming session instead, use
`run --follow-me --duration 3600`. If an older demo is already running, stop it
before starting the new mode. After stopping, turn off your sharing to Ava too.

Run defaults to one hour and accepts 30 seconds through four hours. The test
riders share **synthetic** locations with your accepted Dev account. Ava moves
faster, Ben moves slower, and Cleo stops publishing for 90 seconds in each
150-second cycle. The small loop is fixed in Shanghai; it does not read or send
your device's location. Cleo should fade after 15 seconds and disappear after 60
seconds, then return when publication resumes. Their friend details show their
usernames and live GPS stats; the map uses the ordinary rider markers. With no
friend position on screen, Bicino checks for new sharing once a minute in the
foreground and not at all in the background, so keep Bicino open, or bring it
back to the foreground, after `run` starts.

Your app's outgoing toggles start off. Turn on one demo friend's toggle to test
sending your phone's actual live data back to that test account. `status` should
show `seesYourSharing` and `receivesStats` only for the selected recipients.
Turning a toggle off stops that direction; the demo rider's independent incoming
stream continues. Keep your outgoing toggles off when you finish testing.

`stop` signals the owned simulator process and revokes the test riders' outgoing
consents. The clearly labelled test friendships remain available for future
tests. Stale samples also expire through the normal 60-second server/client
policy. The process does not survive a backend container replacement; rerun the
command after a deployment. The operator wrapper recopies the program and public
client configuration from `/opt/bicino-social-dev/demo-friends`; it stores no
Firebase service-account key or token there. It never changes app runtime env
files, deployment image pins, database rows directly, or production accounts.

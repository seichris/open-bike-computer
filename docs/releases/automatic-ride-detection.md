# Automatic Ride Detection release note (gated draft)

Bicino can recognize sustained outdoor cycling on compatible Bike Computer
hardware, ask to start a Watch-owned ride, and automatically pause and resume
that ride at sustained stops.

- **Ask to Start** remains the safe default.
- **Start Automatically** is opt-in and requires a reachable, authorized Apple
  Watch with the Bicino companion installed.
- Manual pause, resume, finish, discard, and **Not Now** always take precedence.
- Workout screens distinguish **Auto-Paused** from **Paused** and show wall
  **Elapsed** time separately from HealthKit **Moving** time.
- HealthKit remains Watch-owned; the bike computer does not save a second ride
  or provide standalone ride history.

This note is prepared for a future staged release. Production firmware must not
advertise the feature until the trace, false-start, recovery, compatibility,
and both-board stability gates in the implementation plan have passed.

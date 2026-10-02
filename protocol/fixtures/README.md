# World Radio wire fixtures

`world-radio-v1.txt` contains independently specified request/status bytes and
malformed inputs. It is intentionally not generated from either codec.
`test_world_radio_protocol.cpp` checks firmware decoding and encoding;
`WorldRadioTests.swift` checks phone decoding and status encoding against the
same file. Run the tests from the repository root (C++ also supports `esp32/`).
The optional first C++ argument overrides the fixture path.

Coverage includes negative and boundary E7 coordinates, `UInt32.max` request
identity, full UTF-8 byte budgets (48/28/24), NFC accents, reserved bytes,
unknown versions/commands/states, zero IDs and short/overlong packets.
There are no protocol layout or version changes in the reuse refactor.

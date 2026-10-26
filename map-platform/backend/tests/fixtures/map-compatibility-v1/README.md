# Durable map corpus, contract v1

Frozen producer output for
[`map-compatibility-contract-v1.json`](../../../../config/map-compatibility-contract-v1.json).
The [durable map compatibility](../../../../../docs/map-compatibility-contract.md)
guarantee is that every later app, firmware and backend still reads these exact
bytes.

`tests/map_compatibility_fixture.py` built this directory once, on 2026-10-26,
with the real packaging, promotion, companion and signing code. It contains:

- one development-signed stream per contract profile (`*.development.bmap`);
- production promotions for every production-eligible profile, plus a rotated
  production key and an updated worker for `buildings-3d-v1`;
- the iPhone contour companion for each contour profile (`*.btopo`);
- `corpus.json`, the delivery metadata (job artifacts and catalog
  publications), and `corpus.txt`, a line index for the firmware host tests.

The signers use public test scalars. The trust tooling rejects their key IDs and
public keys, so no production app or firmware can trust them.

Never regenerate or edit these files. Backend, iPhone, firmware and catalog
tests pin the hashes. When a reader cannot read a frozen map, fix the reader or
add a verified migration. A later contract revision gets a new corpus
directory: run the generator with a new `--output`, which refuses to overwrite
an existing directory.

# Licensing

Open Bike Computer is a multi-license open source repository. The license that
applies depends on the component and on whether the material is
project-authored or comes from a third party.

## Network service: AGPL-3.0-only

Unless a more specific notice applies, project-authored software source code,
tests, scripts, and software configuration in these paths are licensed under
the [GNU Affero General Public License version 3 only](LICENSES/AGPL-3.0-only.txt):

- `backend/`
- `config/`

The AGPL applies its source-sharing requirements to modified versions that
users interact with remotely over a network as well as to distributed copies.

## Distributed and local software: GPL-3.0-only

Unless a more specific notice applies, all other project-authored software
source code, tests, scripts, and software configuration are licensed under the
[GNU General Public License version 3 only](LICENSE). This includes the iOS
application, top-level tooling, and GitHub workflows.

The following imported or derived components retain their existing GNU GPL
version 3 terms as stated by their own notices. This licensing change does not
alter whether those existing terms permit a later GPL version:

- `esp32/` — see [`esp32/LICENSE`](esp32/LICENSE)
- `tools/OSM_Extract/` — see
  [`tools/OSM_Extract/LICENSE`](tools/OSM_Extract/LICENSE)

The backend container image combines the AGPL-covered backend and configuration
with the GPL-covered `tools/OSM_Extract` component. Section 13 of AGPLv3 permits
that combination: the backend and configuration remain under AGPL-3.0-only,
while `tools/OSM_Extract` remains under its existing GPL version 3 terms.

## Separate licenses and official distribution

The repository owner may offer project-authored software under separate terms,
including terms suitable for official App Store distribution or proprietary
commercial integration. The public AGPL and GPL grants remain available and
are not withdrawn by a separate license.

The [Contributor License Agreement](CLA.md) gives the repository owner the
rights needed to offer accepted contributions under separate terms while
promising that each accepted contribution also remains available under the
public license that applied to its component when it was submitted.

These separate-licensing rights do not cover upstream or third-party material
that the repository owner does not have the right to relicense.

## Third-party and other material

Third-party source code, libraries, generated artifacts, fonts, images,
reference documents, map data, and other bundled material remain subject to
their own notices and licenses. A component-level or file-level license takes
priority over the repository-level license.

The Battery Status screen's bicycle geometry in
`esp32/lib/gui/src/batteryStatusScr.cpp` is adapted from the Lucide Bike icon
and remains available under the [Lucide ISC license](LICENSES/Lucide-ISC.txt).

Documentation, artwork, trademarks, hardware reference documents, and other
non-software material are not licensed by the software licenses above. All
rights in that material remain with their respective copyright or other rights
holders unless a specific notice says otherwise.

The project name, logos, and other marks are not licensed for use as trademarks
by any software license in this repository.

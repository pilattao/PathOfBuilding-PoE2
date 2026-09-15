# PoB2 MCP API adapter

Work-in-progress port of the JSON-line TCP/stdio adapter from
[charleslucas/PathOfBuilding](https://github.com/charleslucas/PathOfBuilding/tree/dce0763b627876f511489cac0adaf4f2622d0dbc/src/API)
to Path of Building Community (PoE2). Upstream adapter provenance and the
repository MIT licence are retained.

The PoB2 core tree contract includes `weaponSets` (node ID to 0/common,
1/first weapon, 2/second weapon) and the nine-argument `ImportFromNodeList` ABI.
Omitted assignments preserve current modes; an explicit empty map clears them.
Resource exports include Spirit and Ward and identify the actual passive-tree
version rather than the build-format compatibility version.

The matching suite provides a reversible installer in
`scripts/install_pob2_api.py` and adapter contract tests in `tests/poe2/`.
The installer enables the API only with `POB_API_TCP=1`. It binds exclusively
to loopback. Choose a free `POB_API_TCP_PORT` and inspect `API/startup.log` for
startup failures. The normal PoB2 updater remains available; reinstall the
hook after it replaces Main.lua.

Core reads, tree preservation, level/skill/config/item/charm mutations and
rollback have been tested against a real PoB2 0.23.1 process. A 650 KB export
was received intact. The TCP adapter queues partial writes across frames. This does not certify every inherited handler;
full per-tool coverage is tracked by the suite's ongoing PoE2 port.

# Vendored test dependencies

Test-only sources, committed as ordinary files so the suite builds with no network.
Nothing under this directory is deployed; `src/HOODTToken.sol` imports nothing.

- `v4-core/src`: Uniswap v4 core, commit 46c6834698c48bc4a463a86d8420f4eb1d7f3b75
  (https://github.com/Uniswap/v4-core), the `src/` tree without `src/test`. Licences are in
  `v4-core/licenses/`. One edit: `src/ProtocolFees.sol` imports solmate's `Owned` by the
  relative path `../../solmate/src/auth/Owned.sol` instead of the `solmate/` remapping,
  because `remappings.txt` is not part of this task's write scope.
- `solmate/src/auth/Owned.sol`: transmissions11/solmate `src/auth/Owned.sol` (MIT, SPDX
  header in the file), the only solmate file v4-core's `src/` needs.

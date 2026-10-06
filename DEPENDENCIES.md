# Vendored dependencies

All required Solidity dependencies are ordinary files in `lib/`; builds need no package downloads.

- `lib/forge-std`: Foundry standard library **v1.9.7**, from
  <https://github.com/foundry-rs/forge-std/tree/v1.9.7>. Includes upstream `src/`
  and MIT / Apache-2.0 license files. Test-only dependency.
- `lib/openzeppelin-contracts`: OpenZeppelin Contracts **v5.0.2**, from
  <https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2>.
  Includes only Ownable, Ownable2Step, Pausable, ReentrancyGuard, SafeERC20 and
  their transitive imports, plus the upstream MIT license. Sources are unmodified.

The build pins Solidity 0.8.26 by version; the verifier supplies this compiler.
No compiler binary, submodule, FFI, filesystem permission, or runtime download is required.

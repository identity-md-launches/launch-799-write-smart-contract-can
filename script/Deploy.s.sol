// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CappedAssetVault} from "../src/CappedAssetVault.sol";
import {OpenDepositPolicy} from "../src/OpenDepositPolicy.sol";

/// @notice Local deployment rehearsal, with explicit arguments and no environment or broadcast calls.
/// @dev The project factory deploys the two application contracts directly with these same arguments.
contract Deploy {
    function run(address owner, address usdt, address usdc, uint8 imdDecimals)
        external
        returns (OpenDepositPolicy policy, CappedAssetVault vault)
    {
        policy = new OpenDepositPolicy();
        vault = new CappedAssetVault(owner, usdt, usdc, imdDecimals, address(policy));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IDepositPolicy} from "./interfaces/IDepositPolicy.sol";

/// @notice Version 1 admits everyone; the vault itself always enforces pause, assets and cap.
contract OpenDepositPolicy is IDepositPolicy {
    function policyId() external pure returns (bytes32) {
        return keccak256("identitymd.capped-vault.deposit-policy.v1");
    }

    function allowsDeposit(address, address, address, uint256, uint256) external pure returns (bool) {
        return true;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IDepositPolicy} from "../../src/interfaces/IDepositPolicy.sol";

contract RestrictedPolicy is IDepositPolicy {
    address public immutable depositor;

    constructor(address depositor_) {
        depositor = depositor_;
    }

    function policyId() external pure returns (bytes32) {
        return keccak256("identitymd.capped-vault.deposit-policy.v1");
    }

    function allowsDeposit(address, address sender, address, uint256, uint256) external view returns (bool) {
        return sender == depositor;
    }
}

contract WrongPolicy {
    function policyId() external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @dev ABI-compatible but intentionally attempts SSTORE; the vault must invoke it statically.
contract WritingPolicy {
    uint256 public writes;

    function policyId() external pure returns (bytes32) {
        return keccak256("identitymd.capped-vault.deposit-policy.v1");
    }

    function allowsDeposit(address, address, address, uint256, uint256) external returns (bool) {
        writes++;
        return true;
    }
}

contract RevertingPolicy is IDepositPolicy {
    function policyId() external pure returns (bytes32) {
        return keccak256("identitymd.capped-vault.deposit-policy.v1");
    }

    function allowsDeposit(address, address, address, uint256, uint256) external pure returns (bool) {
        revert("policy unavailable");
    }
}

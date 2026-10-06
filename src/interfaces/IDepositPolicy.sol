// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Replaceable deposit admission logic; called with STATICCALL, never delegatecall.
interface IDepositPolicy {
    function policyId() external view returns (bytes32);

    /// @param asset address(0) means native ETH.
    /// @param amount Actual amount received, in the asset's smallest units.
    /// @param totalUsdWad Combined value after receipt, in 18-decimal dollars.
    function allowsDeposit(address vault, address depositor, address asset, uint256 amount, uint256 totalUsdWad)
        external
        view
        returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CappedAssetVault} from "../../src/CappedAssetVault.sol";

contract RejectingReceiver {
    receive() external payable {
        revert("ETH rejected");
    }
}

contract ReenteringReceiver {
    CappedAssetVault public vault;
    bool public reentered;
    bytes public reason;

    function configure(CappedAssetVault vault_) external {
        vault = vault_;
    }

    receive() external payable {
        (reentered, reason) = address(vault).call(abi.encodeCall(vault.withdrawETH, (1)));
    }
}

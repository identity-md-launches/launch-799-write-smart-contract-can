// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultBase} from "./VaultBase.sol";
import {CappedAssetVault} from "../src/CappedAssetVault.sol";
import {OpenDepositPolicy} from "../src/OpenDepositPolicy.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract LocalFactory {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "deployment failed");
    }
}

contract DeploymentTest is VaultBase {
    function test_DeploymentRehearsalTakesExplicitArguments() public {
        Deploy deployer = new Deploy();
        vm.prank(STRANGER);
        (OpenDepositPolicy nextPolicy, CappedAssetVault nextVault) =
            deployer.run(OWNER, address(usdt), address(usdc), 18);
        assertEq(nextVault.owner(), OWNER);
        assertEq(address(nextVault.depositPolicy()), address(nextPolicy));
        assertEq(nextVault.WITHDRAWER(), PAYEE);
        _checkRuntime(address(nextPolicy));
        _checkRuntime(address(nextVault));
    }

    function test_FactoryStaticConstructorsAndRuntimeRestrictions() public {
        LocalFactory factory = new LocalFactory();
        address nextPolicy = factory.deploy(type(OpenDepositPolicy).creationCode, bytes32(uint256(1)));
        bytes memory code = abi.encodePacked(
            type(CappedAssetVault).creationCode, abi.encode(OWNER, address(usdt), address(usdc), uint8(18), nextPolicy)
        );
        assertLe(code.length, 49_152);
        address nextVault = factory.deploy(code, bytes32(uint256(2)));
        assertEq(CappedAssetVault(payable(nextVault)).owner(), OWNER);
        assertEq(CappedAssetVault(payable(nextVault)).WITHDRAWER(), PAYEE);
        _checkRuntime(nextPolicy);
        _checkRuntime(nextVault);
    }

    function _checkRuntime(address application) private view {
        bytes memory code = application.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}

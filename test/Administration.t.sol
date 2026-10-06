// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultBase} from "./VaultBase.sol";
import {RestrictedPolicy, WrongPolicy, WritingPolicy, RevertingPolicy} from "./mocks/Policies.sol";
import {CappedAssetVault} from "../src/CappedAssetVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract AdministrationTest is VaultBase {
    function test_OnlyOwnerPausesAndUpgrades() public {
        _assertNotAdministrator(ALICE);
        _assertNotAdministrator(STRANGER);
        _assertNotAdministrator(PAYEE);
    }

    function test_TwoStepOwnershipPreservesWithdrawalAddress() public {
        vm.prank(OWNER);
        vault.transferOwnership(ALICE);
        assertEq(vault.owner(), OWNER);
        assertEq(vault.pendingOwner(), ALICE);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        vault.acceptOwnership();
        vm.prank(ALICE);
        vault.acceptOwnership();
        assertEq(vault.owner(), ALICE);
        assertEq(vault.pendingOwner(), address(0));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        vault.pause();
        vm.prank(ALICE);
        vault.pause();
        assertEq(vault.WITHDRAWER(), PAYEE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.UnauthorizedWithdrawer.selector, ALICE));
        vault.withdrawETH(1);
    }

    function test_ZeroSelfAndRenouncedOwnershipRejected() public {
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        vault.transferOwnership(address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(vault)));
        vault.transferOwnership(address(vault));
        vm.expectRevert(CappedAssetVault.OwnershipRenunciationDisabled.selector);
        vault.renounceOwnership();
        vm.stopPrank();
        assertEq(vault.owner(), OWNER);
    }

    function test_UpgradeRequiresPause() public {
        RestrictedPolicy next = new RestrictedPolicy(ALICE);
        vm.prank(OWNER);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vault.upgradeTo(address(next));
    }

    function test_UpgradeChangesAdmissionAndPreservesCustodyState() public {
        _eth(1 ether);
        _deposit(usdt, 100e6);
        RestrictedPolicy next = new RestrictedPolicy(ALICE);
        vm.startPrank(OWNER);
        vault.transferOwnership(STRANGER);
        vault.pause();
        vm.expectEmit(true, true, false, true, address(vault));
        emit CappedAssetVault.PolicyUpgraded(address(policy), address(next));
        vault.upgradeTo(address(next));
        assertTrue(vault.paused());
        assertEq(vault.owner(), OWNER);
        assertEq(vault.pendingOwner(), STRANGER);
        assertEq(address(vault.depositPolicy()), address(next));
        assertEq(vault.totalValueUsd(), 2700e18);
        assertEq(vault.WITHDRAWER(), PAYEE);
        vault.unpause();
        vm.stopPrank();
        vm.prank(STRANGER);
        vm.expectRevert(CappedAssetVault.DepositRejected.selector);
        vault.depositETH{value: 1 ether}();
        assertEq(address(vault).balance, 1 ether);
        _eth(1 ether);
        assertEq(vault.totalValueUsd(), 5300e18);
        vm.prank(PAYEE);
        vault.withdrawAll(address(0));
        assertEq(PAYEE.balance, 2 ether);
    }

    function test_PolicyRejectionRollsBackTokenTransfer() public {
        RestrictedPolicy next = new RestrictedPolicy(STRANGER);
        _upgrade(address(next));
        vm.startPrank(ALICE);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(CappedAssetVault.DepositRejected.selector);
        vault.depositToken(address(usdc), 1e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.allowance(ALICE, address(vault)), 1e6);
    }

    function test_PolicyCannotBypassCap() public {
        _fill();
        RestrictedPolicy next = new RestrictedPolicy(ALICE);
        _upgrade(address(next));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.CapExceeded.selector, 10_000e18 + 2600));
        vault.depositETH{value: 1}();
    }

    function test_InvalidUpgradesLeaveExistingPolicy() public {
        WrongPolicy wrong = new WrongPolicy();
        vm.prank(OWNER);
        vault.pause();
        _assertInvalidPolicy(address(0));
        _assertInvalidPolicy(STRANGER);
        _assertInvalidPolicy(address(vault));
        _assertInvalidPolicy(address(usdc));
        _assertInvalidPolicy(address(wrong));
        assertEq(address(vault.depositPolicy()), address(policy));
    }

    function test_StaticPolicyCannotWriteAndWithdrawalStillWorks() public {
        _eth(1 ether);
        WritingPolicy next = new WritingPolicy();
        _upgrade(address(next));
        vm.prank(ALICE);
        (bool ok,) = address(vault).call{value: 1, gas: 200_000}(abi.encodeCall(vault.depositETH, ()));
        assertFalse(ok);
        assertEq(next.writes(), 0);
        assertEq(address(vault).balance, 1 ether);
        vm.prank(PAYEE);
        vault.withdrawAll(address(0));
        assertEq(PAYEE.balance, 1 ether);
        _upgrade(address(policy));
        _eth(1 ether);
    }

    function test_RevertingPolicyCannotBlockWithdrawalsOrReplacement() public {
        _fill();
        RevertingPolicy next = new RevertingPolicy();
        _upgrade(address(next));
        vm.prank(PAYEE);
        vault.withdrawAll(address(usdc));
        vm.expectRevert(bytes("policy unavailable"));
        vault.depositETH{value: 1}();
        vm.prank(PAYEE);
        vault.withdrawAll(address(0));
        _upgrade(address(policy));
        _eth(1 ether);
        assertEq(vault.totalValueUsd(), 6500e18);
    }

    function test_ConstructorRejectsInvalidConfiguration() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CappedAssetVault(address(0), address(usdt), address(usdc), 18, address(policy));
        vm.expectRevert(CappedAssetVault.InvalidTokenConfiguration.selector);
        new CappedAssetVault(OWNER, address(0), address(usdc), 18, address(policy));
        vm.expectRevert(CappedAssetVault.InvalidTokenConfiguration.selector);
        new CappedAssetVault(OWNER, address(usdt), address(0), 18, address(policy));
        vm.expectRevert(CappedAssetVault.InvalidTokenConfiguration.selector);
        new CappedAssetVault(OWNER, address(usdc), address(usdc), 18, address(policy));
        vm.expectRevert(CappedAssetVault.InvalidTokenConfiguration.selector);
        new CappedAssetVault(OWNER, IMD_ADDRESS, address(usdc), 18, address(policy));
        vm.expectRevert(CappedAssetVault.InvalidTokenConfiguration.selector);
        new CappedAssetVault(OWNER, address(usdt), IMD_ADDRESS, 18, address(policy));
        vm.expectRevert(CappedAssetVault.InvalidTokenConfiguration.selector);
        new CappedAssetVault(OWNER, address(usdt), address(usdc), 19, address(policy));
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.InvalidPolicy.selector, address(0)));
        new CappedAssetVault(OWNER, address(usdt), address(usdc), 18, address(0));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_NonOwnerCannotAdminister(address caller) public {
        if (caller == OWNER) caller = STRANGER;
        _assertNotAdministrator(caller);
    }

    function _assertNotAdministrator(address caller) private {
        bytes memory reason = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
        vm.startPrank(caller);
        vm.expectRevert(reason);
        vault.pause();
        vm.expectRevert(reason);
        vault.unpause();
        vm.expectRevert(reason);
        vault.upgradeTo(address(policy));
        vm.expectRevert(reason);
        vault.transferOwnership(ALICE);
        vm.expectRevert(reason);
        vault.renounceOwnership();
        vm.stopPrank();
    }

    function _upgrade(address next) private {
        vm.startPrank(OWNER);
        vault.pause();
        vault.upgradeTo(next);
        vault.unpause();
        vm.stopPrank();
    }

    function _assertInvalidPolicy(address next) private {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.InvalidPolicy.selector, next));
        vault.upgradeTo(next);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultBase} from "./VaultBase.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {CappedAssetVault} from "src/CappedAssetVault.sol";
import {IDepositPolicy} from "src/interfaces/IDepositPolicy.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Accepts only the exact post-transfer context configured by the test.
contract ContextPolicy is IDepositPolicy {
    bytes32 private immutable expected;

    constructor(address vault, address sender, address asset, uint256 received, uint256 value) {
        expected = keccak256(abi.encode(vault, sender, asset, received, value));
    }

    function policyId() external pure returns (bytes32) {
        return keccak256("identitymd.capped-vault.deposit-policy.v1");
    }

    function allowsDeposit(address vault, address sender, address asset, uint256 received, uint256 value)
        external
        view
        returns (bool)
    {
        return msg.sender == vault && keccak256(abi.encode(vault, sender, asset, received, value)) == expected;
    }
}

contract WithdrawalForwarder {
    function forward(address vault, bytes calldata data) external returns (bool, bytes memory) {
        return vault.call(data);
    }
}

/// @dev Installed at the authorized payee so callbacks exercise the guard with valid authority.
contract TokenWithdrawalCallback {
    bool public succeeded;
    bytes public reason;

    function attempt(address vault, bytes calldata data) external {
        (succeeded, reason) = vault.call(data);
    }
}

contract AdversarialVaultTest is VaultBase {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_MixedCapAcrossSendersAndRefill(uint256 ethSeed, uint256 imdSeed, uint256 split) public {
        // Each leg has an integral six-decimal dollar value; the stablecoins fill the exact remainder.
        uint256 ethAmount = bound(ethSeed, 0, 30_000) * 1e14;
        uint256 imdAmount = bound(imdSeed, 0, 100_000_000) * 1e12;
        uint256 stableAmount = (10_000e18 - ethAmount * 2600 - imdAmount * 9) / 1e12;
        uint256 usdtAmount = bound(split, 0, stableAmount - 1);
        uint256 usdcAmount = stableAmount - usdtAmount;
        if (ethAmount != 0) _eth(ethAmount);
        if (imdAmount != 0) _deposit(imd, imdAmount);
        if (usdtAmount != 0) _deposit(usdt, usdtAmount);
        _fund(STRANGER);
        vm.startPrank(STRANGER);
        usdc.approve(address(vault), usdcAmount);
        vault.depositToken(address(usdc), usdcAmount);
        vm.stopPrank();
        assertEq(vault.totalValueUsd(), 10_000e18);
        assertEq(vault.remainingCapacityUsd(), 0);

        _rejectExtraUnit(usdt, 1e12);
        _rejectExtraUnit(usdc, 1e12);
        _rejectExtraUnit(imd, 9);
        uint256 beforeETH = ALICE.balance;
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.CapExceeded.selector, 10_000e18 + 2600));
        vault.depositETH{value: 1}();
        assertEq(ALICE.balance, beforeETH);

        uint256 removed = bound(split, 1, usdcAmount);
        vm.prank(PAYEE);
        vault.withdrawToken(address(usdc), removed);
        assertEq(usdc.balanceOf(PAYEE), removed);
        _deposit(usdt, removed);
        assertEq(vault.totalValueUsd(), 10_000e18, "another asset can refill withdrawn capacity");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_IMDDecimalBoundaryAndFullWithdrawal(uint8 decimalSeed) public {
        _imdBoundary(uint8(bound(decimalSeed, 0, 18)));
    }

    function test_IMDZeroAndEighteenDecimalBoundaries() public {
        _imdBoundary(0);
        _imdBoundary(18);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FeeReceiptCapAndAtomicRollback(uint256 amountSeed, uint16 feeSeed) public {
        uint256 amount = bound(amountSeed, 1, 20_000e6);
        uint256 feeBps = bound(feeSeed, 0, 10_000);
        uint256 received = amount - amount * feeBps / 10_000;
        usdc.setBehavior(0, feeBps, false, false);
        uint256 supplyBefore = usdc.totalSupply();
        uint256 senderBefore = usdc.balanceOf(ALICE);
        vm.startPrank(ALICE);
        usdc.approve(address(vault), amount);
        if (received == 0) {
            vm.expectRevert(CappedAssetVault.InvalidReceipt.selector);
        } else if (received > 10_000e6) {
            vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.CapExceeded.selector, received * 1e12));
        } else {
            vm.expectEmit(true, true, false, true, address(vault));
            emit CappedAssetVault.Deposited(ALICE, address(usdc), received, received * 1e12);
        }
        vault.depositToken(address(usdc), amount);
        vm.stopPrank();

        if (received == 0 || received > 10_000e6) {
            assertEq(usdc.balanceOf(ALICE), senderBefore);
            assertEq(usdc.balanceOf(address(vault)), 0);
            assertEq(usdc.totalSupply(), supplyBefore, "rejected deposits must undo fee burns");
            assertEq(usdc.allowance(ALICE, address(vault)), amount);
            assertEq(vault.remainingCapacityUsd(), 10_000e18);
        } else {
            assertEq(usdc.balanceOf(ALICE), senderBefore - amount);
            assertEq(usdc.balanceOf(address(vault)), received);
            assertEq(usdc.totalSupply(), supplyBefore - (amount - received));
            assertEq(usdc.allowance(ALICE, address(vault)), 0);
            usdc.setBehavior(0, 0, false, false);
            vm.prank(PAYEE);
            vault.withdrawAll(address(usdc));
            assertEq(usdc.balanceOf(PAYEE), received);
            assertEq(vault.remainingCapacityUsd(), 10_000e18);
        }
    }

    function test_PolicyGetsActualReceiptAndCombinedPostTransferValue() public {
        _eth(1 ether);
        _deposit(usdt, 300e6);
        usdc.setBehavior(0, 1000, false, false);
        ContextPolicy exact = new ContextPolicy(address(vault), ALICE, address(usdc), 90e6, 2990e18);
        _install(address(exact));
        _deposit(usdc, 100e6);
        assertEq(usdc.balanceOf(address(vault)), 90e6);
        assertEq(vault.totalValueUsd(), 2990e18);
        vm.startPrank(ALICE);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(CappedAssetVault.DepositRejected.selector);
        vault.depositToken(address(usdc), 100e6);
        vm.stopPrank();
        assertEq(vault.totalValueUsd(), 2990e18);
        assertEq(usdc.allowance(ALICE, address(vault)), 100e6);
    }

    function test_ReceivePassesActualSenderAndETHContextToPolicy() public {
        _deposit(usdc, 100e6);
        ContextPolicy exact = new ContextPolicy(address(vault), STRANGER, address(0), 1 ether, 2700e18);
        _install(address(exact));
        vm.prank(ALICE);
        (bool wrongSender, bytes memory reason) = address(vault).call{value: 1 ether}("");
        assertFalse(wrongSender);
        assertEq(reason, abi.encodeWithSelector(CappedAssetVault.DepositRejected.selector));
        vm.prank(STRANGER);
        (bool accepted,) = address(vault).call{value: 1 ether}("");
        assertTrue(accepted);
        assertEq(vault.totalValueUsd(), 2700e18);
    }

    function test_BeneficiaryTransactionOriginDoesNotAuthorizeIntermediary() public {
        _fill();
        WithdrawalForwarder intermediary = new WithdrawalForwarder();
        vm.prank(PAYEE, PAYEE);
        (bool ok, bytes memory reason) =
            intermediary.forward(address(vault), abi.encodeCall(vault.withdrawAll, (address(0))));
        assertFalse(ok);
        assertEq(
            reason, abi.encodeWithSelector(CappedAssetVault.UnauthorizedWithdrawer.selector, address(intermediary))
        );
        assertEq(vault.totalValueUsd(), 10_000e18);
        assertEq(PAYEE.balance, 0);
    }

    function test_AuthorizedTokenCallbackCannotReenterAnyWithdrawalPath() public {
        _fill();
        TokenWithdrawalCallback callback = new TokenWithdrawalCallback();
        vm.etch(PAYEE, address(callback).code);
        bytes[] memory attempts = new bytes[](4);
        attempts[0] = abi.encodeCall(vault.withdrawETH, (1));
        attempts[1] = abi.encodeCall(vault.withdrawToken, (address(usdt), 1));
        attempts[2] = abi.encodeCall(vault.withdrawAll, (address(0)));
        attempts[3] = abi.encodeCall(vault.withdrawAll, (address(imd)));
        for (uint256 i; i < attempts.length; ++i) {
            usdc.setCallback(PAYEE, abi.encodeCall(callback.attempt, (address(vault), attempts[i])));
            vm.prank(PAYEE);
            vault.withdrawToken(address(usdc), 1e6);
            assertFalse(TokenWithdrawalCallback(PAYEE).succeeded());
            assertEq(
                TokenWithdrawalCallback(PAYEE).reason(),
                abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            );
        }
        assertEq(usdc.balanceOf(PAYEE), 4e6);
        assertEq(usdc.balanceOf(address(vault)), 3496e6);
        assertEq(address(vault).balance, 1 ether);
        assertEq(usdt.balanceOf(address(vault)), 3000e6);
        assertEq(imd.balanceOf(address(vault)), 100e18);
    }

    function test_OverflowingUnsolicitedTokenBalanceFailsClosedButCanBeRecovered() public {
        _eth(1 ether);
        uint256 hugeAmount = type(uint256).max / 1e12 + 1;
        usdc.mint(address(vault), hugeAmount);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vault.depositETH{value: 1}();
        assertEq(address(vault).balance, 1 ether);
        vm.prank(OWNER);
        vault.pause();
        vm.startPrank(PAYEE);
        vault.withdrawAll(address(0));
        vault.withdrawAll(address(usdc));
        vm.stopPrank();
        assertEq(usdc.balanceOf(PAYEE), hugeAmount);
        assertEq(PAYEE.balance, 1 ether);
        assertEq(vault.remainingCapacityUsd(), 10_000e18);
    }

    function _imdBoundary(uint8 decimals_) private {
        CappedAssetVault target = new CappedAssetVault(OWNER, address(usdt), address(usdc), decimals_, address(policy));
        uint256 oneToken = 10 ** decimals_;
        uint256 limit = 10_000 * oneToken / 9;
        uint256 payeeBefore = imd.balanceOf(PAYEE);
        vm.startPrank(ALICE);
        imd.approve(address(target), limit + 1);
        target.depositToken(address(imd), oneToken);
        assertEq(target.totalValueUsd(), 9e18);
        target.depositToken(address(imd), limit - oneToken);
        assertLe(target.totalValueUsd(), 10_000e18);
        assertLt(target.remainingCapacityUsd(), 9e18 / oneToken);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.CapExceeded.selector, (limit + 1) * (9e18 / oneToken)));
        target.depositToken(address(imd), 1);
        vm.stopPrank();
        assertEq(imd.balanceOf(address(target)), limit);
        assertEq(imd.allowance(ALICE, address(target)), 1);
        vm.prank(PAYEE);
        target.withdrawAll(address(imd));
        assertEq(imd.balanceOf(PAYEE) - payeeBefore, limit);
        assertEq(target.remainingCapacityUsd(), 10_000e18);
    }

    function _rejectExtraUnit(MockToken token, uint256 unitValue) private {
        uint256 beforeBalance = token.balanceOf(ALICE);
        vm.startPrank(ALICE);
        token.approve(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.CapExceeded.selector, 10_000e18 + unitValue));
        vault.depositToken(address(token), 1);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), beforeBalance);
        assertEq(token.allowance(ALICE, address(vault)), 1);
    }

    function _install(address next) private {
        vm.startPrank(OWNER);
        vault.pause();
        vault.upgradeTo(next);
        vault.unpause();
        vm.stopPrank();
    }
}

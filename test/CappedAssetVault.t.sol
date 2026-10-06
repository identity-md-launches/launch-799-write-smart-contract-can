// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultBase} from "./VaultBase.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {RejectingReceiver, ReenteringReceiver} from "./mocks/Receivers.sol";
import {CappedAssetVault} from "../src/CappedAssetVault.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CappedAssetVaultTest is VaultBase {
    function test_ConstructorSetsExplicitRolesAndPrices() public view {
        assertEq(vault.owner(), OWNER);
        assertEq(vault.WITHDRAWER(), PAYEE);
        assertEq(vault.IMD(), IMD_ADDRESS);
        assertEq(vault.USDT(), address(usdt));
        assertEq(vault.USDC(), address(usdc));
        assertEq(vault.imdDecimals(), 18);
        assertEq(vault.ETH_PRICE_USD(), 2600);
        assertEq(vault.IMD_PRICE_USD(), 9);
        assertEq(vault.remainingCapacityUsd(), 10_000e18);
        assertFalse(vault.paused());
    }

    function test_AllFourAssetsFillOneSharedCap() public {
        _fill();
        assertEq(vault.totalValueUsd(), 10_000e18);
        assertEq(vault.remainingCapacityUsd(), 0);
        assertEq(address(vault).balance, 1 ether);
        assertEq(imd.balanceOf(address(vault)), 100e18);
        assertEq(usdt.balanceOf(address(vault)), 3000e6);
        assertEq(usdc.balanceOf(address(vault)), 3500e6);
    }

    function test_DepositEmitsActualReceivedAndCombinedValue() public {
        vm.startPrank(ALICE);
        usdc.approve(address(vault), 5e6);
        vm.expectEmit(true, true, false, true, address(vault));
        emit CappedAssetVault.Deposited(ALICE, address(usdc), 5e6, 5e18);
        vault.depositToken(address(usdc), 5e6);
        vm.stopPrank();
    }

    function test_ReceiveUsesCapAndPauseChecks() public {
        vm.prank(ALICE);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.totalValueUsd(), 2600e18);
        vm.prank(ALICE);
        (ok,) = address(vault).call{value: 3 ether}("");
        assertFalse(ok);
        assertEq(address(vault).balance, 1 ether);
        vm.prank(OWNER);
        vault.pause();
        vm.prank(ALICE);
        (ok,) = address(vault).call{value: 1}("");
        assertFalse(ok);
    }

    function test_UnknownSelectorRejectsETH() public {
        (bool ok,) = address(vault).call{value: 1 ether}(hex"12345678");
        assertFalse(ok);
        assertEq(address(vault).balance, 0);
    }

    function test_ZeroDepositsRejected() public {
        vm.expectRevert(CappedAssetVault.ZeroAmount.selector);
        vault.depositETH();
        vm.expectRevert(CappedAssetVault.ZeroAmount.selector);
        vault.depositToken(address(usdt), 0);
        (bool ok,) = address(vault).call("");
        assertFalse(ok);
    }

    function test_UnsupportedAssetRejected() public {
        MockToken other = new MockToken(18);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.UnsupportedAsset.selector, address(other)));
        vault.depositToken(address(other), 1);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.UnsupportedAsset.selector, address(0)));
        vault.depositToken(address(0), 1);
    }

    function test_ExcessTokenDepositRollsBackBalancesAndAllowance() public {
        _fill();
        vm.startPrank(ALICE);
        usdc.approve(address(vault), 1);
        uint256 beforeBalance = usdc.balanceOf(ALICE);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.CapExceeded.selector, 10_000e18 + 1e12));
        vault.depositToken(address(usdc), 1);
        assertEq(usdc.balanceOf(ALICE), beforeBalance);
        assertEq(usdc.allowance(ALICE, address(vault)), 1);
        assertEq(usdc.balanceOf(address(vault)), 3500e6);
        vm.stopPrank();
    }

    function test_ETHBoundaryOneWeiAboveFails() public {
        uint256 limit = uint256(10_000e18) / 2600;
        _eth(limit);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.CapExceeded.selector, (limit + 1) * 2600));
        vault.depositETH{value: 1}();
        assertEq(address(vault).balance, limit);
    }

    function test_IMDBoundaryAndRepeatedDustCannotEvadeCap() public {
        uint256 limit = uint256(10_000e18) / 9;
        _deposit(imd, limit - 2);
        _deposit(imd, 1);
        _deposit(imd, 1);
        vm.startPrank(ALICE);
        imd.approve(address(vault), 1);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.CapExceeded.selector, (limit + 1) * 9));
        vault.depositToken(address(imd), 1);
        vm.stopPrank();
        assertEq(vault.totalValueUsd(), limit * 9);
    }

    function test_StablecoinSixDecimalsAndIMDEighteenDecimals() public {
        _deposit(usdt, 1);
        _deposit(usdc, 1);
        _deposit(imd, 1);
        _eth(1);
        assertEq(vault.totalValueUsd(), 2e12 + 9 + 2600);
    }

    function test_ConfiguredIMDDecimalsAreUsedExactly() public {
        CappedAssetVault six = new CappedAssetVault(OWNER, address(usdt), address(usdc), 6, address(policy));
        imd.mint(address(six), 1e6);
        assertEq(six.totalValueUsd(), 9e18);
    }

    function test_NoAllowanceOrBalanceCannotDeposit() public {
        vm.prank(ALICE);
        vm.expectRevert();
        vault.depositToken(address(usdc), 1e6);
        vm.startPrank(STRANGER);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert();
        vault.depositToken(address(usdc), 1e6);
        vm.stopPrank();
        assertEq(vault.totalValueUsd(), 0);
    }

    function test_USDTWithoutReturnDataDepositsAndWithdraws() public {
        _deposit(usdt, 20e6);
        vm.prank(PAYEE);
        vault.withdrawToken(address(usdt), 3e6);
        assertEq(usdt.balanceOf(PAYEE), 3e6);
        assertEq(vault.totalValueUsd(), 17e18);
    }

    function test_FalseReturningTokenRollsBackDeposit() public {
        usdc.setBehavior(2, 0, false, false);
        vm.startPrank(ALICE);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
        vault.depositToken(address(usdc), 1e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_MalformedTokenReturnRollsBackDeposit() public {
        usdc.setBehavior(3, 0, false, false);
        vm.startPrank(ALICE);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert();
        vault.depositToken(address(usdc), 1e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_TokenReturningSuccessWithoutMovementRejected() public {
        usdc.setBehavior(0, 0, false, true);
        vm.startPrank(ALICE);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(CappedAssetVault.InvalidReceipt.selector);
        vault.depositToken(address(usdc), 1e6);
        vm.stopPrank();
    }

    function test_FeeOnTransferValuesActualReceiptAtCap() public {
        usdc.setBehavior(0, 1000, false, false);
        _deposit(usdt, 1000e6);
        _deposit(usdc, 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 9000e6);
        assertEq(vault.totalValueUsd(), 10_000e18);
    }

    function test_OneHundredPercentFeeRejected() public {
        usdc.setBehavior(0, 10_000, false, false);
        vm.startPrank(ALICE);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(CappedAssetVault.InvalidReceipt.selector);
        vault.depositToken(address(usdc), 1e6);
        vm.stopPrank();
    }

    function test_TokenDepositReentrancyBlocked() public {
        usdc.setCallback(address(vault), abi.encodeCall(vault.depositETH, ()));
        _deposit(usdc, 1e6);
        assertFalse(usdc.callbackSucceeded());
        assertEq(usdc.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(vault.totalValueUsd(), 1e18);
    }

    function test_UnexpectedBalanceIncreaseRejected() public {
        usdc.setCallback(address(usdc), abi.encodeCall(usdc.mint, (address(vault), 1)));
        vm.startPrank(ALICE);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(CappedAssetVault.InvalidReceipt.selector);
        vault.depositToken(address(usdc), 1e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_TokenTransferRevertRollsBackDeposit() public {
        usdc.setBehavior(0, 0, true, false);
        vm.startPrank(ALICE);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(bytes("token paused"));
        vault.depositToken(address(usdc), 1e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.allowance(ALICE, address(vault)), 1e6);
    }

    function test_DirectTokenDonationsCountAndCanExceedCap() public {
        _deposit(usdc, 9999e6);
        vm.prank(ALICE);
        usdc.transfer(address(vault), 2e6);
        assertEq(vault.totalValueUsd(), 10_001e18);
        assertEq(vault.remainingCapacityUsd(), 0);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.CapExceeded.selector, 10_001e18 + 2600));
        vault.depositETH{value: 1}();
        vm.prank(PAYEE);
        vault.withdrawToken(address(usdc), 2e6);
        _deposit(usdc, 1e6);
        assertEq(vault.totalValueUsd(), 10_000e18);
    }

    function test_ForcedETHCountsAndRemainsWithdrawableWhilePaused() public {
        vm.deal(address(vault), 5 ether);
        assertEq(vault.totalValueUsd(), 13_000e18);
        assertEq(vault.remainingCapacityUsd(), 0);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.CapExceeded.selector, 13_000e18 + 2600));
        vault.depositETH{value: 1}();
        vm.prank(OWNER);
        vault.pause();
        vm.prank(PAYEE);
        vault.withdrawAll(address(0));
        assertEq(PAYEE.balance, 5 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_PartialAndFullWithdrawalsForEveryAssetWhilePaused() public {
        _fill();
        vm.prank(OWNER);
        vault.pause();
        vm.startPrank(PAYEE);
        vault.withdrawETH(0.4 ether);
        vault.withdrawToken(address(usdt), 1000e6);
        vault.withdrawToken(address(usdc), 1000e6);
        vault.withdrawToken(address(imd), 25e18);
        assertEq(vault.totalValueUsd(), 6735e18);
        vault.withdrawAll(address(0));
        vault.withdrawAll(address(usdt));
        vault.withdrawAll(address(usdc));
        vault.withdrawAll(address(imd));
        vm.stopPrank();
        assertEq(vault.totalValueUsd(), 0);
        assertEq(PAYEE.balance, 1 ether);
        assertEq(usdt.balanceOf(PAYEE), 3000e6);
        assertEq(usdc.balanceOf(PAYEE), 3500e6);
        assertEq(imd.balanceOf(PAYEE), 100e18);
    }

    function test_WithdrawalReopensCapacity() public {
        _deposit(usdc, 10_000e6);
        vm.prank(PAYEE);
        vault.withdrawToken(address(usdc), 2600e6);
        _eth(1 ether);
        assertEq(vault.totalValueUsd(), 10_000e18);
    }

    function test_OwnerCannotWithdraw() public {
        _fill();
        _assertNoWithdrawal(OWNER);
        _assertNoWithdrawal(ALICE);
        _assertNoWithdrawal(STRANGER);
        assertEq(vault.totalValueUsd(), 10_000e18);
    }

    function test_ZeroAndExcessWithdrawalsRejected() public {
        _eth(1 ether);
        _deposit(usdt, 1e6);
        vm.startPrank(PAYEE);
        vm.expectRevert(CappedAssetVault.ZeroAmount.selector);
        vault.withdrawETH(0);
        vm.expectRevert(CappedAssetVault.ZeroAmount.selector);
        vault.withdrawToken(address(usdt), 0);
        vm.expectRevert(CappedAssetVault.InsufficientBalance.selector);
        vault.withdrawETH(1 ether + 1);
        vm.expectRevert(CappedAssetVault.InsufficientBalance.selector);
        vault.withdrawToken(address(usdt), 1e6 + 1);
        vm.expectRevert(CappedAssetVault.ZeroAmount.selector);
        vault.withdrawAll(address(usdc));
        vm.stopPrank();
    }

    function test_FailedETHWithdrawalKeepsFundsAndAllowsRetry() public {
        _eth(1 ether);
        RejectingReceiver receiver = new RejectingReceiver();
        vm.etch(PAYEE, address(receiver).code);
        vm.prank(PAYEE);
        vm.expectRevert(CappedAssetVault.EtherTransferFailed.selector);
        vault.withdrawAll(address(0));
        assertEq(address(vault).balance, 1 ether);
        vm.etch(PAYEE, hex"");
        vm.prank(PAYEE);
        vault.withdrawAll(address(0));
        assertEq(address(vault).balance, 0);
    }

    function test_ETHWithdrawalReentrancyBlocked() public {
        _eth(1 ether);
        ReenteringReceiver receiver = new ReenteringReceiver();
        vm.etch(PAYEE, address(receiver).code);
        ReenteringReceiver(payable(PAYEE)).configure(vault);
        vm.prank(PAYEE);
        vault.withdrawETH(0.5 ether);
        assertFalse(ReenteringReceiver(payable(PAYEE)).reentered());
        assertEq(
            ReenteringReceiver(payable(PAYEE)).reason(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(address(vault).balance, 0.5 ether);
        assertEq(PAYEE.balance, 0.5 ether);
    }

    function test_TokenFailureDoesNotFreezeOtherWithdrawals() public {
        _fill();
        usdt.setBehavior(1, 0, true, false);
        vm.startPrank(PAYEE);
        vm.expectRevert(bytes("token paused"));
        vault.withdrawAll(address(usdt));
        vault.withdrawAll(address(0));
        vault.withdrawAll(address(usdc));
        vault.withdrawAll(address(imd));
        vm.stopPrank();
        assertEq(usdt.balanceOf(address(vault)), 3000e6);
        usdt.setBehavior(1, 0, false, false);
        vm.prank(PAYEE);
        vault.withdrawAll(address(usdt));
        assertEq(vault.totalValueUsd(), 0);
    }

    function test_BrokenBalanceReadDoesNotFreezeETHWithdrawal() public {
        _eth(1 ether);
        usdc.setBalancesRevert(true);
        vm.expectRevert(bytes("balance unavailable"));
        vault.depositETH{value: 1}();
        vm.prank(PAYEE);
        vault.withdrawAll(address(0));
        assertEq(PAYEE.balance, 1 ether);
    }

    function test_FalseReturningTokenRollsBackWithdrawal() public {
        _deposit(usdc, 1e6);
        usdc.setBehavior(2, 0, false, false);
        vm.prank(PAYEE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
        vault.withdrawAll(address(usdc));
        assertEq(usdc.balanceOf(address(vault)), 1e6);
        assertEq(usdc.balanceOf(PAYEE), 0);
    }

    function test_OnlyBeneficiaryCanRecoverUnsupportedToken() public {
        MockToken other = new MockToken(18);
        other.mint(address(vault), 15e18);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(CappedAssetVault.UnauthorizedWithdrawer.selector, OWNER));
        vault.withdrawToken(address(other), 15e18);
        vm.prank(PAYEE);
        vault.withdrawAll(address(other));
        assertEq(other.balanceOf(PAYEE), 15e18);
    }

    function test_PausedDepositsFailAndOwnerCanResume() public {
        vm.prank(OWNER);
        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.depositETH{value: 1}();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.depositToken(address(usdc), 1e6);
        vm.prank(OWNER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.pause();
        vm.prank(OWNER);
        vault.unpause();
        _eth(1);
        vm.prank(OWNER);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vault.unpause();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ExactValuationAndFullConservation(uint256 ethSeed, uint256 stableSeed, uint256 imdSeed) public {
        uint256 ethAmount = bound(ethSeed, 1, 1 ether);
        uint256 stableAmount = bound(stableSeed, 1, 1000e6);
        uint256 imdAmount = bound(imdSeed, 1, 100e18);
        _eth(ethAmount);
        _deposit(usdt, stableAmount);
        _deposit(usdc, stableAmount);
        _deposit(imd, imdAmount);
        assertEq(vault.totalValueUsd(), ethAmount * 2600 + stableAmount * 2e12 + imdAmount * 9);
        assertLe(vault.totalValueUsd(), 10_000e18);
        vm.startPrank(PAYEE);
        vault.withdrawAll(address(0));
        vault.withdrawAll(address(usdt));
        vault.withdrawAll(address(usdc));
        vault.withdrawAll(address(imd));
        vm.stopPrank();
        assertEq(PAYEE.balance, ethAmount);
        assertEq(usdt.balanceOf(PAYEE), stableAmount);
        assertEq(usdc.balanceOf(PAYEE), stableAmount);
        assertEq(imd.balanceOf(PAYEE), imdAmount);
        assertEq(vault.totalValueUsd(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_UnauthorizedWithdrawerAlwaysFails(address caller) public {
        if (caller == PAYEE) caller = STRANGER;
        _assertNoWithdrawal(caller);
    }

    function _assertNoWithdrawal(address caller) private {
        bytes memory reason = abi.encodeWithSelector(CappedAssetVault.UnauthorizedWithdrawer.selector, caller);
        vm.startPrank(caller);
        vm.expectRevert(reason);
        vault.withdrawETH(1);
        vm.expectRevert(reason);
        vault.withdrawToken(address(usdc), 1);
        vm.expectRevert(reason);
        vault.withdrawAll(address(0));
        vm.expectRevert(reason);
        vault.withdrawAll(address(usdt));
        vm.stopPrank();
    }
}

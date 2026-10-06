// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultBase} from "./VaultBase.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {CappedAssetVault} from "../src/CappedAssetVault.sol";
import {OpenDepositPolicy} from "../src/OpenDepositPolicy.sol";

/// @dev Exercises successful deposits, over-cap attempts, withdrawals, pauses and policy upgrades.
contract VaultHandler is Test {
    CappedAssetVault public immutable vault;
    address public immutable owner;
    address public immutable payee;
    address[4] public assets;
    uint256[4] public received;
    uint256[4] public withdrawn;
    OpenDepositPolicy private immutable _firstPolicy;
    OpenDepositPolicy private immutable _secondPolicy;

    constructor(CappedAssetVault vault_) {
        vault = vault_;
        owner = vault_.owner();
        payee = vault_.WITHDRAWER();
        assets = [address(0), vault_.USDT(), vault_.USDC(), vault_.IMD()];
        _firstPolicy = OpenDepositPolicy(address(vault_.depositPolicy()));
        _secondPolicy = new OpenDepositPolicy();
    }

    function deposit(uint8 choice, uint96 seed) external {
        uint256 index = choice % 4;
        uint256 multiplier = index == 0 ? 2600 : (index == 3 ? 9 : 1e12);
        uint256 capacity = vault.remainingCapacityUsd() / multiplier;
        // Half the inputs deliberately request at least one unit beyond capacity.
        uint256 amount = seed % 2 == 0 ? capacity + 1 : bound(uint256(seed), 1, capacity + 1);
        bool shouldSucceed = !vault.paused() && amount <= capacity;
        bool ok;
        if (index == 0) {
            vm.deal(address(this), amount);
            (ok,) = address(vault).call{value: amount}(abi.encodeCall(vault.depositETH, ()));
        } else {
            MockToken token = MockToken(assets[index]);
            token.mint(address(this), amount);
            token.approve(address(vault), amount);
            (ok,) = address(vault).call(abi.encodeCall(vault.depositToken, (assets[index], amount)));
        }
        assertEq(ok, shouldSucceed, "deposit outcome");
        if (ok) received[index] += amount;
    }

    function withdraw(uint8 choice, uint96 seed) external {
        uint256 index = choice % 4;
        uint256 balance = index == 0 ? address(vault).balance : MockToken(assets[index]).balanceOf(address(vault));
        if (balance == 0) return;
        uint256 amount = bound(uint256(seed), 1, balance);
        vm.prank(payee);
        if (index == 0) vault.withdrawETH(amount);
        else vault.withdrawToken(assets[index], amount);
        withdrawn[index] += amount;
    }

    function togglePause() external {
        bool paused = vault.paused();
        vm.prank(owner);
        if (paused) vault.unpause();
        else vault.pause();
    }

    function upgrade() external {
        bool wasPaused = vault.paused();
        vm.startPrank(owner);
        if (!wasPaused) vault.pause();
        address next =
            address(vault.depositPolicy()) == address(_firstPolicy) ? address(_secondPolicy) : address(_firstPolicy);
        vault.upgradeTo(next);
        if (!wasPaused) vault.unpause();
        vm.stopPrank();
    }
}

contract VaultInvariantTest is VaultBase {
    VaultHandler private _handler;

    function setUp() public override {
        super.setUp();
        _handler = new VaultHandler(vault);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.withdraw.selector;
        selectors[2] = VaultHandler.togglePause.selector;
        selectors[3] = VaultHandler.upgrade.selector;
        targetContract(address(_handler));
        targetSelector(FuzzSelector({addr: address(_handler), selectors: selectors}));
    }

    /// @dev Unsolicited transfers are covered separately; no contract can bound those.
    function invariant_AcceptedDepositsStayWithinSharedCap() public view {
        assertLe(vault.totalValueUsd(), 10_000e18);
        assertEq(vault.totalValueUsd() + vault.remainingCapacityUsd(), 10_000e18);
    }

    function invariant_ConservationAndFixedCustody() public view {
        assertEq(vault.owner(), OWNER);
        assertEq(vault.WITHDRAWER(), PAYEE);
        for (uint256 i; i < 4; ++i) {
            address asset = _handler.assets(i);
            uint256 held = i == 0 ? address(vault).balance : MockToken(asset).balanceOf(address(vault));
            uint256 paid = i == 0 ? PAYEE.balance : MockToken(asset).balanceOf(PAYEE);
            assertEq(_handler.received(i), held + _handler.withdrawn(i));
            assertEq(paid, _handler.withdrawn(i));
        }
    }
}

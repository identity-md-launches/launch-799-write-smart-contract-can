// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CappedAssetVault} from "../src/CappedAssetVault.sol";
import {OpenDepositPolicy} from "../src/OpenDepositPolicy.sol";
import {MockToken} from "./mocks/MockToken.sol";

abstract contract VaultBase is Test {
    CappedAssetVault internal vault;
    OpenDepositPolicy internal policy;
    MockToken internal usdt;
    MockToken internal usdc;
    MockToken internal imd;
    address internal constant OWNER = address(0xA11CE);
    address internal constant ALICE = address(0xB0B);
    address internal constant STRANGER = address(0xCAFE);
    address internal constant PAYEE = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    address internal constant IMD_ADDRESS = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    function setUp() public virtual {
        usdt = new MockToken(6);
        usdc = new MockToken(6);
        MockToken template = new MockToken(18);
        vm.etch(IMD_ADDRESS, address(template).code);
        imd = MockToken(IMD_ADDRESS);
        policy = new OpenDepositPolicy();
        vault = new CappedAssetVault(OWNER, address(usdt), address(usdc), 18, address(policy));
        usdt.setBehavior(1, 0, false, false);
        vm.deal(ALICE, 100 ether);
        vm.deal(PAYEE, 0);
        vm.deal(STRANGER, 100 ether);
        vm.deal(address(this), 100 ether);
        _fund(ALICE);
    }

    function _fund(address account) internal {
        usdt.mint(account, 100_000e6);
        usdc.mint(account, 100_000e6);
        imd.mint(account, 100_000e18);
    }

    function _deposit(MockToken token, uint256 amount) internal {
        vm.startPrank(ALICE);
        token.approve(address(vault), amount);
        vault.depositToken(address(token), amount);
        vm.stopPrank();
    }

    function _eth(uint256 amount) internal {
        vm.prank(ALICE);
        vault.depositETH{value: amount}();
    }

    function _fill() internal {
        _eth(1 ether);
        _deposit(imd, 100e18);
        _deposit(usdt, 3000e6);
        _deposit(usdc, 3500e6);
    }
}

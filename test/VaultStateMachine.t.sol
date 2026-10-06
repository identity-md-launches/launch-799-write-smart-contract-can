// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultBase} from "./VaultBase.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {RestrictedPolicy, RevertingPolicy, WrongPolicy} from "./mocks/Policies.sol";
import {CappedAssetVault} from "src/CappedAssetVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev The model uses successful input amounts, never vault balances/capacity/roles to choose outcomes.
/// Tokens are honest, fee-free stand-ins; fee and callback behavior is tested separately.
contract VaultStateMachineHandler is Test {
    uint256 private constant CAP = 10_000e18;
    address private constant PAYEE = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    CappedAssetVault public immutable vault;
    address[4] public assets;
    address[3] public actors;
    address[4] public policies;
    uint256[4] public deposited;
    uint256[4] public donated;
    uint256[4] public paid;
    uint256[4][3] public initial;
    uint256[4][3] public spent;
    address public modelOwner;
    address public modelPending;
    bool public modelPaused;
    uint256 public modelPolicy;
    uint256 public successfulDeposits;
    uint256 public rejectedDeposits;
    uint256 public successfulWithdrawals;

    constructor(CappedAssetVault vault_, address owner, address alice, address bob) {
        vault = vault_;
        modelOwner = owner;
        assets = [address(0), vault_.USDT(), vault_.USDC(), vault_.IMD()];
        actors = [alice, bob, owner];
        policies = [
            address(vault_.depositPolicy()),
            address(new RestrictedPolicy(alice)),
            address(new RevertingPolicy()),
            address(new WrongPolicy())
        ];
        for (uint256 a; a < 3; ++a) {
            vm.deal(actors[a], 10_000 ether);
            initial[a][0] = actors[a].balance;
            for (uint256 i = 1; i < 4; ++i) {
                MockToken token = MockToken(assets[i]);
                token.mint(actors[a], i == 3 ? 10_000_000e18 : 10_000_000e6);
                initial[a][i] = token.balanceOf(actors[a]);
            }
        }
    }

    function deposit(uint8 actorSeed, uint8 assetSeed, uint256 seed, bool useReceive) external {
        uint256 a = actorSeed % 3;
        uint256 i = assetSeed % 4;
        uint256 price = _unitPrice(i);
        uint256 value = modelValue();
        uint256 available = value >= CAP ? 0 : (CAP - value) / price;
        uint256 mode = seed % 5;
        uint256 amount = mode == 0
            ? 0
            : mode == 1 ? 1 : mode == 2 ? available : mode == 3 ? available + 1 : bound(seed, 1, available + 1);
        bytes memory error;
        if (modelPaused) {
            error = abi.encodeWithSelector(Pausable.EnforcedPause.selector);
        } else if (amount == 0) {
            error = abi.encodeWithSelector(CappedAssetVault.ZeroAmount.selector);
        } else if (value + amount * price > CAP) {
            error = abi.encodeWithSelector(CappedAssetVault.CapExceeded.selector, value + amount * price);
        } else if (modelPolicy == 2) {
            error = abi.encodeWithSignature("Error(string)", "policy unavailable");
        } else if (modelPolicy == 1 && a != 0) {
            error = abi.encodeWithSelector(CappedAssetVault.DepositRejected.selector);
        }

        bool ok;
        bytes memory result;
        if (i == 0) {
            bytes memory data = useReceive ? bytes("") : abi.encodeCall(vault.depositETH, ());
            vm.prank(actors[a]);
            (ok, result) = address(vault).call{value: amount}(data);
        } else {
            vm.startPrank(actors[a]);
            MockToken(assets[i]).approve(address(vault), amount);
            (ok, result) = address(vault).call(abi.encodeCall(vault.depositToken, (assets[i], amount)));
            vm.stopPrank();
        }
        _checkOutcome(ok, result, error);
        if (ok) {
            deposited[i] += amount;
            spent[a][i] += amount;
            successfulDeposits++;
            assertLe(modelValue(), CAP, "an admitted deposit exceeded the shared cap");
        } else {
            rejectedDeposits++;
        }
        if (i != 0) {
            assertEq(MockToken(assets[i]).allowance(actors[a], address(vault)), ok ? 0 : amount, "allowance atomicity");
        }
        assertBalances();
    }

    function withdraw(uint8 assetSeed, uint256 seed, bool all) external {
        uint256 i = assetSeed % 4;
        uint256 held = modelHeld(i);
        uint256 mode = seed % 4;
        uint256 amount = all ? held : mode == 0 ? 0 : mode == 1 ? held + 1 : mode == 2 ? held : bound(seed, 0, held);
        bytes memory error;
        if (amount == 0) error = abi.encodeWithSelector(CappedAssetVault.ZeroAmount.selector);
        else if (amount > held) error = abi.encodeWithSelector(CappedAssetVault.InsufficientBalance.selector);
        vm.prank(PAYEE);
        (bool ok, bytes memory result) = address(vault).call(_withdrawCall(i, amount, all));
        _checkOutcome(ok, result, error);
        if (ok) {
            paid[i] += amount;
            successfulWithdrawals++;
        }
        assertBalances();
    }

    function unauthorizedWithdrawal(uint8 actorSeed, uint8 assetSeed, uint256 amount, bool all) external {
        address caller = actors[actorSeed % 3];
        vm.prank(caller);
        (bool ok, bytes memory result) = address(vault).call(_withdrawCall(assetSeed % 4, amount, all));
        _checkOutcome(ok, result, abi.encodeWithSelector(CappedAssetVault.UnauthorizedWithdrawer.selector, caller));
        assertBalances();
    }

    /// @dev Models transfers outside the vault's entry points, including forced ETH.
    function donate(uint8 actorSeed, uint8 assetSeed, uint256 seed) external {
        uint256 a = actorSeed % 3;
        uint256 i = assetSeed % 4;
        uint256 amount = bound(seed, 1, 20_000e18 / _unitPrice(i));
        if (i == 0) {
            vm.deal(actors[a], actors[a].balance - amount);
            vm.deal(address(vault), address(vault).balance + amount);
        } else {
            vm.prank(actors[a]);
            // USDT returns no data. A raw call avoids a mock-ABI bool decoder in the harness.
            (bool ok,) = assets[i].call(abi.encodeCall(MockToken.transfer, (address(vault), amount)));
            assertTrue(ok, "donation transfer");
        }
        donated[i] += amount;
        spent[a][i] += amount;
        assertBalances();
    }

    /// @dev Interleaves authorized/unauthorized actions and checks failures against independent role state.
    function administer(uint8 operation, uint8 callerSeed, uint8 argument) external {
        uint256 op = operation % 6;
        address caller = callerSeed % 4 == 3 ? modelOwner : actors[callerSeed % 3];
        address candidate = actors[argument % 3];
        uint256 nextPolicy = argument % 4;
        bytes memory data;
        if (op == 0) data = abi.encodeCall(vault.pause, ());
        else if (op == 1) data = abi.encodeCall(vault.unpause, ());
        else if (op == 2) data = abi.encodeCall(vault.upgradeTo, (policies[nextPolicy]));
        else if (op == 3) data = abi.encodeCall(vault.transferOwnership, (candidate));
        else if (op == 4) data = abi.encodeCall(vault.acceptOwnership, ());
        else data = abi.encodeCall(vault.renounceOwnership, ());

        bytes memory error;
        if (op == 4 ? caller != modelPending : caller != modelOwner) {
            error = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
        } else if (op == 0 && modelPaused) {
            error = abi.encodeWithSelector(Pausable.EnforcedPause.selector);
        } else if ((op == 1 || op == 2) && !modelPaused) {
            error = abi.encodeWithSelector(Pausable.ExpectedPause.selector);
        } else if (op == 2 && nextPolicy == 3) {
            error = abi.encodeWithSelector(CappedAssetVault.InvalidPolicy.selector, policies[3]);
        } else if (op == 5) {
            error = abi.encodeWithSelector(CappedAssetVault.OwnershipRenunciationDisabled.selector);
        }

        vm.prank(caller);
        (bool ok, bytes memory result) = address(vault).call(data);
        _checkOutcome(ok, result, error);
        if (ok) {
            if (op == 0) {
                modelPaused = true;
            } else if (op == 1) {
                modelPaused = false;
            } else if (op == 2) {
                modelPolicy = nextPolicy;
            } else if (op == 3) {
                modelPending = candidate;
            } else if (op == 4) {
                modelOwner = modelPending;
                modelPending = address(0);
            }
        }
        assertAdministration();
        assertBalances();
    }

    /// @dev Used after each campaign without changing pause, policy, or ownership first.
    function drain() external {
        for (uint256 i; i < 4; ++i) {
            uint256 held = modelHeld(i);
            if (held == 0) continue;
            vm.prank(PAYEE);
            vault.withdrawAll(assets[i]);
            paid[i] += held;
            successfulWithdrawals++;
        }
        assertBalances();
        assertEq(vault.totalValueUsd(), 0, "beneficiary can empty all custody after any sequence");
    }

    function modelHeld(uint256 i) public view returns (uint256) {
        return deposited[i] + donated[i] - paid[i];
    }

    function modelValue() public view returns (uint256 value) {
        for (uint256 i; i < 4; ++i) {
            value += modelHeld(i) * _unitPrice(i);
        }
    }

    function assertBalances() public view {
        for (uint256 i; i < 4; ++i) {
            assertEq(
                _balance(i, address(vault)),
                modelHeld(i),
                "custody differs from admitted and donated units minus payouts"
            );
            assertEq(_balance(i, PAYEE), paid[i], "withdrawals must reach only the fixed beneficiary");
            for (uint256 a; a < 3; ++a) {
                assertEq(_balance(i, actors[a]) + spent[a][i], initial[a][i], "unexpected actor balance change");
            }
        }
        uint256 value = modelValue();
        assertEq(vault.totalValueUsd(), value, "valuation from independent receipt ledger");
        assertEq(vault.remainingCapacityUsd(), value >= CAP ? 0 : CAP - value, "remaining capacity including donations");
    }

    function assertAdministration() public view {
        assertEq(vault.owner(), modelOwner);
        assertEq(vault.pendingOwner(), modelPending);
        assertEq(vault.paused(), modelPaused);
        assertEq(address(vault.depositPolicy()), policies[modelPolicy]);
        assertEq(vault.WITHDRAWER(), PAYEE);
    }

    function _checkOutcome(bool ok, bytes memory result, bytes memory error) private pure {
        assertEq(ok, error.length == 0, "unexpected call outcome");
        if (!ok) assertEq(result, error, "unexpected revert cause");
    }

    function _withdrawCall(uint256 i, uint256 amount, bool all) private view returns (bytes memory) {
        if (all) return abi.encodeCall(vault.withdrawAll, (assets[i]));
        if (i == 0) return abi.encodeCall(vault.withdrawETH, (amount));
        return abi.encodeCall(vault.withdrawToken, (assets[i], amount));
    }

    function _balance(uint256 i, address account) private view returns (uint256) {
        return i == 0 ? account.balance : MockToken(assets[i]).balanceOf(account);
    }

    function _unitPrice(uint256 i) private pure returns (uint256) {
        return i == 0 ? 2600 : i == 3 ? 9 : 1e12;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract VaultStateMachineTest is VaultBase {
    VaultStateMachineHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultStateMachineHandler(vault, OWNER, ALICE, STRANGER);
        // Nonempty initial custody makes withdrawal and rejection assertions nonvacuous.
        for (uint8 i; i < 4; ++i) {
            handler.deposit(i % 3, i, 4, false);
        }
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = VaultStateMachineHandler.deposit.selector;
        selectors[1] = VaultStateMachineHandler.withdraw.selector;
        selectors[2] = VaultStateMachineHandler.unauthorizedWithdrawal.selector;
        selectors[3] = VaultStateMachineHandler.donate.selector;
        selectors[4] = VaultStateMachineHandler.administer.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_AllFundsAccountedAndOnlyBeneficiaryPaid() public view {
        handler.assertBalances();
        assertGe(handler.successfulDeposits(), 4);
    }

    function invariant_PausePolicyAndOwnershipMatchAuthorizedTransitions() public view {
        handler.assertAdministration();
    }

    function afterInvariant() public {
        handler.drain();
        handler.assertAdministration();
    }

    function test_HandlerExercisesRejectionHandoverPolicyAndRecovery() public {
        handler.deposit(0, 1, 2, false); // Fill the remaining capacity.
        handler.deposit(1, 1, 1, false); // Above the cap by one stablecoin unit.
        handler.unauthorizedWithdrawal(2, 1, 1, true); // Owner is not beneficiary.
        handler.administer(0, 3, 0); // Pause as current owner.
        handler.administer(2, 3, 1); // Install allowlist.
        handler.administer(3, 3, 1); // Nominate STRANGER.
        handler.administer(4, 0, 0); // Wrong actor cannot accept.
        handler.administer(4, 1, 0); // Accept as STRANGER.
        handler.withdraw(1, 2, true); // Withdrawal while paused.
        handler.administer(1, 3, 0); // Unpause as new owner.
        handler.deposit(1, 2, 1, false); // Allowlist rejection, even for new owner.
        handler.deposit(0, 2, 1, false); // Allowed depositor.
        handler.administer(0, 3, 0);
        handler.administer(2, 3, 2); // Broken policy.
        handler.administer(1, 3, 0);
        handler.deposit(0, 0, 1, true); // Reverting policy rejects receive().
        handler.donate(1, 2, 20_000e6); // Unsolicited excess must stay recoverable.
        handler.drain();
        handler.administer(0, 3, 0);
        handler.administer(2, 3, 0); // Restore open policy.
        handler.administer(1, 3, 0);
        handler.deposit(2, 0, 1, true); // Reopen an emptied vault for the old owner.
        assertGe(handler.rejectedDeposits(), 3);
        assertGt(handler.successfulWithdrawals(), 0);
        handler.assertAdministration();
        handler.assertBalances();
    }
}

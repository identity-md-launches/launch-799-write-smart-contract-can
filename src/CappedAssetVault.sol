// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDepositPolicy} from "./interfaces/IDepositPolicy.sol";

/// @notice Receives up to $10,000 of ETH, USDT, USDC and IMD at fixed prices.
/// @dev Upgradeable admission policy, immutable custody rules. Deposits grant no redemption rights.
contract CappedAssetVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_USD_WAD = 10_000e18;
    uint256 public constant ETH_PRICE_USD = 2_600;
    uint256 public constant IMD_PRICE_USD = 9;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant WITHDRAWER = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    bytes32 public constant POLICY_ID = keccak256("identitymd.capped-vault.deposit-policy.v1");

    address public immutable USDT;
    address public immutable USDC;
    uint8 public immutable imdDecimals;
    uint256 private immutable _imdUsdPerUnit;

    IDepositPolicy public depositPolicy;

    error InvalidTokenConfiguration();
    error UnsupportedAsset(address asset);
    error ZeroAmount();
    error CapExceeded(uint256 totalUsdWad);
    error InvalidReceipt();
    error UnauthorizedWithdrawer(address caller);
    error InsufficientBalance();
    error EtherTransferFailed();
    error InvalidPolicy(address policy);
    error DepositRejected();
    error OwnershipRenunciationDisabled();

    event Deposited(address indexed sender, address indexed asset, uint256 amount, uint256 totalUsdWad);
    event Withdrawn(address indexed asset, uint256 amount);
    event PolicyUpgraded(address indexed previousPolicy, address indexed newPolicy);

    /// @param initialOwner Explicit administration owner; never inferred from a deploying factory.
    /// @param usdt Ethereum USDT (6 decimals). Verify this address before deployment.
    /// @param usdc Ethereum USDC (6 decimals). Verify this address before deployment.
    /// @param imdDecimals_ Verified decimals at the pinned IMD address; supported range 0..18.
    /// @param initialPolicy Previously deployed policy implementing IDepositPolicy.
    constructor(address initialOwner, address usdt, address usdc, uint8 imdDecimals_, address initialPolicy)
        Ownable(initialOwner)
    {
        if (
            usdt == address(0) || usdc == address(0) || usdt == usdc || usdt == IMD || usdc == IMD
                || usdt == address(this) || usdc == address(this) || imdDecimals_ > 18
        ) revert InvalidTokenConfiguration();
        USDT = usdt;
        USDC = usdc;
        imdDecimals = imdDecimals_;
        _imdUsdPerUnit = IMD_PRICE_USD * 10 ** (18 - imdDecimals_);
        _setPolicy(initialPolicy);
    }

    modifier onlyWithdrawer() {
        if (msg.sender != WITHDRAWER) revert UnauthorizedWithdrawer(msg.sender);
        _;
    }

    /// @notice Empty-calldata ETH transfers use the same checks as depositETH().
    /// @dev Send with enough gas; Solidity transfer/send's 2300 stipend is insufficient.
    receive() external payable nonReentrant whenNotPaused {
        _acceptETH();
    }

    function depositETH() external payable nonReentrant whenNotPaused {
        _acceptETH();
    }

    /// @notice Approve this vault first. Values and events use the amount actually received.
    function depositToken(address asset, uint256 amount) external nonReentrant whenNotPaused {
        if (asset != USDT && asset != USDC && asset != IMD) revert UnsupportedAsset(asset);
        if (amount == 0) revert ZeroAmount();
        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance <= beforeBalance || afterBalance - beforeBalance > amount) revert InvalidReceipt();
        _acceptDeposit(asset, afterBalance - beforeBalance);
    }

    /// @notice Only the fixed beneficiary can withdraw; pause and policy never restrict this path.
    function withdrawETH(uint256 amount) external nonReentrant onlyWithdrawer {
        _withdrawETH(amount);
    }

    /// @notice Also recovers accidentally sent ERC20s. All transfers go to WITHDRAWER.
    function withdrawToken(address asset, uint256 amount) external nonReentrant onlyWithdrawer {
        _withdrawToken(asset, amount);
    }

    /// @notice Withdraw the entire balance of one asset; address(0) selects ETH.
    function withdrawAll(address asset) external nonReentrant onlyWithdrawer {
        if (asset == address(0)) {
            _withdrawETH(address(this).balance);
        } else {
            _withdrawToken(asset, IERC20(asset).balanceOf(address(this)));
        }
    }

    /// @notice Current holdings at fixed prices; not lifetime receipts or a market valuation.
    /// @dev Includes unsolicited balances. Checked arithmetic fails closed on pathological token balances.
    function totalValueUsd() public view returns (uint256) {
        return address(this).balance * ETH_PRICE_USD + IERC20(USDT).balanceOf(address(this)) * 1e12
            + IERC20(USDC).balanceOf(address(this)) * 1e12 + IERC20(IMD).balanceOf(address(this)) * _imdUsdPerUnit;
    }

    function remainingCapacityUsd() external view returns (uint256) {
        uint256 value = totalValueUsd();
        return value >= MAX_USD_WAD ? 0 : MAX_USD_WAD - value;
    }

    function pause() external nonReentrant onlyOwner {
        _pause();
    }

    function unpause() external nonReentrant onlyOwner {
        _unpause();
    }

    /// @notice Upgrade admission logic while paused. Custody, prices, cap and payee stay fixed.
    /// @dev STATICCALL isolation prevents a replacement from modifying vault storage or moving funds.
    function upgradeTo(address newPolicy) external nonReentrant onlyOwner whenPaused {
        _setPolicy(newPolicy);
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0) || newOwner == address(this)) revert OwnableInvalidOwner(newOwner);
        super.transferOwnership(newOwner);
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenunciationDisabled();
    }

    function _acceptETH() private {
        if (msg.value == 0) revert ZeroAmount();
        _acceptDeposit(address(0), msg.value);
    }

    function _acceptDeposit(address asset, uint256 received) private {
        uint256 value = totalValueUsd();
        if (value > MAX_USD_WAD) revert CapExceeded(value);
        if (!depositPolicy.allowsDeposit(address(this), msg.sender, asset, received, value)) revert DepositRejected();
        emit Deposited(msg.sender, asset, received, value);
    }

    function _withdrawETH(uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        if (amount > address(this).balance) revert InsufficientBalance();
        emit Withdrawn(address(0), amount);
        // Both entry points hold the reentrancy guard. A failed send rolls back the event too.
        (bool success,) = payable(WITHDRAWER).call{value: amount}("");
        if (!success) revert EtherTransferFailed();
    }

    function _withdrawToken(address asset, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        IERC20 token = IERC20(asset);
        if (amount > token.balanceOf(address(this))) revert InsufficientBalance();
        emit Withdrawn(asset, amount);
        token.safeTransfer(WITHDRAWER, amount);
    }

    function _setPolicy(address next) private {
        if (next == address(this) || next.code.length == 0) revert InvalidPolicy(next);
        try IDepositPolicy(next).policyId() returns (bytes32 id) {
            if (id != POLICY_ID) revert InvalidPolicy(next);
        } catch {
            revert InvalidPolicy(next);
        }
        address previous = address(depositPolicy);
        depositPolicy = IDepositPolicy(next);
        emit PolicyUpgraded(previous, next);
    }
}

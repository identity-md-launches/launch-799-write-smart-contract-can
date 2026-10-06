// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Configurable adversarial ERC20; return mode 1 mimics USDT's empty transfer result.
contract MockToken is IERC20 {
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public feeBps;
    uint8 public returnMode;
    bool public transfersRevert;
    bool public balancesRevert;
    bool public noMovement;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function balanceOf(address account) external view returns (uint256) {
        require(!balancesRevert, "balance unavailable");
        return _balances[account];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return _result();
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return _result();
    }

    function setBehavior(uint8 mode, uint256 fee, bool revertTransfers, bool noMovement_) external {
        returnMode = mode;
        feeBps = fee;
        transfersRevert = revertTransfers;
        noMovement = noMovement_;
    }

    function setBalancesRevert(bool value) external {
        balancesRevert = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(!transfersRevert, "token paused");
        if (!noMovement) {
            uint256 fee = amount * feeBps / 10_000;
            _balances[from] -= amount;
            _balances[to] += amount - fee;
            totalSupply -= fee;
            emit Transfer(from, to, amount - fee);
        }
        if (callbackTarget != address(0)) {
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
    }

    function _result() private view returns (bool) {
        if (returnMode == 1) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (returnMode == 2) return false;
        if (returnMode == 3) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 1)
            }
        }
        return true;
    }
}

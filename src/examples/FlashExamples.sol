// SPDX-License-Identifier: MIT
pragma solidity =0.8.25;

import {WETH} from "solmate/tokens/WETH.sol";
import {IUniswapV2Callee} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Callee.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

interface IUniswapV3PoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniswapV3FlashCallback {
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}

interface IV4PoolManagerLike {
    function unlock(bytes calldata data) external returns (bytes memory);
    function take(address token, address to, uint256 amount) external;
    function settle(address token, uint256 amount) external;
}

interface IV4UnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

contract V2FlashSwapExample is IUniswapV2Callee {
    IUniswapV2Pair public immutable pair;
    WETH public immutable weth;
    address public immutable initiator;

    constructor(IUniswapV2Pair _pair, WETH _weth, address _initiator) {
        pair = _pair;
        weth = _weth;
        initiator = _initiator;
    }

    function execute(uint256 amountWethOut) external {
        require(msg.sender == initiator, "only initiator");
        pair.swap(amountWethOut, 0, address(this), abi.encode(amountWethOut));
    }

    function uniswapV2Call(address, uint256 amount0, uint256 amount1, bytes calldata data) external override {
        require(msg.sender == address(pair), "only pair");
        require(amount1 == 0, "unexpected token1");

        uint256 amountBorrowed = abi.decode(data, (uint256));
        require(amount0 == amountBorrowed, "amount mismatch");

        weth.withdraw(amountBorrowed);

        uint256 amountToRepay = (amountBorrowed * 1000) / 997 + 1;
        weth.deposit{value: amountToRepay}();
        weth.transfer(address(pair), amountToRepay);
    }

    receive() external payable {}
}

contract V3FlashExample is IUniswapV3FlashCallback {
    IUniswapV3PoolLike public immutable pool;
    WETH public immutable weth;
    address public immutable initiator;

    constructor(IUniswapV3PoolLike _pool, WETH _weth, address _initiator) {
        pool = _pool;
        weth = _weth;
        initiator = _initiator;
    }

    function executeBorrowToken0(uint256 amount0) external {
        require(msg.sender == initiator, "only initiator");
        require(pool.token0() == address(weth), "token0 not WETH");
        pool.flash(address(this), amount0, 0, abi.encode(amount0));
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256, bytes calldata data) external override {
        require(msg.sender == address(pool), "only pool");

        uint256 amountBorrowed = abi.decode(data, (uint256));
        weth.withdraw(amountBorrowed);

        uint256 amountToRepay = amountBorrowed + fee0;
        weth.deposit{value: amountToRepay}();
        weth.transfer(msg.sender, amountToRepay);
    }

    receive() external payable {}
}

contract V4FlashAccountingExample is IV4UnlockCallback {
    IV4PoolManagerLike public immutable manager;
    WETH public immutable weth;
    address public immutable initiator;

    constructor(IV4PoolManagerLike _manager, WETH _weth, address _initiator) {
        manager = _manager;
        weth = _weth;
        initiator = _initiator;
    }

    function execute(uint256 amountWeth) external {
        require(msg.sender == initiator, "only initiator");
        manager.unlock(abi.encode(amountWeth));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");

        uint256 amountBorrowed = abi.decode(data, (uint256));
        manager.take(address(weth), address(this), amountBorrowed);

        weth.withdraw(amountBorrowed);

        uint256 amountToRepay = amountBorrowed;
        weth.deposit{value: amountToRepay}();
        weth.transfer(address(manager), amountToRepay);
        manager.settle(address(weth), amountToRepay);

        return "";
    }

    receive() external payable {}
}

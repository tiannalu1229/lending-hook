// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "./v4-core/libraries/Hooks.sol";
import {BaseHook} from "./v4-periphery/BaseHook.sol";
import {IPoolManager} from "./v4-core/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "./v4-core/libraries/PoolId.sol";
import {BalanceDelta} from "./v4-core/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "./v4-core/libraries/CurrencyLibrary.sol";
import {TickMath} from "./v4-core/libraries/TickMath.sol";
import {UniV4UserHook} from "./UniV4UserHook.sol";
// import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
// import "forge-std/Test.sol";
type PoolId is bytes32;
contract StopLoss is UniV4UserHook, ERC1155 {
    // using FixedPointMathLib for uint256;
    using PoolIdLibrary for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    mapping(bytes32 poolId => int24 tickLower) public tickLowerLasts;
    mapping(bytes32 poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount))) public stopLossPositions;

    // -- 1155 state -- //
    mapping(uint256 tokenId => TokenIdData) public tokenIdIndex;
    mapping(uint256 tokenId => bool) public tokenIdExists;
    mapping(uint256 tokenId => uint256 claimable) public claimable;
    mapping(uint256 tokenId => uint256 supply) public totalSupply;

    struct TokenIdData {
        IPoolManager.PoolKey poolKey;
        int24 tickLower;
        bool zeroForOne;
    }

    // constants for sqrtPriceLimitX96 which allow for unlimited impact
    // (stop loss *should* market sell regardless of market depth 🥴)
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_RATIO + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_RATIO - 1;

    constructor(IPoolManager _poolManager) UniV4UserHook(_poolManager) ERC1155("") {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function toId(IPoolManager.PoolKey memory poolKey) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolKey));
    }

    function afterInitialize(address, IPoolManager.PoolKey calldata key, uint160, int24 tick)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        setTickLowerLast(toId(key), getTickLower(tick, key.tickSpacing));
        return StopLoss.afterInitialize.selector;
    }

    function afterSwap(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta
    ) external override returns (bytes4) {
        int24 prevTick = tickLowerLasts[toId(key)];
        (, int24 tick,,,,) = poolManager.getSlot0(key.toId());
        int24 currentTick = getTickLower(tick, key.tickSpacing);
        tick = prevTick;

        int256 swapAmounts;

        // fill stop losses in the opposite direction of the swap
        // avoids abuse/attack vectors
        bool stopLossZeroForOne = !params.zeroForOne;

        // TODO: test for off by one because of inequality
        if (prevTick < currentTick) {
            for (; tick < currentTick;) {
                swapAmounts = stopLossPositions[toId(key)][tick][stopLossZeroForOne];
                if (swapAmounts > 0) {
                    fillStopLoss(key, tick, stopLossZeroForOne, swapAmounts);
                }
                unchecked {
                    tick += key.tickSpacing;
                }
            }
        } else {
            for (; currentTick < tick;) {
                swapAmounts = stopLossPositions[toId(key)][tick][stopLossZeroForOne];
                if (swapAmounts > 0) {
                    fillStopLoss(key, tick, stopLossZeroForOne, swapAmounts);
                }
                unchecked {
                    tick -= key.tickSpacing;
                }
            }
        }
        return StopLoss.afterSwap.selector;
    }

    function fillStopLoss(IPoolManager.PoolKey calldata poolKey, int24 triggerTick, bool zeroForOne, int256 swapAmount)
        internal
    {
        IPoolManager.SwapParams memory stopLossSwapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        // TODO: may need a way to halt to prevent perpetual stop loss triggers
        BalanceDelta delta = UniV4UserHook.swap(poolKey, stopLossSwapParams, address(this));
        stopLossPositions[toId(poolKey)][triggerTick][zeroForOne] -= swapAmount;

        // capital from the swap is redeemable by position holders
        uint256 tokenId = getTokenId(poolKey, triggerTick, zeroForOne);

        // TODO: safe casting
        // balance delta returned by .swap(): negative amount indicates outflow from pool (and inflow into contract)
        // therefore, we need to invert
        uint256 amount = zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));
        claimable[tokenId] += amount;
    }

    // -- Stop Loss User Facing Functions -- //
    function placeStopLoss(IPoolManager.PoolKey calldata poolKey, int24 tickLower, uint256 amountIn, bool zeroForOne)
        external
        returns (int24 tick)
    {
        // round down according to tickSpacing
        // TODO: should we round up depending on direction of the position?
        tick = getTickLower(tickLower, poolKey.tickSpacing);
        // TODO: safe casting
        stopLossPositions[toId(poolKey)][tick][zeroForOne] += int256(amountIn);

        // mint the receipt token
        uint256 tokenId = getTokenId(poolKey, tick, zeroForOne);
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdIndex[tokenId] = TokenIdData({poolKey: poolKey, tickLower: tick, zeroForOne: zeroForOne});
        }
        _mint(msg.sender, tokenId, amountIn, "");
        totalSupply[tokenId] += amountIn;

        // interactions: transfer token0 to this contract
        address token = zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);
    }

    // TODO: implement, is out of scope for the hackathon
    function killStopLoss() external {}
    // ------------------------------------- //

    // -- 1155 -- //
    function uri(uint256) public pure override returns (string memory) {
        return "https://example.com";
    }

    function getTokenId(IPoolManager.PoolKey calldata poolKey, int24 tickLower, bool zeroForOne)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(poolKey.toId(), tickLower, zeroForOne)));
    }

    function redeem(uint256 tokenId, uint256 amountIn, address destination) external {
        // checks: an amount to redeem
        require(claimable[tokenId] > 0, "StopLoss: no claimable amount");
        // uint256 receiptBalance = balanceOf[msg.sender][tokenId];
        uint256 receiptBalance = 100;
        require(amountIn <= receiptBalance, "StopLoss: not enough tokens to redeem");

        TokenIdData memory data = tokenIdIndex[tokenId];
        address token =
            data.zeroForOne ? Currency.unwrap(data.poolKey.currency1) : Currency.unwrap(data.poolKey.currency0);

        // effects: burn the token
        // amountOut = claimable * (amountIn / totalSupply)
        uint256 amountOut = claimable[tokenId] * totalSupply[tokenId] / amountIn;
        claimable[tokenId] -= amountOut;
        _burn(msg.sender, tokenId, amountIn);
        totalSupply[tokenId] -= amountIn;

        // interaction: transfer the underlying to the caller
        IERC20(token).transfer(destination, amountOut);
    }
    // ---------- //

    // -- Util functions -- //
    function setTickLowerLast(bytes32 poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getTickLower(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }
}

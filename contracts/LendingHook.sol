// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Hooks} from "./v4-core/libraries/Hooks.sol";
import {IHooks} from "./v4-core/interfaces/IHooks.sol";
import {BaseHook} from "./v4-periphery/BaseHook.sol";
import {IPoolManager} from "./v4-core/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "./v4-core/libraries/PoolId.sol";
import {BalanceDelta} from "./v4-core/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "./v4-core/libraries/CurrencyLibrary.sol";
import {TickMath} from "./v4-core/libraries/TickMath.sol";
import {UniV4UserHook} from "./UniV4UserHook.sol";
import {ILending} from "./interfaces/ILending.sol";

/**
 * @title 
 * @author yun peng
 * @notice 当有人在池子中进行swap，对所有继承协议进行清算
 *         继承协议需要缴纳一定gas费并随时补充
 */

type PoolId is bytes32;
contract LendingHook is UniV4UserHook, ERC20 {  
    // using FixedPointMathLib for uint256;
    using PoolIdLibrary for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    uint160 public constant E18 = 1000000000000000000;
    address public constant ZERO_ADDRESS = 0x0000000000000000000000000000000000000000;

    mapping(bytes32 poolId => int24 tickLower) public tickLowerLasts;
    mapping(bytes32 poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount))) public stopLossPositions;

    //lending params
    address[] lendingAddress;
    uint256[] tick;

    //rewards params
    mapping(address user => uint256 timeStramp) public user2Time;
    mapping(address user => uint256 amount) public user2LP;
    address lastestUser;

    struct TokenIdData {
        IPoolManager.PoolKey poolKey;
        int24 tickLower;
        bool zeroForOne;
    }

    // constants for sqrtPriceLimitX96 which allow for unlimited impact
    // (stop loss *should* market sell regardless of market depth 🥴)
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_RATIO + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_RATIO - 1;


    struct CallbackData {
        address sender;
        IPoolManager.PoolKey key;
        IPoolManager.SwapParams params;
    }

    constructor(IPoolManager _poolManager) 
        UniV4UserHook(_poolManager) 
        ERC20("qilin", "qilin") 
    {}

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
    
    function afterSwap(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta
    ) external override poolManagerOnly returns (bytes4) {
        (uint160 nowPrice,,,,,)= IPoolManager(poolManager).getSlot0(key.toId());
        for (uint i = 0; i < lendingAddress.length; i++) {
            ILending(lendingAddress[i]).liquidate(int256(uint256(nowPrice)));
        }
        return LendingHook.afterSwap.selector;
    }

    function initialize(Currency currency, uint24 fee, int24 tickSpacing) external {
        IPoolManager.PoolKey memory poolKey = IPoolManager.PoolKey({
            currency0: currency,
            currency1: Currency.wrap(ZERO_ADDRESS),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(this)
        });
        
        IPoolManager(address(poolManager)).initialize(poolKey, E18);
    }

    function modifyPosition(
        Currency currency, 
        uint24 fee, 
        int24 tickSpacing, 
        int256 amount
    ) external {
        IPoolManager.PoolKey memory poolKey = IPoolManager.PoolKey({
            currency0: currency,
            currency1: Currency.wrap(ZERO_ADDRESS),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(this)
        });
        lastestUser = msg.sender;
        IPoolManager(address(poolManager)).lock(abi.encode(poolKey, IPoolManager.ModifyPositionParams(0, 1, amount)));
    }

    function lockAcquired(uint256, bytes calldata rawData) external override poolManagerOnly returns (bytes memory) {
        (IPoolManager.PoolKey memory key, IPoolManager.SwapParams memory swapParams) =
            abi.decode(rawData, (IPoolManager.PoolKey, IPoolManager.SwapParams));

        BalanceDelta delta = poolManager.swap(key, swapParams);

        if (swapParams.zeroForOne) {
            if (delta.amount0() > 0) {
                key.currency0.transfer(address(poolManager), uint256(uint128(delta.amount0())));
                poolManager.settle(key.currency0);
            }
            if (delta.amount1() < 0) {
                poolManager.take(key.currency1, address(this), uint256(uint128(-delta.amount1())));
            }
        } else {
            if (delta.amount1() > 0) {
                key.currency1.transfer(address(poolManager), uint256(uint128(delta.amount1())));
                poolManager.settle(key.currency1);
            }
            if (delta.amount0() < 0) {
                poolManager.take(key.currency0, address(this), uint256(uint128(-delta.amount0())));
            }
        }
        return bytes("");
    }

    function borrow(
        uint256 id,
        IPoolManager.PoolKey calldata key,
        uint256 amount,
        int256 ratio) external {
        (uint160 nowPrice,,,,,)= IPoolManager(poolManager).getSlot0(key.toId());
        ILending(lendingAddress[id]).borrow(int256(uint256(nowPrice)), amount, ratio, msg.sender);
    }
}

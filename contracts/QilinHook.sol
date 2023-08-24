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
// import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
// import "forge-std/Test.sol";
type PoolId is bytes32;
contract QilinHook is UniV4UserHook, ERC20 {
    // using FixedPointMathLib for uint256;
    using PoolIdLibrary for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    uint160 public constant E18 = 1000000000000000000;
    address public constant ZERO_ADDRESS = 0x0000000000000000000000000000000000000000;

    mapping(bytes32 poolId => int24 tickLower) public tickLowerLasts;
    mapping(bytes32 poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount))) public stopLossPositions;

    // -- 1155 state -- //
    mapping(uint256 tokenId => TokenIdData) public tokenIdIndex;
    mapping(uint256 tokenId => bool) public tokenIdExists;
    mapping(uint256 tokenId => uint256 claimable) public claimable;
    mapping(uint256 tokenId => uint256 supply) public totalSupply;

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

    // function beforeModifyPosition(
    //     address,
    //     IPoolManager.PoolKey calldata key,
    //     IPoolManager.ModifyPositionParams calldata params
    // ) external override returns (bytes4) {
    //     int24 prevTick = tickLowerLasts[toId(key)];
    //     //领取奖励
    //     return QilinHook.beforeModifyPosition.selector;
    // }

    function afterModifyPosition(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        BalanceDelta
    ) external override returns (bytes4) {
        //领取奖励
        user2Time[lastestUser] = block.timestamp;
        lastestUser = ZERO_ADDRESS;
        return QilinHook.afterModifyPosition.selector;
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

    function modifyPosition(Currency currency, uint24 fee, int24 tickSpacing, int256 amount) external {
        IPoolManager.PoolKey memory poolKey = IPoolManager.PoolKey({
            currency0: currency,
            currency1: Currency.wrap(ZERO_ADDRESS),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(this)
        });
        lastestUser = msg.sender;
        IPoolManager(address(poolManager)).lock(abi.encode(poolKey, IPoolManager.ModifyPositionParams(, 1, amount)));
    }

    function lockAcquired(uint256, bytes calldata rawData) external override poolManagerOnly returns (bytes memory) {
        (IPoolManager.PoolKey memory key, IPoolManager.ModifyPositionParams memory modifyPositionParams) =
            abi.decode(rawData, (IPoolManager.PoolKey, IPoolManager.ModifyPositionParams));

        BalanceDelta delta = poolManager.modifyPosition(key, modifyPositionParams);
        user2LP[lastestUser] = user2LP[lastestUser] + uint256(BalanceDelta.unwrap(delta));

        //将之前的奖励结算掉,重新开始计算
        if (delta.amount0() > 0) {
            key.currency0.transfer(address(poolManager), uint256(uint128(delta.amount0())));
            poolManager.settle(key.currency0);
        }
        if (delta.amount1() < 0) {
            poolManager.take(key.currency1, address(this), uint256(uint128(-delta.amount1())));
        }

        return bytes("");
    }
}

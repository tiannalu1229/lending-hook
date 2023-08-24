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
contract Lending is ILending {
    
    address public _token;
    address public _assets;
    uint256 public index;
    int256 public _tick;
    int256 public _basePrice;
    mapping(int256 => uint256[]) tick2Position;
    mapping(uint256 => address) index2User;
    mapping(uint256 => uint256) index2Amount;
    mapping(uint256 => int256) index2Ratio;
    mapping(uint256 => uint256) index2Borrow;
    int256[] public tickIndex;

    constructor(
        int256 basePrice_,
        address token_,
        address assets_,
        int256 tick_
    ) {
        _basePrice = basePrice_;
        _token = token_;
        _assets = assets_;
        _tick = tick_;
    }
    
    function borrow(int256 price, uint256 amount, int256 ratio, address user) external override {
        //transfer to contract
        IERC20(_token).transferFrom(user, address(this), amount);
        //计算借出数量
        index++;
        index2User[index] = msg.sender;
        index2Ratio[index] = ratio;
        index2Amount[index] = amount;
        int256 liqPrice = price * ratio / 100;
        int256 t = (liqPrice - _basePrice) * _tick / 100000000000000000;
        uint256[] storage tick2Position4Tick = tick2Position[t];
        tick2Position4Tick.push(index);
        tick2Position[t] = tick2Position4Tick;
        tickIndex[tickIndex.length] = t;
        //transfer to user
        uint256 borrow = (amount * uint256(price)) * uint256(ratio) / 100;
        index2Borrow[index] = borrow;
        IERC20(_assets).transferFrom(address(this), user, borrow);
    }
    
    function reedem(uint256 id, address user) external override {
        //user transfer to contract
        IERC20(_assets).transferFrom(user, address(this), index2Borrow[id]);
        require(index2Amount[id] > 0, "no id");
        //transfer to user
        IERC20(_token).transferFrom(address(this), user, index2Amount[id]);
    }

    function liquidate(int256 nowPrice) external override {
        int256 liqTick = (nowPrice - _basePrice) / 100000000000000000;
        for (uint i = 0; i < tickIndex.length; i++) {
            int256 x = tickIndex[i];
            if (x > nowPrice) {
                //清算该tick中所有仓位
                uint256[] memory positions = tick2Position[x];
                for (uint j = 0; j < positions.length; j++) {
                    uint256 position = positions[j];
                    index2Amount[position] = 0;
                }
            }
        }
    }
}
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {IPoolManager} from "./IPoolManager.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";

/// @notice The PoolManager contract decides whether to invoke specific hooks by inspecting the leading bits
/// of the hooks contract address. For example, a 1 bit in the first bit of the address will
/// cause the 'before swap' hook to be invoked. See the Hooks library for the full spec.
/// @dev Should only be callable by the v4 PoolManager.
interface ILending {
    
    function borrow(int256 price, uint256 amount, int256 ratio, address user) external;
    
    function reedem(uint256 id, address user) external;
    
    function liquidate(int256 nowPrice) external;
}

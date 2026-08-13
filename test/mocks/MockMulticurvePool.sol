// test/mocks/MockMulticurvePool.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMulticurvePool} from "../../src/IMulticurvePool.sol";
import {RIKRoyaltySplitter} from "../../src/RIKRoyaltySplitter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev A pool that pays its configured fees to whoever collects them.
contract MockMulticurvePool is IMulticurvePool {
    address private _token0;
    address private _token1;
    uint256 private _fees0;
    uint256 private _fees1;
    uint256 private _collectCount;

    constructor(address token0_, address token1_) {
        _token0 = token0_;
        _token1 = token1_;
    }

    function setFees(uint256 fees0_, uint256 fees1_) external {
        _fees0 = fees0_;
        _fees1 = fees1_;
    }

    /// @dev Lets a test point both sides at the same token, which a real pool never does.
    function setTokens(address token0_, address token1_) external {
        _token0 = token0_;
        _token1 = token1_;
    }

    function collectCount() external view returns (uint256) {
        return _collectCount;
    }

    function token0() external view returns (address) {
        return _token0;
    }

    function token1() external view returns (address) {
        return _token1;
    }

    function collectFees() external virtual {
        _collectCount++;

        uint256 amount0 = _fees0;
        uint256 amount1 = _fees1;
        _fees0 = 0;
        _fees1 = 0;

        if (amount0 != 0) require(IERC20(_token0).transfer(msg.sender, amount0), "MockPool: transfer0 failed");
        if (amount1 != 0) require(IERC20(_token1).transfer(msg.sender, amount1), "MockPool: transfer1 failed");
    }
}

/// @dev A pool whose `collectFees` reports success while sending nothing.
contract SilentMulticurvePool is IMulticurvePool {
    address private immutable _token0;
    address private immutable _token1;

    constructor(address token0_, address token1_) {
        _token0 = token0_;
        _token1 = token1_;
    }

    function token0() external view returns (address) {
        return _token0;
    }

    function token1() external view returns (address) {
        return _token1;
    }

    function collectFees() external {}
}

/// @dev A pool that takes tokens out of the collector instead of paying it.
contract DrainingMulticurvePool is IMulticurvePool {
    address private immutable _token0;
    address private immutable _token1;
    uint256 private immutable _amount;

    constructor(address token0_, address token1_, uint256 amount_) {
        _token0 = token0_;
        _token1 = token1_;
        _amount = amount_;
    }

    function token0() external view returns (address) {
        return _token0;
    }

    function token1() external view returns (address) {
        return _token1;
    }

    /// @dev Shrinks the collector's balance across the call. The splitter must treat that as an
    ///      error rather than wrapping it into an enormous credit.
    function collectFees() external {
        MockERC20(_token0).burn(msg.sender, _amount);
    }
}

/// @dev A pool that calls back into the splitter while it is collecting.
contract ReenteringMulticurvePool is IMulticurvePool {
    address private immutable _token0;
    address private immutable _token1;
    RIKRoyaltySplitter private immutable _splitter;

    constructor(address token0_, address token1_, RIKRoyaltySplitter splitter_) {
        _token0 = token0_;
        _token1 = token1_;
        _splitter = splitter_;
    }

    function token0() external view returns (address) {
        return _token0;
    }

    function token1() external view returns (address) {
        return _token1;
    }

    function collectFees() external {
        _splitter.collectPoolFees(this);
    }
}

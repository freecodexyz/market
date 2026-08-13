// test/mocks/MockERC20.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev A plain, well-behaved ERC20 with an open mint.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Open and allowance-free, so a hostile pool can shrink a holder's balance in a test.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/**
 * @dev An ERC20 that keeps a percentage of every transfer.
 *
 * Exists to prove that {RIKRoyaltySplitter} credits what actually arrived rather than what a pool
 * claimed to send. A splitter that trusted a reported amount would create buckets it cannot pay.
 */
contract FeeOnTransferERC20 is ERC20 {
    uint256 private constant _BPS = 10_000;

    uint256 private immutable _feeBps;

    constructor(string memory name_, string memory symbol_, uint256 feeBps_) ERC20(name_, symbol_) {
        _feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function feeBps() external view returns (uint256) {
        return _feeBps;
    }

    /// @dev Burns the fee rather than routing it anywhere, which is enough to shrink the delta.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * _feeBps) / _BPS;
        super._update(from, to, value - fee);
        super._update(from, address(0), fee);
    }
}

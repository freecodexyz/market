// src/DopplerPoolKey.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IDopplerHookInitializer, PoolKey} from "./IDopplerHookInitializer.sol";

/**
 * @dev Reads the pool identity shared by Doppler's multicurve and hook initializer families.
 *
 * Both expose `getState(address)`, but return different tuples. Multicurve (including decay)
 * returns eight static ABI words; hook initializers return eleven head words plus dynamic bytes.
 * The selector alone therefore cannot identify the return layout.
 */
library DopplerPoolKey {
    /**
     * @dev Reads the initializer's authoritative state for `asset`. Reverts from the initializer
     * are propagated, and an address without code is rejected by {Address-functionStaticCall}.
     */
    function read(address initializer, address asset) internal view returns (PoolKey memory) {
        return
            decode(Address.functionStaticCall(initializer, abi.encodeCall(IDopplerHookInitializer.getState, (asset))));
    }

    /**
     * @dev Decodes the two supported return layouts without changing or guessing the pool key.
     * Solidity's ABI decoder rejects truncated data and invalid field encodings. Unused members
     * describe the sale, not its pool identity.
     */
    function decode(bytes memory state) internal pure returns (PoolKey memory poolKey) {
        if (state.length == 8 * 32) {
            (,, poolKey,) = abi.decode(state, (address, uint8, PoolKey, int24));
        } else {
            (,,,,, poolKey,) = abi.decode(state, (address, uint256, address, bytes, uint8, PoolKey, int24));
        }
    }
}

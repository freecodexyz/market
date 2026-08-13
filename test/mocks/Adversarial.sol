// test/mocks/Adversarial.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {IAirlock} from "../../src/IAirlock.sol";
import {IJwtVerifier} from "../../src/IJwtVerifier.sol";
import {RIK} from "../../src/RIK.sol";
import {RIKLauncher} from "../../src/RIKLauncher.sol";
import {RIKRoyaltySplitter} from "../../src/RIKRoyaltySplitter.sol";

// --- ERC-721 receivers ------------------------------------------------------

/// @dev Accepts ERC-721s properly. The baseline a smart-contract wallet has to meet.
contract CompliantReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Implements the hook but answers with the wrong selector, which `_safeMint` must reject.
contract WrongAnswerReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(0xdeadbeef);
    }
}

/// @dev Refuses delivery outright.
contract RejectingReceiver is IERC721Receiver {
    error NotToday();

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotToday();
    }
}

/**
 * @dev Calls back into {RIK-register} from inside the mint hook.
 *
 * `_safeMint` hands control to the receiver, so this is the one place a registration can be
 * re-entered. Re-entering for the same repository must fail; re-entering for a different one is
 * legitimate and must keep working.
 */
contract ReenteringReceiver is IERC721Receiver {
    RIK private _rik;
    bytes private _reentrantCall;

    bool public reentered;
    bool public reentrySucceeded;

    function arm(RIK rik_, bytes calldata reentrantCall_) external {
        _rik = rik_;
        _reentrantCall = reentrantCall_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (_reentrantCall.length != 0 && !reentered) {
            reentered = true;
            // Raw call so a revert inside the nested registration does not take this one down.
            (bool ok,) = address(_rik).call(_reentrantCall);
            reentrySucceeded = ok;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

// --- verifiers --------------------------------------------------------------

/// @dev Returns whatever payload it is told to. Stands in for a compromised verifier, which is the
///      root of trust the whole registry rests on.
contract ScriptedVerifier is IJwtVerifier {
    bytes private _payload;

    constructor(bytes memory payload_) {
        _payload = payload_;
    }

    function verifyGithubOidc(bytes32, bytes calldata, bytes calldata, bytes calldata)
        external
        view
        returns (bytes memory)
    {
        return _payload;
    }
}

/// @dev Always rejects, so the failure has to propagate out of `register`.
contract RevertingVerifier is IJwtVerifier {
    error Nope();

    function verifyGithubOidc(bytes32, bytes calldata, bytes calldata, bytes calldata)
        external
        pure
        returns (bytes memory)
    {
        revert Nope();
    }
}

/**
 * @dev Tries to write storage while verifying.
 *
 * {IJwtVerifier-verifyGithubOidc} is declared `view`, so the compiler reaches it with STATICCALL and
 * this cannot succeed. That is what makes the verifier unable to reenter the registry, and it is
 * worth pinning: relaxing the interface to non-view would silently remove the protection.
 *
 * It deliberately does not inherit {IJwtVerifier}, because Solidity forbids implementing a `view`
 * interface function with a state-changing one — which is itself part of the guarantee.
 */
contract StateWritingVerifier {
    uint256 public calls;

    function verifyGithubOidc(bytes32, bytes calldata, bytes calldata, bytes calldata) external returns (bytes memory) {
        calls++;
        return "";
    }
}

// --- tokens -----------------------------------------------------------------

/// @dev Reverts on transfer. A bucket must survive a payout that could not be delivered.
contract RevertingERC20 is ERC20 {
    error TransferDisabled();

    bool private _blocked;

    constructor() ERC20("Reverting", "RVT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(bool value) external {
        _blocked = value;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (_blocked) revert TransferDisabled();
        return super.transfer(to, value);
    }
}

/// @dev Reports failure instead of reverting, the classic non-compliant ERC20 {SafeERC20} exists for.
contract FalseReturningERC20 is ERC20 {
    constructor() ERC20("Silent", "SLT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev Calls back into the splitter from inside a transfer, the way an ERC-777 hook would.
contract ReenteringERC20 is ERC20 {
    RIKRoyaltySplitter private _splitter;
    uint256 private _repoId;
    bool private _armed;

    bool public reentered;
    bool public reentrySucceeded;

    constructor() ERC20("Hostile", "HST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(RIKRoyaltySplitter splitter_, uint256 repoId_) external {
        _splitter = splitter_;
        _repoId = repoId_;
        _armed = true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (_armed && !reentered) {
            reentered = true;
            (bool ok,) = address(_splitter).call(abi.encodeCall(RIKRoyaltySplitter.claim, (_repoId, address(this), to)));
            reentrySucceeded = ok;
        }
        return super.transfer(to, value);
    }
}

// --- airlocks ---------------------------------------------------------------

/// @dev Reads the launcher's state while creating, which is the window the slot reservation closes.
contract ObservingAirlock is IAirlock {
    RIKLauncher private _launcher;
    address private immutable _asset;
    uint256 private immutable _repoId;

    address public observedMarket;

    constructor(address asset_, uint256 repoId_) {
        _asset = asset_;
        _repoId = repoId_;
    }

    function setLauncher(RIKLauncher launcher_) external {
        _launcher = launcher_;
    }

    function create(CreateParams calldata)
        external
        returns (address asset, address pool, address governance, address timelock, address migrationPool)
    {
        observedMarket = _launcher.marketOf(_repoId);
        return (_asset, address(0xB001), address(0), address(0), address(0));
    }

    function getIntegratorFees(address, address) external pure returns (uint256) {
        return 0;
    }

    function collectIntegratorFees(address, address, uint256) external pure {}
}

/// @dev Hands back an address the launcher uses as its own in-progress marker.
contract SentinelReturningAirlock is IAirlock {
    function create(CreateParams calldata)
        external
        pure
        returns (address asset, address pool, address governance, address timelock, address migrationPool)
    {
        return (address(1), address(0xB001), address(0), address(0), address(0));
    }

    function getIntegratorFees(address, address) external pure returns (uint256) {
        return 0;
    }

    function collectIntegratorFees(address, address, uint256) external pure {}
}

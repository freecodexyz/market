// test/MarketFixture.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {GithubOidcVerifier} from "../src/GithubOidcVerifier.sol";
import {IAirlock} from "../src/IAirlock.sol";
import {PoolKey} from "../src/IDopplerHookInitializer.sol";
import {IRIKRoyaltySplitter} from "../src/IRIKRoyaltySplitter.sol";
import {RIK} from "../src/RIK.sol";
import {RIKLauncher} from "../src/RIKLauncher.sol";
import {RIKRoyaltySplitter} from "../src/RIKRoyaltySplitter.sol";
import {MockAirlock} from "./mocks/MockAirlock.sol";
import {MockDopplerHookInitializer} from "./mocks/MockDopplerHookInitializer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {OidcFixture} from "./OidcFixture.sol";

/**
 * @dev The whole system, wired the way the deploy script wires it.
 *
 * The launcher and the splitter point at each other and both wirings are immutable, so the only way
 * to build them is to precompute one address before deploying the other. Doing that here rather
 * than mocking either side means the launch and payout tests exercise the real authorization path,
 * including registrations that come from real signed OIDC proofs.
 */
abstract contract MarketFixture is OidcFixture {
    /// @dev Must match the defaults baked into `test/fixtures/load-fixture.mjs`.
    uint64 constant ATTESTATION_REPO_ID = 900100200;
    string constant WORKFLOW_REF = "freecodexyz/market/.github/workflows/register-rik.yml@refs/heads/main";

    uint256 constant REPO_ID = 1296269;
    uint256 constant OWNER_ID = 583231;

    GithubOidcVerifier verifier;
    RIK rik;
    MockAirlock airlock;
    MockDopplerHookInitializer initializer;
    RIKLauncher launcher;
    RIKRoyaltySplitter splitter;

    MockERC20 asset;
    MockERC20 numeraire;

    address protocolOwner = address(0x0FEE);
    address stranger = address(0xBAD);
    address alice = address(0x1111111111111111111111111111111111111111);
    address bob = address(0x2222222222222222222222222222222222222222);

    address constant POOL_ADDRESS = address(0xB001);
    /// @dev The integrator a caller would like to set, and which the launcher must overwrite.
    address constant CALLER_INTEGRATOR = address(0xDEFEA7);

    function _deployMarket() internal {
        verifier = new GithubOidcVerifier(address(this));
        rik = new RIK(address(this), verifier);
        rik.setAttestationRepoId(ATTESTATION_REPO_ID);
        rik.setJobWorkflowRef(WORKFLOW_REF);

        asset = new MockERC20("Repository Token", "REPO");
        numeraire = new MockERC20("Wrapped Ether", "WETH");
        airlock = new MockAirlock(address(asset), POOL_ADDRESS);
        initializer = new MockDopplerHookInitializer();

        uint64 nonce = vm.getNonce(address(this));
        address launcherAddress = vm.computeCreateAddress(address(this), nonce);
        address splitterAddress = vm.computeCreateAddress(address(this), nonce + 1);

        launcher = new RIKLauncher(airlock, IERC721(address(rik)), IRIKRoyaltySplitter(splitterAddress));
        splitter = new RIKRoyaltySplitter(IERC721(address(rik)), airlock, launcherAddress, protocolOwner);

        assertEq(address(launcher), launcherAddress, "launcher address mismatch");
        assertEq(address(splitter), splitterAddress, "splitter address mismatch");
    }

    /// @dev Mints a repository's key to `wallet` through a real OIDC proof.
    ///
    ///      The market half does not care who claimed a repository, only who holds its key, so the
    ///      claimant is just the owner here. `RIK.t.sol` is where the two are pulled apart.
    function _registerRepo(uint256 repoId, uint256 ownerId, address wallet) internal {
        Fixture memory f = _fixture("sample-jwt.json", repoId, ownerId, ownerId, wallet);
        verifier.addKey(f.kid, f.modulus, f.exponent);
        rik.register(f.kid, f.headerB64, f.payloadB64, f.signature, repoId, ownerId, ownerId, wallet);
    }

    /// @dev Funds the initializer and credits `asset`'s pool with fees it has earned.
    function _earn(address asset_, uint256 amount0, uint256 amount1) internal {
        (address currency0, address currency1) = _currenciesOf(asset_);
        if (amount0 != 0) MockERC20(currency0).mint(address(initializer), amount0);
        if (amount1 != 0) MockERC20(currency1).mint(address(initializer), amount1);
        initializer.accrue(asset_, amount0, amount1);
    }

    /// @dev The sorted pair for `asset_`, which is the order the splitter credits them in.
    function _currenciesOf(address asset_) internal view returns (address currency0, address currency1) {
        (,,,,, PoolKey memory poolKey,) = initializer.getState(asset_);
        return (poolKey.currency0, poolKey.currency1);
    }

    /// @dev Registers `REPO_ID` to `alice` and launches its market.
    function _launchedMarket() internal returns (address launched) {
        _registerRepo(REPO_ID, OWNER_ID, alice);

        vm.prank(alice);
        launched = launcher.launch(REPO_ID, _params());
    }

    /// @dev Recognisable values throughout, so a forwarding test can tell them apart.
    function _params() internal view returns (IAirlock.CreateParams memory p) {
        return _paramsFor(address(numeraire), address(initializer));
    }

    /// @dev Lets a test vary only the two fields the launcher reasons about.
    function _paramsFor(address numeraire_, address initializer_)
        internal
        pure
        returns (IAirlock.CreateParams memory p)
    {
        p.initialSupply = 1_000_000 ether;
        p.numTokensToSell = 500_000 ether;
        p.numeraire = numeraire_;
        p.tokenFactory = address(0x70E3);
        p.tokenFactoryData = hex"1234";
        p.governanceFactory = address(0x90C0);
        p.governanceFactoryData = hex"5678";
        p.poolInitializer = initializer_;
        p.poolInitializerData = hex"abcd";
        p.liquidityMigrator = address(0x111111);
        p.liquidityMigratorData = hex"dcba";
        p.integrator = CALLER_INTEGRATOR;
        p.salt = bytes32(uint256(1));
    }
}

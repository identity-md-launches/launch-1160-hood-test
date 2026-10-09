// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HOODTToken} from "../src/HOODTToken.sol";

import {PoolManager} from "./vendor/v4-core/src/PoolManager.sol";
import {IPoolManager} from "./vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "./vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "./vendor/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "./vendor/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "./vendor/v4-core/src/types/PoolId.sol";
import {Currency} from "./vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "./vendor/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "./vendor/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "./vendor/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "./vendor/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "./vendor/v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "./vendor/v4-core/src/libraries/StateLibrary.sol";

/// @notice The ERC-20 surface the pool flows use.
interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Pays what a BalanceDelta says the caller owes and takes what it is owed, the way every
/// v4 integrator settles: sync, transfer, settle for debts; take for credits.
library Settlement {
    function settle(IPoolManager manager, Currency currency, int128 amount) internal {
        if (amount < 0) {
            manager.sync(currency);
            IERC20Like(Currency.unwrap(currency)).transfer(address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @notice IMD, the chain's pair token, as a plain 18-decimal ERC-20 placed at the real address so
/// the pool orders its currencies exactly as it will on Robinhood Chain.
contract PairTokenStub {
    string public constant name = "IdentityMD";
    string public constant symbol = "IMD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Stands in for the launch factory: deploys the token (so the constructor mints to it),
/// forwards shares, initialises the pool and seeds it single-sided through the pool manager's
/// unlock, then collects the position's fees. Only the test drives it.
contract LaunchFactoryStub is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    struct Seed {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    address private immutable controller = msg.sender;
    IPoolManager private immutable manager;
    HOODTToken public token;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    modifier onlyController() {
        require(msg.sender == controller, "not the test");
        _;
    }

    function deployToken() external onlyController returns (HOODTToken deployed) {
        deployed = new HOODTToken();
        token = deployed;
    }

    function move(address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }

    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external onlyController returns (int24) {
        return manager.initialize(key, sqrtPriceX96);
    }

    function seed(Seed calldata seed_) external onlyController returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(true, abi.encode(seed_))), (BalanceDelta));
    }

    function collect(Seed calldata position) external onlyController returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(false, abi.encode(position))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (bool adding, bytes memory inner) = abi.decode(data, (bool, bytes));
        Seed memory s = abi.decode(inner, (Seed));
        int256 delta = adding ? int256(uint256(s.liquidity)) : int256(0);
        (BalanceDelta callerDelta,) =
            manager.modifyLiquidity(s.key, ModifyLiquidityParams(s.tickLower, s.tickUpper, delta, bytes32(0)), "");
        Settlement.settle(manager, s.key.currency0, callerDelta.amount0());
        Settlement.settle(manager, s.key.currency1, callerDelta.amount1());
        return abi.encode(callerDelta);
    }
}

/// @notice An ordinary trader: nothing the token could have any reason to treat specially.
contract TraderStub is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(key, zeroForOne, amountSpecified)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified) = abi.decode(data, (PoolKey, bool, int256));
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = manager.swap(key, SwapParams(zeroForOne, amountSpecified, limit), "");
        Settlement.settle(manager, key.currency0, delta.amount0());
        Settlement.settle(manager, key.currency1, delta.amount1());
        return abi.encode(delta);
    }
}

/// @notice The launch as the factory performs it on Robinhood Chain, against a real Uniswap v4
/// PoolManager built at its chain address: swarm share out, pool seeded single-sided at the price
/// derived from the economics, remainder forwarded, then a trader buys and sells through the pool
/// with its 1.25% fee. Every flow must move exactly what it says, because the token has no tax.
/// @dev Abstract: the two concrete suites below pin the factory's CREATE2 salt so the token lands
/// on either side of IMD, because the real currency order is only known once the token is deployed.
abstract contract HOODTLaunchPoolTest is Test {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 constant SWARM_BPS = 1_000;
    uint256 constant POOL_BPS = 9_000;
    uint256 constant SWARM_SHARE = SUPPLY * SWARM_BPS / 10_000;
    uint256 constant POOL_SHARE = SUPPLY * POOL_BPS / 10_000;
    uint256 constant INITIAL_MARKET_CAP_WEI = 2_500 ether;
    uint24 constant FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    /// @dev launch.json pool.initialPrice: sqrt price with HOODT as currency0, provenance only.
    uint160 constant MANIFEST_SQRT_PRICE = 125_270_724_187_523_965_593_206_900;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant REMAINDER_TO = 0x000000000000000000000000000000000000dEaD;
    address constant DISTRIBUTOR = address(0xD157);

    IPoolManager manager;
    PairTokenStub imd;
    LaunchFactoryStub factory;
    HOODTToken token;
    TraderStub trader;
    PoolKey key;
    bool hoodtIsCurrency0;
    uint160 openingSqrtPrice;
    LaunchFactoryStub.Seed position;

    function setUp() public {
        // IMD at its real address.
        vm.etch(IMD, address(new PairTokenStub()).code);
        imd = PairTokenStub(IMD);

        // The pool manager constructed in place at its real address: v4 records the address it was
        // built at and refuses to run anywhere else, so copying runtime code there would not do.
        vm.etch(POOL_MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool built, bytes memory runtime) = POOL_MANAGER.call("");
        require(built && runtime.length > 0, "pool manager could not be built in place");
        vm.etch(POOL_MANAGER, runtime);
        manager = IPoolManager(POOL_MANAGER);

        // Pick a factory salt whose first CREATE (the token) lands on the wanted side of IMD.
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(LaunchFactoryStub).creationCode, abi.encode(manager)));
        uint256 salt;
        while (true) {
            address predictedFactory = vm.computeCreate2Address(bytes32(salt), initCodeHash, address(this));
            address predictedToken = vm.computeCreateAddress(predictedFactory, 1);
            if ((predictedToken < IMD) == _wantHoodtIsCurrency0()) break;
            ++salt;
        }
        factory = new LaunchFactoryStub{salt: bytes32(salt)}(manager);
        token = factory.deployToken();
        trader = new TraderStub(manager);

        hoodtIsCurrency0 = address(token) < IMD;
        assertEq(hoodtIsCurrency0, _wantHoodtIsCurrency0(), "the salt search did not give the wanted order");
        (Currency c0, Currency c1) = hoodtIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(IMD))
            : (Currency.wrap(IMD), Currency.wrap(address(token)));
        key = PoolKey(c0, c1, FEE, TICK_SPACING, IHooks(address(0)));

        // The opening price the deployer derives from the economics: 2,500 IMD for the whole supply,
        // expressed for whichever currency order the deployed addresses give.
        openingSqrtPrice = hoodtIsCurrency0
            ? uint160(_sqrt(FullMath.mulDiv(INITIAL_MARKET_CAP_WEI, 2 ** 192, SUPPLY)))
            : uint160(_sqrt(FullMath.mulDiv(SUPPLY, 2 ** 192, INITIAL_MARKET_CAP_WEI)));
    }

    function _wantHoodtIsCurrency0() internal pure virtual returns (bool);

    // ---------------------------------------------------------------- the launch itself

    /// @dev Runs the factory's launch: swarm share, pool initialise, single-sided seed, remainder.
    function _launch() internal returns (uint256 seeded, uint256 remainder) {
        assertTrue(factory.move(DISTRIBUTOR, SWARM_SHARE), "swarm transfer returned false");
        factory.initialize(key, openingSqrtPrice);
        position = _singleSidedPosition(POOL_SHARE);
        uint256 before = token.balanceOf(address(factory));
        factory.seed(position);
        seeded = before - token.balanceOf(address(factory));
        remainder = token.balanceOf(address(factory));
        assertTrue(factory.move(REMAINDER_TO, remainder), "remainder transfer returned false");
    }

    function test_constructorMintsTheWholeSupplyToTheFactory() public view {
        assertEq(token.balanceOf(address(factory)), SUPPLY, "the factory does not hold the whole supply");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    /// @dev launch.json's initialPrice is the sqrt price of 2,500 IMD / 1e9 HOODT with HOODT as
    /// currency0, to within integer-sqrt rounding of the figure the economics give.
    function test_manifestInitialPriceMatchesTheEconomics() public pure {
        uint256 derived = _sqrt(FullMath.mulDiv(INITIAL_MARKET_CAP_WEI, 2 ** 192, SUPPLY));
        assertApproxEqRel(derived, MANIFEST_SQRT_PRICE, 1e9, "pool.initialPrice disagrees with the economics");
    }

    function test_launchFlowsMoveExactlyWhatTheySay() public {
        (uint256 seeded, uint256 remainder) = _launch();

        assertEq(token.balanceOf(DISTRIBUTOR), SWARM_SHARE, "the swarm's 10% arrived short");
        assertGt(seeded, 0, "the seed took nothing");
        assertLe(seeded, POOL_SHARE, "the seed took more than the 90% pool share");
        // Single-sided liquidity rounds down; the seed is the pool share less at most a few units.
        assertGe(seeded, POOL_SHARE - 1e6, "the seed left far more than rounding dust behind");
        assertEq(token.balanceOf(POOL_MANAGER), seeded, "the pool manager holds something other than the seed");
        assertEq(token.balanceOf(REMAINDER_TO), remainder, "the remainder arrived short");
        assertEq(remainder, SUPPLY - SWARM_SHARE - seeded, "the remainder is not what was left");
        assertEq(token.balanceOf(address(factory)), 0, "the factory kept units back");
        assertEq(
            token.balanceOf(DISTRIBUTOR) + token.balanceOf(POOL_MANAGER) + token.balanceOf(REMAINDER_TO),
            SUPPLY,
            "the launch created or destroyed units"
        );
        assertEq(token.totalSupply(), SUPPLY);

        (uint160 sqrtPrice, int24 tick,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(sqrtPrice, openingSqrtPrice, "the pool did not open at the derived price");
        assertEq(tick, TickMath.getTickAtSqrtPrice(openingSqrtPrice));
        assertEq(lpFee, FEE, "the pool fee is not 12500");
        assertEq(manager.getLiquidity(key.toId()), 0, "a single-sided seed must sit outside the current tick");
    }

    /// @dev The distributor pays claimants until it is empty; every claim arrives whole and the last
    /// one gets exactly what is left, so nobody is shorted by a tax on the claim path.
    function testFuzz_swarmClaimsExhaustTheDistributorExactly(uint8 claimantCount, uint256 skew) public {
        uint256 n = bound(claimantCount, 1, 40);
        factory.move(DISTRIBUTOR, SWARM_SHARE);
        uint256 each = SWARM_SHARE / n;
        skew = bound(skew, 0, each);
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            address claimant = address(uint160(0xC1A1_0000 + i));
            uint256 amount = i + 1 == n ? SWARM_SHARE - paid : (i % 2 == 0 ? each - skew : each + skew);
            vm.prank(DISTRIBUTOR);
            assertTrue(token.transfer(claimant, amount));
            assertEq(token.balanceOf(claimant), amount, "a claim arrived short");
            paid += amount;
        }
        assertEq(paid, SWARM_SHARE);
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "the distributor kept something back");
        vm.prank(DISTRIBUTOR);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientBalance.selector, DISTRIBUTOR, 0, 1));
        token.transfer(address(0xC1A1), 1);
    }

    /// @dev The factory cannot seed more than it holds: a seed sized above the balance reverts inside
    /// the pool manager's unlock and leaves pool and balances untouched.
    function test_seedBeyondTheFactoryBalanceReverts() public {
        factory.move(DISTRIBUTOR, SWARM_SHARE);
        factory.initialize(key, openingSqrtPrice);
        LaunchFactoryStub.Seed memory tooBig = _singleSidedPosition(POOL_SHARE + SWARM_SHARE);
        vm.expectRevert();
        factory.seed(tooBig);
        assertEq(token.balanceOf(address(factory)), SUPPLY - SWARM_SHARE);
        assertEq(token.balanceOf(POOL_MANAGER), 0);
        assertEq(manager.getLiquidity(key.toId()), 0);
    }

    // ---------------------------------------------------------------- trading through the pool

    /// @dev Launch, then buy with one IMD: exact input of IMD, HOODT out. The pool's deltas and
    /// the token balances must agree to the unit, which only holds for a token with no tax.
    function _launchAndBuyOneImd() internal returns (uint256 seeded, uint256 bought) {
        (seeded,) = _launch();
        imd.mint(address(trader), 1 ether);
        BalanceDelta buy = trader.swap(key, !hoodtIsCurrency0, -int256(1 ether));
        int128 hoodtOut = hoodtIsCurrency0 ? buy.amount0() : buy.amount1();
        int128 imdPaid = hoodtIsCurrency0 ? buy.amount1() : buy.amount0();
        assertEq(imdPaid, -int128(int256(1 ether)), "the exact-input buy did not take exactly the input");
        assertGt(hoodtOut, 0, "the trader could not buy");
        bought = uint256(uint128(hoodtOut));
    }

    function test_traderBuysThroughThePoolManagerPayingTheFee() public {
        (uint256 seeded, uint256 bought) = _launchAndBuyOneImd();
        assertEq(token.balanceOf(address(trader)), bought, "the trader received less HOODT than the pool paid");
        assertEq(token.balanceOf(POOL_MANAGER), seeded - bought, "the pool manager lost more HOODT than it paid");
        assertEq(imd.balanceOf(POOL_MANAGER), 1 ether);
        assertEq(imd.balanceOf(address(trader)), 0);

        // At a 2,500 IMD cap for 1e9 HOODT, 1 IMD buys about 400,000 HOODT less the 1.25% fee and
        // the price impact of the trade itself.
        assertLt(bought, 400_000 ether * (1_000_000 - uint256(FEE)) / 1_000_000, "the fee was not charged");
        assertGt(bought, 390_000 ether, "the buy returned far less than the opening price implies");

        // The price moved in HOODT's favour and the fee accrued to the pool, in IMD only.
        (uint160 sqrtPriceAfterBuy,,,) = manager.getSlot0(key.toId());
        if (hoodtIsCurrency0) assertGt(sqrtPriceAfterBuy, openingSqrtPrice, "buying HOODT did not raise its price");
        else assertLt(sqrtPriceAfterBuy, openingSqrtPrice, "buying HOODT did not raise its price");
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        assertGt(hoodtIsCurrency0 ? growth1 : growth0, 0, "no IMD fee accrued on the buy");
        assertEq(hoodtIsCurrency0 ? growth0 : growth1, 0, "a HOODT fee accrued before any HOODT was sold");
    }

    function test_traderSellsBackThroughThePoolManagerPayingTheFeeAgain() public {
        (uint256 seeded, uint256 bought) = _launchAndBuyOneImd();

        // Sell everything back: exact input of HOODT, IMD out.
        BalanceDelta sell = trader.swap(key, hoodtIsCurrency0, -int256(bought));
        int128 hoodtPaid = hoodtIsCurrency0 ? sell.amount0() : sell.amount1();
        uint256 returned = uint256(uint128(hoodtIsCurrency0 ? sell.amount1() : sell.amount0()));
        assertEq(uint256(uint128(-hoodtPaid)), bought, "the sell did not take exactly what was bought");
        assertEq(token.balanceOf(address(trader)), 0, "the trader could not sell everything");
        assertEq(token.balanceOf(POOL_MANAGER), seeded, "the pool manager did not get back exactly what was sold");
        assertEq(imd.balanceOf(address(trader)), returned);
        assertEq(imd.balanceOf(POOL_MANAGER), 1 ether - returned);

        // Two 1.25% fees were paid; nothing else of note was lost on a trade this small.
        assertLt(returned, 1 ether * (1_000_000 - uint256(FEE)) / 1_000_000, "the round trip did not pay the fee");
        assertGt(returned, 0.96 ether, "the round trip lost more than two fees and slippage explain");
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        assertGt(hoodtIsCurrency0 ? growth0 : growth1, 0, "no HOODT fee accrued on the sell");

        // Supply conservation across every party the launch touched.
        assertEq(
            token.balanceOf(DISTRIBUTOR) + token.balanceOf(POOL_MANAGER) + token.balanceOf(REMAINDER_TO)
                + token.balanceOf(address(trader)) + token.balanceOf(address(factory)),
            SUPPLY
        );
    }

    /// @dev The fees belong to the seeded position. Collecting them moves exactly the accrued
    /// amounts of each currency to the factory and nothing else.
    function test_seederCollectsExactlyTheAccruedFees() public {
        (uint256 seeded,) = _launch();
        imd.mint(address(trader), 5 ether);
        trader.swap(key, !hoodtIsCurrency0, -int256(5 ether));
        uint256 bought = token.balanceOf(address(trader));
        trader.swap(key, hoodtIsCurrency0, -int256(bought));

        uint256 factoryHoodtBefore = token.balanceOf(address(factory));
        uint256 factoryImdBefore = imd.balanceOf(address(factory));
        uint256 poolHoodtBefore = token.balanceOf(POOL_MANAGER);
        BalanceDelta fees = factory.collect(position);
        int128 hoodtFee = hoodtIsCurrency0 ? fees.amount0() : fees.amount1();
        int128 imdFee = hoodtIsCurrency0 ? fees.amount1() : fees.amount0();
        assertGt(hoodtFee, 0, "no HOODT fee to collect after a sell");
        assertGt(imdFee, 0, "no IMD fee to collect after a buy");
        assertEq(token.balanceOf(address(factory)) - factoryHoodtBefore, uint256(uint128(hoodtFee)));
        assertEq(imd.balanceOf(address(factory)) - factoryImdBefore, uint256(uint128(imdFee)));
        assertEq(poolHoodtBefore - token.balanceOf(POOL_MANAGER), uint256(uint128(hoodtFee)));
        // The fee is roughly 1.25% of the HOODT sold, and the sale returned HOODT to the pool.
        assertApproxEqRel(uint256(uint128(hoodtFee)), bought * uint256(FEE) / 1_000_000, 0.01e18);
        assertEq(poolHoodtBefore, seeded, "the pool did not hold the seed again after the round trip");
    }

    /// @dev Any trade size up to half the opening cap: the trader can buy and sell back, the pool's
    /// deltas equal the token movements to the unit, and the supply is conserved across all parties.
    function testFuzz_roundTripOfAnySizeIsExactAndConservesSupply(uint256 imdIn) public {
        imdIn = bound(imdIn, 1e9, 1_250 ether);
        (uint256 seeded,) = _launch();
        imd.mint(address(trader), imdIn);

        BalanceDelta buy = trader.swap(key, !hoodtIsCurrency0, -int256(imdIn));
        uint256 bought = uint256(uint128(hoodtIsCurrency0 ? buy.amount0() : buy.amount1()));
        assertGt(bought, 0, "a trader could not buy");
        assertEq(token.balanceOf(address(trader)), bought);
        assertEq(token.balanceOf(POOL_MANAGER), seeded - bought);

        BalanceDelta sell = trader.swap(key, hoodtIsCurrency0, -int256(bought));
        uint256 returned = uint256(uint128(hoodtIsCurrency0 ? sell.amount1() : sell.amount0()));
        assertEq(token.balanceOf(address(trader)), 0, "a trader could not sell everything back");
        assertEq(token.balanceOf(POOL_MANAGER), seeded);
        assertLt(returned, imdIn, "a round trip through a 1.25% pool returned at least what went in");
        assertEq(imd.balanceOf(address(trader)) + imd.balanceOf(POOL_MANAGER), imdIn);
        assertEq(
            token.balanceOf(DISTRIBUTOR) + token.balanceOf(POOL_MANAGER) + token.balanceOf(REMAINDER_TO)
                + token.balanceOf(address(trader)),
            SUPPLY
        );
    }

    /// @dev An exact-output buy delivers exactly the HOODT asked for: the pool pays `amount`, the
    /// trader receives `amount`. A fee-on-transfer token would fail this.
    function testFuzz_exactOutputBuyDeliversExactlyTheAmount(uint256 want) public {
        want = bound(want, 1, 100_000_000 ether);
        (uint256 seeded,) = _launch();
        imd.mint(address(trader), 100_000 ether);
        BalanceDelta buy = trader.swap(key, !hoodtIsCurrency0, int256(want));
        int128 hoodtOut = hoodtIsCurrency0 ? buy.amount0() : buy.amount1();
        assertEq(uint256(uint128(hoodtOut)), want, "the pool did not pay the exact output");
        assertEq(token.balanceOf(address(trader)), want, "the trader did not receive the exact output");
        assertEq(token.balanceOf(POOL_MANAGER), seeded - want);
        assertGt(100_000 ether - imd.balanceOf(address(trader)), 0, "the buy cost nothing");
    }

    /// @dev Selling HOODT one does not have fails inside the pool manager's unlock with the token's
    /// own error and leaves the pool exactly as it was.
    function test_sellingMoreThanHeldRevertsWithTheTokenErrorAndChangesNothing() public {
        (uint256 seeded,) = _launch();
        imd.mint(address(trader), 1 ether);
        trader.swap(key, !hoodtIsCurrency0, -int256(1 ether));
        uint256 held = token.balanceOf(address(trader));
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());

        vm.expectRevert(
            abi.encodeWithSelector(HOODTToken.InsufficientBalance.selector, address(trader), held, held + 1)
        );
        trader.swap(key, hoodtIsCurrency0, -int256(held + 1));

        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore, "a failed sell moved the price");
        assertEq(token.balanceOf(address(trader)), held);
        assertEq(token.balanceOf(POOL_MANAGER), seeded - held);
    }

    /// @dev A trader with no IMD cannot buy: the pair-token transfer in settlement fails and the
    /// HOODT side is untouched.
    function test_buyWithoutPairTokenRevertsAndMovesNoHoodt() public {
        (uint256 seeded,) = _launch();
        vm.expectRevert();
        trader.swap(key, !hoodtIsCurrency0, -int256(1 ether));
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(POOL_MANAGER), seeded);
    }

    /// @dev Nobody but a holder can pull HOODT out of the pool manager: the token has no privileged
    /// path, and the manager's balance is only reachable through its own accounting.
    function test_nobodyCanMoveThePoolManagersHoodtDirectly() public {
        (uint256 seeded,) = _launch();
        address[3] memory callers = [address(factory), address(this), DISTRIBUTOR];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(HOODTToken.InsufficientAllowance.selector, callers[i], 0, uint256(1))
            );
            token.transferFrom(POOL_MANAGER, callers[i], 1);
        }
        assertEq(token.balanceOf(POOL_MANAGER), seeded);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev A position holding `amount` of HOODT entirely on the HOODT side of the current price:
    /// above it when HOODT is currency0, below it when HOODT is currency1.
    function _singleSidedPosition(uint256 amount) internal view returns (LaunchFactoryStub.Seed memory s) {
        int24 current = TickMath.getTickAtSqrtPrice(openingSqrtPrice);
        s.key = key;
        if (hoodtIsCurrency0) {
            s.tickLower = _ceilToSpacing(current + 1);
            s.tickUpper = TickMath.maxUsableTick(TICK_SPACING);
            uint160 sA = TickMath.getSqrtPriceAtTick(s.tickLower);
            uint160 sB = TickMath.getSqrtPriceAtTick(s.tickUpper);
            uint256 intermediate = FullMath.mulDiv(sA, sB, FixedPoint96.Q96);
            s.liquidity = uint128(FullMath.mulDiv(amount, intermediate, sB - sA));
        } else {
            s.tickLower = TickMath.minUsableTick(TICK_SPACING);
            s.tickUpper = _floorToSpacing(current);
            uint160 sA = TickMath.getSqrtPriceAtTick(s.tickLower);
            uint160 sB = TickMath.getSqrtPriceAtTick(s.tickUpper);
            s.liquidity = uint128(FullMath.mulDiv(amount, FixedPoint96.Q96, sB - sA));
        }
    }

    function _ceilToSpacing(int24 tick) internal pure returns (int24) {
        int24 q = tick / TICK_SPACING;
        if (q * TICK_SPACING < tick) q += 1;
        return q * TICK_SPACING;
    }

    function _floorToSpacing(int24 tick) internal pure returns (int24) {
        int24 q = tick / TICK_SPACING;
        if (q * TICK_SPACING > tick) q -= 1;
        return q * TICK_SPACING;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }
}

/// @notice HOODT sorts below IMD: HOODT is currency0, as launch.json's initialPrice assumes.
contract HOODTLaunchPoolHoodtIsCurrency0Test is HOODTLaunchPoolTest {
    function _wantHoodtIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

/// @notice HOODT sorts above IMD: HOODT is currency1 and the deployer inverts the opening price.
contract HOODTLaunchPoolHoodtIsCurrency1Test is HOODTLaunchPoolTest {
    function _wantHoodtIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

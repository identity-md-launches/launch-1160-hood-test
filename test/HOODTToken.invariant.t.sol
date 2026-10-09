// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HOODTToken} from "../src/HOODTToken.sol";

/// @notice Drives the token with random, bounded call sequences from a fixed cast of actors and
/// keeps a ghost ledger of every balance and allowance. The failure paths are called on purpose
/// with `expectRevert`, so a sequence that makes one of them succeed fails the run.
contract HOODTHandler is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;

    HOODTToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public transfers;
    uint256 public transferFroms;
    uint256 public revertsSeen;

    constructor(HOODTToken token_, address deployer, address[] memory actors_) {
        token = token_;
        actors = actors_;
        ghostBalance[deployer] = SUPPLY;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ---------------------------------------------------------------- happy paths

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        bool ok = token.transfer(to, amount);
        require(ok, "transfer returned false");
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        transfers++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = type(uint256).max;
        vm.prank(owner);
        require(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[from][spender];
        uint256 cap = allowed < ghostBalance[from] ? allowed : ghostBalance[from];
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        require(token.transferFrom(from, to, amount), "transferFrom returned false");
        if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        transferFroms++;
    }

    // ---------------------------------------------------------------- failure paths

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ghostBalance[from];
        excess = bound(excess, 1, type(uint256).max - held);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientBalance.selector, from, held, held + excess));
        token.transfer(to, held + excess);
        revertsSeen++;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        vm.expectRevert(HOODTToken.ZeroAddress.selector);
        token.transfer(address(0), amount);
        revertsSeen++;
    }

    function transferFromTooMuchAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        uint256 allowed = ghostAllowance[from][spender];
        if (allowed == type(uint256).max) return; // infinite allowance has no excess
        excess = bound(excess, 1, type(uint256).max - allowed);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(HOODTToken.InsufficientAllowance.selector, spender, allowed, allowed + excess)
        );
        token.transferFrom(from, _actor(toSeed), allowed + excess);
        revertsSeen++;
    }

    function transferFromTooMuchBalance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        uint256 held = ghostBalance[from];
        uint256 allowed = ghostAllowance[from][spender];
        if (allowed <= held) return; // then the allowance check fires first, covered above
        excess = bound(excess, 1, allowed - held);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientBalance.selector, from, held, held + excess));
        token.transferFrom(from, _actor(toSeed), held + excess);
        revertsSeen++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        vm.prank(_actor(ownerSeed));
        vm.expectRevert(HOODTToken.ZeroAddress.selector);
        token.approve(address(0), amount);
        revertsSeen++;
    }

    /// @dev Somebody keeps trying the admin calls a token might have. None exists, from anyone.
    function adminAttempt(uint256 callerSeed, uint256 which, uint256 amount) external {
        string[9] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "transferOwnership(address)",
            "setFee(uint256)"
        ];
        address caller = _actor(callerSeed);
        bytes memory data = abi.encodeWithSignature(signatures[which % signatures.length], caller, amount);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        require(!ok, "an admin call succeeded");
        revertsSeen++;
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract HOODTTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;

    HOODTToken token;
    HOODTHandler handler;
    address deployer = makeAddr("deployer");
    address[] actors;
    bytes32 codeHashAtDeployment;

    function setUp() public {
        vm.prank(deployer);
        token = new HOODTToken();
        codeHashAtDeployment = address(token).codehash;

        actors.push(deployer);
        actors.push(makeAddr("distributor"));
        actors.push(makeAddr("claimant"));
        actors.push(makeAddr("trader"));
        actors.push(makeAddr("holder"));
        actors.push(address(0xdead));

        handler = new HOODTHandler(token, deployer, actors);
        targetContract(address(handler));
    }

    /// @dev What the contract reports equals what the ledger says it owes: every balance.
    function invariant_balancesMatchTheLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.ghostBalance(actors[i]), "balance drifted from the ledger");
        }
    }

    /// @dev The supply is fixed: the sum of all balances is exactly 1e27 and totalSupply never moves.
    function invariant_sumOfBalancesIsTheFixedSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "units were created or destroyed");
        assertEq(token.totalSupply(), SUPPLY, "totalSupply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds units");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own units");
    }

    function invariant_allowancesMatchTheLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.ghostAllowance(actors[i], actors[j]),
                    "allowance drifted from the ledger"
                );
            }
        }
    }

    /// @dev Nothing about the contract itself can change: same code, same constants.
    function invariant_codeAndConstantsAreImmutable() public view {
        assertEq(address(token).codehash, codeHashAtDeployment, "runtime code changed");
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Hood Test");
        assertEq(token.symbol(), "HOODT");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HOODTToken} from "../src/HOODTToken.sol";

/// @notice Property tests for HOODT at the edges the smoke suite does not reach: arbitrary
/// amounts, arbitrary callers, the same call twice, an allowance that is larger than the balance,
/// a balance that is larger than the allowance, selectors the contract does not have.
/// Foundry's default fuzz runs are kept on purpose.
contract HOODTTokenFuzzTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    HOODTToken token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new HOODTToken();
    }

    function _usable(address a) internal view returns (bool) {
        // Not zero (the token rejects it), not a precompile, not an existing contract in the test
        // (the token itself, the test, the cheatcode address), so a transfer to it is an ordinary one.
        return a != address(0) && uint160(a) > 0xff && a.code.length == 0 && a != address(token);
    }

    // ---------------------------------------------------------------- deployment

    /// @dev Whoever deploys receives the whole supply: the factory, in the real launch.
    function testFuzz_anyDeployerReceivesTheWholeSupply(address who) public {
        vm.assume(_usable(who));
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), who, SUPPLY);
        vm.prank(who);
        HOODTToken fresh = new HOODTToken();
        assertEq(fresh.balanceOf(who), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(deployer), 0, "another deployment credited a stranger");
    }

    /// @dev Two deployments are two independent supplies; neither can see or move the other.
    function test_twoDeploymentsDoNotShareState() public {
        vm.prank(alice);
        HOODTToken other = new HOODTToken();
        assertEq(other.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_runtimeFitsEip170() public view {
        assertLe(address(token).code.length, 24_576);
    }

    // ---------------------------------------------------------------- transfer

    function testFuzz_transferMovesExactlyTheAmount(address to, uint256 amount) public {
        vm.assume(_usable(to) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, to, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount, "recipient did not receive the exact amount");
        assertEq(token.balanceOf(deployer), SUPPLY - amount, "sender did not lose the exact amount");
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY, "a transfer created or destroyed units");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferOfMoreThanTheBalanceRevertsAndMovesNothing(uint256 held, uint256 attempt) public {
        held = bound(held, 0, SUPPLY - 1);
        attempt = bound(attempt, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, held);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientBalance.selector, alice, held, attempt));
        token.transfer(bob, attempt);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
    }

    function testFuzz_transferToZeroAddressAlwaysReverts(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        vm.expectRevert(HOODTToken.ZeroAddress.selector);
        token.transfer(address(0), amount);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testFuzz_selfTransferChangesNothing(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, amount));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev Repeating a transfer costs exactly twice, and a chain of transfers conserves units.
    function testFuzz_repeatedAndChainedTransfersConserveSupply(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY / 2);
        b = bound(b, 0, a);
        vm.startPrank(deployer);
        token.transfer(alice, a);
        token.transfer(alice, a);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 2 * a);

        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(alice, b);
        assertEq(token.balanceOf(alice), 2 * a);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
    }

    /// @dev A holder with nothing can still send zero; a holder with nothing cannot send one.
    function testFuzz_emptyHolderCanOnlySendZero(address who) public {
        vm.assume(_usable(who) && who != deployer);
        vm.prank(who);
        assertTrue(token.transfer(alice, 0));
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientBalance.selector, who, 0, 1));
        token.transfer(alice, 1);
    }

    // ---------------------------------------------------------------- approve / transferFrom

    function testFuzz_approveSetsNotAdds(uint256 first, uint256 second) public {
        vm.startPrank(deployer);
        token.approve(alice, first);
        assertEq(token.allowance(deployer, alice), first);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, second);
        token.approve(alice, second);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), second, "approve accumulated instead of overwriting");
        assertEq(token.allowance(alice, deployer), 0, "allowance leaked in the other direction");
    }

    /// @dev Approving more than one holds is allowed; it only fails when spent beyond the balance.
    function testFuzz_allowanceMayExceedBalanceButCannotBeSpentBeyondIt(uint256 held, uint256 attempt) public {
        held = bound(held, 0, SUPPLY - 1);
        attempt = bound(attempt, held + 1, type(uint256).max - 1);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, type(uint256).max - 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientBalance.selector, alice, held, attempt));
        token.transferFrom(alice, bob, attempt);
        assertEq(token.allowance(alice, bob), type(uint256).max - 1, "a failed transferFrom consumed allowance");
        assertEq(token.balanceOf(alice), held);
    }

    function testFuzz_transferFromSpendsExactlyTheAmountOfAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, type(uint256).max - 1); // max is the infinite sentinel, tested apart
        amount = bound(amount, 0, allowed < SUPPLY ? allowed : SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);

        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, bob, amount);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, amount));
        assertEq(token.allowance(deployer, alice), allowed - amount, "allowance not reduced by the exact amount");
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(alice), 0, "the spender received something");
    }

    function testFuzz_transferFromBeyondAllowanceRevertsEvenWithBalance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        amount = bound(amount, allowed + 1, type(uint256).max);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientAllowance.selector, alice, allowed, amount));
        token.transferFrom(deployer, bob, amount);
        assertEq(token.allowance(deployer, alice), allowed);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testFuzz_infiniteAllowanceSurvivesAnySpend(uint256 amount, uint256 again) public {
        amount = bound(amount, 0, SUPPLY);
        again = bound(again, 0, SUPPLY - amount);
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.startPrank(alice);
        token.transferFrom(deployer, bob, amount);
        token.transferFrom(deployer, bob, again);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(bob), amount + again);
    }

    /// @dev The allowance is per spender: a second spender has none, and spending by one does not
    /// touch the other's.
    function testFuzz_allowancesAreIsolatedPerSpender(uint256 toAlice, uint256 spend) public {
        toAlice = bound(toAlice, 1, SUPPLY);
        spend = bound(spend, 1, toAlice);
        vm.prank(deployer);
        token.approve(alice, toAlice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientAllowance.selector, bob, 0, spend));
        token.transferFrom(deployer, bob, spend);

        vm.prank(alice);
        token.transferFrom(deployer, alice, spend);
        assertEq(token.allowance(deployer, alice), toAlice - spend);
        assertEq(token.allowance(deployer, bob), 0);
    }

    /// @dev transferFrom on one's own balance still needs an allowance (ERC-20 as OpenZeppelin
    /// implements it); the holder has `transfer` for that. Documented, not a defect.
    function test_transferFromOfOwnBalanceNeedsAnAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    function testFuzz_transferFromToZeroAddressReverts(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(HOODTToken.ZeroAddress.selector);
        token.transferFrom(deployer, address(0), amount);
    }

    function testFuzz_approveZeroSpenderRevertsForAnyAmount(uint256 amount) public {
        vm.prank(deployer);
        vm.expectRevert(HOODTToken.ZeroAddress.selector);
        token.approve(address(0), amount);
        assertEq(token.allowance(deployer, address(0)), 0);
    }

    /// @dev An approval from an account that holds nothing is recorded; it is simply unspendable.
    function testFuzz_anyoneMayApproveAnyone(address owner, address spender, uint256 amount) public {
        vm.assume(_usable(owner) && _usable(spender));
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
        if (owner != deployer && amount > 0) {
            vm.prank(spender);
            vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientBalance.selector, owner, 0, 1));
            token.transferFrom(owner, spender, 1);
        }
    }

    // ---------------------------------------------------------------- no other surface

    /// @dev Any selector outside the ERC-20 set fails: there is no fallback, no admin, no mint.
    function testFuzz_unknownSelectorsRevert(bytes4 selector, bytes32 a, bytes32 b) public {
        vm.assume(
            selector != HOODTToken.transfer.selector && selector != HOODTToken.approve.selector
                && selector != HOODTToken.transferFrom.selector && selector != token.balanceOf.selector
                && selector != token.allowance.selector && selector != HOODTToken.totalSupply.selector
                && selector != token.name.selector && selector != token.symbol.selector
                && selector != token.decimals.selector && selector != token.TOTAL_SUPPLY.selector
        );
        vm.prank(deployer);
        (bool ok,) = address(token).call(abi.encodePacked(selector, a, b));
        assertFalse(ok, "an unknown selector succeeded");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_emptyCalldataAndPlainEtherAreRejected() public {
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        (bool ok,) = address(token).call("");
        assertFalse(ok, "empty calldata was accepted");
        vm.prank(deployer);
        (ok,) = address(token).call{value: 1 wei}("");
        assertFalse(ok, "the token accepted ether");
        vm.prank(deployer);
        (ok,) = address(token).call{value: 1 wei}(abi.encodeCall(HOODTToken.transfer, (alice, 1)));
        assertFalse(ok, "a payable transfer was accepted");
        assertEq(address(token).balance, 0);
    }

    /// @dev The ERC-20 metadata is constant and ABI-decodable by a caller that only knows the
    /// standard interface.
    function test_metadataDecodesThroughTheStandardAbi() public view {
        (bool ok, bytes memory data) = address(token).staticcall(abi.encodeWithSignature("name()"));
        assertTrue(ok);
        assertEq(abi.decode(data, (string)), "Hood Test");
        (ok, data) = address(token).staticcall(abi.encodeWithSignature("symbol()"));
        assertTrue(ok);
        assertEq(abi.decode(data, (string)), "HOODT");
        (ok, data) = address(token).staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(ok);
        assertEq(abi.decode(data, (uint8)), 18);
        (ok, data) = address(token).staticcall(abi.encodeWithSignature("totalSupply()"));
        assertTrue(ok);
        assertEq(abi.decode(data, (uint256)), 1e27);
    }
}

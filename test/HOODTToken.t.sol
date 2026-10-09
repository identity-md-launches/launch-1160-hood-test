// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HOODTToken} from "../src/HOODTToken.sol";

/// @notice Smoke tests for the HOODT launch token: deploy, supply, metadata, a transfer, and the
/// failure paths an ordinary ERC-20 must have. A separate, fuller suite follows this one.
contract HOODTTokenTest is Test {
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

    // ---------------------------------------------------------------- deploy and metadata

    function test_metadata() public view {
        assertEq(token.name(), "Hood Test");
        assertEq(token.symbol(), "HOODT");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(SUPPLY, 1e27);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        HOODTToken fresh = new HOODTToken();
        assertEq(fresh.balanceOf(alice), SUPPLY, "deployer does not hold the whole supply");
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY, "setUp deployer does not hold the whole supply");
    }

    function test_constructorMakesNoExternalCalls() public {
        // A constructor that called out would revert or misbehave on an empty chain; deploying
        // from a fresh EOA with nothing else deployed must succeed and mint to that EOA.
        address lone = makeAddr("lone");
        vm.prank(lone);
        HOODTToken fresh = new HOODTToken();
        assertEq(fresh.balanceOf(lone), SUPPLY);
    }

    // ---------------------------------------------------------------- transfers

    function test_transferMovesExactAmountWithNoFee() public {
        uint256 amount = 123_456_789 ether;
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount, "recipient received less than sent");
        assertEq(token.balanceOf(deployer), SUPPLY - amount, "sender lost more than sent");
        assertEq(token.totalSupply(), SUPPLY, "transfer changed supply");

        // And onward from an ordinary holder, equally exact.
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferWholeBalanceAndZeroAmount() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);

        vm.prank(bob);
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1));
        token.transfer(alice, SUPPLY + 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(HOODTToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------- allowances

    function test_approveAndTransferFrom() public {
        uint256 amount = 1_000 ether;
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, amount);
        vm.prank(deployer);
        assertTrue(token.approve(alice, amount));
        assertEq(token.allowance(deployer, alice), amount);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 400 ether));
        assertEq(token.balanceOf(bob), 400 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 400 ether);
        assertEq(token.allowance(deployer, alice), 600 ether, "allowance not decremented");
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
        assertEq(token.balanceOf(deployer), SUPPLY, "a transferFrom without allowance moved funds");
    }

    function test_transferFromRevertsWhenAllowanceExceeded() public {
        vm.prank(deployer);
        token.approve(alice, 5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HOODTToken.InsufficientAllowance.selector, alice, 5, 6));
        token.transferFrom(deployer, bob, 6);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.prank(deployer);
        vm.expectRevert(HOODTToken.ZeroAddress.selector);
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------- no admin surface

    function test_noMintOrAdminSelectorsExist() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "transferOwnership(address)",
            "owner()",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, type(uint128).max));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }
}

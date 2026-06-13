// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { StakeAndAdvance } from "../src/StakeAndAdvance.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";
import { TestBase } from "./TestBase.sol";

contract StakeAndAdvanceHarness is StakeAndAdvance {
    constructor(MockUSDC usdc_, address arbiter_, uint64 disputeWindow_, uint16 collateralBps_)
        StakeAndAdvance(usdc_, arbiter_, disputeWindow_, collateralBps_)
    { }

    function setCreditCap(address vendor_, uint256 cap, uint64 expiry) external {
        _setCreditCap(vendor_, cap, expiry);
    }
}

contract StakeAndAdvanceTest is TestBase {
    event Deposited(
        uint256 indexed stakeId,
        address indexed user,
        address indexed vendor,
        address payer,
        uint256 amount,
        uint256 collateral,
        uint256 creditAllocation
    );

    uint256 internal constant USDC = 1e6;

    MockUSDC internal token;
    StakeAndAdvanceHarness internal creditLine;

    address internal vendor = address(0xA11CE);
    address internal arbiter = address(0xA4B17E4);
    address internal user = address(0xB0B);
    address internal payer = address(0xC0FFEE);

    function setUp() external {
        token = new MockUSDC();
        vm.prank(vendor);
        creditLine = new StakeAndAdvanceHarness(token, arbiter, 10 minutes, 6000);

        token.mint(user, 1_000 * USDC);
        token.mint(payer, 1_000 * USDC);
        token.mint(vendor, 1_000 * USDC);

        vm.prank(user);
        token.approve(address(creditLine), type(uint256).max);
        vm.prank(payer);
        token.approve(address(creditLine), type(uint256).max);
        vm.prank(vendor);
        token.approve(address(creditLine), type(uint256).max);
    }

    function test_constructor_setsState() external view {
        assertEq(address(creditLine.usdc()), address(token), "usdc");
        assertEq(creditLine.vendor(), vendor, "vendor");
        assertEq(creditLine.arbiter(), arbiter, "arbiter");
        assertEq(creditLine.disputeWindow(), 10 minutes, "window");
        assertEq(creditLine.collateralBps(), 6000, "collateral bps");
    }

    function test_deposit_splitsTranches() external {
        uint256 amount = 250 * USDC;

        vm.expectEmit(true, true, true, true);
        emit Deposited(1, user, vendor, user, amount, 150 * USDC, 100 * USDC);

        vm.prank(user);
        uint256 stakeId = creditLine.deposit(user, amount);

        (
            address stakeUser,
            address stakeVendor,
            uint256 stakeAmount,
            uint256 collateral,
            uint256 creditAllocation,,
            StakeAndAdvance.StakeState state,,
        ) = creditLine.stakes(stakeId);

        assertEq(stakeUser, user, "stake user");
        assertEq(stakeVendor, vendor, "stake vendor");
        assertEq(stakeAmount, amount, "amount");
        assertEq(collateral, 150 * USDC, "collateral");
        assertEq(creditAllocation, 100 * USDC, "allocation");
        assertEq(uint256(state), uint256(StakeAndAdvance.StakeState.Active), "active");
        assertEq(creditLine.vendorCreditAllocationTotal(vendor), 100 * USDC, "total allocation");
        assertEq(token.balanceOf(address(creditLine)), amount, "contract balance");
        assertEq(token.balanceOf(user), 750 * USDC, "user balance");
    }

    function test_depositOnBehalf_creditsExplicitUser() external {
        vm.prank(payer);
        uint256 stakeId = creditLine.deposit(user, 250 * USDC);

        (address stakeUser,,,,,,,,) = creditLine.stakes(stakeId);

        assertEq(stakeUser, user, "stake user");
        assertEq(token.balanceOf(payer), 750 * USDC, "payer balance");
        assertEq(token.balanceOf(user), 1_000 * USDC, "user balance");
    }

    function test_creditLimit_zeroUntilAttested() external {
        vm.prank(user);
        creditLine.deposit(user, 250 * USDC);

        assertEq(creditLine.effectiveCreditLimit(vendor), 0, "limit");
    }

    function test_drawdown_withinLimit() external {
        vm.prank(user);
        creditLine.deposit(user, 250 * USDC);
        creditLine.setCreditCap(vendor, 100 * USDC, 0);

        vm.prank(vendor);
        creditLine.drawdown(100 * USDC);

        assertEq(creditLine.currentOutstandingDebt(vendor), 100 * USDC, "debt");
        assertEq(token.balanceOf(vendor), 1_100 * USDC, "vendor balance");
        assertEq(token.balanceOf(address(creditLine)), 150 * USDC, "contract balance");
    }

    function test_drawdown_revertsOverLimit() external {
        vm.prank(user);
        creditLine.deposit(user, 250 * USDC);
        creditLine.setCreditCap(vendor, 99 * USDC, 0);

        vm.expectRevert(StakeAndAdvance.CreditLimitExceeded.selector);
        vm.prank(vendor);
        creditLine.drawdown(100 * USDC);
    }

    function test_repay_reducesDebt() external {
        vm.prank(user);
        creditLine.deposit(user, 250 * USDC);
        creditLine.setCreditCap(vendor, 100 * USDC, 0);

        vm.prank(vendor);
        creditLine.drawdown(100 * USDC);

        vm.prank(vendor);
        creditLine.repay(40 * USDC);

        assertEq(creditLine.currentOutstandingDebt(vendor), 60 * USDC, "debt");
        assertEq(token.balanceOf(address(creditLine)), 190 * USDC, "contract balance");
    }
}

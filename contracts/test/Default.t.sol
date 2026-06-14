// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Fixtures } from "./Fixtures.sol";
import { StakeAndAdvance } from "../src/StakeAndAdvance.sol";

/// Default mechanics: permissionless write-down after due + grace, NAV falls, members bear the loss.
contract DefaultTest is Fixtures {
    function setUp() public {
        _deployPool(0);
    }

    function test_markDefaulted_revertsWithoutDebt() public {
        _deposit(alice, 1000 * USDC1);
        vm.expectRevert(StakeAndAdvance.NoDebt.selector);
        pool.markDefaulted();
    }

    function test_markDefaulted_revertsBeforeWindow() public {
        _deposit(alice, 1000 * USDC1);
        _deliverTerms(1000 * USDC1, _farExpiry(), 1000);
        pool.drawdown(1000 * USDC1);
        // still within repayment window + grace
        vm.expectRevert(StakeAndAdvance.NotDefaultable.selector);
        pool.markDefaulted();
    }

    function test_markDefaulted_writesDownNav_membersLose() public {
        _deposit(alice, 1000 * USDC1);
        _deliverTerms(1000 * USDC1, _farExpiry(), 1000);
        pool.drawdown(600 * USDC1); // 600 lent, 400 stays liquid
        assertEq(pool.cash(), 400 * USDC1, "liquid remainder");

        // Past due + grace, anyone can crystallize the loss.
        vm.warp(block.timestamp + REPAYMENT_WINDOW + GRACE + 1);
        vm.prank(bob); // permissionless
        pool.markDefaulted();

        assertEq(pool.outstandingPrincipal(), 0, "principal written off");
        assertEq(pool.totalDefaultedAmount(), 600 * USDC1, "loss recorded");
        assertEq(pool.totalAssets(), 400 * USDC1, "NAV backing fell to the liquid remainder");
        assertEq(uint256(pool.navPerShare1e18()), 0.4e18, "NAV dropped to 0.4");
        assertEq(pool.defaulted(), true, "default flag set");

        // Alice redeems and eats the loss: 1000 shares -> 400 USDC.
        vm.prank(alice);
        uint256 assets = pool.redeem(1000 * USDC1);
        assertEq(assets, 400 * USDC1, "member recovers only the un-lent remainder");
    }
}

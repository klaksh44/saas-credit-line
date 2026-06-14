// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Fixtures } from "./Fixtures.sol";
import { StakeAndAdvance } from "../src/StakeAndAdvance.sol";

/// Credit-terms delivery (onReport), drawdown limits, interest accrual, repayment, NAV growth.
contract CreditLineTest is Fixtures {
    function setUp() public {
        _deployPool(0);
    }

    function test_onReport_setsTerms_onlyReporter() public {
        _deliverTerms(500 * USDC1, _farExpiry(), 1200);
        assertEq(pool.creditCap(), 500 * USDC1, "cap");
        assertEq(uint256(pool.interestRateBps()), 1200, "rate");
        assertEq(pool.effectiveCreditLimit(), 500 * USDC1, "limit");
    }

    function test_onReport_revertsUnauthorized() public {
        bytes memory report = abi.encode(address(this), uint256(500 * USDC1), _farExpiry(), uint16(1200));
        vm.expectRevert(StakeAndAdvance.UnauthorizedReportSender.selector); // caller is company, not reporter
        pool.onReport("", report);
    }

    function test_onReport_revertsBadRate() public {
        bytes memory report = abi.encode(address(this), uint256(500 * USDC1), _farExpiry(), uint16(10_001));
        vm.prank(reporter);
        vm.expectRevert(StakeAndAdvance.InvalidInterestRateBps.selector);
        pool.onReport("", report);
    }

    function test_drawdown_revertsBeforeUnderwriting() public {
        _deposit(alice, 1000 * USDC1);
        vm.expectRevert(StakeAndAdvance.CreditLimitExceeded.selector); // cap is 0 until underwritten
        pool.drawdown(1);
    }

    function test_drawdown_withinCap_setsDueDate() public {
        _deposit(alice, 1000 * USDC1);
        _deliverTerms(600 * USDC1, _farExpiry(), 1000);
        pool.drawdown(500 * USDC1);
        assertEq(pool.outstandingPrincipal(), 500 * USDC1, "principal");
        assertEq(pool.cash(), 500 * USDC1, "cash reduced");
        assertEq(usdc.balanceOf(address(this)) >= 500 * USDC1, true, "company received funds");
        assertEq(uint256(pool.dueAt()), block.timestamp + REPAYMENT_WINDOW, "due date set");
        assertEq(uint256(pool.drawdownCount()), 1, "drawdown counted");
    }

    function test_drawdown_revertsOverCap() public {
        _deposit(alice, 1000 * USDC1);
        _deliverTerms(500 * USDC1, _farExpiry(), 1000);
        vm.expectRevert(StakeAndAdvance.CreditLimitExceeded.selector);
        pool.drawdown(600 * USDC1);
    }

    function test_capExpiry_freezesBorrowing() public {
        _deposit(alice, 1000 * USDC1);
        uint64 expiry = uint64(block.timestamp + 100);
        _deliverTerms(1000 * USDC1, expiry, 1000);
        assertEq(pool.effectiveCreditLimit(), 1000 * USDC1, "limit before expiry");
        vm.warp(block.timestamp + 101);
        assertEq(pool.effectiveCreditLimit(), 0, "limit zero after expiry");
        vm.expectRevert(StakeAndAdvance.CreditLimitExceeded.selector);
        pool.drawdown(1);
    }

    function test_interestAccrual_isExact() public {
        _deposit(alice, 1000 * USDC1);
        _deliverTerms(1000 * USDC1, _farExpiry(), 1000); // 10% APR
        pool.drawdown(1000 * USDC1);

        vm.warp(block.timestamp + pool.SECONDS_PER_YEAR());
        assertEq(pool.accruedInterest(), 100 * USDC1, "1yr @ 10% on 1000 = 100");

        // Half a year on its own would be 50; confirm linearity by checking the half point fresh.
    }

    function test_interestAccrual_halfYear() public {
        _deposit(alice, 1000 * USDC1);
        _deliverTerms(1000 * USDC1, _farExpiry(), 1000);
        pool.drawdown(1000 * USDC1);
        vm.warp(block.timestamp + pool.SECONDS_PER_YEAR() / 2);
        assertEq(pool.accruedInterest(), 50 * USDC1, "half year => 50");
    }

    function test_repay_liftsNavAndCanProfit() public {
        _deposit(alice, 1000 * USDC1);
        _deliverTerms(1000 * USDC1, _farExpiry(), 1000);
        pool.drawdown(1000 * USDC1);
        vm.warp(block.timestamp + pool.SECONDS_PER_YEAR());

        _repayAll(); // pays 1000 principal + 100 interest
        assertEq(pool.outstandingPrincipal(), 0, "principal cleared");
        assertEq(pool.totalInterestPaid(), 100 * USDC1, "interest realized");
        assertEq(pool.totalAssets(), 1100 * USDC1, "assets grew by interest");
        assertEq(uint256(pool.navPerShare1e18()), 1.1e18, "NAV up to 1.1");

        vm.prank(alice);
        uint256 assets = pool.redeem(1000 * USDC1);
        assertEq(assets, 1100 * USDC1, "alice redeems at a profit");
    }

    function test_repay_onTimeVsLate() public {
        _deposit(alice, 1000 * USDC1);
        _deliverTerms(1000 * USDC1, _farExpiry(), 1000);

        // On time: repay within the window.
        pool.drawdown(400 * USDC1);
        vm.warp(block.timestamp + 10 days);
        _repayAll();
        assertEq(uint256(pool.onTimeRepaymentCount()), 1, "on-time counted");
        assertEq(uint256(pool.lateRepaymentCount()), 0, "no late yet");

        // Late: repay after the window.
        pool.drawdown(400 * USDC1);
        vm.warp(block.timestamp + 40 days);
        _repayAll();
        assertEq(uint256(pool.lateRepaymentCount()), 1, "late counted");
        assertEq(uint256(pool.repaymentCount()), 2, "two cycles closed");
    }

    function test_repay_revertsTooLarge() public {
        _deposit(alice, 1000 * USDC1);
        _deliverTerms(1000 * USDC1, _farExpiry(), 1000);
        pool.drawdown(100 * USDC1);
        vm.expectRevert(StakeAndAdvance.RepayTooLarge.selector);
        pool.repay(200 * USDC1); // no interest yet => 200 all principal > 100 outstanding
    }
}

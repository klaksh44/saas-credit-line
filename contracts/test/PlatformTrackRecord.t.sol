// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Fixtures } from "./Fixtures.sol";

/// The repayment history surfaced to the underwriting model via trackRecord().
contract PlatformTrackRecordTest is Fixtures {
    function setUp() public {
        _deployPool(0);
    }

    function test_trackRecord_accumulatesAcrossCycles() public {
        _deposit(alice, 2000 * USDC1);
        _deliverTerms(2000 * USDC1, _farExpiry(), 1000);

        // Cycle 1: on-time.
        pool.drawdown(500 * USDC1);
        vm.warp(block.timestamp + 5 days);
        _repayAll();

        // Cycle 2: late.
        pool.drawdown(500 * USDC1);
        vm.warp(block.timestamp + 45 days);
        _repayAll();

        (
            uint256 drawdowns,
            uint256 repayments,
            uint256 onTime,
            uint256 late,
            uint256 interestPaid,
            uint256 defaultedAmount,
            uint256 outstanding,
            uint64 debtDueAt
        ) = pool.trackRecord();

        assertEq(drawdowns, 2, "drawdowns");
        assertEq(repayments, 2, "repayments");
        assertEq(onTime, 1, "on-time");
        assertEq(late, 1, "late");
        assertEq(interestPaid > 0, true, "interest realized");
        assertEq(defaultedAmount, 0, "no defaults");
        assertEq(outstanding, 0, "fully repaid");
        assertEq(uint256(debtDueAt), 0, "due date cleared");
    }
}

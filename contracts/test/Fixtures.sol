// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { TestBase } from "./TestBase.sol";
import { StakeAndAdvance } from "../src/StakeAndAdvance.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";
import { IERC20 } from "../src/token/IERC20.sol";

/// @dev Shared setup + helpers for the pool ("company bank") tests.
///      The test contract itself is the deployer, hence the `company` (single borrower).
contract Fixtures is TestBase {
    MockUSDC internal usdc;
    StakeAndAdvance internal pool;

    address internal reporter = address(0xBEEF); // authorized credit-terms reporter
    address internal alice = address(0xA11CE); // a member (customer)
    address internal bob = address(0xB0B); // another member

    uint256 internal constant USDC1 = 1e6; // 1 USDC (6 decimals)
    uint64 internal constant REPAYMENT_WINDOW = 30 days;
    uint64 internal constant GRACE = 7 days;

    function _deployPool(uint16 minReserveBps) internal {
        usdc = new MockUSDC();
        pool = new StakeAndAdvance(
            IERC20(address(usdc)), reporter, REPAYMENT_WINDOW, GRACE, minReserveBps
        );
        // The company funds itself so it can repay principal + interest later.
        usdc.mint(address(this), 1_000_000 * USDC1);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        _fund(who, amount);
        vm.prank(who);
        shares = pool.deposit(amount);
    }

    function _deliverTerms(uint256 cap, uint64 expiry, uint16 rateBps) internal {
        bytes memory report = abi.encode(address(this), cap, expiry, rateBps);
        vm.prank(reporter);
        pool.onReport("", report);
    }

    /// @dev Far-future expiry so the cap stays active across time warps.
    function _farExpiry() internal view returns (uint64) {
        return uint64(block.timestamp + 3650 days);
    }

    /// @dev Company repays everything currently owed (principal + accrued interest).
    function _repayAll() internal {
        uint256 owed = pool.accruedInterest();
        uint256 principal = pool.outstandingPrincipal();
        pool.repay(principal + owed);
    }

    /// @dev Run one full profitable cycle: set terms, draw `principal`, let `elapsed` pass, repay in full.
    ///      Lifts NAV by the interest paid. Assumes the pool has enough lendable cash (reserve == 0).
    function _profitableCycle(uint256 principal, uint16 rateBps, uint64 elapsed) internal {
        _deliverTerms(principal, _farExpiry(), rateBps);
        pool.drawdown(principal);
        vm.warp(block.timestamp + elapsed);
        _repayAll();
    }
}

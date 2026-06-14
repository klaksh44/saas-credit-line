// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Fixtures } from "./Fixtures.sol";
import { StakeAndAdvance } from "../src/StakeAndAdvance.sol";

/// Core pool / share accounting: deposit, redeem, NAV, transfer, reserve liquidity.
contract StakeAndAdvanceTest is Fixtures {
    function setUp() public {
        _deployPool(0);
    }

    function test_constructor_setsState() public view {
        assertEq(address(pool.usdc()), address(usdc), "usdc");
        assertEq(pool.company(), address(this), "company");
        assertEq(pool.keystoneForwarder(), reporter, "forwarder");
        assertEq(uint256(pool.repaymentWindow()), uint256(REPAYMENT_WINDOW), "repaymentWindow");
        assertEq(uint256(pool.defaultGracePeriod()), uint256(GRACE), "grace");
        assertEq(uint256(pool.minReserveBps()), 0, "reserveBps");
        assertEq(uint256(pool.navPerShare1e18()), 1e18, "nav starts at 1.0");
    }

    function test_firstDeposit_mintsOneToOne() public {
        uint256 shares = _deposit(alice, 500 * USDC1);
        assertEq(shares, 500 * USDC1, "shares 1:1 on bootstrap");
        assertEq(pool.sharesOf(alice), 500 * USDC1, "alice shares");
        assertEq(pool.totalShares(), 500 * USDC1, "totalShares");
        assertEq(pool.cash(), 500 * USDC1, "cash");
        assertEq(pool.totalAssets(), 500 * USDC1, "totalAssets");
        assertEq(uint256(pool.navPerShare1e18()), 1e18, "nav still 1.0");
    }

    function test_secondDeposit_pricedAtNav() public {
        _deposit(alice, 1000 * USDC1);
        // Lift NAV to 1.1 via a profitable cycle (1000 @ 10% for one year => +100 interest).
        _profitableCycle(1000 * USDC1, 1000, pool.SECONDS_PER_YEAR());
        assertEq(uint256(pool.navPerShare1e18()), 1.1e18, "nav lifted to 1.1");

        // Bob deposits 1100 at NAV 1.1 => 1000 shares.
        uint256 shares = _deposit(bob, 1100 * USDC1);
        assertEq(shares, 1000 * USDC1, "bob shares priced at NAV");
        assertEq(pool.totalShares(), 2000 * USDC1, "totalShares");
        assertEq(uint256(pool.navPerShare1e18()), 1.1e18, "nav unchanged by fair-priced deposit");
    }

    function test_redeem_returnsNavValue() public {
        _deposit(alice, 400 * USDC1);
        vm.prank(alice);
        uint256 assets = pool.redeem(400 * USDC1);
        assertEq(assets, 400 * USDC1, "redeem at NAV 1.0");
        assertEq(usdc.balanceOf(alice), 400 * USDC1, "alice got USDC");
        assertEq(pool.totalShares(), 0, "shares burned");
        assertEq(pool.cash(), 0, "cash drained");
    }

    function test_redeem_revertsWhenIlliquid() public {
        _deposit(alice, 1000 * USDC1);
        _deliverTerms(1000 * USDC1, _farExpiry(), 1000);
        pool.drawdown(1000 * USDC1); // all cash lent out
        assertEq(pool.cash(), 0, "no liquid cash");
        vm.prank(alice);
        vm.expectRevert(StakeAndAdvance.InsufficientLiquidity.selector);
        pool.redeem(1000 * USDC1);
    }

    function test_depositFor_creditsBeneficiary() public {
        // Company (address(this)) pays on behalf of bob (relayer / Dynamic funding seam).
        uint256 shares = pool.depositFor(bob, 250 * USDC1);
        assertEq(shares, 250 * USDC1, "shares minted");
        assertEq(pool.sharesOf(bob), 250 * USDC1, "bob credited");
        assertEq(pool.sharesOf(address(this)), 0, "payer holds none");
    }

    function test_transferShares_movesBalance() public {
        _deposit(alice, 300 * USDC1);
        vm.prank(alice);
        pool.transferShares(bob, 100 * USDC1);
        assertEq(pool.sharesOf(alice), 200 * USDC1, "alice debited");
        assertEq(pool.sharesOf(bob), 100 * USDC1, "bob credited");
    }

    function test_transferShares_revertsOverBalance() public {
        _deposit(alice, 50 * USDC1);
        vm.prank(alice);
        vm.expectRevert(StakeAndAdvance.InsufficientShares.selector);
        pool.transferShares(bob, 51 * USDC1);
    }

    function test_deposit_revertsOnZero() public {
        vm.expectRevert(StakeAndAdvance.InvalidAmount.selector);
        pool.deposit(0);
    }

    function test_proRataYield_sharedAcrossMembers() public {
        // Two members enter equally at NAV 1.0, then a profitable cycle lifts NAV for both.
        _deposit(alice, 1000 * USDC1);
        _deposit(bob, 1000 * USDC1);
        _profitableCycle(2000 * USDC1, 1000, pool.SECONDS_PER_YEAR()); // +200 interest on 2000

        // NAV = 2200/2000 = 1.1 => each 1000-share holder redeems 1100.
        vm.prank(alice);
        uint256 a = pool.redeem(1000 * USDC1);
        vm.prank(bob);
        uint256 b = pool.redeem(1000 * USDC1);
        assertEq(a, 1100 * USDC1, "alice pro-rata yield");
        assertEq(b, 1100 * USDC1, "bob pro-rata yield");
    }
}

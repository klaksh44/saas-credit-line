// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { StakeAndAdvance } from "../src/StakeAndAdvance.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";
import { TestBase } from "./TestBase.sol";

contract PersonhoodTest is TestBase {
    uint256 internal constant USDC = 1e6;

    MockUSDC internal token;
    StakeAndAdvance internal creditLine;

    address internal vendor = address(0xA11CE);
    address internal arbiter = address(0xA4B17E4);
    address internal forwarder = address(0xF04);
    address internal user = address(0xB0B);

    uint256 internal signerPk = 0xC0FFEE;
    uint256 internal wrongPk = 0xBADBAD;

    function setUp() external {
        token = new MockUSDC();
        vm.prank(vendor);
        creditLine = new StakeAndAdvance(token, arbiter, forwarder, 10 minutes, 6000);

        vm.prank(vendor);
        creditLine.setWorldIdSigner(vm.addr(signerPk));

        token.mint(user, 1_000 * USDC);
        vm.prank(user);
        token.approve(address(creditLine), type(uint256).max);
    }

    function _voucher(uint256 pk, address forUser, bytes32 nullifierHash, uint64 deadline)
        internal
        view
        returns (bytes memory sig)
    {
        bytes32 structHash = keccak256(
            abi.encode(creditLine.PERSONHOOD_TYPEHASH(), forUser, nullifierHash, deadline)
        );
        bytes32 digest =
            keccak256(abi.encodePacked(hex"1901", creditLine.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function test_deposit_requiresValidVoucher() external {
        bytes32 nh = keccak256("human-1");
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _voucher(signerPk, user, nh, deadline);

        vm.prank(user);
        uint256 stakeId = creditLine.depositWithPersonhood(user, 250 * USDC, nh, deadline, sig);

        (address stakeUser,, uint256 amount,,,,,,) = creditLine.stakes(stakeId);
        assertEq(stakeUser, user, "stake user");
        assertEq(amount, 250 * USDC, "amount");
        assertEq(creditLine.usedNullifier(nh), true, "nullifier consumed");
        assertEq(token.balanceOf(address(creditLine)), 250 * USDC, "contract balance");
    }

    function test_deposit_rejectsReusedNullifier() external {
        bytes32 nh = keccak256("human-1");
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _voucher(signerPk, user, nh, deadline);

        vm.prank(user);
        creditLine.depositWithPersonhood(user, 250 * USDC, nh, deadline, sig);

        // Same human (same nullifier) cannot claim a second free subscription.
        vm.expectRevert(StakeAndAdvance.NullifierAlreadyUsed.selector);
        vm.prank(user);
        creditLine.depositWithPersonhood(user, 1 * USDC, nh, deadline, sig);
    }

    function test_deposit_rejectsForgedSigner() external {
        bytes32 nh = keccak256("human-2");
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _voucher(wrongPk, user, nh, deadline);

        vm.expectRevert(StakeAndAdvance.InvalidVoucherSignature.selector);
        vm.prank(user);
        creditLine.depositWithPersonhood(user, 250 * USDC, nh, deadline, sig);
    }

    function test_deposit_rejectsExpiredVoucher() external {
        bytes32 nh = keccak256("human-3");
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _voucher(signerPk, user, nh, deadline);

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(StakeAndAdvance.VoucherExpired.selector);
        vm.prank(user);
        creditLine.depositWithPersonhood(user, 250 * USDC, nh, deadline, sig);
    }

    function test_deposit_revertsWhenSignerUnset() external {
        MockUSDC freshToken = new MockUSDC();
        vm.prank(vendor);
        StakeAndAdvance fresh = new StakeAndAdvance(freshToken, arbiter, forwarder, 10 minutes, 6000);

        bytes32 nh = keccak256("human-4");
        uint64 deadline = uint64(block.timestamp + 1 hours);

        vm.expectRevert(StakeAndAdvance.WorldIdSignerNotSet.selector);
        vm.prank(user);
        fresh.depositWithPersonhood(user, 250 * USDC, nh, deadline, hex"00");
    }
}

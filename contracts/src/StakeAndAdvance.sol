// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IReceiver } from "./interfaces/IReceiver.sol";
import { IERC20 } from "./token/IERC20.sol";
import { SafeERC20 } from "./token/SafeERC20.sol";
import { ReentrancyGuard } from "./utils/ReentrancyGuard.sol";

contract StakeAndAdvance is IReceiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;

    enum StakeState {
        None,
        Active,
        Cancelled,
        Disputed,
        Resolved
    }

    struct Stake {
        address user;
        address vendor;
        uint256 amount;
        uint256 collateral;
        uint256 creditAllocation;
        uint256 pendingObligation;
        StakeState state;
        uint64 createdAt;
        uint64 disputedAt;
    }

    IERC20 public immutable usdc;
    address public immutable vendor;
    address public arbiter;
    address public keystoneForwarder;
    uint64 public disputeWindow;
    uint16 public collateralBps;
    uint256 public nextStakeId = 1;

    mapping(uint256 stakeId => Stake stake) public stakes;
    mapping(address vendor => uint256 allocation) public vendorCreditAllocationTotal;
    mapping(address vendor => uint256 debt) public currentOutstandingDebt;

    mapping(address vendor => uint256 cap) internal _vendorCreditCap;
    mapping(address vendor => uint64 expiry) internal _vendorCapExpiry;

    event Deposited(
        uint256 indexed stakeId,
        address indexed user,
        address indexed vendor,
        address payer,
        uint256 amount,
        uint256 collateral,
        uint256 creditAllocation
    );
    event DrawnDown(address indexed vendor, uint256 amount, uint256 outstandingDebt);
    event Repaid(address indexed vendor, uint256 amount, uint256 outstandingDebt);
    event CreditCapUpdated(address indexed vendor, uint256 cap, uint64 expiry);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidCollateralBps();
    error OnlyVendor();
    error CreditLimitExceeded();
    error RepayTooLarge();
    error UnauthorizedReportSender();

    constructor(IERC20 usdc_, address arbiter_, uint64 disputeWindow_, uint16 collateralBps_) {
        if (address(usdc_) == address(0) || arbiter_ == address(0)) revert InvalidAddress();
        if (collateralBps_ > BPS) revert InvalidCollateralBps();

        usdc = usdc_;
        vendor = msg.sender;
        arbiter = arbiter_;
        disputeWindow = disputeWindow_;
        collateralBps = collateralBps_;
    }

    modifier onlyVendor() {
        if (msg.sender != vendor) revert OnlyVendor();
        _;
    }

    function deposit(address user, uint256 amount) external nonReentrant returns (uint256 stakeId) {
        if (user == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 collateral = amount * collateralBps / BPS;
        uint256 creditAllocation = amount - collateral;

        stakeId = nextStakeId++;
        stakes[stakeId] = Stake({
            user: user,
            vendor: vendor,
            amount: amount,
            collateral: collateral,
            creditAllocation: creditAllocation,
            pendingObligation: 0,
            state: StakeState.Active,
            createdAt: uint64(block.timestamp),
            disputedAt: 0
        });

        vendorCreditAllocationTotal[vendor] += creditAllocation;
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(stakeId, user, vendor, msg.sender, amount, collateral, creditAllocation);
    }

    function effectiveCreditLimit(address vendor_) public view returns (uint256) {
        uint256 cap = _activeCreditCap(vendor_);
        uint256 allocation = vendorCreditAllocationTotal[vendor_];
        return cap < allocation ? cap : allocation;
    }

    function availableCredit(address vendor_) external view returns (uint256) {
        uint256 limit = effectiveCreditLimit(vendor_);
        uint256 outstanding = currentOutstandingDebt[vendor_];
        return outstanding >= limit ? 0 : limit - outstanding;
    }

    function vendorCreditCap(address vendor_) external view returns (uint256) {
        return _vendorCreditCap[vendor_];
    }

    function vendorCapExpiry(address vendor_) external view returns (uint64) {
        return _vendorCapExpiry[vendor_];
    }

    function drawdown(uint256 amount) external onlyVendor nonReentrant {
        if (amount == 0) revert InvalidAmount();

        uint256 nextDebt = currentOutstandingDebt[msg.sender] + amount;
        if (nextDebt > effectiveCreditLimit(msg.sender)) revert CreditLimitExceeded();

        currentOutstandingDebt[msg.sender] = nextDebt;
        usdc.safeTransfer(msg.sender, amount);

        emit DrawnDown(msg.sender, amount, nextDebt);
    }

    function repay(uint256 amount) external onlyVendor nonReentrant {
        if (amount == 0) revert InvalidAmount();

        uint256 outstanding = currentOutstandingDebt[msg.sender];
        if (amount > outstanding) revert RepayTooLarge();

        currentOutstandingDebt[msg.sender] = outstanding - amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit Repaid(msg.sender, amount, outstanding - amount);
    }

    function onReport(bytes calldata, bytes calldata) external virtual override {
        revert UnauthorizedReportSender();
    }

    function _setCreditCap(address vendor_, uint256 cap, uint64 expiry) internal {
        if (vendor_ == address(0)) revert InvalidAddress();
        _vendorCreditCap[vendor_] = cap;
        _vendorCapExpiry[vendor_] = expiry;
        emit CreditCapUpdated(vendor_, cap, expiry);
    }

    function _activeCreditCap(address vendor_) internal view returns (uint256) {
        uint64 expiry = _vendorCapExpiry[vendor_];
        if (expiry != 0 && block.timestamp > expiry) return 0;
        return _vendorCreditCap[vendor_];
    }
}

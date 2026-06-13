// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IReceiver } from "./interfaces/IReceiver.sol";
import { IERC20 } from "./token/IERC20.sol";
import { SafeERC20 } from "./token/SafeERC20.sol";
import { ReentrancyGuard } from "./utils/ReentrancyGuard.sol";

contract StakeAndAdvance is IReceiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_CREDIT_ALLOCATION_BPS = 7_000;
    uint64 public constant REPAYMENT_WINDOW = 30 days;

    enum StakeState {
        None,
        Active,
        Cancelled,
        Disputed,
        Resolved
    }

    enum Outcome {
        RefundUser,
        ReleaseToVendor,
        Split
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
    address public treasury;
    uint64 public disputeWindow;
    uint16 public collateralBps;
    uint256 public nextStakeId = 1;
    uint256 public collateralReservedTotal;
    uint256 public collateralInYield;

    mapping(uint256 stakeId => Stake stake) public stakes;
    mapping(address vendor => uint256 principal) public vendorPrincipalTotal;
    mapping(address vendor => uint256 allocation) public vendorCreditAllocationTotal;
    mapping(address vendor => uint256 debt) public currentOutstandingDebt;
    mapping(address vendor => uint256 obligation) public priorityObligation;
    mapping(address vendor => uint256 count) public platformDrawdownCount;
    mapping(address vendor => uint256 count) public platformRepaymentCount;
    mapping(address vendor => uint256 count) public onTimeRepaymentCount;
    mapping(address vendor => uint256 count) public lateRepaymentCount;
    mapping(address vendor => uint256 amount) public totalRepaidAmount;
    mapping(address vendor => uint64 dueAt) public currentDebtDueAt;

    mapping(address vendor => uint256 cap) internal _vendorCreditCap;
    mapping(address vendor => uint64 expiry) internal _vendorCapExpiry;
    mapping(address vendor => uint16 allocationBps) internal _vendorCreditAllocationBps;

    // --- World ID personhood (one free subscription per human) ---
    // Validation happens off-chain (World ID cloud verify); the backend signs an EIP-712
    // voucher that this contract verifies. The nullifierHash is the uniqueness key.
    bytes32 public constant PERSONHOOD_TYPEHASH =
        keccak256("Personhood(address user,bytes32 nullifierHash,uint64 deadline)");
    bytes32 public immutable DOMAIN_SEPARATOR;
    address public worldIdSigner;
    mapping(bytes32 nullifierHash => bool used) public usedNullifier;

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
    event RepaymentCycleClosed(address indexed vendor, bool onTime, uint64 dueAt);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event CollateralPulledForYield(address indexed treasury, uint256 amount);
    event CollateralReturnedFromYield(address indexed treasury, uint256 amount);
    event Settled(
        uint256 indexed stakeId,
        address indexed user,
        address indexed vendor,
        uint256 immediateRefund,
        uint256 pendingObligation
    );
    event DisputeRaised(uint256 indexed stakeId, address indexed raisedBy, uint64 disputedAt);
    event DisputeResolved(
        uint256 indexed stakeId,
        Outcome indexed outcome,
        uint256 userAmount,
        uint256 vendorAmount,
        uint256 pendingObligation
    );
    event AutoReleased(uint256 indexed stakeId, uint256 immediateRefund, uint256 pendingObligation);
    event CreditTermsUpdated(
        address indexed vendor, uint256 cap, uint64 expiry, uint16 creditAllocationBps
    );
    event WorldIdSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event PersonhoodVerified(
        bytes32 indexed nullifierHash, address indexed user, uint256 indexed stakeId
    );

    error InvalidAddress();
    error InvalidAmount();
    error InvalidCollateralBps();
    error InvalidCreditAllocationBps();
    error OnlyVendor();
    error OnlyTreasury();
    error OnlyStakeUser();
    error OnlyStakeParty();
    error OnlyArbiter();
    error StakeNotActive();
    error StakeNotDisputed();
    error DisputeWindowOpen();
    error CreditLimitExceeded();
    error RepayTooLarge();
    error UnauthorizedReportSender();
    error WorldIdSignerNotSet();
    error NullifierAlreadyUsed();
    error VoucherExpired();
    error InvalidVoucherSignature();
    error InvalidSignatureLength();

    constructor(
        IERC20 usdc_,
        address arbiter_,
        address keystoneForwarder_,
        uint64 disputeWindow_,
        uint16 collateralBps_
    ) {
        if (address(usdc_) == address(0) || arbiter_ == address(0)) {
            revert InvalidAddress();
        }
        if (collateralBps_ > BPS) revert InvalidCollateralBps();

        usdc = usdc_;
        vendor = msg.sender;
        arbiter = arbiter_;
        keystoneForwarder = keystoneForwarder_;
        treasury = msg.sender;
        disputeWindow = disputeWindow_;
        collateralBps = collateralBps_;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("StakeAndAdvance")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    modifier onlyVendor() {
        if (msg.sender != vendor) revert OnlyVendor();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert OnlyTreasury();
        _;
    }

    /// @notice Ungated deposit (e.g. EOA or relayer paying on behalf of `user`).
    function deposit(address user, uint256 amount) external nonReentrant returns (uint256 stakeId) {
        return _deposit(user, amount);
    }

    /// @notice One-free-subscription-per-human deposit. World ID proof is validated off-chain
    /// (cloud verify); the backend signs an EIP-712 voucher over (user, nullifierHash, deadline)
    /// with `worldIdSigner`. The nullifierHash (unique per app+action per person) is consumed
    /// here so a single human cannot claim a second free subscription / credit allocation.
    function depositWithPersonhood(
        address user,
        uint256 amount,
        bytes32 nullifierHash,
        uint64 deadline,
        bytes calldata signature
    ) external nonReentrant returns (uint256 stakeId) {
        if (worldIdSigner == address(0)) revert WorldIdSignerNotSet();
        if (block.timestamp > deadline) revert VoucherExpired();
        if (usedNullifier[nullifierHash]) revert NullifierAlreadyUsed();

        bytes32 structHash =
            keccak256(abi.encode(PERSONHOOD_TYPEHASH, user, nullifierHash, deadline));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR, structHash));
        if (_recover(digest, signature) != worldIdSigner) revert InvalidVoucherSignature();

        usedNullifier[nullifierHash] = true;
        stakeId = _deposit(user, amount);
        emit PersonhoodVerified(nullifierHash, user, stakeId);
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 stakeId) {
        if (user == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 creditAllocation = amount * _activeCreditAllocationBps(vendor) / BPS;
        uint256 collateral = amount - creditAllocation;

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
        vendorPrincipalTotal[vendor] += amount;
        collateralReservedTotal += collateral;
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

    function defaultCreditAllocationBps() public view returns (uint16) {
        return BPS - collateralBps;
    }

    function vendorCreditAllocationBps(address vendor_) external view returns (uint16) {
        return _activeCreditAllocationBps(vendor_);
    }

    function platformTrackRecord(address vendor_)
        external
        view
        returns (
            uint256 drawdownCount,
            uint256 repaymentCount,
            uint256 onTimeCount,
            uint256 lateCount,
            uint256 repaidAmount,
            uint256 outstandingDebt,
            uint64 debtDueAt
        )
    {
        return (
            platformDrawdownCount[vendor_],
            platformRepaymentCount[vendor_],
            onTimeRepaymentCount[vendor_],
            lateRepaymentCount[vendor_],
            totalRepaidAmount[vendor_],
            currentOutstandingDebt[vendor_],
            currentDebtDueAt[vendor_]
        );
    }

    function drawdown(uint256 amount) external onlyVendor nonReentrant {
        if (amount == 0) revert InvalidAmount();

        uint256 outstanding = currentOutstandingDebt[msg.sender];
        uint256 nextDebt = outstanding + amount;
        if (nextDebt > effectiveCreditLimit(msg.sender)) revert CreditLimitExceeded();

        currentOutstandingDebt[msg.sender] = nextDebt;
        platformDrawdownCount[msg.sender] += 1;
        if (outstanding == 0) {
            currentDebtDueAt[msg.sender] = uint64(block.timestamp + REPAYMENT_WINDOW);
        }
        usdc.safeTransfer(msg.sender, amount);

        emit DrawnDown(msg.sender, amount, nextDebt);
    }

    function repay(uint256 amount) external onlyVendor nonReentrant {
        if (amount == 0) revert InvalidAmount();

        uint256 outstanding = currentOutstandingDebt[msg.sender];
        if (amount > outstanding) revert RepayTooLarge();

        uint256 nextOutstanding = outstanding - amount;
        currentOutstandingDebt[msg.sender] = nextOutstanding;
        _reducePriorityObligation(msg.sender, amount);
        totalRepaidAmount[msg.sender] += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        if (nextOutstanding == 0) {
            _closeRepaymentCycle(msg.sender);
        }

        emit Repaid(msg.sender, amount, nextOutstanding);
    }

    function setWorldIdSigner(address newSigner) external onlyVendor {
        if (newSigner == address(0)) revert InvalidAddress();

        address previousSigner = worldIdSigner;
        worldIdSigner = newSigner;

        emit WorldIdSignerUpdated(previousSigner, newSigner);
    }

    function setTreasury(address newTreasury) external onlyVendor {
        if (newTreasury == address(0)) revert InvalidAddress();

        address previousTreasury = treasury;
        treasury = newTreasury;

        emit TreasuryUpdated(previousTreasury, newTreasury);
    }

    function pullCollateralForYield(uint256 amount) external onlyTreasury nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (collateralInYield + amount > collateralReservedTotal) revert InvalidAmount();

        collateralInYield += amount;
        usdc.safeTransfer(treasury, amount);

        emit CollateralPulledForYield(treasury, amount);
    }

    function returnCollateralFromYield(uint256 amount) external onlyTreasury nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (amount > collateralInYield) revert InvalidAmount();

        collateralInYield -= amount;
        usdc.safeTransferFrom(treasury, address(this), amount);

        emit CollateralReturnedFromYield(treasury, amount);
    }

    function cancel(uint256 stakeId) external nonReentrant {
        Stake storage stake = stakes[stakeId];
        if (stake.state != StakeState.Active) revert StakeNotActive();
        if (msg.sender != stake.user) revert OnlyStakeUser();

        (uint256 immediateRefund, uint256 pendingObligation) =
            _settleByCreditRule(stakeId, StakeState.Cancelled);

        emit Settled(stakeId, stake.user, stake.vendor, immediateRefund, pendingObligation);
    }

    function raiseDispute(uint256 stakeId) external {
        Stake storage stake = stakes[stakeId];
        if (stake.state != StakeState.Active) revert StakeNotActive();
        if (msg.sender != stake.user && msg.sender != stake.vendor) revert OnlyStakeParty();

        stake.state = StakeState.Disputed;
        stake.disputedAt = uint64(block.timestamp);

        emit DisputeRaised(stakeId, msg.sender, uint64(block.timestamp));
    }

    function resolveDispute(uint256 stakeId, Outcome outcome) external nonReentrant {
        if (msg.sender != arbiter) revert OnlyArbiter();

        Stake storage stake = stakes[stakeId];
        if (stake.state != StakeState.Disputed) revert StakeNotDisputed();

        _removeAllocation(stake);
        stake.state = StakeState.Resolved;

        uint256 userAmount;
        uint256 vendorAmount;
        uint256 pendingObligation;

        if (outcome == Outcome.RefundUser) {
            userAmount = stake.amount;
        } else if (outcome == Outcome.ReleaseToVendor) {
            vendorAmount = stake.amount;
        } else {
            userAmount = stake.collateral;
            vendorAmount = stake.creditAllocation;
        }

        if (userAmount != 0) usdc.safeTransfer(stake.user, userAmount);
        if (vendorAmount != 0) usdc.safeTransfer(stake.vendor, vendorAmount);

        emit DisputeResolved(stakeId, outcome, userAmount, vendorAmount, pendingObligation);
    }

    function autoRelease(uint256 stakeId) external nonReentrant {
        Stake storage stake = stakes[stakeId];
        if (stake.state != StakeState.Disputed) revert StakeNotDisputed();
        if (block.timestamp <= stake.disputedAt + disputeWindow) revert DisputeWindowOpen();

        (uint256 immediateRefund, uint256 pendingObligation) =
            _settleByCreditRule(stakeId, StakeState.Resolved);

        emit AutoReleased(stakeId, immediateRefund, pendingObligation);
    }

    function onReport(bytes calldata, bytes calldata report) external virtual override {
        if (msg.sender != keystoneForwarder) revert UnauthorizedReportSender();

        (address reportVendor, uint256 cap, uint64 expiry, uint16 creditAllocationBps) =
            abi.decode(report, (address, uint256, uint64, uint16));
        _setCreditTerms(reportVendor, cap, expiry, creditAllocationBps);
    }

    function _setCreditCap(address vendor_, uint256 cap, uint64 expiry) internal {
        _setCreditTerms(vendor_, cap, expiry, defaultCreditAllocationBps());
    }

    function _setCreditTerms(
        address vendor_,
        uint256 cap,
        uint64 expiry,
        uint16 creditAllocationBps
    ) internal {
        if (vendor_ == address(0)) revert InvalidAddress();
        if (creditAllocationBps > MAX_CREDIT_ALLOCATION_BPS) revert InvalidCreditAllocationBps();
        _vendorCreditCap[vendor_] = cap;
        _vendorCapExpiry[vendor_] = expiry;
        _vendorCreditAllocationBps[vendor_] = creditAllocationBps;
        emit CreditTermsUpdated(vendor_, cap, expiry, creditAllocationBps);
    }

    function _activeCreditCap(address vendor_) internal view returns (uint256) {
        uint64 expiry = _vendorCapExpiry[vendor_];
        if (expiry != 0 && block.timestamp > expiry) return 0;
        return _vendorCreditCap[vendor_];
    }

    function _activeCreditAllocationBps(address vendor_) internal view returns (uint16) {
        uint64 expiry = _vendorCapExpiry[vendor_];
        if (expiry != 0 && block.timestamp > expiry) return defaultCreditAllocationBps();

        uint16 allocationBps = _vendorCreditAllocationBps[vendor_];
        return allocationBps == 0 ? defaultCreditAllocationBps() : allocationBps;
    }

    function _attributedDebt(address vendor_, uint256 allocation, uint256 totalAllocation)
        internal
        view
        returns (uint256)
    {
        if (allocation == 0 || totalAllocation == 0) return 0;

        uint256 outstanding = currentOutstandingDebt[vendor_];
        uint256 debtShare = outstanding * allocation / totalAllocation;
        return debtShare > allocation ? allocation : debtShare;
    }

    function _settleByCreditRule(uint256 stakeId, StakeState finalState)
        internal
        returns (uint256 immediateRefund, uint256 pendingObligation)
    {
        Stake storage stake = stakes[stakeId];
        uint256 totalAllocationBeforeSettle = vendorCreditAllocationTotal[stake.vendor];

        pendingObligation =
            _attributedDebt(stake.vendor, stake.creditAllocation, totalAllocationBeforeSettle);
        immediateRefund = stake.amount - pendingObligation;

        stake.pendingObligation = pendingObligation;
        stake.state = finalState;
        _removeAllocation(stake);

        if (pendingObligation != 0) {
            priorityObligation[stake.vendor] += pendingObligation;
        }

        usdc.safeTransfer(stake.user, immediateRefund);
    }

    function _removeAllocation(Stake storage stake) internal {
        vendorPrincipalTotal[stake.vendor] -= stake.amount;
        vendorCreditAllocationTotal[stake.vendor] -= stake.creditAllocation;
        collateralReservedTotal -= stake.collateral;
    }

    function _reducePriorityObligation(address vendor_, uint256 amount) internal {
        uint256 obligation = priorityObligation[vendor_];
        if (obligation == 0) return;
        priorityObligation[vendor_] = amount >= obligation ? 0 : obligation - amount;
    }

    /// @dev EIP-2098-free 65-byte ECDSA recovery with low-s + canonical-v enforcement.
    function _recover(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) revert InvalidSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        if (
            uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
        ) revert InvalidVoucherSignature();
        if (v != 27 && v != 28) revert InvalidVoucherSignature();

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidVoucherSignature();
        return signer;
    }

    function _closeRepaymentCycle(address vendor_) internal {
        uint64 dueAt = currentDebtDueAt[vendor_];
        bool onTime = dueAt == 0 || block.timestamp <= dueAt;

        platformRepaymentCount[vendor_] += 1;
        if (onTime) {
            onTimeRepaymentCount[vendor_] += 1;
        } else {
            lateRepaymentCount[vendor_] += 1;
        }

        currentDebtDueAt[vendor_] = 0;
        emit RepaymentCycleClosed(vendor_, onTime, dueAt);
    }
}

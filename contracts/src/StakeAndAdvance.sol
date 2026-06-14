// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IReceiver } from "./interfaces/IReceiver.sol";
import { IERC20 } from "./token/IERC20.sol";
import { SafeERC20 } from "./token/SafeERC20.sol";
import { ReentrancyGuard } from "./utils/ReentrancyGuard.sol";

/// @title StakeAndAdvance — "the customers are the bank"
/// @notice A per-company, single-borrower credit pool. Members (the company's customers) deposit
///         USDC and receive NAV-based yield-bearing shares. The pool lends an AI-underwritten,
///         undercollateralized credit line to the company; drawdowns accrue interest. Interest paid
///         in raises the pool's net asset value (NAV) so every share is worth more; a default writes
///         down outstanding principal so NAV falls — shareholders bear the credit risk, like a bank.
///         Members exit by redeeming shares at the current NAV, bounded by the liquid reserve.
/// @dev    Accounting is strictly cash-basis: `totalAssets = cash + outstandingPrincipal`. Accrued-but-
///         -unpaid interest is NOT counted as an asset, so the pool can never promise more than it holds
///         and a default can only lose principal that was genuinely lent. The credit cap and interest
///         rate are delivered by an authorized Chainlink reporter through `onReport` (Arc has no
///         KeystoneForwarder, so a reporter key plays that role).
contract StakeAndAdvance is IReceiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_INTEREST_RATE_BPS = 10_000; // 100% APR ceiling (sanity bound)
    uint64 public constant SECONDS_PER_YEAR = 365 days;

    IERC20 public immutable usdc;
    address public immutable company; // the borrower (deployer)

    address public keystoneForwarder; // authorized credit-terms reporter
    uint64 public repaymentWindow; // due-date horizon from the first drawdown of a cycle
    uint64 public defaultGracePeriod; // grace after the due date before a permissionless default
    uint16 public minReserveBps; // fraction of total assets kept liquid for redemptions

    // --- pool / share accounting (cash basis) ---
    uint256 public cash; // USDC held by the pool, available to lend or redeem
    uint256 public outstandingPrincipal; // drawn by the company, not yet repaid
    uint256 public totalShares;
    mapping(address member => uint256 shares) public sharesOf;

    // --- interest accrual ---
    uint256 public interestDue; // accrued, unpaid interest owed by the company
    uint64 public lastAccrual; // timestamp of the last accrual checkpoint
    uint64 public dueAt; // current cycle due date (0 when there is no debt)

    // --- credit terms (delivered by Chainlink underwriting via onReport) ---
    uint256 internal _creditCap;
    uint64 internal _capExpiry;
    uint16 public interestRateBps; // APR applied to outstanding principal

    // --- track record (feeds the next underwriting round) ---
    uint256 public drawdownCount;
    uint256 public repaymentCount;
    uint256 public onTimeRepaymentCount;
    uint256 public lateRepaymentCount;
    uint256 public totalInterestPaid;
    uint256 public totalDefaultedAmount;
    bool public defaulted; // pool has taken at least one default loss

    event Deposited(address indexed member, address indexed payer, uint256 assets, uint256 shares);
    event Redeemed(address indexed member, uint256 shares, uint256 assets);
    event SharesTransferred(address indexed from, address indexed to, uint256 shares);
    event DrawnDown(address indexed company, uint256 amount, uint256 outstandingPrincipal, uint64 dueAt);
    event Repaid(
        address indexed company,
        uint256 principalPaid,
        uint256 interestPaid,
        uint256 outstandingPrincipal
    );
    event RepaymentCycleClosed(address indexed company, bool onTime, uint64 dueAt);
    event InterestAccrued(uint256 added, uint256 interestDue);
    event Defaulted(address indexed company, uint256 principalWrittenOff, uint64 at);
    event CreditTermsUpdated(
        address indexed company, uint256 cap, uint64 expiry, uint16 interestRateBps
    );

    error InvalidAddress();
    error InvalidAmount();
    error InvalidReserveBps();
    error InvalidInterestRateBps();
    error OnlyCompany();
    error CreditLimitExceeded();
    error InsufficientLiquidity();
    error RepayTooLarge();
    error UnauthorizedReportSender();
    error NotDefaultable();
    error NoDebt();
    error InsufficientShares();

    constructor(
        IERC20 usdc_,
        address keystoneForwarder_,
        uint64 repaymentWindow_,
        uint64 defaultGracePeriod_,
        uint16 minReserveBps_
    ) {
        if (address(usdc_) == address(0)) revert InvalidAddress();
        if (minReserveBps_ > BPS) revert InvalidReserveBps();

        usdc = usdc_;
        company = msg.sender;
        keystoneForwarder = keystoneForwarder_;
        repaymentWindow = repaymentWindow_;
        defaultGracePeriod = defaultGracePeriod_;
        minReserveBps = minReserveBps_;
        lastAccrual = uint64(block.timestamp);
    }

    modifier onlyCompany() {
        if (msg.sender != company) revert OnlyCompany();
        _;
    }

    // ----------------------------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------------------------

    /// @notice Total pool value backing the shares (cash basis): liquid cash + principal out on loan.
    function totalAssets() public view returns (uint256) {
        return cash + outstandingPrincipal;
    }

    /// @notice Shares minted for `assets` deposited at the current NAV.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        uint256 supply = totalShares;
        uint256 backing = totalAssets();
        if (supply == 0 || backing == 0) return assets; // bootstrap: 1 share == 1 USDC
        return assets * supply / backing;
    }

    /// @notice USDC returned for burning `shares` at the current NAV.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 supply = totalShares;
        if (supply == 0) return 0;
        return shares * totalAssets() / supply;
    }

    /// @notice NAV per share scaled to 1e18 (for display / off-chain math).
    function navPerShare1e18() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return totalAssets() * 1e18 / totalShares;
    }

    function creditCap() external view returns (uint256) {
        return _creditCap;
    }

    function capExpiry() external view returns (uint64) {
        return _capExpiry;
    }

    /// @notice The credit cap if still within its TTL, else 0 (expired underwriting freezes borrowing).
    function activeCreditCap() public view returns (uint256) {
        if (_capExpiry != 0 && block.timestamp > _capExpiry) return 0;
        return _creditCap;
    }

    /// @notice Maximum total principal the company may have outstanding right now.
    function effectiveCreditLimit() public view returns (uint256) {
        return activeCreditCap();
    }

    /// @notice How much the company can draw right now (min of cap headroom and lendable cash).
    function availableToBorrow() public view returns (uint256) {
        uint256 limit = activeCreditCap();
        uint256 headroom = outstandingPrincipal >= limit ? 0 : limit - outstandingPrincipal;
        uint256 liquid = _lendableCash();
        return headroom < liquid ? headroom : liquid;
    }

    /// @notice Cash above the required liquidity reserve (the part that may be lent out).
    function _lendableCash() internal view returns (uint256) {
        uint256 required = totalAssets() * minReserveBps / BPS;
        if (cash <= required) return 0;
        return cash - required;
    }

    /// @notice Interest owed by the company including not-yet-checkpointed accrual.
    function accruedInterest() public view returns (uint256) {
        return interestDue + _pendingInterest();
    }

    function _pendingInterest() internal view returns (uint256) {
        if (outstandingPrincipal == 0 || interestRateBps == 0) return 0;
        uint256 dt = block.timestamp - lastAccrual;
        return outstandingPrincipal * interestRateBps * dt / (uint256(BPS) * SECONDS_PER_YEAR);
    }

    /// @notice Repayment history + current exposure, consumed by the underwriting model.
    function trackRecord()
        external
        view
        returns (
            uint256 drawdowns,
            uint256 repayments,
            uint256 onTime,
            uint256 late,
            uint256 interestPaid,
            uint256 defaultedAmount,
            uint256 outstanding,
            uint64 debtDueAt
        )
    {
        return (
            drawdownCount,
            repaymentCount,
            onTimeRepaymentCount,
            lateRepaymentCount,
            totalInterestPaid,
            totalDefaultedAmount,
            outstandingPrincipal,
            dueAt
        );
    }

    /// @notice One-call snapshot of the whole pool (for the backend / frontend).
    function poolState()
        external
        view
        returns (
            uint256 assets,
            uint256 liquidCash,
            uint256 outstanding,
            uint256 shares,
            uint256 navPerShare,
            uint256 cap,
            uint64 expiry,
            uint16 rateBps,
            uint64 debtDueAt,
            bool isDefaulted
        )
    {
        uint256 nav = totalShares == 0 ? 1e18 : totalAssets() * 1e18 / totalShares;
        return (
            totalAssets(),
            cash,
            outstandingPrincipal,
            totalShares,
            nav,
            _creditCap,
            _capExpiry,
            interestRateBps,
            dueAt,
            defaulted
        );
    }

    // ----------------------------------------------------------------------------------
    // Interest accrual
    // ----------------------------------------------------------------------------------

    /// @dev Checkpoint interest. MUST be called before any mutation of `outstandingPrincipal`
    ///      or `interestRateBps` so the piecewise integral stays exact.
    function _accrue() internal {
        uint256 pending = _pendingInterest();
        if (pending != 0) {
            interestDue += pending;
            emit InterestAccrued(pending, interestDue);
        }
        lastAccrual = uint64(block.timestamp);
    }

    // ----------------------------------------------------------------------------------
    // Member deposit / redeem (the "be the bank" side)
    // ----------------------------------------------------------------------------------

    /// @notice Deposit USDC and receive shares at the current NAV.
    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        return _deposit(msg.sender, amount);
    }

    /// @notice Deposit on behalf of `member` (relayer / embedded-wallet funding seam, e.g. Dynamic).
    ///         `msg.sender` pays; `member` receives the shares.
    function depositFor(address member, uint256 amount)
        external
        nonReentrant
        returns (uint256 shares)
    {
        return _deposit(member, amount);
    }

    function _deposit(address member, uint256 amount) internal returns (uint256 shares) {
        if (member == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        shares = previewDeposit(amount); // priced on pre-deposit assets
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        cash += amount;
        totalShares += shares;
        sharesOf[member] += shares;

        emit Deposited(member, msg.sender, amount, shares);
    }

    /// @notice Burn shares and withdraw USDC at the current NAV (bounded by liquid cash).
    function redeem(uint256 shares) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert InvalidAmount();
        if (sharesOf[msg.sender] < shares) revert InsufficientShares();

        assets = previewRedeem(shares);
        if (assets > cash) revert InsufficientLiquidity();

        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        cash -= assets;
        usdc.safeTransfer(msg.sender, assets);

        emit Redeemed(msg.sender, shares, assets);
    }

    /// @notice Transfer shares to another holder (keeps the position tradeable / transferable).
    function transferShares(address to, uint256 shares) external {
        if (to == address(0)) revert InvalidAddress();
        if (sharesOf[msg.sender] < shares) revert InsufficientShares();

        sharesOf[msg.sender] -= shares;
        sharesOf[to] += shares;

        emit SharesTransferred(msg.sender, to, shares);
    }

    // ----------------------------------------------------------------------------------
    // Company credit line (interest-bearing)
    // ----------------------------------------------------------------------------------

    /// @notice Company draws against the underwritten credit line, bounded by cap and liquid reserve.
    function drawdown(uint256 amount) external onlyCompany nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _accrue();

        uint256 nextDebt = outstandingPrincipal + amount;
        if (nextDebt > activeCreditCap()) revert CreditLimitExceeded();
        if (amount > _lendableCash()) revert InsufficientLiquidity();

        if (outstandingPrincipal == 0) {
            dueAt = uint64(block.timestamp) + repaymentWindow;
        }
        outstandingPrincipal = nextDebt;
        cash -= amount;
        drawdownCount += 1;
        usdc.safeTransfer(company, amount);

        emit DrawnDown(company, amount, nextDebt, dueAt);
    }

    /// @notice Company repays; payment covers accrued interest first, then principal. Interest paid in
    ///         raises `totalAssets` (and therefore NAV) — that is the yield members earn.
    function repay(uint256 amount) external onlyCompany nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _accrue();

        uint256 interestPortion = amount <= interestDue ? amount : interestDue;
        uint256 principalPortion = amount - interestPortion;
        if (principalPortion > outstandingPrincipal) revert RepayTooLarge();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        cash += amount;
        interestDue -= interestPortion;
        outstandingPrincipal -= principalPortion;
        totalInterestPaid += interestPortion;

        if (outstandingPrincipal == 0 && interestDue == 0) {
            _closeCycle();
        }

        emit Repaid(company, principalPortion, interestPortion, outstandingPrincipal);
    }

    function _closeCycle() internal {
        bool onTime = dueAt == 0 || block.timestamp <= dueAt;
        repaymentCount += 1;
        if (onTime) {
            onTimeRepaymentCount += 1;
        } else {
            lateRepaymentCount += 1;
        }
        emit RepaymentCycleClosed(company, onTime, dueAt);
        dueAt = 0;
    }

    /// @notice Permissionless: once the debt is past due + grace, write off the outstanding principal
    ///         as a pool loss. `totalAssets` (and NAV) fall; shareholders bear the loss pro-rata.
    function markDefaulted() external nonReentrant {
        if (outstandingPrincipal == 0) revert NoDebt();
        if (dueAt == 0 || block.timestamp <= uint256(dueAt) + defaultGracePeriod) {
            revert NotDefaultable();
        }
        _accrue();

        uint256 writeOff = outstandingPrincipal;
        outstandingPrincipal = 0;
        interestDue = 0; // unpaid interest was never an asset; clear it
        totalDefaultedAmount += writeOff;
        lateRepaymentCount += 1;
        defaulted = true;
        dueAt = 0;

        emit Defaulted(company, writeOff, uint64(block.timestamp));
    }

    // ----------------------------------------------------------------------------------
    // Credit-terms delivery (Chainlink Confidential AI underwriting)
    // ----------------------------------------------------------------------------------

    /// @notice Authorized reporter delivers the underwritten credit terms:
    ///         abi.encode(company, creditCap, expiry, interestRateBps).
    function onReport(bytes calldata, bytes calldata report) external override {
        if (msg.sender != keystoneForwarder) revert UnauthorizedReportSender();

        (address reportCompany, uint256 cap, uint64 expiry, uint16 rateBps) =
            abi.decode(report, (address, uint256, uint64, uint16));
        if (rateBps > MAX_INTEREST_RATE_BPS) revert InvalidInterestRateBps();

        _accrue(); // settle interest at the old rate before repricing
        _creditCap = cap;
        _capExpiry = expiry;
        interestRateBps = rateBps;

        emit CreditTermsUpdated(reportCompany, cap, expiry, rateBps);
    }
}

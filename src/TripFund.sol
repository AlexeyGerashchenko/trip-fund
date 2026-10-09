// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITripFund} from "./interfaces/ITripFund.sol";

/// @notice A fixed-deadline team trip fund using a single standard ERC-20 token.
/// @dev Fee-on-transfer and rebasing tokens are outside the supported token model.
contract TripFund is ITripFund, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable override token;
    address public immutable override organizer;
    uint256 public immutable override goal;
    uint256 public immutable override deadline;

    mapping(address => uint256) public override contributions;
    /// @notice Historical sum of accepted contributions, never reduced by payouts.
    uint256 public override totalRaised;
    bool public override withdrawn;

    constructor(IERC20 token_, address organizer_, uint256 goal_, uint256 deadline_) {
        if (address(token_) == address(0) || organizer_ == address(0)) revert ZeroAddress();
        if (goal_ == 0) revert ZeroGoal();
        if (deadline_ <= block.timestamp) revert DeadlineNotInFuture();

        token = token_;
        organizer = organizer_;
        goal = goal_;
        deadline = deadline_;
    }

    function contribute(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp >= deadline) revert FundingClosed();

        contributions[msg.sender] += amount;
        totalRaised += amount;
        emit Contributed(msg.sender, amount);
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw() external override nonReentrant {
        if (block.timestamp < deadline) revert DeadlineNotReached();
        if (msg.sender != organizer) revert OnlyOrganizer();
        if (totalRaised < goal) revert GoalNotReached();
        if (withdrawn) revert AlreadyWithdrawn();

        withdrawn = true;
        // Use accounting rather than balanceOf: unsolicited tokens stay in the fund.
        emit Withdrawn(organizer, totalRaised);
        token.safeTransfer(organizer, totalRaised);
    }

    function refund() external override nonReentrant {
        if (block.timestamp < deadline) revert DeadlineNotReached();
        if (totalRaised >= goal) revert GoalReached();
        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NoContribution();

        contributions[msg.sender] = 0;
        emit Refunded(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ITripFund} from "./interfaces/ITripFund.sol";

/// @notice V1 implementation for an OpenZeppelin 5.x transparent proxy.
contract TripFundV1 is ITripFund, Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // Preserve this order and these types in all later implementations.
    IERC20 public override token;
    address public override organizer;
    uint256 public override goal;
    uint256 public override deadline;
    mapping(address => uint256) public override contributions;
    uint256 public override totalRaised;
    bool public override withdrawn;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 token_, address organizer_, uint256 goal_, uint256 deadline_) public initializer {
        if (address(token_) == address(0) || organizer_ == address(0)) revert ZeroAddress();
        if (goal_ == 0) revert ZeroGoal();
        if (deadline_ <= block.timestamp) revert DeadlineNotInFuture();

        __ReentrancyGuard_init();
        token = token_;
        organizer = organizer_;
        goal = goal_;
        deadline = deadline_;
    }

    function contribute(uint256 amount) external override nonReentrant {
        _recordContribution(msg.sender, amount);
        // The helper above only updates storage; the token call follows the event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Contributed(msg.sender, amount);
        _collect(msg.sender, amount);
    }

    /// @dev Both entry points in V2 use the same checks and accounting.
    function _recordContribution(address beneficiary, uint256 amount) internal {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp >= deadline) revert FundingClosed();

        contributions[beneficiary] += amount;
        totalRaised += amount;
    }

    function _collect(address payer, uint256 amount) internal {
        token.safeTransferFrom(payer, address(this), amount);
    }

    function withdraw() external override nonReentrant {
        if (block.timestamp < deadline) revert DeadlineNotReached();
        if (msg.sender != organizer) revert OnlyOrganizer();
        if (totalRaised < goal) revert GoalNotReached();
        if (withdrawn) revert AlreadyWithdrawn();

        withdrawn = true;
        // State and event precede the external token transfer.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Withdrawn(organizer, totalRaised);
        token.safeTransfer(organizer, totalRaised);
    }

    function refund() external override nonReentrant {
        if (block.timestamp < deadline) revert DeadlineNotReached();
        if (totalRaised >= goal) revert GoalReached();
        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NoContribution();

        contributions[msg.sender] = 0;
        // State and event precede the external token transfer.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Refunded(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }
}

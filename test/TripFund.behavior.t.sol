// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITripFund} from "../src/interfaces/ITripFund.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {FailingToken} from "./mocks/FailingToken.sol";

/// @dev Run the same full acceptance suite against both the constructor and proxy V1.
abstract contract TripFundBehaviorTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ORGANIZER = address(0xC0FFEE);
    address internal constant ADMIN_OWNER = address(0xAD);
    address internal constant STRANGER = address(0xBAD);
    uint256 internal constant GOAL = 100 ether;
    uint256 internal constant INITIAL_BALANCE = 1_000 ether;

    MockERC20 internal token;
    ITripFund internal fund;
    uint256 internal deadline;

    event Contributed(address indexed contributor, uint256 amount);
    event Refunded(address indexed contributor, uint256 amount);
    event Withdrawn(address indexed organizer, uint256 amount);

    function _deploy(IERC20 token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        virtual
        returns (ITripFund);

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        deadline = block.timestamp + 7 days;
        token = new MockERC20();
        token.mint(ALICE, INITIAL_BALANCE);
        token.mint(BOB, INITIAL_BALANCE);
        token.mint(STRANGER, INITIAL_BALANCE);
        fund = _deploy(token, ORGANIZER, GOAL, deadline);
    }

    function _contribute(address payer, uint256 amount) internal {
        vm.startPrank(payer);
        token.approve(address(fund), amount);
        fund.contribute(amount);
        vm.stopPrank();
    }

    function _snapshot() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                fund.totalRaised(),
                fund.contributions(ALICE),
                fund.contributions(BOB),
                fund.withdrawn(),
                token.balanceOf(ALICE),
                token.balanceOf(BOB),
                token.balanceOf(ORGANIZER),
                token.balanceOf(address(fund)),
                token.allowance(ALICE, address(fund)),
                token.allowance(BOB, address(fund))
            )
        );
    }

    function test_InitialParametersAndAccounting() public view {
        assertEq(address(fund.token()), address(token));
        assertEq(fund.organizer(), ORGANIZER);
        assertEq(fund.goal(), GOAL);
        assertEq(fund.deadline(), deadline);
        assertEq(fund.totalRaised(), 0);
        assertEq(fund.contributions(ALICE), 0);
        assertFalse(fund.withdrawn());
        assertEq(token.decimals(), 18);
    }

    function test_RejectZeroToken() public {
        vm.expectRevert(ITripFund.ZeroAddress.selector);
        _deploy(IERC20(address(0)), ORGANIZER, GOAL, deadline);
    }

    function test_RejectZeroOrganizer() public {
        vm.expectRevert(ITripFund.ZeroAddress.selector);
        _deploy(token, address(0), GOAL, deadline);
    }

    function test_RejectZeroGoal() public {
        vm.expectRevert(ITripFund.ZeroGoal.selector);
        _deploy(token, ORGANIZER, 0, deadline);
    }

    function test_RejectDeadlineNow() public {
        vm.expectRevert(ITripFund.DeadlineNotInFuture.selector);
        _deploy(token, ORGANIZER, GOAL, block.timestamp);
    }

    function test_RejectDeadlineInPast() public {
        vm.expectRevert(ITripFund.DeadlineNotInFuture.selector);
        _deploy(token, ORGANIZER, GOAL, block.timestamp - 1);
    }

    function test_TwoContributorsAndRepeatedContributions() public {
        _contribute(ALICE, 10 ether);
        _contribute(BOB, 20 ether);
        _contribute(ALICE, 30 ether);
        assertEq(fund.contributions(ALICE), 40 ether);
        assertEq(fund.contributions(BOB), 20 ether);
        assertEq(fund.totalRaised(), 60 ether);
        assertEq(token.balanceOf(address(fund)), 60 ether);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE - 40 ether);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE - 20 ether);
    }

    function test_ContributionEvent() public {
        vm.prank(ALICE);
        token.approve(address(fund), 10 ether);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Contributed(ALICE, 10 ether);
        vm.prank(ALICE);
        fund.contribute(10 ether);
    }

    function test_ZeroContributionRevertsWithoutChanges() public {
        _contribute(ALICE, 5 ether);
        bytes32 before_ = _snapshot();
        vm.expectRevert(ITripFund.ZeroAmount.selector);
        vm.prank(ALICE);
        fund.contribute(0);
        assertEq(_snapshot(), before_);
    }

    function test_InsufficientAllowanceRevertsWithoutChanges() public {
        _contribute(BOB, 5 ether);
        vm.prank(ALICE);
        token.approve(address(fund), 4 ether);
        bytes32 before_ = _snapshot();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(fund), 4 ether, 5 ether)
        );
        vm.prank(ALICE);
        fund.contribute(5 ether);
        assertEq(_snapshot(), before_);
    }

    function test_NoApprovalRevertsWithoutChanges() public {
        bytes32 before_ = _snapshot();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(fund), 0, 5 ether)
        );
        vm.prank(ALICE);
        fund.contribute(5 ether);
        assertEq(_snapshot(), before_);
    }

    function test_InsufficientBalanceRevertsWithoutChanges() public {
        vm.prank(ALICE);
        token.approve(address(fund), INITIAL_BALANCE + 1);
        bytes32 before_ = _snapshot();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, ALICE, INITIAL_BALANCE, INITIAL_BALANCE + 1
            )
        );
        vm.prank(ALICE);
        fund.contribute(INITIAL_BALANCE + 1);
        assertEq(_snapshot(), before_);
    }

    function test_ContributionOneSecondBeforeDeadline() public {
        vm.warp(deadline - 1);
        _contribute(ALICE, 10 ether);
        assertEq(fund.totalRaised(), 10 ether);
    }

    function test_ContributionAtDeadlineRevertsWithoutChanges() public {
        vm.prank(ALICE);
        token.approve(address(fund), 10 ether);
        vm.warp(deadline);
        bytes32 before_ = _snapshot();
        vm.expectRevert(ITripFund.FundingClosed.selector);
        vm.prank(ALICE);
        fund.contribute(10 ether);
        assertEq(_snapshot(), before_);
    }

    function test_ContributionAfterDeadlineReverts() public {
        vm.warp(deadline + 1);
        vm.expectRevert(ITripFund.FundingClosed.selector);
        vm.prank(ALICE);
        fund.contribute(10 ether);
        assertEq(fund.totalRaised(), 0);
    }

    function test_EarlyWithdrawForbiddenEvenWhenGoalReached() public {
        _contribute(ALICE, GOAL);
        vm.warp(deadline - 1);
        bytes32 before_ = _snapshot();
        vm.expectRevert(ITripFund.DeadlineNotReached.selector);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(_snapshot(), before_);
    }

    function test_EarlyRefundForbidden() public {
        _contribute(ALICE, 10 ether);
        vm.warp(deadline - 1);
        bytes32 before_ = _snapshot();
        vm.expectRevert(ITripFund.DeadlineNotReached.selector);
        vm.prank(ALICE);
        fund.refund();
        assertEq(_snapshot(), before_);
    }

    function test_EarlyRefundForbiddenEvenWhenGoalReached() public {
        _contribute(ALICE, GOAL);
        vm.expectRevert(ITripFund.DeadlineNotReached.selector);
        vm.prank(ALICE);
        fund.refund();
        assertEq(fund.contributions(ALICE), GOAL);
    }

    function test_ExactGoalWithdrawAtDeadline() public {
        _contribute(ALICE, 40 ether);
        _contribute(BOB, 60 ether);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Withdrawn(ORGANIZER, GOAL);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertTrue(fund.withdrawn());
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), GOAL);
        assertEq(fund.contributions(ALICE), 40 ether);
        assertEq(fund.contributions(BOB), 60 ether);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE - 40 ether);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE - 60 ether);
    }

    function test_AboveGoalWithdrawsEntireAccountedSum() public {
        _contribute(ALICE, 70 ether);
        _contribute(BOB, 80 ether);
        vm.warp(deadline);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(token.balanceOf(ORGANIZER), 150 ether);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), 150 ether);
    }

    function test_StrangerCannotWithdraw() public {
        _contribute(ALICE, GOAL);
        vm.warp(deadline);
        bytes32 before_ = _snapshot();
        vm.expectRevert(ITripFund.OnlyOrganizer.selector);
        vm.prank(ALICE);
        fund.withdraw();
        assertEq(_snapshot(), before_);
    }

    function test_WithdrawOnlyOnce() public {
        _contribute(ALICE, GOAL);
        vm.warp(deadline);
        vm.prank(ORGANIZER);
        fund.withdraw();
        bytes32 before_ = _snapshot();
        vm.expectRevert(ITripFund.AlreadyWithdrawn.selector);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(_snapshot(), before_);
    }

    function test_WithdrawForbiddenOnFailure() public {
        _contribute(ALICE, GOAL - 1);
        vm.warp(deadline);
        bytes32 before_ = _snapshot();
        vm.expectRevert(ITripFund.GoalNotReached.selector);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(_snapshot(), before_);
    }

    function test_IndependentFullRefundsAtDeadline() public {
        _contribute(ALICE, 10 ether);
        _contribute(ALICE, 15 ether);
        _contribute(BOB, 30 ether);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Refunded(ALICE, 25 ether);
        vm.prank(ALICE);
        fund.refund();
        assertEq(fund.contributions(ALICE), 0);
        assertEq(fund.contributions(BOB), 30 ether);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE - 30 ether);
        assertEq(token.balanceOf(address(fund)), 30 ether);
        assertEq(fund.totalRaised(), 55 ether);

        vm.prank(BOB);
        fund.refund();
        assertEq(fund.contributions(BOB), 0);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE);
        assertEq(token.balanceOf(ORGANIZER), 0);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), 55 ether);
    }

    function test_RefundWithoutContributionReverts() public {
        _contribute(ALICE, 10 ether);
        vm.warp(deadline);
        bytes32 before_ = _snapshot();
        vm.expectRevert(ITripFund.NoContribution.selector);
        vm.prank(BOB);
        fund.refund();
        assertEq(_snapshot(), before_);
    }

    function test_RefundOnlyOnce() public {
        _contribute(ALICE, 10 ether);
        vm.warp(deadline);
        vm.prank(ALICE);
        fund.refund();
        bytes32 before_ = _snapshot();
        vm.expectRevert(ITripFund.NoContribution.selector);
        vm.prank(ALICE);
        fund.refund();
        assertEq(_snapshot(), before_);
    }

    function test_RefundForbiddenOnSuccessBeforeAndAfterWithdraw() public {
        _contribute(ALICE, GOAL);
        vm.warp(deadline);
        bytes32 before_ = _snapshot();
        vm.expectRevert(ITripFund.GoalReached.selector);
        vm.prank(ALICE);
        fund.refund();
        assertEq(_snapshot(), before_);
        vm.prank(ORGANIZER);
        fund.withdraw();
        before_ = _snapshot();
        vm.expectRevert(ITripFund.GoalReached.selector);
        vm.prank(ALICE);
        fund.refund();
        assertEq(_snapshot(), before_);
    }

    function test_DirectTransferStaysAfterSuccessfulWithdrawal() public {
        _contribute(ALICE, GOAL);
        vm.prank(STRANGER);
        token.transfer(address(fund), 17 ether);
        assertEq(fund.totalRaised(), GOAL);
        assertEq(fund.contributions(STRANGER), 0);
        assertEq(token.balanceOf(address(fund)), GOAL + 17 ether);
        vm.warp(deadline);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        assertEq(token.balanceOf(address(fund)), 17 ether);
        assertEq(fund.totalRaised(), GOAL);
    }

    function test_DirectTransferDoesNotReachGoalAndStaysAfterRefunds() public {
        _contribute(ALICE, 10 ether);
        _contribute(BOB, 20 ether);
        vm.prank(STRANGER);
        token.transfer(address(fund), GOAL);
        assertEq(fund.totalRaised(), 30 ether);
        assertEq(fund.contributions(STRANGER), 0);
        vm.warp(deadline);
        vm.expectRevert(ITripFund.GoalNotReached.selector);
        vm.prank(ORGANIZER);
        fund.withdraw();
        vm.prank(ALICE);
        fund.refund();
        vm.prank(BOB);
        fund.refund();
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), GOAL);
        assertEq(fund.totalRaised(), 30 ether);
        vm.expectRevert(ITripFund.NoContribution.selector);
        vm.prank(STRANGER);
        fund.refund();
    }

    function test_EmptyFundCannotPayAnyone() public {
        vm.warp(deadline);
        vm.expectRevert(ITripFund.GoalNotReached.selector);
        vm.prank(ORGANIZER);
        fund.withdraw();
        vm.expectRevert(ITripFund.NoContribution.selector);
        vm.prank(ALICE);
        fund.refund();
        assertEq(fund.totalRaised(), 0);
    }

    function _useFailingToken() internal returns (FailingToken failing) {
        failing = new FailingToken();
        failing.mint(ALICE, INITIAL_BALANCE);
        token = failing;
        fund = _deploy(token, ORGANIZER, GOAL, deadline);
    }

    function test_FalseTransferFromRollsBackContribution() public {
        FailingToken failing = _useFailingToken();
        vm.prank(ALICE);
        token.approve(address(fund), 10 ether);
        failing.setFailTransferFrom(true);
        bytes32 before_ = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(ALICE);
        fund.contribute(10 ether);
        assertEq(_snapshot(), before_);
        failing.setFailTransferFrom(false);
        vm.prank(ALICE);
        fund.contribute(10 ether);
        assertEq(fund.totalRaised(), 10 ether);
    }

    function test_FailedWithdrawRollsBackFlagAndAllowsRetry() public {
        FailingToken failing = _useFailingToken();
        _contribute(ALICE, GOAL);
        vm.warp(deadline);
        failing.setFailTransfers(true);
        bytes32 before_ = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(_snapshot(), before_);
        assertFalse(fund.withdrawn());
        failing.setFailTransfers(false);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertTrue(fund.withdrawn());
        assertEq(token.balanceOf(ORGANIZER), GOAL);
    }

    function test_FailedRefundRestoresContributionAndAllowsRetry() public {
        FailingToken failing = _useFailingToken();
        _contribute(ALICE, 10 ether);
        vm.warp(deadline);
        failing.setFailTransfers(true);
        bytes32 before_ = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(ALICE);
        fund.refund();
        assertEq(_snapshot(), before_);
        assertEq(fund.contributions(ALICE), 10 ether);
        failing.setFailTransfers(false);
        vm.prank(ALICE);
        fund.refund();
        assertEq(fund.contributions(ALICE), 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
    }

    function testFuzz_RepeatedContributionsAndRefunds(uint96 first, uint96 second, uint96 third) public {
        uint256 a = bound(uint256(first), 1, 30 ether);
        uint256 b = bound(uint256(second), 1, 30 ether);
        uint256 c = bound(uint256(third), 1, 30 ether);
        _contribute(ALICE, a);
        _contribute(BOB, b);
        _contribute(ALICE, c);
        assertEq(fund.contributions(ALICE), a + c);
        assertEq(fund.contributions(BOB), b);
        assertEq(fund.totalRaised(), a + b + c);
        vm.warp(deadline);
        vm.prank(BOB);
        fund.refund();
        vm.prank(ALICE);
        fund.refund();
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), a + b + c);
    }

    function testFuzz_SuccessWithdrawsOnlyAccountedTokens(uint96 excess, uint96 donation) public {
        uint256 extra = bound(uint256(excess), 0, 100 ether);
        uint256 direct = bound(uint256(donation), 1, 100 ether);
        _contribute(ALICE, GOAL + extra);
        vm.prank(STRANGER);
        token.transfer(address(fund), direct);
        vm.warp(deadline);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(token.balanceOf(ORGANIZER), GOAL + extra);
        assertEq(token.balanceOf(address(fund)), direct);
        assertEq(fund.totalRaised(), GOAL + extra);
    }
}

contract TripFundTest is TripFundBehaviorTest {
    function _deploy(IERC20 token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (ITripFund)
    {
        return new TripFund(token_, organizer_, goal_, deadline_);
    }
}

contract TripFundProxyV1Test is TripFundBehaviorTest {
    TripFundV1 private implementation;

    function setUp() public override {
        implementation = new TripFundV1();
        super.setUp();
    }

    function _deploy(IERC20 token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (ITripFund)
    {
        // Reject invalid parameters in the initialize call, not after proxy creation.
        // The full shared suite verifies the same revert behavior as the constructor.
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            ADMIN_OWNER,
            abi.encodeCall(TripFundV1.initialize, (token_, organizer_, goal_, deadline_))
        );
        return ITripFund(address(proxy));
    }
}

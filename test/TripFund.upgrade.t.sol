// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {ITripFund} from "../src/interfaces/ITripFund.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract TripFundUpgradeTest is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant FRIEND = address(0xF123);
    address internal constant ORGANIZER = address(0xC0FFEE);
    address internal constant ADMIN_OWNER = address(0xAD);
    uint256 internal constant GOAL = 100 ether;
    uint256 internal constant INITIAL_BALANCE = 1_000 ether;
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 internal constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    MockERC20 internal token;
    TripFundV1 internal implementationV1;
    TripFundV2 internal implementationV2;
    TripFundV1 internal v1;
    TripFundV2 internal v2;
    TransparentUpgradeableProxy internal proxy;
    ProxyAdmin internal admin;
    uint256 internal deadline;

    event ContributedFor(address indexed payer, address indexed beneficiary, uint256 amount);

    function setUp() public {
        vm.warp(1_800_000_000);
        deadline = block.timestamp + 7 days;
        token = new MockERC20();
        token.mint(ALICE, INITIAL_BALANCE);
        token.mint(BOB, INITIAL_BALANCE);
        implementationV1 = new TripFundV1();
        implementationV2 = new TripFundV2();
        proxy = new TransparentUpgradeableProxy(
            address(implementationV1),
            ADMIN_OWNER,
            abi.encodeCall(TripFundV1.initialize, (IERC20(address(token)), ORGANIZER, GOAL, deadline))
        );
        v1 = TripFundV1(address(proxy));
        admin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT)))));
        assertEq(admin.owner(), ADMIN_OWNER);
    }

    function _contributeV1(address payer, uint256 amount) internal {
        vm.startPrank(payer);
        token.approve(address(proxy), amount);
        v1.contribute(amount);
        vm.stopPrank();
    }

    function _upgrade() internal {
        vm.prank(ADMIN_OWNER);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(implementationV2), "");
        v2 = TripFundV2(address(proxy));
    }

    function _contributeFor(address payer, address beneficiary, uint256 amount) internal {
        vm.startPrank(payer);
        token.approve(address(proxy), amount);
        v2.contributeFor(beneficiary, amount);
        vm.stopPrank();
    }

    function test_UpgradePreservesStateThenFriendReceivesRefund() public {
        _contributeV1(ALICE, 10 ether);
        _contributeV1(BOB, 20 ether);
        _contributeV1(ALICE, 5 ether);
        address originalAddress = address(proxy);
        uint256 originalBalance = token.balanceOf(originalAddress);
        vm.warp(deadline - 1 days);
        _upgrade();

        assertEq(address(v2), originalAddress);
        assertEq(address(v2.token()), address(token));
        assertEq(v2.organizer(), ORGANIZER);
        assertEq(v2.goal(), GOAL);
        assertEq(v2.deadline(), deadline);
        assertEq(v2.contributions(ALICE), 15 ether);
        assertEq(v2.contributions(BOB), 20 ether);
        assertEq(v2.totalRaised(), 35 ether);
        assertEq(token.balanceOf(originalAddress), originalBalance);
        assertFalse(v2.withdrawn());
        assertEq(address(uint160(uint256(vm.load(originalAddress, IMPLEMENTATION_SLOT)))), address(implementationV2));
        assertEq(address(uint160(uint256(vm.load(originalAddress, ADMIN_SLOT)))), address(admin));

        _contributeFor(ALICE, FRIEND, 12 ether);
        _contributeFor(BOB, FRIEND, 3 ether);
        // The ordinary entry point is still available and accumulates Alice's V1 balance.
        vm.startPrank(ALICE);
        token.approve(address(proxy), 2 ether);
        v2.contribute(2 ether);
        vm.stopPrank();
        assertEq(v2.contributions(ALICE), 17 ether);
        assertEq(v2.contributions(FRIEND), 15 ether);
        assertEq(v2.totalRaised(), 52 ether);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE - 29 ether);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE - 23 ether);
        assertEq(token.balanceOf(FRIEND), 0);

        vm.warp(deadline);
        vm.prank(FRIEND);
        v2.refund();
        assertEq(token.balanceOf(FRIEND), 15 ether);
        assertEq(v2.contributions(FRIEND), 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE - 29 ether);
        vm.prank(ALICE);
        v2.refund();
        vm.prank(BOB);
        v2.refund();
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE - 12 ether);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE - 3 ether);
        assertEq(token.balanceOf(address(proxy)), 0);
        assertEq(v2.totalRaised(), 52 ether);
    }

    /// @dev This test performs real OpenZeppelin validation, deployment and upgrade.
    /// No unsafeSkipAllChecks/UnsafeUpgrades options are used.
    function test_OpenZeppelinValidatedDeploymentAndUpgrade() public {
        Options memory opts;
        opts.referenceContract = "TripFundV1.sol:TripFundV1";
        Upgrades.validateUpgrade("TripFundV2.sol:TripFundV2", opts);

        address checkedProxy = Upgrades.deployTransparentProxy(
            "TripFundV1.sol:TripFundV1",
            ADMIN_OWNER,
            abi.encodeCall(TripFundV1.initialize, (IERC20(address(token)), ORGANIZER, GOAL, deadline))
        );
        TripFundV1 checkedV1 = TripFundV1(checkedProxy);
        vm.startPrank(ALICE);
        token.approve(checkedProxy, 10 ether);
        checkedV1.contribute(10 ether);
        vm.stopPrank();
        address previousImplementation = Upgrades.getImplementationAddress(checkedProxy);
        address previousAdmin = Upgrades.getAdminAddress(checkedProxy);

        Upgrades.upgradeProxy(checkedProxy, "TripFundV2.sol:TripFundV2", "", opts, ADMIN_OWNER);
        TripFundV2 checkedV2 = TripFundV2(checkedProxy);
        assertTrue(Upgrades.getImplementationAddress(checkedProxy) != previousImplementation);
        assertEq(Upgrades.getAdminAddress(checkedProxy), previousAdmin);
        assertEq(address(checkedV2), checkedProxy);
        assertEq(address(checkedV2.token()), address(token));
        assertEq(checkedV2.organizer(), ORGANIZER);
        assertEq(checkedV2.goal(), GOAL);
        assertEq(checkedV2.deadline(), deadline);
        assertEq(checkedV2.contributions(ALICE), 10 ether);
        assertEq(checkedV2.totalRaised(), 10 ether);
        assertEq(token.balanceOf(checkedProxy), 10 ether);

        vm.startPrank(BOB);
        token.approve(checkedProxy, 5 ether);
        checkedV2.contributeFor(FRIEND, 5 ether);
        token.approve(checkedProxy, 2 ether);
        checkedV2.contribute(2 ether);
        vm.stopPrank();
        vm.warp(deadline);
        vm.prank(FRIEND);
        checkedV2.refund();
        assertEq(token.balanceOf(FRIEND), 5 ether);
        vm.prank(ALICE);
        checkedV2.refund();
        vm.prank(BOB);
        checkedV2.refund();
        assertEq(token.balanceOf(checkedProxy), 0);
        assertEq(checkedV2.totalRaised(), 17 ether);
    }

    function test_OnlyProxyAdminOwnerCanUpgrade() public {
        _contributeV1(ALICE, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        vm.prank(ALICE);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(implementationV2), "");
        assertEq(address(uint160(uint256(vm.load(address(proxy), IMPLEMENTATION_SLOT)))), address(implementationV1));
        assertEq(v1.contributions(ALICE), 10 ether);
        assertEq(token.balanceOf(address(proxy)), 10 ether);
        _upgrade();
        assertEq(address(uint160(uint256(vm.load(address(proxy), IMPLEMENTATION_SLOT)))), address(implementationV2));
    }

    function test_OrganizerCannotUpgradeUnlessAdminOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ORGANIZER));
        vm.prank(ORGANIZER);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(implementationV2), "");
    }

    function test_DirectProxyUpgradeByNonAdminIsRejected() public {
        vm.expectRevert();
        vm.prank(ADMIN_OWNER);
        ITransparentUpgradeableProxy(address(proxy)).upgradeToAndCall(address(implementationV2), "");
        assertEq(address(uint160(uint256(vm.load(address(proxy), IMPLEMENTATION_SLOT)))), address(implementationV1));
    }

    function test_ProxyCannotInitializeTwiceInV1() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v1.initialize(token, ALICE, 1, deadline + 1 days);
        assertEq(v1.organizer(), ORGANIZER);
        assertEq(v1.goal(), GOAL);
        assertEq(v1.deadline(), deadline);
    }

    function test_ProxyCannotInitializeAgainAfterUpgrade() public {
        _contributeV1(ALICE, 10 ether);
        _upgrade();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initialize(token, ALICE, 1, deadline + 1 days);
        assertEq(v2.organizer(), ORGANIZER);
        assertEq(v2.contributions(ALICE), 10 ether);
        assertEq(v2.totalRaised(), 10 ether);
    }

    function test_DirectV1ImplementationInitializationDisabled() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementationV1.initialize(token, ORGANIZER, GOAL, deadline);
    }

    function test_DirectV2ImplementationInitializationDisabled() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementationV2.initialize(token, ORGANIZER, GOAL, deadline);
    }

    function test_ContributeForEventAndPayerBalance() public {
        _upgrade();
        vm.prank(ALICE);
        token.approve(address(proxy), 10 ether);
        vm.expectEmit(true, true, false, true, address(proxy));
        emit ContributedFor(ALICE, FRIEND, 10 ether);
        vm.prank(ALICE);
        v2.contributeFor(FRIEND, 10 ether);
        assertEq(v2.contributions(FRIEND), 10 ether);
        assertEq(v2.contributions(ALICE), 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE - 10 ether);
        assertEq(token.balanceOf(FRIEND), 0);
        assertEq(token.balanceOf(address(proxy)), 10 ether);
    }

    function test_ContributeForZeroBeneficiaryRejected() public {
        _upgrade();
        vm.expectRevert(ITripFund.ZeroAddress.selector);
        vm.prank(ALICE);
        v2.contributeFor(address(0), 1 ether);
        assertEq(v2.totalRaised(), 0);
        assertEq(v2.contributions(address(0)), 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
    }

    function test_ContributeForZeroAmountRejected() public {
        _upgrade();
        vm.expectRevert(ITripFund.ZeroAmount.selector);
        vm.prank(ALICE);
        v2.contributeFor(FRIEND, 0);
        assertEq(v2.totalRaised(), 0);
    }

    function test_ContributeForRequiresPayerAllowance() public {
        _upgrade();
        // Approval by the beneficiary does not authorize spending from the payer.
        vm.prank(FRIEND);
        token.approve(address(proxy), 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(proxy), 0, 10 ether)
        );
        vm.prank(ALICE);
        v2.contributeFor(FRIEND, 10 ether);
        assertEq(v2.totalRaised(), 0);
        assertEq(v2.contributions(FRIEND), 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(proxy)), 0);
    }

    function test_ApprovalToImplementationDoesNotAuthorizeProxy() public {
        _upgrade();
        vm.prank(ALICE);
        token.approve(address(implementationV2), 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(proxy), 0, 10 ether)
        );
        vm.prank(ALICE);
        v2.contributeFor(FRIEND, 10 ether);
        assertEq(v2.totalRaised(), 0);
    }

    function test_ContributeForInsufficientPayerBalanceRollsBack() public {
        _upgrade();
        vm.prank(ALICE);
        token.approve(address(proxy), INITIAL_BALANCE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, ALICE, INITIAL_BALANCE, INITIAL_BALANCE + 1
            )
        );
        vm.prank(ALICE);
        v2.contributeFor(FRIEND, INITIAL_BALANCE + 1);
        assertEq(v2.totalRaised(), 0);
        assertEq(v2.contributions(FRIEND), 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(proxy)), 0);
        assertEq(token.allowance(ALICE, address(proxy)), INITIAL_BALANCE + 1);
    }

    function test_ContributeForOneSecondBeforeDeadlineAndRejectAtDeadline() public {
        _upgrade();
        vm.warp(deadline - 1);
        _contributeFor(ALICE, FRIEND, 10 ether);
        vm.prank(ALICE);
        token.approve(address(proxy), 5 ether);
        vm.warp(deadline);
        vm.expectRevert(ITripFund.FundingClosed.selector);
        vm.prank(ALICE);
        v2.contributeFor(FRIEND, 5 ether);
        assertEq(v2.totalRaised(), 10 ether);
        assertEq(v2.contributions(FRIEND), 10 ether);
        assertEq(token.balanceOf(address(proxy)), 10 ether);
        assertEq(token.allowance(ALICE, address(proxy)), 5 ether);
    }

    function test_PayerCannotRefundGiftAndBeneficiaryCannotRefundTwice() public {
        _upgrade();
        _contributeFor(ALICE, FRIEND, 10 ether);
        vm.warp(deadline);
        vm.expectRevert(ITripFund.NoContribution.selector);
        vm.prank(ALICE);
        v2.refund();
        vm.prank(FRIEND);
        v2.refund();
        vm.expectRevert(ITripFund.NoContribution.selector);
        vm.prank(FRIEND);
        v2.refund();
        assertEq(token.balanceOf(FRIEND), 10 ether);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE - 10 ether);
        assertEq(v2.totalRaised(), 10 ether);
    }

    function test_ContributeForSelfAndOrdinaryContributionAccumulate() public {
        _contributeV1(ALICE, 10 ether);
        _upgrade();
        _contributeFor(ALICE, ALICE, 5 ether);
        vm.startPrank(ALICE);
        token.approve(address(proxy), 3 ether);
        v2.contribute(3 ether);
        vm.stopPrank();
        assertEq(v2.contributions(ALICE), 18 ether);
        assertEq(v2.totalRaised(), 18 ether);
        vm.warp(deadline);
        vm.prank(ALICE);
        v2.refund();
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
    }

    function test_ContributeForSuccessUsesOriginalWithdrawalRules() public {
        _contributeV1(ALICE, 40 ether);
        _upgrade();
        _contributeFor(BOB, FRIEND, 60 ether);
        vm.expectRevert(ITripFund.DeadlineNotReached.selector);
        vm.prank(ORGANIZER);
        v2.withdraw();
        vm.warp(deadline);
        vm.expectRevert(ITripFund.GoalReached.selector);
        vm.prank(FRIEND);
        v2.refund();
        vm.expectRevert(ITripFund.OnlyOrganizer.selector);
        vm.prank(FRIEND);
        v2.withdraw();
        vm.prank(ORGANIZER);
        v2.withdraw();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        assertEq(v2.totalRaised(), GOAL);
        vm.expectRevert(ITripFund.AlreadyWithdrawn.selector);
        vm.prank(ORGANIZER);
        v2.withdraw();
    }

    function test_DirectTokensStayAcrossUpgradeAndRefund() public {
        _contributeV1(ALICE, 10 ether);
        vm.prank(BOB);
        token.transfer(address(proxy), 100 ether);
        _upgrade();
        assertEq(v2.totalRaised(), 10 ether);
        assertEq(token.balanceOf(address(proxy)), 110 ether);
        _contributeFor(ALICE, FRIEND, 5 ether);
        vm.warp(deadline);
        vm.prank(ALICE);
        v2.refund();
        vm.prank(FRIEND);
        v2.refund();
        assertEq(token.balanceOf(address(proxy)), 100 ether);
        assertEq(v2.totalRaised(), 15 ether);
    }

    function testFuzz_GiftAlwaysRefundsBeneficiary(uint96 amount) public {
        _upgrade();
        uint256 gift = bound(uint256(amount), 1, GOAL - 1);
        _contributeFor(ALICE, FRIEND, gift);
        vm.warp(deadline);
        vm.prank(FRIEND);
        v2.refund();
        assertEq(token.balanceOf(FRIEND), gift);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE - gift);
        assertEq(token.balanceOf(address(proxy)), 0);
        assertEq(v2.contributions(FRIEND), 0);
        assertEq(v2.totalRaised(), gift);
    }
}

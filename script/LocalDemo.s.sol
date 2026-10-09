// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Entirely local simulation: no RPC, private keys or broadcast required.
contract LocalDemo is Script {
    function run() external {
        address alice = address(0xA11CE);
        address friend = address(0xF123);
        address organizer = address(0xC0FFEE);
        address adminOwner = address(0xAD);
        uint256 deadline = block.timestamp + 7 days;
        MockERC20 token = new MockERC20();
        token.mint(alice, 1_000 ether);

        address proxy = Upgrades.deployTransparentProxy(
            "TripFundV1.sol:TripFundV1",
            adminOwner,
            abi.encodeCall(TripFundV1.initialize, (IERC20(address(token)), organizer, 100 ether, deadline))
        );
        vm.startPrank(alice);
        token.approve(proxy, 10 ether);
        TripFundV1(proxy).contribute(10 ether);
        vm.stopPrank();

        Upgrades.upgradeProxy(proxy, "TripFundV2.sol:TripFundV2", "", adminOwner);
        TripFundV2 fund = TripFundV2(proxy);
        vm.startPrank(alice);
        token.approve(proxy, 5 ether);
        fund.contributeFor(friend, 5 ether);
        vm.stopPrank();
        require(fund.contributions(alice) == 10 ether, "V1 contribution lost");
        require(fund.totalRaised() == 15 ether, "Wrong totalRaised");

        vm.warp(deadline);
        vm.prank(friend);
        fund.refund();
        vm.prank(alice);
        fund.refund();
        require(token.balanceOf(friend) == 5 ether, "Friend did not receive refund");
        require(token.balanceOf(alice) == 995 ether, "Wrong payer balance");
        require(token.balanceOf(proxy) == 0, "Fund not empty");
        require(fund.totalRaised() == 15 ether, "Historical total changed");

        console2.log("Local V1 -> V2 demo passed");
        console2.log("Token", address(token));
        console2.log("Same proxy for V1 and V2", proxy);
        console2.log("Historical totalRaised", fund.totalRaised());
        console2.log("Friend received", token.balanceOf(friend));
    }
}

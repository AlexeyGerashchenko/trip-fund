// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TripFundV1} from "./TripFundV1.sol";

/// @notice V2 adds gifts without changing V1 storage or its initialization.
/// @custom:oz-upgrades-from TripFundV1
contract TripFundV2 is TripFundV1 {
    event ContributedFor(address indexed payer, address indexed beneficiary, uint256 amount);

    function contributeFor(address beneficiary, uint256 amount) external nonReentrant {
        _recordContribution(beneficiary, amount);
        // The helper above only updates storage; the token call follows the event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ContributedFor(msg.sender, beneficiary, amount);
        _collect(msg.sender, amount);
    }
}

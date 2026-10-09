// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockERC20} from "../../src/MockERC20.sol";

/// @dev Simulates ERC-20 false returns to verify SafeERC20 transaction rollback.
contract FailingToken is MockERC20 {
    bool public failTransfers;
    bool public failTransferFrom;

    function setFailTransfers(bool value) external {
        failTransfers = value;
    }

    function setFailTransferFrom(bool value) external {
        failTransferFrom = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransferFrom) return false;
        return super.transferFrom(from, to, amount);
    }
}

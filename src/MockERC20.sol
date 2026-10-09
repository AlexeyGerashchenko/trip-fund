// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Local test/demo token only: anyone may mint; no fees or rebasing.
contract MockERC20 is ERC20 {
    constructor() ERC20("Trip Token", "TRIP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

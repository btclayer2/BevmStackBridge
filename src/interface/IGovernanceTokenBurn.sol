// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

// Native: lock-mint-burn-unlock
interface IGovernanceTokenBurn {
    function burn(uint256 amount) external returns (bool);
}

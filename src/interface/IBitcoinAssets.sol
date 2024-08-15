// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

// Token: lock-mint-burn-unlock
interface IBitcoinAssets {
    function burnFrom(address account, uint256 amount) external;

    function protocol() external view returns (string memory);

    function balanceOf(address account) external view returns (uint256);
}

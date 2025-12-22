// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IWithdrawPrecompile {
    function withdrawBitcoinAssets(address, uint256, string memory) external;
    function withdrawGovToken(uint256, bytes32) external;
    function queryGovToken() external view returns (address);
    function queryCurrentFees() external view returns (uint64, uint64, uint64);
    function withdrawLightning(address, uint256, bytes memory) external returns (uint256);
    function estimateRent(address) external view returns (uint256, uint64);
    function rentSettings() external view returns (uint256, uint64);
}

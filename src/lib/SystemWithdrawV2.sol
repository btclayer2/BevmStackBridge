// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./IWithdrawPrecompile.sol";

library SystemWithdraw {
    /// address = 1027
    function precompile() internal pure returns (address) {
        return address(0x403);
    }

    /// Minimum withdrawal gas value in evm
    function MIN_TRANSFER_GAS_VALUE(uint8 gasDecimalsOnBitcoin) public pure returns (uint256) {
        // gasTokenDecimalsOnBitcoin = 8
        // defaultGasTokenDecimalsOnBevm = 18
        require(gasDecimalsOnBitcoin <= 18, "InvalidDecimals");
        return 10 ** (18 - gasDecimalsOnBitcoin);
    }

    function withdrawGasToken(uint8 gasDecimalsOnBitcoin, uint256 value, string calldata btcAddr)
        internal
        returns (uint256, uint256)
    {
        uint256 normalizedValue =
            (value / MIN_TRANSFER_GAS_VALUE(gasDecimalsOnBitcoin)) * MIN_TRANSFER_GAS_VALUE(gasDecimalsOnBitcoin);

        require(normalizedValue > 0, "Normalized gas is zero");

        (bool success, bytes memory returnData) = precompile().call(
            abi.encodePacked(
                IWithdrawPrecompile.withdrawBitcoinAssets.selector, address(0), normalizedValue, btcAddr
            )
        );
        require(success, string(returnData));

        require(returnData.length == 32, "Invalid returnData");
        uint256 id = abi.decode(returnData, (uint256));

        return (normalizedValue, id);
    }

    function withdrawErc20Token(address token, uint256 value, string calldata btcAddr) internal returns (uint256) {
        (bool success, bytes memory returnData) = precompile().call(
            abi.encodePacked(IWithdrawPrecompile.withdrawBitcoinAssets.selector, token, value, btcAddr)
        );

        require(success, string(returnData));

        require(returnData.length == 32, "Invalid returnData");
        uint256 id = abi.decode(returnData, (uint256));

        return id;
    }

    function withdrawGovToken(uint256 value, bytes32 substratePubkey) internal {
        (bool success, bytes memory returnData) = precompile().call(
            abi.encodePacked(IWithdrawPrecompile.withdrawGovToken.selector, value, substratePubkey)
        );

        require(success, string(returnData));
    }

    function governanceToken() internal view returns (address) {
        (, bytes memory returnData) =
            precompile().staticcall(abi.encodePacked(IWithdrawPrecompile.queryGovToken.selector));
        require(returnData.length == 32, "Invalid returnData");

        address govToken = abi.decode(returnData, (address));
        require(govToken != address(0), "GovToken not register");

        return govToken;
    }

    function withdrawBitcoinFees() internal view returns (uint256, uint256, uint256) {
        (, bytes memory returnData) =
            precompile().staticcall(abi.encodePacked(IWithdrawPrecompile.queryCurrentFees.selector));
        require(returnData.length == 96, "Invalid returnData");

        (uint256 withdrawBtcFee, uint256 withdrawBrc20Fee, uint256 withdrawRunesFee) =
            abi.decode(returnData, (uint64, uint64, uint64));

        return (withdrawBtcFee, withdrawBrc20Fee, withdrawRunesFee);
    }

    function withdrawLightning(uint8 gasDecimalsOnBitcoin, address sender, uint256 value) internal returns (uint256) {
        uint256 normalizedValue =
            (value / MIN_TRANSFER_GAS_VALUE(gasDecimalsOnBitcoin)) * MIN_TRANSFER_GAS_VALUE(gasDecimalsOnBitcoin);

        require(normalizedValue > 0, "Normalized gas is zero");

        (bool success, bytes memory returnData) = precompile().call(
            abi.encodePacked(IWithdrawPrecompile.withdrawLightning.selector, sender, normalizedValue)
        );

        require(success, string(returnData));

        return normalizedValue;
    }
}

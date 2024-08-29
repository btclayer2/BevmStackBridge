// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

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
        returns (bool, uint256, uint256)
    {
        uint256 normalizedValue =
            (value / MIN_TRANSFER_GAS_VALUE(gasDecimalsOnBitcoin)) * MIN_TRANSFER_GAS_VALUE(gasDecimalsOnBitcoin);

        require(normalizedValue > 0, "Normalized gas is zero");

        (bool success, bytes memory returnData) =
            precompile().call(abi.encodePacked(uint8(0), address(0), value, btcAddr));

        require(success, string(returnData));

        require(returnData.length == 32, "Invalid returnData");
        uint256 id = abi.decode(returnData, (uint256));

        return (success, normalizedValue, id);
    }

    function withdrawErc20Token(address token, uint256 value, string calldata btcAddr)
        internal
        returns (bool, uint256)
    {
        (bool success, bytes memory returnData) = precompile().call(abi.encodePacked(uint8(0), token, value, btcAddr));

        require(success, string(returnData));

        require(returnData.length == 32, "Invalid returnData");
        uint256 id = abi.decode(returnData, (uint256));

        return (success, id);
    }

    function withdrawGovToken(uint256 value, bytes32 substratePubkey) internal returns (bool) {
        (bool success, bytes memory returnData) = precompile().call(abi.encodePacked(uint8(1), value, substratePubkey));

        require(success, string(returnData));

        return success;
    }

    function governanceToken() internal returns (address) {
        (, bytes memory returnData) = precompile().call(abi.encodePacked(uint8(2)));
        require(returnData.length == 32, "Invalid returnData");

        address govToken = abi.decode(returnData, (address));
        require(govToken != address(0), "GovToken not register");

        return govToken;
    }

    function withdrawBitcoinFees() internal view returns (uint256, uint256, uint256) {
        (, bytes memory returnData) = precompile().staticcall(abi.encodePacked(uint8(3)));
        require(returnData.length == 96, "Invalid returnData");

        (uint256 withdrawBtcFee, uint256 withdrawBrc20Fee, uint256 withdrawRunesFee) =
            abi.decode(returnData, (uint64, uint64, uint64));

        return (withdrawBtcFee, withdrawBrc20Fee, withdrawRunesFee);
    }

    function withdrawBitcoinFee(address token) internal view returns (uint256) {
        // bytes4(keccak256(bytes("qureyFeeByToken(address)"))
        // 0x4f12a4be
        // bytes4 sig = 0x4f12a4be;

        // TODO: use abi.encodeWithSelector

        (, bytes memory returnData) = precompile().staticcall(abi.encodePacked(uint8(4), token));
        require(returnData.length == 32, "Invalid returnData");

        uint256 withdrawFee = abi.decode(returnData, (uint64));

        return withdrawFee;
    }
}

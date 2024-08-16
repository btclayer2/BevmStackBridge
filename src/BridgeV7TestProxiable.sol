// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interface/IBitcoinAssets.sol";
import "./interface/IGovernanceTokenBurn.sol";

import "./lib/SystemWithdraw.sol";
import "./lib/Types.sol";

// Bridge V7Test: 20240816
/// @custom:oz-upgrades-from BridgeV6Proxiable
contract BridgeV7TestProxiable is Initializable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    ////////////////////////////////
    // STATE VARIABLES OR STORAGE //
    ////////////////////////////////

    /// @custom:storage-location erc7201:openzeppelin.storage.BridgeV6

    struct BridgeV7Storage {
        // Gas type hash(keccak256("btc") or keccak256("brc20") or keccak256("runes"))
        bytes32 gasTypeHash; // 32 bytes (BridgeV7StorageLocation + 0)
        // Cold address: receive gasFee and external tokens
        address cold; // 20 bytes (BridgeV7StorageLocation + 1)
        uint8 gasDecimalsOnBitcoin; // 1 byte  (BridgeV7StorageLocation + 1)
        bool isV7Test; // 1 byte  (BridgeV7StorageLocation + 1)
        // Padding for alignment and to fill slot 1
        uint8[10] _padding; // 11 bytes (BridgeV7StorageLocation + 1)
        // Bitcoin assets withdraw nonce
        uint64 withdrawNonce; // 8 bytes (BridgeV7StorageLocation + 2)
        // Bitcoin assets deposit nonce
        uint64 depositNonce; // 8 bytes (BridgeV7StorageLocation + 2)
        // Governance and gas token withdraw nonce from evm to wasm
        uint64 wasmWithdrawNonce; // 8 bytes (BridgeV7StorageLocation + 2)
        // Governance and gas token deposit nonce from wasm to evm
        uint64 wasmDepositNonce; // 8 bytes (BridgeV7StorageLocation + 2)
        // Prepaid gas fee factor compare with btc
        GasFactor gasFactor; // 16 bytes (BridgeV7StorageLocation + 3)
        // Padding for alignment to fill slot 3
        uint128 _padding2; // 16 bytes (BridgeV7StorageLocation + 3)
        // Responsible for updating gas factor
        mapping(address => bool) gasGuarder; // (BridgeV7StorageLocation + 4)
        // bitcoin assets deposit records by deposit nonce
        mapping(uint64 => DepositRecordV3) recordsV3ByNonce; // (BridgeV7StorageLocation + 5)
        // bitcoin assets deposit records by deposit txid
        mapping(bytes32 => DepositRecordV3) recordsV3ByTxId; // (BridgeV7StorageLocation + 6)
        // governance and gas token deposit records by wasm deposit nonce
        mapping(uint64 => WasmDepositRecord) recordsWasm; // (BridgeV7StorageLocation + 7)
        // Reserving some storage slots allowing future versions of the proxy contract
        // to use up those slots without affecting the storage layout
        uint256[16] __gap; // (BridgeV7StorageLocation + 8) ... (BridgeV7StorageLocation + 23)
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.BridgeV6")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BridgeV7StorageLocation =
        0x84c29a0e22e621bfc9bf4684a2e0d2c54d2bdba6e47077cf5e8a1b3a7ffd9500;

    function _getBridgeV7Storage() private pure returns (BridgeV7Storage storage $) {
        assembly {
            $.slot := BridgeV7StorageLocation
        }
    }

    ///////////////
    /// EVENTS ///
    /////////////

    event DepositFromWasm(uint64 nonce, bool isGas, bytes32 from, uint256 amount, address to, uint32 blockNumber);

    // 0 is btc, other are runes/brc20.
    event DepositFromBitcoin(uint32 assetId, bytes32 reversedTxId, address account, uint256 value, uint256 blockNumber);

    event WithdrawGov(address from, uint256 amount, bytes32 to);

    event WithdrawGas(address sender, uint256 amount, uint256 withdrawId, uint256 FeeWith18Decimals, string receiver);

    event WithdrawOther(
        address sender, uint256 amount, uint256 withdrawId, uint256 FeeWith18Decimals, address token, string receiver
    );

    event PrepaidGasFee(PrepaidGasFeeInfo info);

    ///////////////////
    ///  MODIFIERS ///
    /////////////////

    modifier onlyGasGuarder() {
        BridgeV7Storage storage $ = _getBridgeV7Storage();
        require(owner() == _msgSender() || $.gasGuarder[_msgSender()], "caller is not the gas guarder");
        _;
    }

    modifier autoIncreaseWithdrawNonce() {
        BridgeV7Storage storage $ = _getBridgeV7Storage();
        $.withdrawNonce = $.withdrawNonce + 1;

        _;
    }

    modifier autoIncreaseDepositNonce() {
        BridgeV7Storage storage $ = _getBridgeV7Storage();
        $.depositNonce = $.depositNonce + 1;

        _;
    }

    modifier autoIncreaseWasmWithdrawNonce() {
        BridgeV7Storage storage $ = _getBridgeV7Storage();
        $.wasmWithdrawNonce = $.wasmWithdrawNonce + 1;

        _;
    }

    modifier autoIncreaseWasmDepositNonce() {
        BridgeV7Storage storage $ = _getBridgeV7Storage();
        $.wasmDepositNonce = $.wasmDepositNonce + 1;

        _;
    }

    ///////////////////
    ///  INITIALIZE ///
    ///////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Acts as our constructor
    function initialize(InitialParameters memory _init) public initializer {
        __Ownable_init(_init.owner);
        __Pausable_init();
        __UUPSUpgradeable_init();

        BridgeV7Storage storage $ = _getBridgeV7Storage();

        _setGasType($, _init.gasType);
        _setCold($, _init.cold);
        _setGasFactor($, _init.gasFactorMul, _init.gasFactorDiv);

        $.gasDecimalsOnBitcoin = _init.gasDecimalsOnBitcoin;
        $.withdrawNonce = _init.withdrawNonce;
        $.depositNonce = _init.depositNonce;
        $.wasmWithdrawNonce = _init.wasmWithdrawNonce;
        $.wasmDepositNonce = _init.wasmDepositNonce;
    }

    /// @dev Assist with upgradable proxy
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Call while Upgrading
    function reinitialize(string memory /*_network*/ ) public reinitializer(2) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();
        $.isV7Test = true;
    }

    fallback() external payable {
        // protection against accidental submissions by calling non-existent function
        revert("NOT_SUPPORT_FALLBACK");
    }

    receive() external payable {
        // protection against accidental submissions by calling non-existent function
        revert("NOT_SUPPORT_RECEIVE");
    }

    ///////////////////
    ///  EXTERNAL /////
    ///////////////////

    // deposit BitcoinAssets(bitcoin => bevm)
    function depositFromBitcoin(uint32 assetId, bytes32 reversedTxId, address account, uint256 value)
        external
        autoIncreaseDepositNonce
        returns (bool)
    {
        // only system call
        require(tx.origin == address(0x1111111111111111111111111111111111111111), "RequireSystem");

        BridgeV7Storage storage $ = _getBridgeV7Storage();
        uint64 currentDepositNonce = $.depositNonce;

        // deposit records v3

        $.recordsV3ByNonce[currentDepositNonce].assetId = assetId;
        $.recordsV3ByNonce[currentDepositNonce].nonce = currentDepositNonce;
        $.recordsV3ByNonce[currentDepositNonce].txId = reversedTxId;
        $.recordsV3ByNonce[currentDepositNonce].account = account;
        $.recordsV3ByNonce[currentDepositNonce].value = value;
        $.recordsV3ByNonce[currentDepositNonce].blockNumber = block.number;

        $.recordsV3ByTxId[reversedTxId].assetId = assetId;
        $.recordsV3ByTxId[reversedTxId].nonce = currentDepositNonce;
        $.recordsV3ByTxId[reversedTxId].txId = reversedTxId;
        $.recordsV3ByTxId[reversedTxId].account = account;
        $.recordsV3ByTxId[reversedTxId].value = value;
        $.recordsV3ByTxId[reversedTxId].blockNumber = block.number;

        emit DepositFromBitcoin(assetId, reversedTxId, account, value, block.number);

        return true;
    }

    // deposit governance and gas token(wasm => evm)
    function depositFromWasm(bool isGas, bytes32 from, uint256 value, address to, uint32 blockNumber)
        external
        autoIncreaseWasmDepositNonce
        returns (bool)
    {
        // only system call
        require(tx.origin == address(0x1111111111111111111111111111111111111111), "RequireSystem");

        BridgeV7Storage storage $ = _getBridgeV7Storage();
        uint64 currentWasmDepositNonce = $.wasmDepositNonce;

        $.recordsWasm[currentWasmDepositNonce].nonce = currentWasmDepositNonce;
        $.recordsWasm[currentWasmDepositNonce].isGas = isGas;
        $.recordsWasm[currentWasmDepositNonce].from = from;
        $.recordsWasm[currentWasmDepositNonce].value = value;
        $.recordsWasm[currentWasmDepositNonce].to = to;
        $.recordsWasm[currentWasmDepositNonce].blockNumber = blockNumber;

        emit DepositFromWasm(currentWasmDepositNonce, isGas, from, value, to, blockNumber);

        return true;
    }

    // Withdraw governance token(evm => wasm)
    function withdrawGov(uint256 value, bytes32 substratePubkey) external autoIncreaseWasmWithdrawNonce whenNotPaused {
        address govToken = SystemWithdraw.governanceToken();

        SafeERC20.safeTransferFrom(IERC20(govToken), msg.sender, address(this), value);

        // 1. burn governance token
        IGovernanceTokenBurn(govToken).burn(value);

        // 2. withdraw governance token
        SystemWithdraw.withdrawGovToken(value, substratePubkey);

        emit WithdrawGov(msg.sender, value, substratePubkey);
    }

    function withdrawToBitcoin(address token, uint256 amount, string calldata btcAddr)
        external
        payable
        autoIncreaseWithdrawNonce
        whenNotPaused
    {
        PrepaidGasFeeInfo memory info = prepaidGasFee(token, amount);
        require(keccak256(abi.encodePacked(info.result)) == keccak256(abi.encodePacked("success")), "PrepaidGasFeeFail");
        require(msg.value >= info.value, "ValueTooLow");

        if (info.coldAmount > 0) {
            safeTransferGas(cold(), info.coldAmount);
        }

        uint256 refundGas = msg.value - info.value;

        if (info.isGas) {
            (, uint256 actualValue, uint256 withdrawId) =
                SystemWithdraw.withdrawGasToken(gasDecimalsOnBitcoin(), info.wasmAmount, btcAddr);

            if (info.wasmAmount > actualValue) {
                uint256 dustGas = info.wasmAmount - actualValue;
                refundGas += dustGas;
            }

            emit WithdrawGas(msg.sender, actualValue, withdrawId, info.coldAmount, btcAddr);
        } else {
            IBitcoinAssets(token).burnFrom(msg.sender, info.wasmAmount);

            (, uint256 withdrawId) = SystemWithdraw.withdrawErc20Token(token, info.wasmAmount, btcAddr);

            emit WithdrawOther(msg.sender, amount, withdrawId, info.fee, token, btcAddr);
        }

        if (refundGas > 0) {
            safeTransferGas(msg.sender, refundGas);
        }

        emit PrepaidGasFee(info);
    }

    ///////////////
    ///  VIEW /////
    ///////////////

    // V7Test
    function isV7Test() public view returns (bool) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();
        return $.isV7Test;
    }

    function getInitializedVersion() public view returns (uint64) {
        return _getInitializedVersion();
    }

    // Current implement contract version
    function version() public pure returns (string memory) {
        return "7.0.0-test";
    }

    // Minimum btc dust
    function btcDust() public pure returns (uint256) {
        return 546;
    }

    function cold() public view returns (address) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        return $.cold;
    }

    function depositNonce() public view returns (uint64) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        return $.depositNonce;
    }

    function wasmDepositNonce() public view returns (uint64) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        return $.wasmDepositNonce;
    }

    function withdrawNonce() public view returns (uint64) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        return $.withdrawNonce;
    }

    function wasmWithdrawNonce() public view returns (uint64) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        return $.wasmWithdrawNonce;
    }

    function gasDecimalsOnBitcoin() public view returns (uint8) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        return $.gasDecimalsOnBitcoin;
    }

    function gasFactor() public view returns (GasFactor memory) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        return $.gasFactor;
    }

    function gasTypeHash() public view returns (bytes32) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        return $.gasTypeHash;
    }

    function gasGuarder(address account) public view returns (bool) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        return $.gasGuarder[account];
    }

    function recordsV3ByNonce(uint64 nonce) public view returns (DepositRecordV3 memory) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        return $.recordsV3ByNonce[nonce];
    }

    function recordsV3ByTxId(bytes32 txid) public view returns (DepositRecordV3 memory) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        return $.recordsV3ByTxId[txid];
    }

    function recordsWasm(uint64 nonce) public view returns (WasmDepositRecord memory) {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        return $.recordsWasm[nonce];
    }

    function prepaidGasFee(address token, uint256 amount) public view returns (PrepaidGasFeeInfo memory) {
        PrepaidGasFeeInfo memory info;
        info.token = token;
        info.amount = amount;
        info.result = "success";
        if (token == address(0)) {
            info.isGas = true;
        }

        // BTC amount, representing the estimated withdrawal fee
        (uint256 withdrawBtcFee, uint256 withdrawBrc20Fee, uint256 withdrawRunesFee) = currentBitcoinFees();

        bytes32 protocolHash;
        bytes32 CurrentGasTypeHash = gasTypeHash();
        if (info.isGas) {
            protocolHash = CurrentGasTypeHash;
        } else {
            try IBitcoinAssets(token).protocol() returns (string memory _protocol) {
                protocolHash = keccak256(bytes(_protocol));
            } catch {
                revert("protocol() method not implemented");
            }
        }

        GasFactor memory currentGasFactor = gasFactor();

        if (CurrentGasTypeHash == keccak256_btc()) {
            if (protocolHash == keccak256_btc()) {
                info.fee = withdrawBtcFee * 10 ** 10;
                info.feeType = "btc";
                info.value = amount;
                if (amount <= info.fee + btcDust() * 10 ** 10) {
                    info.result = "WithdrawAmountTooLow";
                } else {
                    info.estimateReceiveAmount = amount - info.fee;
                    info.wasmAmount = amount;
                }
            } else if (protocolHash == keccak256_brc20()) {
                info.fee = withdrawBrc20Fee * 10 ** 10;
                info.feeType = "btc";
                info.value = info.fee;
                info.estimateReceiveAmount = amount;
                info.coldAmount = info.fee;
                info.wasmAmount = amount;
            } else if (protocolHash == keccak256_runes()) {
                info.fee = withdrawRunesFee * 10 ** 10;
                info.feeType = "btc";
                info.value = info.fee;
                info.estimateReceiveAmount = amount;
                info.coldAmount = info.fee;
                info.wasmAmount = amount;
            } else {
                info.result = "NotSupportProtocol";
            }
        } else {
            if (protocolHash == keccak256_btc()) {
                // Decimal is 8
                info.fee = withdrawBtcFee;
                info.feeType = "btc";
                if (amount <= info.fee + btcDust()) {
                    info.result = "WithdrawAmountTooLow";
                } else {
                    info.estimateReceiveAmount = amount - info.fee;
                    info.wasmAmount = amount;
                }
            } else if (protocolHash == keccak256_brc20()) {
                if (info.isGas) {
                    info.fee = (withdrawBrc20Fee * 10 ** 10 * currentGasFactor.mul) / currentGasFactor.div;
                    info.feeType = "gas";
                    info.value = amount;
                    if (amount <= info.fee) {
                        info.result = "WithdrawAmountTooLow";
                    } else {
                        info.estimateReceiveAmount = amount - info.fee;
                        info.coldAmount = info.fee;
                        info.wasmAmount = amount - info.fee;
                    }
                } else {
                    info.fee = (withdrawBrc20Fee * 10 ** 10 * currentGasFactor.mul) / currentGasFactor.div;
                    info.feeType = "gas";
                    info.value = info.fee;
                    info.estimateReceiveAmount = amount;
                    info.coldAmount = info.fee;
                    info.wasmAmount = amount;
                }
            } else if (protocolHash == keccak256_runes()) {
                if (info.isGas) {
                    info.fee = (withdrawRunesFee * 10 ** 10 * currentGasFactor.mul) / currentGasFactor.div;
                    info.feeType = "gas";
                    info.value = amount;
                    if (amount <= info.fee) {
                        info.result = "WithdrawAmountTooLow";
                    } else {
                        info.estimateReceiveAmount = amount - info.fee;
                        info.coldAmount = info.fee;
                        info.wasmAmount = amount - info.fee;
                    }
                } else {
                    info.fee = (withdrawRunesFee * 10 ** 10 * currentGasFactor.mul) / currentGasFactor.div;
                    info.feeType = "gas";
                    info.value = info.fee;
                    info.estimateReceiveAmount = amount;
                    info.coldAmount = info.fee;
                    info.wasmAmount = amount;
                }
            } else {
                info.result = "NotSupportProtocol";
            }
        }

        return info;
    }

    function currentBitcoinFees() public view returns (uint256, uint256, uint256) {
        return SystemWithdraw.withdrawBitcoinFees();
    }

    ////////////////
    ///  MANAGE ////
    ////////////////

    function pause() external whenNotPaused onlyOwner {
        _pause();
    }

    function unpause() external whenPaused onlyOwner {
        _unpause();
    }

    function setCold(address newCold) public onlyOwner {
        BridgeV7Storage storage $ = _getBridgeV7Storage();
        _setCold($, newCold);
    }

    function setGasGuarder(address guarder, bool flag) public onlyOwner {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        $.gasGuarder[guarder] = flag;
    }

    function setGasFactor(uint64 newMul, uint64 newDiv) public onlyGasGuarder {
        BridgeV7Storage storage $ = _getBridgeV7Storage();

        _setGasFactor($, newMul, newDiv);
    }

    /////////////////
    ///  INTERNAL ///
    /////////////////

    function _setGasFactor(BridgeV7Storage storage $, uint64 newMul, uint64 newDiv) internal {
        require(newDiv > 0, "ZeroDiv");
        $.gasFactor = GasFactor(newMul, newDiv);
    }

    function _setCold(BridgeV7Storage storage $, address newCold) internal {
        require(newCold != address(0), "InvalidCold");
        $.cold = newCold;
    }

    function _setGasType(BridgeV7Storage storage $, string memory gasType) internal {
        bytes32 typeHash = keccak256(bytes(gasType));

        require(
            keccak256_btc() == typeHash || keccak256_brc20() == typeHash || keccak256_runes() == typeHash,
            "InvalidGasType"
        );

        $.gasTypeHash = typeHash;
    }

    function keccak256_btc() internal pure returns (bytes32) {
        // keccak256("btc") = 4bac7d8baf3f4f429951de9baff555c2f70564c6a43361e09971ef219908703d
        return hex"4bac7d8baf3f4f429951de9baff555c2f70564c6a43361e09971ef219908703d";
    }

    function keccak256_brc20() internal pure returns (bytes32) {
        // keccak256("brc20") = 3f51e27b8fbd083400c6a794e6d5c9c3cbfa4bff19fb1ce008e07b95227c20c8
        return hex"3f51e27b8fbd083400c6a794e6d5c9c3cbfa4bff19fb1ce008e07b95227c20c8";
    }

    function keccak256_runes() internal pure returns (bytes32) {
        // keccak256("runes") = 2f5f4d9de06ae2aa701cd56b3a26b2c5e729ce2620d83e44235cec73e7e37433
        return hex"2f5f4d9de06ae2aa701cd56b3a26b2c5e729ce2620d83e44235cec73e7e37433";
    }

    function safeTransferGas(address to, uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        uint256 oldBalance = to.balance;
        (bool sent,) = payable(to).call{value: amount}("");
        require(sent, "Failed to send gas");
        uint256 newBalance = to.balance;
        require(newBalance == oldBalance + amount, "Unexpected balance change");
    }
}

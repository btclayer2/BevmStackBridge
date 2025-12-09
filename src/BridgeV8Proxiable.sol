// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interface/IBitcoinAssets.sol";
import "./interface/IGovernanceTokenBurn.sol";

import "./lib/SystemWithdrawV2.sol";
import "./lib/Types.sol";

// Bridge V8: 20251209
contract BridgeV8Proxiable is Initializable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    ////////////////////////////////
    // STATE VARIABLES OR STORAGE //
    ////////////////////////////////

    /// @custom:storage-location erc7201:openzeppelin.storage.BridgeV6

    struct BridgeV6Storage {
        // Gas type hash(keccak256("btc") or keccak256("brc20") or keccak256("runes"))
        bytes32 gasTypeHash; // 32 bytes (BridgeV6StorageLocation + 0)
        // Cold address: receive gasFee and external tokens
        address cold; // 20 bytes (BridgeV6StorageLocation + 1)
        uint8 gasDecimalsOnBitcoin; // 1 byte  (BridgeV6StorageLocation + 1)
        // Padding for alignment and to fill slot 1
        uint8[11] _padding; // 11 bytes (BridgeV6StorageLocation + 1)
        // Bitcoin assets withdraw nonce
        uint64 withdrawNonce; // 8 bytes (BridgeV6StorageLocation + 2)
        // Bitcoin assets deposit nonce
        uint64 depositNonce; // 8 bytes (BridgeV6StorageLocation + 2)
        // Governance and gas token withdraw nonce from evm to wasm
        uint64 wasmWithdrawNonce; // 8 bytes (BridgeV6StorageLocation + 2)
        // Governance and gas token deposit nonce from wasm to evm
        uint64 wasmDepositNonce; // 8 bytes (BridgeV6StorageLocation + 2)
        // Prepaid gas fee factor compare with btc
        GasFactor gasFactor; // 16 bytes (BridgeV6StorageLocation + 3)
        // Padding for alignment to fill slot 3
        uint128 _padding2; // 16 bytes (BridgeV6StorageLocation + 3)
        // Responsible for updating gas factor
        mapping(address => bool) gasGuarder; // (BridgeV6StorageLocation + 4)
        // bitcoin assets deposit records by deposit nonce
        mapping(uint64 => DepositRecordV3) recordsV3ByNonce; // (BridgeV6StorageLocation + 5)
        // bitcoin assets deposit records by deposit txid
        mapping(bytes32 => DepositRecordV3) recordsV3ByTxId; // (BridgeV6StorageLocation + 6)
        // governance and gas token deposit records by wasm deposit nonce
        mapping(uint64 => WasmDepositRecord) recordsWasm; // (BridgeV6StorageLocation + 7)

        // Management fee start timestamp (2026-01-01 00:00:00 UTC)
        uint64 managementFeeStartTime; // 8 bytes (BridgeV6StorageLocation + 8)
        // Daily management fee in satoshis (10 satoshis)
        uint64 dailyManagementFee; // 8 bytes (BridgeV6StorageLocation + 8)
        uint128 _padding3; // 16 bytes (BridgeV6StorageLocation + 8)

        // Account management fee records
        mapping(address => AccountManagementFee) accountFees; // (BridgeV6StorageLocation + 9)

        // Reserving some storage slots allowing future versions of the proxy contract
        // to use up those slots without affecting the storage layout
        uint256[14] __gap; // (BridgeV6StorageLocation + 10) ... (BridgeV6StorageLocation + 23)
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.BridgeV6")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BridgeV6StorageLocation =
        0x84c29a0e22e621bfc9bf4684a2e0d2c54d2bdba6e47077cf5e8a1b3a7ffd9500;

    function _getBridgeV6Storage() private pure returns (BridgeV6Storage storage $) {
        assembly {
            $.slot := BridgeV6StorageLocation
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

    event WithdrawLightning(address sender, uint256 amount, uint256 withdrawId);

    event PrepaidGasFee(PrepaidGasFeeInfo info);

    event ManagementFeeDeducted(
        address indexed account,
        uint256 totalFee,
        uint64 feeDays,
        uint64 lastWithdrawTimestamp,
        uint64 newWithdrawTimestamp
    );

    event AccountFeeRecordUpdated(
        address indexed account,
        uint64 lastWithdrawTimestamp,
        uint256 accumulatedFee
    );

    ///////////////////
    ///  MODIFIERS ///
    /////////////////

    modifier onlyGasGuarder() {
        BridgeV6Storage storage $ = _getBridgeV6Storage();
        require(owner() == _msgSender() || $.gasGuarder[_msgSender()], "caller is not the gas guarder");
        _;
    }

    modifier autoIncreaseWithdrawNonce() {
        BridgeV6Storage storage $ = _getBridgeV6Storage();
        $.withdrawNonce = $.withdrawNonce + 1;

        _;
    }

    modifier autoIncreaseDepositNonce() {
        BridgeV6Storage storage $ = _getBridgeV6Storage();
        $.depositNonce = $.depositNonce + 1;

        _;
    }

    modifier autoIncreaseWasmWithdrawNonce() {
        BridgeV6Storage storage $ = _getBridgeV6Storage();
        $.wasmWithdrawNonce = $.wasmWithdrawNonce + 1;

        _;
    }

    modifier autoIncreaseWasmDepositNonce() {
        BridgeV6Storage storage $ = _getBridgeV6Storage();
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

        BridgeV6Storage storage $ = _getBridgeV6Storage();

        _setGasType($, _init.gasType);
        _setCold($, _init.cold);
        _setGasFactor($, _init.gasFactorMul, _init.gasFactorDiv);

        $.gasDecimalsOnBitcoin = _init.gasDecimalsOnBitcoin;
        $.withdrawNonce = _init.withdrawNonce;
        $.depositNonce = _init.depositNonce;
        $.wasmWithdrawNonce = _init.wasmWithdrawNonce;
        $.wasmDepositNonce = _init.wasmDepositNonce;

        // Initialize management fee storage
        _initializeManagementFee();
    }

    /// @dev Assist with upgradable proxy
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Call while Upgrading
    function reinitialize(string memory /*_network*/ ) public reinitializer(3) {
        // Initialize management fee storage
        _initializeManagementFee();
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

        BridgeV6Storage storage $ = _getBridgeV6Storage();
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

        BridgeV6Storage storage $ = _getBridgeV6Storage();
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
            // Still call _calculateAndDeductManagementFee to update account records and emit events
            _calculateAndDeductManagementFee(msg.sender, amount);

            (uint256 actualValue, uint256 withdrawId) =
                SystemWithdraw.withdrawGasToken(gasDecimalsOnBitcoin(), info.wasmAmount, btcAddr);

            if (info.wasmAmount > actualValue) {
                uint256 dustGas = info.wasmAmount - actualValue;
                refundGas += dustGas;
            }

            emit WithdrawGas(msg.sender, actualValue, withdrawId, info.coldAmount, btcAddr);
        } else {
            IBitcoinAssets(token).burnFrom(msg.sender, info.wasmAmount);

            uint256 withdrawId = SystemWithdraw.withdrawErc20Token(token, info.wasmAmount, btcAddr);

            emit WithdrawOther(msg.sender, amount, withdrawId, info.fee, token, btcAddr);
        }

        if (refundGas > 0) {
            safeTransferGas(msg.sender, refundGas);
        }

        emit PrepaidGasFee(info);
    }

    function withdrawToLightning(uint256 amount, string memory lightningInvoice)
        external
        payable
        autoIncreaseWithdrawNonce
        whenNotPaused
    {
        require(msg.value >= amount, "ValueTooLow");
        uint256 invoiceLen = bytes(lightningInvoice).length;
        require(invoiceLen > 0 && invoiceLen <= 512, "InvalidInvoice");

        uint256 refundGas = msg.value - amount;

        (uint256 actualValue, uint256 withdrawId) =
            SystemWithdraw.withdrawLightning(gasDecimalsOnBitcoin(), msg.sender, amount, bytes(lightningInvoice));

        if (amount > actualValue) {
            uint256 dustGas = amount - actualValue;
            refundGas += dustGas;
        }

        emit WithdrawLightning(msg.sender, amount, withdrawId);

        if (refundGas > 0) {
            safeTransferGas(msg.sender, refundGas);
        }
    }

    ///////////////
    ///  VIEW /////
    ///////////////

    // Current implement contract version
    function version() public pure returns (string memory) {
        return "8.0.0";
    }

    // Minimum btc dust
    function btcDust() public pure returns (uint256) {
        return 546;
    }

    function cold() public view returns (address) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        return $.cold;
    }

    function depositNonce() public view returns (uint64) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        return $.depositNonce;
    }

    function wasmDepositNonce() public view returns (uint64) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        return $.wasmDepositNonce;
    }

    function withdrawNonce() public view returns (uint64) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        return $.withdrawNonce;
    }

    function wasmWithdrawNonce() public view returns (uint64) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        return $.wasmWithdrawNonce;
    }

    function gasDecimalsOnBitcoin() public view returns (uint8) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        return $.gasDecimalsOnBitcoin;
    }

    function gasFactor() public view returns (GasFactor memory) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        return $.gasFactor;
    }

    function gasTypeHash() public view returns (bytes32) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        return $.gasTypeHash;
    }

    function gasGuarder(address account) public view returns (bool) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        return $.gasGuarder[account];
    }

    function recordsV3ByNonce(uint64 nonce) public view returns (DepositRecordV3 memory) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        return $.recordsV3ByNonce[nonce];
    }

    function recordsV3ByTxId(bytes32 txid) public view returns (DepositRecordV3 memory) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        return $.recordsV3ByTxId[txid];
    }

    function recordsWasm(uint64 nonce) public view returns (WasmDepositRecord memory) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

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

                // Handle management fee

                uint64 currentTime = uint64(block.timestamp);
                BridgeV6Storage storage $ = _getBridgeV6Storage();

                // Check if current time is after management fee start time
                if (currentTime >= $.managementFeeStartTime) {
                    AccountManagementFee storage accountFee = $.accountFees[msg.sender];

                    // Calculate days since last withdrawal or since fee start time
                    uint64 lastTimestamp = accountFee.lastWithdrawTimestamp;
                    if (lastTimestamp == 0) {
                        // First withdrawal, use fee start time
                        lastTimestamp = $.managementFeeStartTime;
                    }

                    // Calculate number of days to charge fee for
                    uint64 feeDays = (currentTime - lastTimestamp) / 86400; // 86400 seconds = 1 day

                    if (feeDays > 0) {
                        // Calculate total management fee (feeDays * daily fee in satoshis)
                        uint256 totalManagementFee = uint256(feeDays) * uint256($.dailyManagementFee);

                        // Convert to 18 decimals
                        uint256 managementFeeIn18Decimals = totalManagementFee * 10**10;

                        // Deduct management fee from estimateReceiveAmount and wasmAmount
                        if (info.estimateReceiveAmount >= managementFeeIn18Decimals) {
                            info.estimateReceiveAmount = info.estimateReceiveAmount - managementFeeIn18Decimals;
                            info.wasmAmount = info.wasmAmount - managementFeeIn18Decimals;
                        } else {
                            // Management fee would make estimateReceiveAmount negative
                            info.result = "InsufficientAmountForManagementFee";
                        }
                    }
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
        BridgeV6Storage storage $ = _getBridgeV6Storage();
        _setCold($, newCold);
    }

    function setGasGuarder(address guarder, bool flag) public onlyOwner {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        $.gasGuarder[guarder] = flag;
    }

    function setGasFactor(uint64 newMul, uint64 newDiv) public onlyGasGuarder {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        _setGasFactor($, newMul, newDiv);
    }

    /////////////////
    ///  INTERNAL ///
    /////////////////

    function _setGasFactor(BridgeV6Storage storage $, uint64 newMul, uint64 newDiv) internal {
        require(newDiv > 0, "ZeroDiv");
        $.gasFactor = GasFactor(newMul, newDiv);
    }

    function _setCold(BridgeV6Storage storage $, address newCold) internal {
        require(newCold != address(0), "InvalidCold");
        $.cold = newCold;
    }

    function _setGasType(BridgeV6Storage storage $, string memory gasType) internal {
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

    ////////////////
    // MANAGEMENT FEE FUNCTIONS //
    ////////////////

    /**
     * @dev Initialize management fee settings
     */
    function _initializeManagementFee() internal {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        // Set management fee start time to 2026-01-01 00:00:00 UTC (timestamp: 1767225600)
        $.managementFeeStartTime = 1767225600;

        // Set daily management fee to 10 satoshis
        $.dailyManagementFee = 10;
    }

    /**
     * @dev Calculate and deduct management fee for an account
     * @param account The account address
     * @param amount The withdrawal amount
     */
    function _calculateAndDeductManagementFee(address account, uint256 amount)
        internal
    {
        BridgeV6Storage storage $ = _getBridgeV6Storage();

        uint64 currentTime = uint64(block.timestamp);
        // Check if current time is after management fee start time
        if (currentTime >= $.managementFeeStartTime) {
            AccountManagementFee storage accountFee = $.accountFees[account];

            // Calculate days since last withdrawal or since fee start time
            uint64 lastTimestamp = accountFee.lastWithdrawTimestamp;
            if (lastTimestamp == 0) {
                // First withdrawal, use fee start time
                lastTimestamp = $.managementFeeStartTime;
            }

            // Calculate number of days to charge fee for
            uint64 feeDays = (currentTime - lastTimestamp) / 86400; // 86400 seconds = 1 day

            // Calculate total fee (feeDays * daily fee in satoshis)
            uint256 totalFee = uint256(feeDays) * uint256($.dailyManagementFee);

            // Convert fee to the same decimals as the withdrawal amount
            // Assuming amount is in 18 decimals and fee is in satoshis (8 decimals)
            uint256 feeIn18Decimals = totalFee * 10**10;

            // REVERT if fee exceeds withdrawal amount - don't confiscate user funds
            require(feeIn18Decimals <= amount, "InsufficientAmountForManagementFee");

            // Update account fee record
            accountFee.lastWithdrawTimestamp = currentTime;
            accountFee.accumulatedFee += feeIn18Decimals;

            // Emit events
            emit ManagementFeeDeducted(
                account,
                feeIn18Decimals,
                feeDays,
                lastTimestamp,
                currentTime
            );

            emit AccountFeeRecordUpdated(
                account,
                currentTime,
                accountFee.accumulatedFee
            );
        }
    }

    /**
     * @dev Get management fee info for an account
     * @param account The account address
     * @return AccountManagementFee The account's fee record
     */
    function getAccountManagementFee(address account) external view returns (AccountManagementFee memory) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();
        return $.accountFees[account];
    }

    /**
     * @dev Get management fee settings
     * @return startTime Management fee start timestamp
     * @return dailyFee Daily management fee in satoshis
     */
    function getManagementFeeSettings() external view returns (uint64 startTime, uint64 dailyFee) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();
        return ($.managementFeeStartTime, $.dailyManagementFee);
    }

    /**
     * @dev Calculate estimated management fee for an account
     * @param account The account address
     * @return estimatedFee Estimated fee in 18 decimals
     * @return feeDays Number of days to be charged
     */
    function estimateManagementFee(address account) external view returns (uint256 estimatedFee, uint64 feeDays) {
        BridgeV6Storage storage $ = _getBridgeV6Storage();
        AccountManagementFee storage accountFee = $.accountFees[account];

        uint64 currentTime = uint64(block.timestamp);

        if (currentTime < $.managementFeeStartTime) {
            return (0, 0);
        }

        uint64 lastTimestamp = accountFee.lastWithdrawTimestamp;
        if (lastTimestamp == 0) {
            lastTimestamp = $.managementFeeStartTime;
        }

        feeDays = (currentTime - lastTimestamp) / 86400;

        if (feeDays == 0) {
            return (0, 0);
        }

        uint256 totalFee = uint256(feeDays) * uint256($.dailyManagementFee);
        estimatedFee = totalFee * 10**10; // Convert to 18 decimals
    }
}

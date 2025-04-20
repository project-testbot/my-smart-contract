// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

interface IFlashLoanProvider {
    function flashLoan(
        address receiver,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory params
    ) external;
}

contract ArbitrageCore {
    using SafeMath for uint256;

    // Owner of the contract, for configuration
    address public owner;

    // Chain-specific configurations
    struct ChainConfig {
        address flashLoanProvider;
        uint256 maxGasForTrade; // Maximum gas allowed for an arbitrage trade on this chain
    }
    mapping(uint256 => ChainConfig) public chainConfigs; // Chain ID => Config

    // Price crash safeguard parameters
    uint256 public ethPriceDropThreshold = 5; // Percentage drop
    uint256 public assetPriceDropThreshold = 10; // Percentage drop
    uint256 public priceCheckInterval = 300; // Seconds (5 minutes)
    mapping(address => uint256) public lastCheckedPrice;
    mapping(address => uint256) public previousPrice;
    bool public tradingFrozen = false;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ChainConfigSet(uint256 chainId, address flashLoanProvider, uint256 maxGasForTrade);
    event PriceChecked(address asset, uint256 currentPrice);
    event TradingFrozen(string reason);
    event TradingUnfrozen();

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function.");
        _;
    }

    modifier ensureTradingIsNotFrozen() {
        require(!tradingFrozen, "Trading is currently frozen.");
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), owner);
    }

    function setChainConfig(uint256 _chainId, address _flashLoanProvider, uint256 _maxGasForTrade) external onlyOwner {
        chainConfigs[_chainId] = ChainConfig(_flashLoanProvider, _maxGasForTrade);
        emit ChainConfigSet(_chainId, _flashLoanProvider, _maxGasForTrade);
    }

    function getChainConfig(uint256 _chainId) external view returns (ChainConfig memory) {
        return chainConfigs[_chainId];
    }

    // Placeholder for fetching current price (will need integration with oracles)
    function getCurrentPrice(address _asset) internal pure returns (uint256) {
        // In Phase 1, we'll likely use mocked price feeds in testing.
        // For mainnet, Chainlink or other oracles will be crucial.
        // This is a placeholder for now.
        if (_asset == address(0)) { // Placeholder for ETH
            return 2000 * 10**18; // Example price: $2000
        } else if (_asset == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) { // USDC
            return 1 * 10**6; // Example price: $1
        }
        return 0; // Default to 0 if price not available
    }

    function checkPriceFluctuations() internal {
        // Check ETH price
        uint256 currentEthPrice = getCurrentPrice(address(0));
        if (lastCheckedPrice[address(0)] != 0 && block.timestamp > lastCheckedPrice[address(0)].add(priceCheckInterval)) {
            uint256 priceChange = 0;
            if (previousPrice[address(0)] > 0) {
                priceChange = (previousPrice[address(0)].sub(currentEthPrice)).mul(100).div(previousPrice[address(0)]);
                if (priceChange > ethPriceDropThreshold) {
                    freezeTrading("ETH price dropped significantly.");
                }
            }
            previousPrice[address(0)] = currentEthPrice;
            lastCheckedPrice[address(0)] = block.timestamp;
            emit PriceChecked(address(0), currentEthPrice);
        } else if (lastCheckedPrice[address(0)] == 0) {
            previousPrice[address(0)] = currentEthPrice;
            lastCheckedPrice[address(0)] = block.timestamp;
            emit PriceChecked(address(0), currentEthPrice);
        }

        // Add similar checks for other critical assets (e.g., WBTC) as needed.
        // For simplicity in this initial contract, we'll focus on ETH.
    }

    function freezeTrading(string memory reason) internal onlyOwner {
        tradingFrozen = true;
        emit TradingFrozen(reason);
    }

    function unfreezeTrading() external onlyOwner {
        tradingFrozen = false;
        emit TradingUnfrozen();
    }

    // --- Flash Loan Integration ---
    function executeArbitrage(
        address[] memory _tokensToBorrow,
        uint256[] memory _borrowAmounts,
        bytes memory _arbitrageData // Encoded data for the specific arbitrage strategy
    ) external payable ensureTradingIsNotFrozen {
        uint256 chainId = block.chainid;
        require(chainConfigs[chainId].flashLoanProvider != address(0), "Flash loan provider not configured for this chain.");
        require(gasleft() > chainConfigs[chainId].maxGasForTrade, "Gas left is below the maximum allowed for trade.");

        IFlashLoanProvider(chainConfigs[chainId].flashLoanProvider).flashLoan(
            address(this),
            _tokensToBorrow,
            _borrowAmounts,
            _arbitrageData
        );

        // The execution of the arbitrage trade (swaps, etc.) will happen in the
        // `flashLoan` callback. This contract needs to implement a function
        // that the flash loan provider will call.
    }

    // This function will be called by the flash loan provider after the loan.
    // It's crucial to repay the loan and handle the arbitrage logic here.
    function flashLoanCallback(
        address _borrower,
        address[] memory /* _tokens */,
        uint256[] memory /* _amounts */,
        uint256 /* _fee */,
        bytes memory /* _params */
    ) external {
        require(msg.sender == chainConfigs[block.chainid].flashLoanProvider, "Only flash loan provider can call this.");
        require(_borrower == address(this), "Callback not for this contract.");

        // --- ARBITRAGE LOGIC GOES HERE ---
        // 1. Execute the arbitrage trades using the borrowed funds.
        // 2. Calculate profit.
        // 3. Repay the flash loan (_amounts + _fee).
        // 4. Transfer any remaining profit.

        // Placeholder for now:
        // require(false, "Arbitrage logic not implemented yet.");
    }

    // Function to receive ETH if needed (e.g., for gas on other chains - though no bridging in Phase 1)
    receive() external payable {}
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IAaveLendingPool {
    function flashLoan(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IUniswapV2Router {
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

contract MEVArbitrageBot is Ownable, ReentrancyGuard {
    // Network Configs
    enum Network { ETHEREUM, POLYGON, BASE }
    enum DEX { UNISWAP, SUSHI }
    
    Network public currentNetwork;
    DEX public preferredDEX = DEX.UNISWAP;

    // Security Parameters
    uint256 public slippageTolerance = 50; // 0.5%
    uint256 public maxGasPercent = 30; // Max gas as % of profit
    uint256 public lastExecutionTime;
    uint256 public constant HEARTBEAT_DURATION = 1 hours;
    uint256 public constant PRICE_DROP_THRESHOLD = 10; // 10% drop triggers pause

    // Addresses (Sepolia)
    address public immutable WETH;
    address public immutable USDC;
    address public immutable UNISWAP_ROUTER;
    address public immutable SUSHI_ROUTER;
    address public immutable AAVE_LENDING_POOL;
    address public immutable PRICE_FEED;

    // State
    bool public isPaused;
    uint256 public failedTrades;
    int256 private lastPrice;

    // Events
    event ArbitrageExecuted(Network network, DEX dex, uint256 profit);
    event NetworkSkipped(Network network, string reason);
    event BotHalted(string reason);

    constructor(
        address _weth,
        address _usdc,
        address _uniswapRouter,
        address _sushiRouter,
        address _aavePool,
        address _priceFeed
    ) Ownable(msg.sender) {
        WETH = _weth;
        USDC = _usdc;
        UNISWAP_ROUTER = _uniswapRouter;
        SUSHI_ROUTER = _sushiRouter;
        AAVE_LENDING_POOL = _aavePool;
        PRICE_FEED = _priceFeed;
        currentNetwork = Network.ETHEREUM;
        lastPrice = _getLatestPrice();
    }

    // ================= CORE EXECUTION ================= //
    function executeNetworkArbitrage(Network targetNetwork) external onlyOwner nonReentrant {
        require(!isPaused, "Bot paused");
        _checkMarketConditions();
        
        currentNetwork = targetNetwork;
        
        if (!_isNetworkReady()) {
            emit NetworkSkipped(targetNetwork, "Unfavorable conditions");
            return;
        }

        uint256 expectedProfit = _calculateMaxProfit();
        if (expectedProfit == 0) {
            emit NetworkSkipped(targetNetwork, "No profitable arb");
            return;
        }

        _executeHydraArbitrage(expectedProfit);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external nonReentrant returns (bool) {
        require(msg.sender == AAVE_LENDING_POOL, "Unauthorized");
        require(initiator == address(this), "Invalid initiator");

        uint256 minProfit = abi.decode(params, (uint256));
        uint256 preBalance = IERC20(USDC).balanceOf(address(this));
        
        _performBestArbitrage();
        
        uint256 actualProfit = IERC20(USDC).balanceOf(address(this)) - preBalance;
        if (actualProfit < minProfit) {
            _handleFailedTrade();
            revert("Arb failed");
        }

        IERC20(assets[0]).approve(AAVE_LENDING_POOL, amounts[0] + premiums[0]);
        emit ArbitrageExecuted(currentNetwork, preferredDEX, actualProfit);
        return true;
    }

    // ================= HYDRALOGIC ================= //
    function _isNetworkReady() internal view returns (bool) {
        if (tx.gasprice > block.basefee * 2) return false;
        if (_getPriceChange() < -int256(PRICE_DROP_THRESHOLD)) return false;
        return true;
    }

    function _calculateMaxProfit() internal view returns (uint256) {
        (uint256 uniProfit, uint256 sushiProfit) = _compareDexProfits();
        uint256 maxProfit = uniProfit > sushiProfit ? uniProfit : sushiProfit;
        
        if (maxProfit == 0 || tx.gasprice * gasleft() > maxProfit * maxGasPercent / 100) {
            return 0;
        }
        return maxProfit;
    }

    function _executeHydraArbitrage(uint256 minProfit) internal {
        address[] memory assets = new address[](1);
        assets[0] = WETH;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _getOptimalLoanAmount();

        IAaveLendingPool(AAVE_LENDING_POOL).flashLoan(
            address(this),
            assets,
            amounts,
            new uint256[](1),
            address(this),
            abi.encode(minProfit),
            0
        );
    }

    // ================= ARBITRAGE ENGINE ================= //
    function _compareDexProfits() internal view returns (uint256 uniProfit, uint256 sushiProfit) {
        uint256 amount = 1 ether; // Base calculation amount
        uniProfit = _simulateDexArbitrage(DEX.UNISWAP, amount);
        sushiProfit = _simulateDexArbitrage(DEX.SUSHI, amount);
    }

    function _simulateDexArbitrage(DEX dex, uint256 amountIn) internal view returns (uint256 profit) {
        address router = dex == DEX.UNISWAP ? UNISWAP_ROUTER : SUSHI_ROUTER;
        
        address[] memory path1 = new address[](2);
        path1[0] = WETH;
        path1[1] = USDC;
        
        address[] memory path2 = new address[](2);
        path2[0] = USDC;
        path2[1] = WETH;
        
        try IUniswapV2Router(router).getAmountsOut(amountIn, path1) returns (uint[] memory amounts) {
            uint256 usdcOut = amounts[1];
            uint[] memory amounts2 = IUniswapV2Router(router).getAmountsOut(usdcOut, path2);
            profit = amounts2[1] - amountIn;
        } catch {
            profit = 0;
        }
    }

    function _performBestArbitrage() internal {
        (uint256 uniProfit, uint256 sushiProfit) = _compareDexProfits();
        uint256 amount = IERC20(WETH).balanceOf(address(this));
        
        if (uniProfit >= sushiProfit) {
            preferredDEX = DEX.UNISWAP;
            _executeSwap(DEX.UNISWAP, amount);
        } else {
            preferredDEX = DEX.SUSHI;
            _executeSwap(DEX.SUSHI, amount);
        }
    }

    // ================= SAFETY SYSTEMS ================= //
    function _checkMarketConditions() internal {
        int256 priceChange = _getPriceChange();
        if (priceChange < -int256(PRICE_DROP_THRESHOLD)) {
            isPaused = true;
            emit BotHalted("Market crash detected");
            revert("Market conditions unsafe");
        }
    }

    function _handleFailedTrade() internal {
        failedTrades++;
        if (failedTrades >= 3) {
            isPaused = true;
            emit BotHalted("3 consecutive failures");
        }
    }

    // ================= UTILITIES ================= //
    function _getLatestPrice() internal view returns (int256) {
        (, int256 price,,,) = AggregatorV3Interface(PRICE_FEED).latestRoundData();
        return price;
    }

    function _getPriceChange() internal view returns (int256) {
        int256 currentPrice = _getLatestPrice();
        return ((currentPrice - lastPrice) * 100) / lastPrice;
    }

    function _getOptimalLoanAmount() internal pure returns (uint256) {
        // Simplified - should be based on available liquidity
        return 1 ether; 
    }

    function _executeSwap(DEX dex, uint256 amountIn) internal {
        address router = dex == DEX.UNISWAP ? UNISWAP_ROUTER : SUSHI_ROUTER;
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        IERC20(WETH).approve(router, amountIn);
        IUniswapV2Router(router).swapExactTokensForTokens(
            amountIn,
            _calculateMinOutput(amountIn),
            path,
            address(this),
            block.timestamp + 300
        );
    }

    function _calculateMinOutput(uint256 amount) internal view returns (uint256) {
        return (amount * (10000 - slippageTolerance)) / 10000;
    }
}

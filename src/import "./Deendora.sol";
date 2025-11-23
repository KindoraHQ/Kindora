// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./Deendora.sol";

/// Kindora (KNR) — ERC20 with buy/sell fees, auto-liquidity and charity forwarding.
/// Audit-ready A+ cleanup:
/// - Trading gate enforced (starts OFF; owner enables at launch).
/// - Fees are immutable (no setters).
/// - Fee-exclusion management is available prelaunch and lockable forever.
/// - Manual liquidity LP is locked to DEAD.
/// - Removed unused "feesLocked" state (since no fee setters).

contract Kindora is ERC20, Ownable, ReentrancyLite {

    // BSC mainnet Pancake V2
    address public constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant WBNB_MAINNET   = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant FACTORY_V2     = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address public constant DEAD           = 0x000000000000000000000000000000000000dEaD;

    IUniswapV2Router02 public immutable uniswapV2Router;
    address public immutable uniswapV2Pair;

    address payable public charityWallet;
    address public multisig;

    bool public tradingActive; // starts false
    bool public limitsInEffect = false;
    uint256 public maxTransactionAmount;
    uint256 public maxWallet;

    uint256 public swapTokensAtAmount;

    struct FeeSet { uint16 charity; uint16 burn; uint16 liq; }
    FeeSet public buyFees;
    FeeSet public sellFees;
    uint16 public buyTotalFees;
    uint16 public sellTotalFees;

    bool public feeExclusionsLocked;
    bool public charityWalletLocked;
    bool public maxTxExclusionsLocked;
    bool public rescuesLocked;
    bool public swapEnabled = true;

    // internal tracking of tokens assigned for charity & liquidity
    uint256 private tokensForCharity;
    uint256 private tokensForLiquidity;
    uint256 private pendingEthForCharity;
    bool private swapping;

    mapping(address => bool) public automatedMarketMakerPairs;
    mapping(address => bool) private _isExcludedFromFees;
    mapping(address => bool) private _isExcludedMaxTransactionAmount;

    // Events
    event TradingEnabled(uint256 timestamp, address indexed operator);
    event FeeExclusionsLocked();
    event CharityWalletLocked();
    event MaxTxExclusionsLocked();
    event RescuesLocked();
    event SwapEnabledUpdated(bool enabled);
    event SetAutomatedMarketMakerPair(address pair, bool value);
    event AutoLiquify(uint256 tokenAmount, uint256 ethAmount);
    event SwapBack(uint256 tokensSwapped, uint256 ethReceived);
    event SwapBackDetailed(uint256 tokensProcessed, uint256 liqTokens, uint256 ethForLiq, uint256 ethForCharity);
    event ExcludeFromFees(address indexed account, bool excluded);
    event PendingCharityUpdated(uint256 pending);
    event MultisigUpdated(address indexed newMultisig);

    constructor() ERC20("Kindora", "KNR") {
        uint256 total = 1_000_000 * 1e18;
        _mint(_msgSender(), total);

        // 3% charity, 1% burn, 1% liquidity (denominator 1000)
        buyFees = FeeSet(30, 10, 10);
        sellFees = FeeSet(30, 10, 10);
        buyTotalFees  = 50;
        sellTotalFees = 50;

        maxTransactionAmount = (total * 2) / 100;   // 2%
        maxWallet            = (total * 2) / 100;   // 2%
        swapTokensAtAmount   = (total * 5) / 10000; // 0.05%

        charityWallet = payable(0x0Fbf5f23E61cCa3A4590A4E2503573Ee10fB5974);

        IUniswapV2Router02 _router = IUniswapV2Router02(PANCAKE_ROUTER);
        require(_router.WETH() == WBNB_MAINNET, "WBNB mismatch");
        require(_router.factory() == FACTORY_V2, "Factory mismatch");
        uniswapV2Router = _router;

        address _pair = IUniswapV2Factory(_router.factory()).createPair(address(this), _router.WETH());
        uniswapV2Pair = _pair;
        _setAutomatedMarketMakerPair(_pair, true);

        // Fee exemptions: owner, charity, contract, DEAD
        _excludeFromFeesInternal(owner(), true);
        _excludeFromFeesInternal(charityWallet, true);
        _excludeFromFeesInternal(address(this), true);
        _excludeFromFeesInternal(DEAD, true);

        // max-tx exemptions
        _isExcludedMaxTransactionAmount[owner()] = true;
        _isExcludedMaxTransactionAmount[address(this)] = true;
        _isExcludedMaxTransactionAmount[DEAD] = true;
        _isExcludedMaxTransactionAmount[_pair] = true;
        _isExcludedMaxTransactionAmount[address(_router)] = true;

        // trading starts OFF; fee exclusions NOT locked yet
        tradingActive = false;
        feeExclusionsLocked = false;
    }

    // ============== Internal helpers ==============

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        automatedMarketMakerPairs[pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function _excludeFromFeesInternal(address account, bool excluded) private {
        _isExcludedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    // ============== View helpers ==============

    function isExcludedFromFees(address account) external view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function getTokensForCharity() external view returns (uint256) { return tokensForCharity; }
    function getTokensForLiquidity() external view returns (uint256) { return tokensForLiquidity; }
    function getPendingEthForCharity() external view returns (uint256) { return pendingEthForCharity; }

    function getFeeInfo()
        external
        view
        returns (
            uint16 buyCharity,
            uint16 buyBurn,
            uint16 buyLiq,
            uint16 buyTotal,
            uint16 sellCharity,
            uint16 sellBurn,
            uint16 sellLiq,
            uint16 sellTotal,
            uint16 denominator
        )
    {
        return (
            buyFees.charity,
            buyFees.burn,
            buyFees.liq,
            buyTotalFees,
            sellFees.charity,
            sellFees.burn,
            sellFees.liq,
            sellTotalFees,
            1000
        );
    }

    function getFeePercents()
        external
        view
        returns (
            uint8 buyCharityPercent,
            uint8 buyBurnPercent,
            uint8 buyLiqPercent,
            uint8 buyTotalPercent,
            uint8 sellCharityPercent,
            uint8 sellBurnPercent,
            uint8 sellLiqPercent,
            uint8 sellTotalPercent
        )
    {
        buyCharityPercent  = uint8(buyFees.charity / 10);
        buyBurnPercent     = uint8(buyFees.burn / 10);
        buyLiqPercent      = uint8(buyFees.liq / 10);
        buyTotalPercent    = uint8(buyTotalFees / 10);

        sellCharityPercent = uint8(sellFees.charity / 10);
        sellBurnPercent    = uint8(sellFees.burn / 10);
        sellLiqPercent     = uint8(sellFees.liq / 10);
        sellTotalPercent   = uint8(sellTotalFees / 10);
    }

    // ============== Owner functions ==============

    function enableTrading() external onlyOwner {
        require(!tradingActive, "Trading already enabled");
        tradingActive = true;
        emit TradingEnabled(block.timestamp, msg.sender);
    }

    function setAutomatedMarketMakerPair(address pair, bool value) external onlyOwner {
        require(!tradingActive, "cannot change amm pairs after trading enabled");
        require(pair != address(0), "pair=0");
        _setAutomatedMarketMakerPair(pair, value);
        if (value) {
            _isExcludedMaxTransactionAmount[pair] = true;
        }
    }

    function setLimitsInEffect(bool enabled) external onlyOwner {
        require(!tradingActive, "cannot change limits after trading enabled");
        limitsInEffect = enabled;
    }

    function setSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
        emit SwapEnabledUpdated(enabled);
    }

    function setMultisig(address newMultisig) external onlyOwner {
        multisig = newMultisig;
        emit MultisigUpdated(newMultisig);
    }

    function setCharityWallet(address payable newWallet) external onlyOwner {
        require(!charityWalletLocked, "charity wallet locked");
        require(newWallet != address(0), "charity=0");

        charityWallet = newWallet;

        if (!_isExcludedFromFees[newWallet] && !feeExclusionsLocked) {
            _excludeFromFeesInternal(newWallet, true);
        }
    }

    function excludeFromFees(address account, bool excluded) external onlyOwner {
        require(!feeExclusionsLocked, "fee exclusions locked");
        _excludeFromFeesInternal(account, excluded);
    }

    function lockFeeExclusions() external onlyOwner {
        require(!feeExclusionsLocked, "already locked");
        feeExclusionsLocked = true;
        emit FeeExclusionsLocked();
    }

    function excludeFromMaxTransaction(address account, bool excluded) public onlyOwner {
        require(!maxTxExclusionsLocked, "max-tx exclusions locked");
        require(!tradingActive, "max-tx exclusions locked after trading enabled");
        _isExcludedMaxTransactionAmount[account] = excluded;
    }

    function lockCharityWallet() external onlyOwner {
        require(!charityWalletLocked, "already locked");
        charityWalletLocked = true;
        emit CharityWalletLocked();
    }

    function lockMaxTxExclusions() external onlyOwner {
        require(!maxTxExclusionsLocked, "already locked");
        maxTxExclusionsLocked = true;
        emit MaxTxExclusionsLocked();
    }

    function lockRescues() external onlyOwner {
        require(!rescuesLocked, "already locked");
        rescuesLocked = true;
        emit RescuesLocked();
    }

    function addLiquidityManually(uint256 tokenAmount) external payable onlyOwner {
        require(tokenAmount > 0, "no tokens");
        require(msg.value > 0, "send BNB");

        _transfer(_msgSender(), address(this), tokenAmount);
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.addLiquidityETH{value: msg.value}(
            address(this),
            tokenAmount,
            0,
            0,
            DEAD, // LP locked forever
            block.timestamp
        );
        emit AutoLiquify(tokenAmount, msg.value);
    }

    function rescueTokens(address token, uint256 amount) external {
        require(msg.sender == owner() || msg.sender == multisig, "not authorized");
        require(!rescuesLocked, "rescues locked");
        require(token != address(this), "no self rescue");
        require(IERC20(token).transfer(msg.sender, amount), "rescue token failed");
    }

    function rescueETH(uint256 amount) external {
        require(msg.sender == owner() || msg.sender == multisig, "not authorized");
        require(!rescuesLocked, "rescues locked");
        (bool s,) = payable(msg.sender).call{value: amount}("");
        require(s, "rescue eth failed");
    }

    // ============== Swap & liquidity ==============

    function _swapTokensForEth(uint256 tokenAmount) private {
        if (tokenAmount == 0) return;

        address;
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount, address lpReceiver) private {
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            lpReceiver,
            block.timestamp
        );
        emit AutoLiquify(tokenAmount, ethAmount);
    }

    function swapBack() private nonReentrant {
        if (!swapEnabled) return;

        uint256 contractBalance = balanceOf(address(this));
        uint256 totalToSwap = tokensForCharity + tokensForLiquidity;
        if (contractBalance == 0 || totalToSwap == 0) return;
        if (contractBalance > swapTokensAtAmount * 20) {
            contractBalance = swapTokensAtAmount * 20;
        }

        uint256 liqTokens = (contractBalance * tokensForLiquidity) / totalToSwap;
        uint256 halfLiq   = liqTokens / 2;
        uint256 toSwapForETH = contractBalance - halfLiq;

        uint256 initialETH = address(this).balance;
        uint256 newETH = 0;

        if (toSwapForETH > 0) {
            _swapTokensForEth(toSwapForETH);
            newETH = address(this).balance - initialETH;
        }

        uint256 ethForLiq     = toSwapForETH > 0 ? (newETH * halfLiq) / toSwapForETH : 0;
        uint256 ethForCharity = newETH - ethForLiq;

        if (halfLiq > 0 && ethForLiq > 0) {
            _addLiquidity(halfLiq, ethForLiq, DEAD);
        }
        if (ethForCharity > 0 && charityWallet != address(0)) {
            uint256 totalEthForCharity = ethForCharity + pendingEthForCharity;
            (bool s,) = charityWallet.call{value: totalEthForCharity}("");
            if (!s) {
                pendingEthForCharity = totalEthForCharity;
                emit PendingCharityUpdated(pendingEthForCharity);
            } else {
                pendingEthForCharity = 0;
                emit PendingCharityUpdated(0);
            }
        }

        emit SwapBack(toSwapForETH, newETH);
        emit SwapBackDetailed(contractBalance, liqTokens, ethForLiq, ethForCharity);

        uint256 processedLiquidity = liqTokens;
        uint256 processedCharity = contractBalance - liqTokens;

        if (processedLiquidity >= tokensForLiquidity) tokensForLiquidity = 0;
        else tokensForLiquidity -= processedLiquidity;

        if (processedCharity >= tokensForCharity) tokensForCharity = 0;
        else tokensForCharity -= processedCharity;
    }

    // ============== Core transfer logic ==============

    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0) && to != address(0), "zero address");
        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        // --- Trading gate ---
        if (!tradingActive) {
            require(
                _isExcludedFromFees[from] || _isExcludedFromFees[to],
                "Trading not active"
            );
        }

        if (limitsInEffect && !swapping) {
            if (!_isExcludedMaxTransactionAmount[from] && !_isExcludedMaxTransactionAmount[to]) {
                if (automatedMarketMakerPairs[from]) {
                    require(amount <= maxTransactionAmount, "max tx (buy)");
                    require(balanceOf(to) + amount <= maxWallet, "max wallet");
                }
                else if (automatedMarketMakerPairs[to]) {
                    require(amount <= maxTransactionAmount, "max tx (sell)");
                }
                else {
                    require(balanceOf(to) + amount <= maxWallet, "max wallet");
                }
            }
        }

        bool takeFee = !_isExcludedFromFees[from] && !_isExcludedFromFees[to];
        uint256 fees;

        if (takeFee) {
            // Sell
            if (automatedMarketMakerPairs[to]) {
                if (sellTotalFees > 0) {
                    fees = (amount * sellTotalFees) / 1000;
                    uint256 burnAmt = (amount * sellFees.burn) / 1000;

                    if (burnAmt > 0) _burn(from, burnAmt);

                    uint256 remain = fees - burnAmt;
                    if (remain > 0) {
                        uint16 nonBurn = sellFees.charity + sellFees.liq;
                        if (nonBurn > 0) {
                            tokensForCharity   += (remain * sellFees.charity) / nonBurn;
                            tokensForLiquidity += (remain * sellFees.liq)     / nonBurn;
                        }
                        super._transfer(from, address(this), remain);
                    }
                }
            }
            // Buy
            else if (automatedMarketMakerPairs[from]) {
                if (buyTotalFees > 0) {
                    fees = (amount * buyTotalFees) / 1000;
                    uint256 burnAmt = (amount * buyFees.burn) / 1000;

                    if (burnAmt > 0) _burn(from, burnAmt);

                    uint256 remain = fees - burnAmt;
                    if (remain > 0) {
                        uint16 nonBurn = buyFees.charity + buyFees.liq;
                        if (nonBurn > 0) {
                            tokensForCharity   += (remain * buyFees.charity) / nonBurn;
                            tokensForLiquidity += (remain * buyFees.liq)     / nonBurn;
                        }
                        super._transfer(from, address(this), remain);
                    }
                }
            }
        }

        uint256 contractBalance = balanceOf(address(this));
        bool canSwap = contractBalance >= swapTokensAtAmount;

        if (
            canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from] &&
            takeFee
        ) {
            swapping = true;
            swapBack();
            swapping = false;
        }

        uint256 sendAmount = amount - fees;
        super._transfer(from, to, sendAmount);
    }

    receive() external payable {}
}

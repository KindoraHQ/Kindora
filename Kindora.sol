// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Kindora ERC20 token with fees, liquidity and charity routing
/// @notice ERC20 token extended with buy/sell fees, auto-liquidity and charity routing
/// @dev Burn reduces totalSupply; liquidity LP tokens are sent to DEAD. swapBack trigger runs after fee accounting so a sell that reaches the threshold executes swapBack in the same tx.
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IERC20Metadata is IERC20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) { return msg.sender; }
    function _msgData() internal view virtual returns (bytes calldata) { return msg.data; }
}

abstract contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() { _transferOwnership(_msgSender()); }

    function owner() public view virtual returns (address) { return _owner; }

    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    function transferOwnership(address newOwner) public virtual onlyOwner { 
        require(newOwner != address(0), "Ownable: new owner is the zero address"); 
        _transferOwnership(newOwner); 
    }

    function _transferOwnership(address newOwner) internal virtual { 
        address oldOwner = _owner; 
        _owner = newOwner; 
        emit OwnershipTransferred(oldOwner, newOwner); 
    }
}

contract ERC20 is Context, IERC20, IERC20Metadata {
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 internal _totalSupply;
    string private _name; 
    string private _symbol;

    constructor(string memory name_, string memory symbol_) { 
        _name = name_; 
        _symbol = symbol_; 
    }

    function name() public view virtual override returns (string memory) { return _name; }
    function symbol() public view virtual override returns (string memory) { return _symbol; }
    function decimals() public view virtual override returns (uint8) { return 18; }
    function totalSupply() public view virtual override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view virtual override returns (uint256) { return _balances[account]; }

    function transfer(address to, uint256 amount) public virtual override returns (bool) { 
        _transfer(_msgSender(), to, amount); 
        return true; 
    }

    function allowance(address owner_, address spender) public view virtual override returns (uint256) { 
        return _allowances[owner_][spender]; 
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) { 
        _approve(_msgSender(), spender, amount); 
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        uint256 currentAllowance = _allowances[from][_msgSender()];
        if (currentAllowance != type(uint256).max) { 
            require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance"); 
            unchecked { _approve(from, _msgSender(), currentAllowance - amount); } 
        }
        _transfer(from, to, amount); 
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) { 
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue); 
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender]; 
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero"); 
        unchecked { _approve(_msgSender(), spender, currentAllowance - subtractedValue); } 
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0) && to != address(0), "ERC20: zero address");
        uint256 fromBal = _balances[from]; 
        require(fromBal >= amount, "ERC20: transfer amount exceeds balance");
        unchecked { _balances[from] = fromBal - amount; } 
        _balances[to] += amount; 
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal virtual { 
        require(to != address(0), "ERC20: mint to zero"); 
        _totalSupply += amount; 
        _balances[to] += amount; 
        emit Transfer(address(0), to, amount); 
    }

    function _burn(address from, uint256 amount) internal virtual { 
        require(from != address(0), "ERC20: burn from zero"); 
        uint256 bal = _balances[from]; 
        require(bal >= amount, "ERC20: burn exceeds balance"); 
        unchecked { _balances[from] = bal - amount; } 
        _totalSupply -= amount; 
        emit Transfer(from, address(0), amount); 
    }

    function _approve(address owner_, address spender, uint256 amount) internal virtual { 
        require(owner_ != address(0) && spender != address(0), "ERC20: approve zero"); 
        _allowances[owner_][spender] = amount; 
        emit Approval(owner_, spender, amount); 
    }
}

interface IUniswapV2Factory { 
    function createPair(address tokenA, address tokenB) external returns (address pair); 
}

interface IUniswapV2Router01 { 
    function factory() external view returns (address); 
    function WETH() external view returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) 
        external 
        payable 
        returns (uint amountToken, uint amountETH, uint liquidity); 
}

interface IUniswapV2Router02 is IUniswapV2Router01 { 
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

abstract contract ReentrancyLite { 
    uint256 private _lock; 
    modifier nonReentrant(){ 
        require(_lock == 0, "REENTRANCY"); 
        _lock = 1; 
        _; 
        _lock = 0; 
    } 
}

contract Kindora is ERC20, Ownable, ReentrancyLite {

    // BSC Testnet Pancake V2 Router
    address public constant PANCAKE_ROUTER =  0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    address public constant WBNB_TESTNET   = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    address public constant FACTORY_V2     = 0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    address public constant DEAD           = 0x000000000000000000000000000000000000dEaD;

    IUniswapV2Router02 public immutable uniswapV2Router;
    address public immutable uniswapV2Pair;

    address payable public charityWallet;

    bool public tradingActive = true;
    bool public limitsInEffect = false;
    uint256 public maxTransactionAmount;
    uint256 public maxWallet;

    uint256 public swapTokensAtAmount;

    struct FeeSet { uint16 charity; uint16 burn; uint16 liq; }
    FeeSet public buyFees;
    FeeSet public sellFees;
    uint16 public buyTotalFees;
    uint16 public sellTotalFees;

    bool public feesLocked;
    bool public feeExclusionsLocked;
    bool public charityWalletLocked;
    bool public maxTxExclusionsLocked;
    bool public rescuesLocked;

    uint256 private tokensForCharity;
    uint256 private tokensForLiquidity;
    uint256 public pendingEthForCharity;
    bool private swapping;

    mapping(address => bool) public automatedMarketMakerPairs;
    mapping(address => bool) private _isExcludedFromFees;
    mapping(address => bool) private _isExcludedMaxTransactionAmount;

    /// @notice Emitted when fees are locked permanently
    event FeesLocked();
    /// @notice Emitted when fee exclusions are locked permanently
    event FeeExclusionsLocked();
    /// @notice Emitted when charity wallet gets locked
    event CharityWalletLocked();
    /// @notice Emitted when max-tx exclusions get locked
    event MaxTxExclusionsLocked();
    /// @notice Emitted when rescues get locked
    event RescuesLocked();
    /// @notice Emitted when an automated market maker pair is set or unset
    event SetAutomatedMarketMakerPair(address pair, bool value);
    /// @notice Emitted when tokens are auto-liquified
    event AutoLiquify(uint256 tokenAmount, uint256 ethAmount);
    /// @notice Emitted when tokens are swapped for native coin (BNB)
    event SwapBack(uint256 tokensSwapped, uint256 ethReceived);

    /// @notice Emitted when an address is excluded from or included in fee handling
    event ExcludeFromFees(address indexed account, bool excluded);

    /// @notice Emitted when an address is excluded from or included in max-transaction checks
    event ExcludeFromMaxTransaction(address indexed account, bool excluded);

    /// @notice Emitted when the charity wallet address is changed
    event CharityWalletUpdated(address indexed oldWallet, address indexed newWallet);

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
        swapTokensAtAmount   = (total * 5) / 10000; // 0.05% = 500 tokens

        charityWallet = payable(0x0Fbf5f23E61cCa3A4590A4E2503573Ee10fB5974);

        IUniswapV2Router02 _router = IUniswapV2Router02(PANCAKE_ROUTER);
        require(_router.WETH() == WBNB_TESTNET, "WBNB mismatch");
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

        feeExclusionsLocked = true;
        emit FeeExclusionsLocked();

        _isExcludedMaxTransactionAmount[owner()] = true;
        _isExcludedMaxTransactionAmount[address(this)] = true;
        _isExcludedMaxTransactionAmount[DEAD] = true;
        _isExcludedMaxTransactionAmount[_pair] = true;
        _isExcludedMaxTransactionAmount[address(_router)] = true;

        feesLocked = true;
        emit FeesLocked();
    }

    // ============== Internal helpers ==============

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        automatedMarketMakerPairs[pair] = value; 
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    /// @dev Internal helper to exclude/include an address from fees; emits ExcludeFromFees for observability.
    function _excludeFromFeesInternal(address account, bool excluded) private {
        _isExcludedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    // ============== View helpers ==============

    /// @notice Returns whether an account is excluded from fees.
    /// @param account The account to query
    function isExcludedFromFees(address account) external view returns (bool) { 
        return _isExcludedFromFees[account]; 
    }

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

    function setAutomatedMarketMakerPair(address pair, bool value) external onlyOwner {
        require(pair != address(0), "pair=0"); 
        _setAutomatedMarketMakerPair(pair, value);
        if (value) { 
            _isExcludedMaxTransactionAmount[pair] = true; 
        }
    }

    function setCharityWallet(address payable newWallet) external onlyOwner {
        require(!charityWalletLocked, "charity wallet locked");
        require(newWallet != address(0), "charity=0");

        address old = charityWallet;
        charityWallet = newWallet;
        emit CharityWalletUpdated(old, newWallet);

        if (!_isExcludedFromFees[newWallet] && !feeExclusionsLocked) {
            _excludeFromFeesInternal(newWallet, true);
        }
    }

    function excludeFromMaxTransaction(address account, bool excluded) external onlyOwner {
        require(!maxTxExclusionsLocked, "max-tx exclusions locked");
        _isExcludedMaxTransactionAmount[account] = excluded;
        emit ExcludeFromMaxTransaction(account, excluded);
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
            owner(),
            block.timestamp
        );
        emit AutoLiquify(tokenAmount, msg.value);
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(!rescuesLocked, "rescues locked");
        require(token != address(this), "no self rescue");
        require(IERC20(token).transfer(_msgSender(), amount), "rescue token failed");
    }

    function rescueETH(uint256 amount) external onlyOwner {
        require(!rescuesLocked, "rescues locked");
        (bool s,) = payable(_msgSender()).call{value: amount}("");
        require(s, "rescue eth failed");
    }

    // ============== Swap & liquidity ==============

    function _swapTokensForEth(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
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
        _swapTokensForEth(toSwapForETH);
        uint256 newETH = address(this).balance - initialETH;

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
            } else {
                pendingEthForCharity = 0;
            }
        }

        emit SwapBack(toSwapForETH, newETH);
        tokensForCharity   = 0; 
        tokensForLiquidity = 0;
    }

    // ============== Core transfer logic ==============

    /// @notice Core transfer routine with fee handling for buys and sells.
    /// @dev Fees are charged only when neither sender nor receiver are excluded.
    ///      Burn reduces totalSupply via _burn(); liquidity tokens are accumulated and later used to add liquidity (LP -> DEAD).
    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0) && to != address(0), "zero address");
        if (amount == 0) { 
            super._transfer(from, to, 0); 
            return; 
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

        // ========== take fees first ==========
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

        // ========== then, attempt swapBack using up-to-date balances ==========
        uint256 contractBalance = balanceOf(address(this));
        bool canSwap = contractBalance >= swapTokensAtAmount;

        if (
            canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from] &&
            !_isExcludedFromFees[from] &&
            !_isExcludedFromFees[to]
        ) {
            swapping = true;
            swapBack();
            swapping = false;
        }

        // ========== finally send remainder ==========
        uint256 sendAmount = amount - fees;
        super._transfer(from, to, sendAmount);
    }

    receive() external payable {}
}

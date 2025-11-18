// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/Kindora.sol";

interface IERC20Minimal {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract MockPair {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    event Mint(address indexed to, uint256 amount);
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Mint(to, amount);
    }
}

contract MockFactory {
    mapping(bytes32 => address) public pairs;
    event PairCreated(address indexed tokenA, address indexed tokenB, address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        bytes32 k = keccak256(abi.encodePacked(tokenA, tokenB));
        require(pairs[k] == address(0), "pair exists");
        MockPair p = new MockPair();
        pairs[k] = address(p);
        emit PairCreated(tokenA, tokenB, address(p));
        return address(p);
    }
    function getPair(address tokenA, address tokenB) external view returns (address) {
        return pairs[keccak256(abi.encodePacked(tokenA, tokenB))];
    }
}

contract MockRouter {
    address public immutable factoryAddress;
    address public immutable wethAddress;
    constructor(address _factory, address _weth) {
        factoryAddress = _factory;
        wethAddress = _weth;
    }
    function factory() external view returns (address) { return factoryAddress; }
    function WETH() external view returns (address) { return wethAddress; }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external {
        IERC20Minimal(msg.sender).transferFrom(msg.sender, address(this), amountIn);
        uint256 send = 1 ether;
        if (address(this).balance < send) send = address(this).balance;
        if (send > 0) {
            (bool s,) = payable(msg.sender).call{value: send}("");
            require(s, "mock swap eth send failed");
        }
    }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint,
        uint,
        address to,
        uint
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity) {
        IERC20Minimal(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        address pair = MockFactory(factoryAddress).getPair(token, wethAddress);
        require(pair != address(0), "pair not found");
        uint liq = amountTokenDesired + msg.value;
        MockPair(pair).mint(to, liq);
        return (amountTokenDesired, msg.value, liq);
    }

    receive() external payable {}
}

contract RevertingReceiver {
    fallback() external payable { revert("no ETH"); }
    receive() external payable { revert("no ETH"); }
}

contract KindoraBehaviorTest is Test {
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB_MAINNET   = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant FACTORY_V2     = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant DEAD           = 0x000000000000000000000000000000000000dEaD;

    MockFactory factory;
    MockRouter router;
    Kindora token;

    address deployer = address(0xABCD);
    address buyer    = address(0xBEEF);
    address user     = address(0xCAFE);

    function setUp() public {
        vm.deal(deployer, 100 ether);
        vm.startPrank(deployer);
        factory = new MockFactory();
        router = new MockRouter(address(factory), WBNB_MAINNET);
        vm.stopPrank();

        vm.etch(FACTORY_V2, address(factory).code);
        vm.etch(PANCAKE_ROUTER, address(router).code);

        vm.deal(PANCAKE_ROUTER, 10 ether);

        vm.startPrank(deployer);
        token = new Kindora();
        vm.stopPrank();

        address pair = token.uniswapV2Pair();
        assertTrue(pair != address(0), "pair should be created");
    }

    function t(uint256 v) internal pure returns (uint256) { return v * 1e18; }

    function testBurnReducesTotalSupplyOnBuy() public {
        uint256 initialTotal = token.totalSupply();

        address pair = token.uniswapV2Pair();

        vm.startPrank(deployer);
        token.transfer(pair, t(1000));
        vm.stopPrank();

        vm.startPrank(pair);
        token.transfer(buyer, t(1000));
        vm.stopPrank();

        uint256 expectedBurn = t(1000) * 10 / 1000;
        uint256 finalTotal = token.totalSupply();
        assertEq(initialTotal - finalTotal, expectedBurn, "totalSupply should decrease by burn amount");
        assertEq(token.balanceOf(DEAD), 0, "DEAD token balance should remain 0 for real burns");
    }

    function testLiquidityAccumulationAndLpToDeadLocking() public {
        address pair = token.uniswapV2Pair();

        vm.startPrank(deployer);
        token.transfer(pair, t(5000));
        vm.stopPrank();

        vm.startPrank(pair);
        token.transfer(buyer, t(2000));
        vm.stopPrank();

        vm.startPrank(pair);
        token.transfer(buyer, t(2000));
        vm.stopPrank();

        uint256 contractBal = token.balanceOf(address(token));
        assertTrue(contractBal >= token.swapTokensAtAmount(), "contract should have >= swapTokensAtAmount after buys");

        address mockLP = MockFactory(FACTORY_V2).getPair(address(token), WBNB_MAINNET);
        uint256 lpBefore = MockPair(mockLP).balanceOf(DEAD);

        vm.startPrank(buyer);
        token.transfer(user, t(1));
        vm.stopPrank();

        uint256 lpAfter = MockPair(mockLP).balanceOf(DEAD);
        assertTrue(lpAfter > lpBefore, "LP tokens should be minted and sent to DEAD");

        assertEq(token.balanceOf(DEAD), 0, "Token transfer to DEAD should not be used for burns (use _burn)");
    }

    function testCharityEthForwardingAndPendingBehavior() public {
        address pair = token.uniswapV2Pair();

        vm.startPrank(deployer);
        token.transfer(pair, t(2000));
        vm.stopPrank();

        vm.startPrank(pair);
        token.transfer(buyer, t(1000));
        vm.stopPrank();

        RevertingReceiver bad = new RevertingReceiver();
        vm.startPrank(deployer);
        token.setCharityWallet(payable(address(bad)));
        vm.stopPrank();

        vm.deal(PANCAKE_ROUTER, 5 ether);

        vm.startPrank(buyer);
        token.transfer(user, t(1));
        vm.stopPrank();

        uint256 pending = token.getPendingBnbForCharity();
        assertTrue(pending > 0, "pendingBnbForCharity should be set when charity forwarding fails");

        address payable goodCharity = payable(address(0xDEAD1));
        vm.deal(goodCharity, 0);
        vm.startPrank(deployer);
        token.setCharityWallet(goodCharity);
        vm.stopPrank();

        vm.startPrank(buyer);
        token.transfer(user, t(1));
        vm.stopPrank();

        uint256 pendingAfter = token.getPendingBnbForCharity();
        assertEq(pendingAfter, 0, "pendingBnbForCharity should be zero after successful forwarding");
        assertTrue(goodCharity.balance > 0, "charity should have received BNB after successful forward");
    }

    function testPartialProcessingDoesNotZeroCounters() public {
        address pair = token.uniswapV2Pair();

        vm.startPrank(deployer);
        token.transfer(pair, t(200000));
        vm.stopPrank();

        for (uint i = 0; i < 30; i++) {
            vm.startPrank(pair);
            token.transfer(buyer, t(2000));
            vm.stopPrank();
        }

        uint256 beforeCharity = token.getTokensForCharity();
        uint256 beforeLiq = token.getTokensForLiquidity();
        uint256 totalToSwap = beforeCharity + beforeLiq;
        assertTrue(totalToSwap > token.swapTokensAtAmount() * 20, "totalToSwap should exceed batch cap");

        vm.startPrank(buyer);
        token.transfer(user, t(1));
        vm.stopPrank();

        uint256 afterCharity = token.getTokensForCharity();
        uint256 afterLiq = token.getTokensForLiquidity();

        assertTrue(afterCharity < beforeCharity || afterLiq < beforeLiq, "some counters should be reduced");
        assertTrue(afterCharity + afterLiq < totalToSwap, "processed amount should reduce totalToSwap");
    }

    function testSwapBackDetailedEvent() public {
        address pair = token.uniswapV2Pair();

        vm.startPrank(deployer);
        token.transfer(pair, t(2000));
        vm.stopPrank();

        vm.startPrank(pair);
        token.transfer(buyer, t(1000));
        vm.stopPrank();

        uint256 contractBal = token.balanceOf(address(token));
        assertTrue(contractBal >= token.swapTokensAtAmount(), "contract should have >= swapTokensAtAmount");

        vm.deal(PANCAKE_ROUTER, 5 ether);

        vm.recordLogs();
        vm.startPrank(buyer);
        token.transfer(user, t(1));
        vm.stopPrank();

        // Check that SwapBackDetailed event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundDetailedEvent = false;
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("SwapBackDetailed(uint256,uint256,uint256,uint256)")) {
                foundDetailedEvent = true;
                break;
            }
        }
        assertTrue(foundDetailedEvent, "SwapBackDetailed event should be emitted");
    }
}

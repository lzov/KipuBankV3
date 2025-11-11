// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title KipuBankV3
 * @notice Advanced DeFi bank with Uniswap V2 integration for automatic token swaps to USDC
 * @dev All deposits are converted to USDC: ETH via Uniswap swap (WETH->USDC), other tokens via Uniswap V2 swap
 * @dev Contrato desarrollado para ETH Kipu (Talento Tech - Turno Mañana)
 * @author Gabriel Liz Ovelar - @lzov
 * @custom:security Auditar antes de producción!
 */

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";


contract KipuBankV3 is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint8 public constant USDC_DECIMALS = 6;

    /*//////////////////////////////////////////////////////////////
                                   ROLES
    //////////////////////////////////////////////////////////////*/
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLE ADDRESSES
    //////////////////////////////////////////////////////////////*/
    /// @notice Uniswap V2 Router
    IUniswapV2Router02 public immutable i_uniswapRouter;

    /// @notice Uniswap V2 Factory
    IUniswapV2Factory public immutable i_uniswapFactory;

    /// @notice USDC token address
    address public immutable i_usdc;

    /// @notice Withdraw limit in USDC (6 decimals)
    uint256 public immutable i_withdrawLimit;

    /// @notice Bank cap in USD with 6 decimals (USD * 1e6)
    uint256 public immutable i_bankCapUsd;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice User balances in USDC (6 decimals)
    mapping(address => uint256) private s_balances;

    /// @notice Total value locked in USD with 6 decimals
    uint256 public s_totalUsdLocked;

    /// @notice Deposit counter
    uint256 public s_totalDepositsCount;

    /// @notice Withdrawal counter
    uint256 public s_totalWithdrawalsCount;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amountIn,
        uint256 usdcReceived
    );

    event Withdraw(address indexed user, uint256 amount);

    event TokenSwapped(
        address indexed token,
        uint256 amountIn,
        uint256 usdcOut
    );

    event EmergencyWithdrawal(
        address indexed to,
        address indexed token,
        uint256 amount,
        address indexed by
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error InvalidParameter(string reason);
    error ZeroAmount();
    error BankCapExceeded(uint256 attemptedDepositUsd6, uint256 bankCapUsd6);
    error WithdrawLimitExceeded(uint256 requested, uint256 maxAllowed);
    error InsufficientBalance(uint256 available, uint256 requested);
    error TransferFailed();
    error NoUniswapPair(address token);
    error SwapFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @param _withdrawLimit Withdraw limit in USDC (6 decimals)
     * @param _bankCapUsd Bank cap in USD with 6 decimals (USD * 1e6)
     * @param _uniswapRouter Uniswap V2 Router address
     * @param _usdc USDC token address
     */
    constructor(
        uint256 _withdrawLimit,
        uint256 _bankCapUsd,
        address _uniswapRouter,
        address _usdc
    ) {
        if (_withdrawLimit == 0) revert InvalidParameter("withdraw limit");
        if (_bankCapUsd == 0) revert InvalidParameter("bank cap");
        if (_uniswapRouter == address(0))
            revert InvalidParameter("uniswap router");
        if (_usdc == address(0)) revert InvalidParameter("usdc");

        i_withdrawLimit = _withdrawLimit;
        i_bankCapUsd = _bankCapUsd;
        i_uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        i_usdc = _usdc;

        // Get factory from router
        i_uniswapFactory = IUniswapV2Factory(i_uniswapRouter.factory());

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT / WITHDRAW (PUBLIC)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit ETH, USDC, or any ERC20 token with Uniswap V2 pair
     * @dev ETH is converted to USDC via Uniswap swap (WETH->USDC)
     *      Other tokens are swapped to USDC via Uniswap V2
     *      All balances stored internally as USDC
     * @param token Token address (address(0) for ETH, i_usdc for USDC, other for ERC20)
     * @param amount Amount in token's native units (ignored for ETH, use msg.value)
     * @param minUsdcOut Minimum USDC to receive (slippage protection, use 0 to skip)
     */
    function deposit(
        address token,
        uint256 amount,
        uint256 minUsdcOut
    ) external payable nonReentrant whenNotPaused {
        uint256 usdcToCredit;

        // CASE 1: Native ETH
        if (token == address(0)) {
            if (msg.value == 0) revert ZeroAmount();
            // perform ETH -> USDC swap
            usdcToCredit = _depositEth(msg.value, minUsdcOut);
        }
        // CASE 2: Direct USDC
        else if (token == i_usdc) {
            if (amount == 0) revert ZeroAmount();
            usdcToCredit = amount;
            // Transfer USDC from user
            IERC20(i_usdc).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
        }
        // CASE 3: Other ERC20 (needs swap)
        else {
            if (amount == 0) revert ZeroAmount();
            if (msg.value > 0)
                revert InvalidParameter("no ETH for token deposit");
            usdcToCredit = _depositAndSwap(token, amount, minUsdcOut);
        }

        // Check bank cap
        if (s_totalUsdLocked + usdcToCredit > i_bankCapUsd) {
            revert BankCapExceeded(
                s_totalUsdLocked + usdcToCredit,
                i_bankCapUsd
            );
        }

        // Update state
        s_totalUsdLocked += usdcToCredit;
        s_balances[msg.sender] += usdcToCredit;
        s_totalDepositsCount++;

        emit Deposit(
            msg.sender,
            token,
            token == address(0) ? msg.value : amount,
            usdcToCredit
        );
    }

    /**
     * @notice Withdraw USDC from user's balance
     * @dev All balances are stored as USDC, so withdrawal is always in USDC
     * @param amount Amount of USDC to withdraw (6 decimals)
     */
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount > i_withdrawLimit) {
            revert WithdrawLimitExceeded(amount, i_withdrawLimit);
        }

        uint256 userBalance = s_balances[msg.sender];
        if (amount > userBalance) {
            revert InsufficientBalance(userBalance, amount);
        }

        // Effects
        s_balances[msg.sender] = userBalance - amount;

        // Protect against underflow (aunque checks arriba lo previenen)
        if (s_totalUsdLocked >= amount) {
            s_totalUsdLocked -= amount;
        } else {
            s_totalUsdLocked = 0;
        }

        s_totalWithdrawalsCount++;

        // Interaction: Transfer USDC to user
        IERC20(i_usdc).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pause deposits and withdrawals
     * @dev Only callable by PAUSER_ROLE
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause deposits and withdrawals
     * @dev Only callable by PAUSER_ROLE
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal of tokens by operator/admin
     * @dev Can withdraw any token (ETH, USDC, or other ERC20) in emergencies
     * @param token Token address (address(0) for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address payable to,
        uint256 amount
    ) external onlyRole(OPERATOR_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert InvalidParameter("recipient");

        if (token == address(0)) {
            // Withdraw ETH
            (bool success, ) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            // Withdraw ERC20
            IERC20(token).safeTransfer(to, amount);
        }

        emit EmergencyWithdrawal(to, token, amount, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get user's USDC balance
     * @param user User address
     * @return User's balance in USDC (6 decimals)
     */
    function getBalance(address user) external view returns (uint256) {
        return s_balances[user];
    }

    /**
     * @notice Get total USD locked in the bank
     * @return Total USDC locked (6 decimals)
     */
    function getTotalUsdLocked() external view returns (uint256) {
        return s_totalUsdLocked;
    }

    /**
     * @notice Check if a token has a Uniswap V2 pair with USDC
     * @param token Token address to check
     * @return exists True if pair exists
     */
    function hasPairWithUsdc(address token) external view returns (bool) {
        address pair = i_uniswapFactory.getPair(token, i_usdc);
        if (pair != address(0)) return true;
        // also allow via WETH
        address weth = i_uniswapRouter.WETH();
        address p1 = i_uniswapFactory.getPair(token, weth);
        address p2 = i_uniswapFactory.getPair(weth, i_usdc);
        return (p1 != address(0) && p2 != address(0));
    }

    /**
     * @notice Get deposit and withdrawal counts
     * @return deposits Total deposits
     * @return withdrawals Total withdrawals
     */
    function getCounts()
        external
        view
        returns (uint256 deposits, uint256 withdrawals)
    {
        return (s_totalDepositsCount, s_totalWithdrawalsCount);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Swap ETH to USDC via Uniswap and return received USDC (6 decimals)
     * @param ethAmount Amount of ETH in wei
     * @param minUsdcOut Minimum USDC expected (slippage protection)
     * @return usdcAmount Amount of USDC received
     */
    function _depositEth(uint256 ethAmount, uint256 minUsdcOut) internal returns (uint256) {
        require(ethAmount > 0, "Zero ETH");

        address weth = i_uniswapRouter.WETH();

        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = i_usdc;

        uint256 usdcBefore = IERC20(i_usdc).balanceOf(address(this));

        // Execute swap
        i_uniswapRouter.swapExactETHForTokens{value: ethAmount}(
            minUsdcOut,
            path,
            address(this),
            block.timestamp + 15 minutes
        );

        uint256 usdcAfter = IERC20(i_usdc).balanceOf(address(this));
        uint256 usdcReceived = 0;
        if (usdcAfter >= usdcBefore) usdcReceived = usdcAfter - usdcBefore;

        if (usdcReceived == 0) revert SwapFailed();

        emit TokenSwapped(address(0), ethAmount, usdcReceived);

        return usdcReceived;
    }

    /**
     * @notice Deposit ERC20 token and swap to USDC via Uniswap V2
     * @param token Token address to deposit
     * @param amount Amount of tokens
     * @param minUsdcOut Minimum USDC expected (slippage protection)
     * @return usdcReceived Amount of USDC received from swap
     */
    function _depositAndSwap(
        address token,
        uint256 amount,
        uint256 minUsdcOut
    ) internal returns (uint256) {
        // Determine path: direct token->USDC or token->WETH->USDC
        address weth = i_uniswapRouter.WETH();
        address pairDirect = i_uniswapFactory.getPair(token, i_usdc);

        address[] memory path;

        if (pairDirect != address(0)) {
            path = new address[](2);
            path[0] = token;
            path[1] = i_usdc;
        } else {
            // try token->WETH and WETH->USDC
            address p1 = i_uniswapFactory.getPair(token, weth);
            address p2 = i_uniswapFactory.getPair(weth, i_usdc);
            if (p1 != address(0) && p2 != address(0)) {
                path = new address[](3);
                path[0] = token;
                path[1] = weth;
                path[2] = i_usdc;
            } else {
                revert NoUniswapPair(token);
            }
        }

        // Transfer tokens from user to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Approve router to spend tokens using forceApprove (OpenZeppelin 5.x)
        IERC20(token).forceApprove(address(i_uniswapRouter), amount);

        // Execute swap
        uint256 usdcBefore = IERC20(i_usdc).balanceOf(address(this));

        i_uniswapRouter.swapExactTokensForTokens(
            amount,
            minUsdcOut,
            path,
            address(this),
            block.timestamp + 15 minutes
        );

        uint256 usdcAfter = IERC20(i_usdc).balanceOf(address(this));
        uint256 usdcReceived = 0;
        if (usdcAfter >= usdcBefore) usdcReceived = usdcAfter - usdcBefore;

        if (usdcReceived == 0) {
            // Reset approval for safety before revert
            IERC20(token).forceApprove(address(i_uniswapRouter), 0);
            revert SwapFailed();
        }

        // Reset approval to 0 for security
        IERC20(token).forceApprove(address(i_uniswapRouter), 0);

        emit TokenSwapped(token, amount, usdcReceived);

        return usdcReceived;
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACKS
    //////////////////////////////////////////////////////////////*/
    receive() external payable {
        revert();
    }

    fallback() external payable {
        revert();
    }
}
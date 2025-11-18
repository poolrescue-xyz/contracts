// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * NOTE:
 * - Solidly/Velodrome/Ramses rAMM Pairs expose:  tokens() -> (token0, token1)
 * - UniV2-like (UniswapV2Pair, FraxswapPair, HOPE, etc.): token0(), token1()
 * We support both via _getTokens().
 */
interface ISolidlyPair is IERC20 {
    function tokens() external view returns (address token0, address token1);
    function burn(address to) external returns (uint amount0, uint amount1);
}

contract PoolRescueV1 is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint16 public constant DENOM_BPS   = 10_000;
    uint16 public constant MAX_FEE_BPS = 500;   // 5% hard cap

    uint16 public feeBps;               // e.g. 250 (= 2.5%)
    address public feeRecipient;

    event Removed(
        address indexed user,
        address indexed pair,
        uint256 lpIn,
        address token0, uint256 gross0, uint256 fee0, uint256 net0,
        address token1, uint256 gross1, uint256 fee1, uint256 net1
    );
    event FeeUpdated(uint16 oldBps, uint16 newBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    constructor(address _feeRecipient, uint16 _initialFeeBps) Ownable(msg.sender) {
        require(_feeRecipient != address(0), "feeRecipient=0");
        require(_initialFeeBps <= MAX_FEE_BPS, "fee too high");
        feeRecipient = _feeRecipient;
        feeBps = _initialFeeBps;
    }

    function setFeeBps(uint16 _newBps) external onlyOwner {
        require(_newBps <= MAX_FEE_BPS, "fee too high");
        uint16 old = feeBps;
        feeBps = _newBps;
        emit FeeUpdated(old, _newBps);
    }

    function setFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "feeRecipient=0");
        address old = feeRecipient;
        feeRecipient = _newRecipient;
        emit FeeRecipientUpdated(old, _newRecipient);
    }

    /// @dev Distributes fee & net to recipient and user. Includes a simple FoT sanity.
    function _distribute(IERC20 token, uint256 gross, address user)
        internal
        returns (uint256 fee, uint256 net)
    {
        fee = (gross * feeBps) / DENOM_BPS;
        net = gross - fee;

        uint256 rBefore = token.balanceOf(feeRecipient);
        uint256 uBefore = token.balanceOf(user);

        if (fee > 0) token.safeTransfer(feeRecipient, fee);
        if (net > 0) token.safeTransfer(user, net);

        // Simple FoT sanity checks (revert if token is deflationary or transfer taxed)
        require(token.balanceOf(feeRecipient) >= rBefore + fee, "FoT fee");
        require(token.balanceOf(user)        >= uBefore + net, "FoT net");
    }

    /// @notice Remove liquidity with protocol fee & slippage guards.
    /// @param pair       LP token address (pair)
    /// @param lpAmount   amount of LP to burn
    /// @param min0       minimum token0 out (revert if less)
    /// @param min1       minimum token1 out (revert if less)
    function removeWithFee(
        address pair,
        uint256 lpAmount,
        uint256 min0,
        uint256 min1
    ) external nonReentrant {
        require(lpAmount > 0, "lp=0");

        (address t0, address t1) = _getTokens(pair);
        ISolidlyPair p = ISolidlyPair(pair);

        // Pull LP from user to the pair, then burn to this contract
        IERC20(pair).safeTransferFrom(msg.sender, pair, lpAmount);
        (uint256 amount0, uint256 amount1) = p.burn(address(this));

        require(amount0 >= min0, "slippage0");
        require(amount1 >= min1, "slippage1");

        // Distribute fee + net to user
        (uint256 fee0, uint256 net0) = _distribute(IERC20(t0), amount0, msg.sender);
        (uint256 fee1, uint256 net1) = _distribute(IERC20(t1), amount1, msg.sender);

        emit Removed(
            msg.sender, pair, lpAmount,
            t0, amount0, fee0, net0,
            t1, amount1, fee1, net1
        );
    }

    /// @dev Get tokens for both Solidly (tokens()) and UniV2-like (token0()/token1()) pairs.
    function _getTokens(address pair) internal view returns (address t0, address t1) {
        // Try Solidly-style: tokens()
        (bool ok, bytes memory data) =
            pair.staticcall(abi.encodeWithSignature("tokens()"));
        if (ok && data.length == 64) {
            (t0, t1) = abi.decode(data, (address, address));
            require(t0 != address(0) && t1 != address(0), "tokens() zero");
            return (t0, t1);
        }

        // Fallback: UniswapV2/Fraxswap-style token0()/token1()
        (ok, data) = pair.staticcall(abi.encodeWithSignature("token0()"));
        require(ok && data.length == 32, "token0() missing");
        t0 = abi.decode(data, (address));
        (ok, data) = pair.staticcall(abi.encodeWithSignature("token1()"));
        require(ok && data.length == 32, "token1() missing");
        t1 = abi.decode(data, (address));
        require(t0 != address(0) && t1 != address(0), "token0/1 zero");
    }

    // Block accidental native transfers (defense-in-depth)
    receive() external payable { revert("NO_ETH"); }
    fallback() external payable { revert("NO_ETH"); }
}

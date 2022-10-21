// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title Permissionless pool actions
/// @notice Contains pool methods that can be called by anyone
interface IUniswapV3PoolActions {
    /// @notice Sets the initial price for the pool
    /// @dev Price is represented as a sqrt(amountToken1/amountToken0) Q64.96 value
    /// @param sqrtPriceX96 the initial sqrt price of the pool as a Q64.96
    function initialize(uint160 sqrtPriceX96) external;

    /// @notice Adds liquidity for the given recipient/tickLower/tickUpper position
    /// 为指定的recipient/tickLower/tickUpper position增加流动性
    /// @dev The caller of this method receives a callback in the form of IUniswapV3MintCallback#uniswapV3MintCallback
    /// in which they must pay any token0 or token1 owed for the liquidity. The amount of token0/token1 due depends
    /// on tickLower, tickUpper, the amount of liquidity, and the current price.
    /// 这个方法的调用方NonfungiblePositionManager接收到一个回调函数(pool调用NonfungiblePositionManager)，形式为IUniswapV3MintCallback#uniswapV3MintCallback，
    /// 在这个回调函数中，他们必须为流动性支付token0或token1。token0/token1的金额取决于tickLower、tickUpper、liquidity和当前价格。
    /// @param recipient The address for which the liquidity will be created 为其创建流动性的地址
    /// @param tickLower The lower tick of the position in which to add liquidity 要增加流动性的头寸的tick下限
    /// @param tickUpper The upper tick of the position in which to add liquidity 要增加流动性的头寸的tick上限
    /// @param amount The amount of liquidity to mint 要铸造的流动性数量
    /// @param data Any data that should be passed through to the callback 应该传递给回调函数的数据
    /// @return amount0 The amount of token0 that was paid to mint the given amount of liquidity. Matches the value in the callback token0的数量，用来铸造给定数量的流动性。匹配回调中的值
    /// @return amount1 The amount of token1 that was paid to mint the given amount of liquidity. Matches the value in the callback token1的数量，用来铸造给定数量的流动性。匹配回调中的值
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Collects tokens owed to a position
    /// @dev Does not recompute fees earned, which must be done either via mint or burn of any amount of liquidity.
    /// Collect must be called by the position owner. To withdraw only token0 or only token1, amount0Requested or
    /// amount1Requested may be set to zero. To withdraw all tokens owed, caller may pass any value greater than the
    /// actual tokens owed, e.g. type(uint128).max. Tokens owed may be from accumulated swap fees or burned liquidity.
    /// @param recipient The address which should receive the fees collected
    /// @param tickLower The lower tick of the position for which to collect fees
    /// @param tickUpper The upper tick of the position for which to collect fees
    /// @param amount0Requested How much token0 should be withdrawn from the fees owed
    /// @param amount1Requested How much token1 should be withdrawn from the fees owed
    /// @return amount0 The amount of fees collected in token0
    /// @return amount1 The amount of fees collected in token1

    /// @notice 收集某个头寸欠其owner的tokens
    /// @dev 不重新计算所赚取的费用，这必须通过mint或burn任何数量的流动性完成。
    /// Collect必须由头寸所有者调用，但recipient参数可以是其他人。如果只提取token0或token1，则可以将amount0Requested或amount1Requested设置为零。
    /// 为了提取所有所欠的tokens，调用者可以传递任何大于实际所欠tokens的值，例如type(uint128).max。所欠的tokens可能来自累积的swap手续费或burn流动性产生的本金和手续费。
    /// @param recipient 应该接收所收集费用的地址
    /// @param tickLower 要收取费用的头寸的tickLower
    /// @param tickUpper 要收费费用的头寸的tickUpper
    /// @param amount0Requested 从所欠的费用中提取多少token0
    /// @param amount1Requested 从所欠的费用中提取多少token1
    /// @return amount0 实际收取的token0的数量
    /// @return amount1 实际收取的token0的数量
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    /// @notice Burn liquidity from the sender and account tokens owed for the liquidity to the position
    /// @dev Can be used to trigger a recalculation of fees owed to a position by calling with an amount of 0
    /// @dev Fees must be collected separately via a call to #collect
    /// @param tickLower The lower tick of the position for which to burn liquidity
    /// @param tickUpper The upper tick of the position for which to burn liquidity
    /// @param amount How much liquidity to burn
    /// @return amount0 The amount of token0 sent to the recipient
    /// @return amount1 The amount of token1 sent to the recipient

    /// @notice burn掉sender的流动性，并且计算头寸欠sender的tokens
    /// @dev 可以通过传递参数amount=0调用来触发对某个头寸所欠费用的重新计算
    /// @dev 所欠费用必须通过另一个方法collect单独收集
    /// @param tickLower 需要burn流动性的头寸的tick的最低值
    /// @param tickUpper 需要burn流动性的头寸的tick的最低值
    /// @param amount 要burn多少流动性
    /// @return amount0 发送给接收者的token0的数量
    /// @return amount1 发送给接收者的token1的数量
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Swap token0 for token1, or token1 for token0
    /// 用token0换token1，或用token1换token0
    /// @dev The caller of this method receives a callback in the form of IUniswapV3SwapCallback#uniswapV3SwapCallback
    /// 这个方法的调用者以IUniswapV3SwapCallback#uniswapV3SwapCallback的形式接收回调
    /// @param recipient The address to receive the output of the swap
    /// 接收交换的输出的地址
    /// @param zeroForOne The direction of the swap, true for token0 to token1, false for token1 to token0
    /// 交换的方向，token0到token1为真，token1到token0为假
    /// @param amountSpecified The amount of the swap, which implicitly configures the swap as exact input (positive), or exact output (negative)
    /// 交换的数量，它隐式地将交换配置为精确输入(正数)或精确输出(负数)。为正，则为精确输入；为负，则为精确输出。
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this
    /// value after the swap. If one for zero, the price cannot be greater than this value after the swap
    /// 交换后的token0的价格限制
    /// 如果token0换token1，则交换后的价格不能小于此值，因为交换后token0会贬值，而价格是以token0计价的。
    /// 如果token1换token0，则交换后的价格不能大于此值，因为交换后token0会升值，而价格是以token0计价的。
    /// @param data Any data to be passed through to the callback
    /// @return amount0 The delta of the balance of token0 of the pool, exact when negative, minimum when positive
    /// @return amount1 The delta of the balance of token1 of the pool, exact when negative, minimum when positive
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    /// @notice Receive token0 and/or token1 and pay it back, plus a fee, in the callback
    /// @dev The caller of this method receives a callback in the form of IUniswapV3FlashCallback#uniswapV3FlashCallback
    /// @dev Can be used to donate underlying tokens pro-rata to currently in-range liquidity providers by calling
    /// with 0 amount{0,1} and sending the donation amount(s) from the callback
    /// @param recipient The address which will receive the token0 and token1 amounts
    /// @param amount0 The amount of token0 to send
    /// @param amount1 The amount of token1 to send
    /// @param data Any data to be passed through to the callback
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;

    /// @notice Increase the maximum number of price and liquidity observations that this pool will store
    /// @dev This method is no-op if the pool already has an observationCardinalityNext greater than or equal to
    /// the input observationCardinalityNext.
    /// @param observationCardinalityNext The desired minimum number of observations for the pool to store
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

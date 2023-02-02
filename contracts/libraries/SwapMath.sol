// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './FullMath.sol';
import './SqrtPriceMath.sol';

/// @title Computes the result of a swap within ticks
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
/// @title 计算ticks内一次swap（交换）的结果
/// @notice 包含在一个tick价格范围内计算一次交换结果的方法。
library SwapMath {
    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive
    /// @param sqrtRatioCurrentX96 The current sqrt price of the pool
    /// @param sqrtRatioTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtRatioNextX96 The price after swapping the amount in/out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee

    /// @notice 给定交换的参数,计算交换一些amountin或者amountout的结果
    /// @dev 如果swap的amountSpecified为正数，则fee加上amountin将永远不会超过剩余的金额。fee加上amountin就是trader的输入金额。
    /// amountSpecified是UniswapV3Pool.sol中swap方法的一个参数，代表交换的数量，它隐式地将交换配置为精确输入(正数)或精确输出(负数)。为正，则为精确输入；为负，则为精确输出。
    /// @param sqrtRatioCurrentX96 当前池的根号价格
    /// @param sqrtRatioTargetX96 不能超过的价格，即price target,从这个价格可以推断出swap的方向，是0换1,还是1换0
    /// @param liquidity 可用的流动性
    /// @param amountRemaining 还有多少input或output数量需要swap
    /// @param feePips 从输入金额中收取的费用，以百分之一bip表示
    /// @return sqrtRatioNextX96 交换amountin/amountout后的价格，不超过目标价格sqrtRatioTargetX96
    /// @return amountIn 根据交换方向，token0或token1的swapped in数量
    /// @return amountOut 根据交换方向，trader接收到的token0或token1的数量
    /// @return feeAmount 将被作为手续费的amountin
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    )
        internal
        pure
        returns (
            uint160 sqrtRatioNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        // 如果池子的当前token0价格大于等于目标价格，说明token0要降价，即用token0交换token1
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        // amountRemaining是正数，就说明是exactIn，如果是负数，就是exactOut
        bool exactIn = amountRemaining >= 0;

        if (exactIn) { // 精确输入
            // 刨除fee之后的amountin
            uint256 amountRemainingLessFee = FullMath.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);
            amountIn = zeroForOne
                // 如果token0换token1,根据当前价格、目标价格、流动性，计算需要付出的amount0in
                // getAmount0Delta用于获取两个价格之间的amount0增量
                // 即计算liquidity / sqrt(lower) - liquidity / sqrt(upper)，也就是liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                // 如果token1换token0,根据当前价格、目标价格、流动性，计算需要付出的amount1in
                // getAmount1Delta用于获取两个价格之间的amount1增量
                // 即计算liquidity * (sqrt(upper) - sqrt(lower))
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            // 如果“刨除fee之后的amountin”刚好等于或者大于“需要付出的amountin”，说明amountin可能有剩余，那么就把目标价格设置为真正的swap后的价格，即swap后，价格就变成了目标价格
            if (amountRemainingLessFee >= amountIn) sqrtRatioNextX96 = sqrtRatioTargetX96;
            else
                // “刨除fee之后的amountin”小于“需要付出的amountin”，换句话说，就是amountin不够，那么swap之后的价格就达不到目标价格，所以需要根据amountin重新计算真实的swap之后的价格
                // getNextSqrtPriceFromInput用于在给定token0或token1 amountin的情况下获取下一个根号价格，然后把这个价格设置为真正的swap之后的价格
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
        } else { // 精确输出
            amountOut = zeroForOne
                // 如果token0换token1,根据当前价格、目标价格、流动性，计算能够得到的amount1out
                // getAmount1Delta用于获取两个价格之间的amount1增量
                // 即计算liquidity * (sqrt(upper) - sqrt(lower))
                ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                // 如果token1换token0,根据当前价格、目标价格、流动性，计算能够得到的amount0out
                // getAmount0Delta用于获取两个价格之间的amount0增量
                // 即计算liquidity / sqrt(lower) - liquidity / sqrt(upper)，也就是liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            // 如果期望amountout大于等于价格变化能够得到的amountout，说明能够得到的amountout还未超出期望amountout，那么就用传参sqrtRatioTargetX96作为swap后真正的目标价格
            if (uint256(-amountRemaining) >= amountOut) sqrtRatioNextX96 = sqrtRatioTargetX96;
            else
                // 如果期望amountout小于价格变化能够得到的amountout，说明能够得到的amountout已经超出了期望amountout，则需要重新计算swap后真正的目标价格
                // getNextSqrtPriceFromOutput用于在给定token0或token1的amountout的情况下获取下一个平方根价格，用这个价格作为swap后真正的目标价格
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(//TODO
                    sqrtRatioCurrentX96,
                    liquidity,
                    uint256(-amountRemaining),
                    zeroForOne
                );
        }
        // 以上这一段确定了swap后真正的目标价格sqrtRatioNextX96，是传参输入的目标价格，还是重新计算后的目标价格。目的是为了下面计算amountIn和amountOut。

        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96; // 如果传参输入的目标价格就是swap后真正的目标价格，则为true

        // get the input/output amounts
        if (zeroForOne) {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true); // TODO：可以直接改为amountRemainingLessFee，因为上面的代码中已经通过amountRemainingLessFee计算过sqrtRatioNextX96，那么，通过sqrtRatioNextX96计算amountin算出来肯定也是amountRemainingLessFee，所以，不需要再重复计算
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true); // TODO：可以直接改为amountRemainingLessFee，因为上面的代码中已经通过amountRemainingLessFee计算过sqrtRatioNextX96，那么，通过sqrtRatioNextX96计算amountin算出来肯定也是amountRemainingLessFee，所以，不需要再重复计算
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }
        // 以上这一段确定了amountIn和amountOut。

        // cap the output amount to not exceed the remaining output amount
        // 限制amountout，不超过剩余的output
        // 如果是精确输出，且max==true，那么uint256(-amountRemaining) >= amountOut，则不会执行以下语句
        // 只有max==false，然后重新计算amountOut后，才可能出现重新计算的amountOut都仍然超过期望amountOut，即uint256(-amountRemaining)，那么就把amountOut的值设置为uint256(-amountRemaining)
        // TODO：为什么这种场景不抛出异常？而是要amountOut = uint256(-amountRemaining)？
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }

        // TODO：以下判断中，sqrtRatioNextX96 != sqrtRatioTargetX96可以改为!max
        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // 这种场景的出现说明amountIn是用完了的，上面的代码已经计算除了刨除手续费后的amountRemainingLessFee，amountRemainingLessFee一定就是amountIn
            // 所以amountRemaining-amountIn=amountRemaining-amountRemainingLessFee=手续费
            // we didn't reach the target, so take the remainder of the maximum input as fee
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            // 根据手续费比例计算手续费
            feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }
}

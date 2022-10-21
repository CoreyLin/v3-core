// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './LowGasSafeMath.sol';
import './SafeCast.sol';

import './TickMath.sol';
import './LiquidityMath.sol';

/// @title Tick
/// @notice Contains functions for managing tick processes and relevant calculations
library Tick {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    // info stored for each initialized individual tick
    // 为每个初始化的单个tick存储的信息
    struct Info {
        // the total position liquidity that references this tick
        // 引用该tick的总头寸流动性
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        // 当tick从左到右(从右到左)交叉时增加(减去)的净流动性数量
        // 注意类型是有符号整数，当为正数时说明从左到右应该增加，当为负数时说明从左到右应该减去
        int128 liquidityNet;
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        // 在tick的另一端的每单位流动性的手续费增长(相对于当前tick)
        // 只有相对意义，而不是绝对意义-该值取决于tick的初始化时间
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        // the cumulative tick value on the other side of the tick
        // tick另一端的累计tick值
        int56 tickCumulativeOutside;
        // the seconds per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        // 该tick的另一端每单位流动性的秒数(相对于当前tick)
        // 只有相对意义，而不是绝对意义-该值取决于tick的初始化时间
        uint160 secondsPerLiquidityOutsideX128;
        // the seconds spent on the other side of the tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        // 在tick的另一端花费的时间(相对于当前tick)
        // 只有相对意义，而不是绝对意义-该值取决于tick的初始化时间
        uint32 secondsOutside;
        // true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0
        // these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
        // true如果tick被初始化，即该值完全等价于表达式liquidityGross != 0
        // 这8位被设置为在跨越新初始化的tick时防止新sstores
        bool initialized;
    }

    /// @notice Derives max liquidity per tick from given tick spacing
    /// @dev Executed within the pool constructor
    /// @param tickSpacing The amount of required tick separation, realized in multiples of `tickSpacing`
    ///     e.g., a tickSpacing of 3 requires ticks to be initialized every 3rd tick i.e., ..., -6, -3, 0, 3, 6, ...
    /// @return The max liquidity per tick
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        return type(uint128).max / numTicks;
    }

    /// @notice Retrieves fee growth data
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @param tickCurrent The current tick
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @return feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @return feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries

    /// @notice 获取tickLower和tickUpper之间每单位流动性手续费增长数据
    /// @param self 包含所有已初始化tick的tick信息的映射
    /// @param tickLower 头寸的下tick边界
    /// @param tickUpper 头寸的上tick边界
    /// @param tickCurrent 当前tick
    /// @param feeGrowthGlobal0X128 每单位流动性的全局手续费增长，以token0为单位
    /// @param feeGrowthGlobal1X128 每单位流动性的全局手续费增长，以token1为单位
    /// @return feeGrowthInside0X128 每单位流动性的token0的总手续费增长，在头寸的tick边界内
    /// @return feeGrowthInside1X128 每单位流动性的token1的总手续费增长，在头寸的tick边界内
    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        Info storage lower = self[tickLower]; // 取出tickLower的Info
        Info storage upper = self[tickUpper]; // 取出tickUpper的Info

        // 以下的计算逻辑，只要画图之后，就很好理解
        // calculate fee growth below
        // 计算“下面”，即tickLower左边的手续费累积
        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (tickCurrent >= tickLower) {
            feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
        }

        // calculate fee growth above
        // 计算“上面”，即tickUpper右边的手续费累积
        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (tickCurrent < tickUpper) {
            feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
        }

        // 总的手续费累积，减去tickLower左边的手续费累积和tickUpper右边的手续费累积，就剩tickLower和tickUpper之间的手续费累积
        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The tick that will be updated
    /// @param tickCurrent The current tick
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @param secondsPerLiquidityCumulativeX128 The all-time seconds per max(1, liquidity) of the pool
    /// @param tickCumulative The tick * time elapsed since the pool was first initialized
    /// @param time The current block timestamp cast to a uint32
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    /// @param maxLiquidity The maximum liquidity allocation for a single tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa

    /// @notice 更新一个tick，如果该tick从初始化翻转到未初始化则返回true，反之亦然
    /// @param self 包含所有已初始化ticks的tick信息的映射
    /// @param tick 将被更新的tick
    /// @param tickCurrent 当前tick
    /// @param liquidityDelta 当tick从左到右(从右到左)交叉时，增加(减去)一个新的流动性量
    /// @param feeGrowthGlobal0X128 每单位流动性的全部时间全局费用增长，以token0为单位
    /// @param feeGrowthGlobal1X128 每单位流动性的全部时间全局费用增长，以token1为单位
    /// @param secondsPerLiquidityCumulativeX128 池中全部时间每单位流动性的秒数累积
    /// @param tickCumulative 自池第一次初始化以来的tick * 时间
    /// @param time 当前区块时间戳，转换为uint32
    /// @param upper 更新头寸的upper tick为true，更新头寸的lower tick为false
    /// @param maxLiquidity 单个tick的最大流动性分配
    /// @return flipped 是否将tick从初始化转换为未初始化，或反之亦然
    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 tickCurrent, // 此参数只用在了tick的流动性从无到有的情况下
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        // 为每个初始化的单个tick存储的信息
        Tick.Info storage info = self[tick]; // 注意是storage

        uint128 liquidityGrossBefore = info.liquidityGross; // 引用该tick的总头寸流动性
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta); // 该tick新增后的总流动性

        require(liquidityGrossAfter <= maxLiquidity, 'LO'); // 该tick新增后的总流动性必须小于单个tick的最大流动性分配

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0); // 流动性从无到有，或流动性从有到无，则为true；否则为false

        if (liquidityGrossBefore == 0) { // 如果原先该tick的流动性为0,即未初始化
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            // 按照惯例，我们假设在tick初始化之前的所有增长都发生在tick的“下面”，即左边
            // 如果将被更新的tick < 当前tick，即被更新的tick在当前tick的左边，那么就把当前积累的一些状态变量赋给tick的outside属性
            // 此处得出一个结论，当前tick右边的就是outside的
            if (tick <= tickCurrent) { // 如果将被更新的tick < 当前tick，即被更新的tick在当前tick的左边
                // 如果 tick>tickCurrent，那么以下这些outside属性全都是默认的0,即对于本tick来说，没有outside的值
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128; // 每单位流动性的全部时间全局费用增长，以token0为单位
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128; // 每单位流动性的全部时间全局费用增长，以token1为单位
                info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128; // 池中全部时间每单位流动性的秒数累积
                info.tickCumulativeOutside = tickCumulative; // 自池第一次初始化以来的tick * 时间
                info.secondsOutside = time; // 在tick的另一端花费的时间(相对于当前tick)
            }
            info.initialized = true; // 既然tick的流动性是从无到有，那么就设置为已初始化
        }

        info.liquidityGross = liquidityGrossAfter; // 更新tick的流动性

        // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        // 当下(上)tick从左到右(从右到左)交叉时，流动性必须添加(删除)
        info.liquidityNet = upper
            // 注意liquidityNet类型是有符号整数，当新增流动性时，liquidityDelta为正数；当减少流动性时，liquidityDelta为负数
            // 以新增流动性且流动性从无到有的场景为例，liquidityDelta为正数，那么更新后的info.liquidityNet为-liquidityDelta，即从左到右穿过upper tick时，增加的流动性为 -liquidityDelta，即增加了一个负数，就等于减去了一个正数
            // 以移除流动性为例，移除之前，upper tick的liquidityNet为-6,然后全部移除，传入的liquidityDelta为-6, -6-(-6)=0，即移除后upper tick的liquidityNet为0了
            ? int256(info.liquidityNet).sub(liquidityDelta).toInt128()
            : int256(info.liquidityNet).add(liquidityDelta).toInt128(); // 从左到右穿过lower tick时，增加的流动性为 info.liquidityNet+liquidityDelta
    }

    /// @notice Clears tick data
    /// @param self The mapping containing all initialized tick information for initialized ticks
    /// @param tick The tick that will be cleared

    /// @notice 清除tick数据
    /// @param self 包含所有已初始化tick的tick信息的映射
    /// @param tick 将被清除的tick
    function clear(mapping(int24 => Tick.Info) storage self, int24 tick) internal {
        delete self[tick];
    }

    /// @notice Transitions to next tick as needed by price movement
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The destination tick of the transition
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @param secondsPerLiquidityCumulativeX128 The current seconds per liquidity
    /// @param tickCumulative The tick * time elapsed since the pool was first initialized
    /// @param time The current block.timestamp
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time
    ) internal returns (int128 liquidityNet) {
        Tick.Info storage info = self[tick];
        info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
        info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128 - info.secondsPerLiquidityOutsideX128;
        info.tickCumulativeOutside = tickCumulative - info.tickCumulativeOutside;
        info.secondsOutside = time - info.secondsOutside;
        liquidityNet = info.liquidityNet;
    }
}

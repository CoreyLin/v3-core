// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './FullMath.sol';
import './FixedPoint128.sol';
import './LiquidityMath.sol';

/// @title Position
/// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
/// @dev Positions store additional state for tracking fees owed to the position
library Position {
    // info stored for each user's position
    // 每个用户的头寸信息
    struct Info {
        // the amount of liquidity owned by this position
        // 该头寸拥有的流动性数量
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        // 截至上次更新流动性或所欠手续费时，每单位流动性的手续费增长
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // the fees owed to the position owner in token0/token1
        // token0/token1中欠头寸所有者的金额（本金+手续费）
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @notice Returns the Info struct of a position, given an owner and position boundaries
    /// 给定头寸的所有者和头寸边界，返回头寸的Info结构体
    /// @param self The mapping containing all user positions
    /// 包含所有用户头寸的映射
    /// @param owner The address of the position owner
    /// 头寸所有者的地址
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return position The position info struct of the given owners' position
    function get(
        mapping(bytes32 => Info) storage self, // 注意：storage
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (Position.Info storage position) { // 注意：storage
        position = self[keccak256(abi.encodePacked(owner, tickLower, tickUpper))];
    }

    /// @notice Credits accumulated fees to a user's position
    /// @param self The individual position to update
    /// @param liquidityDelta The change in pool liquidity as a result of the position update
    /// @param feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @param feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries

    /// @notice 累积手续费到一个用户的头寸
    /// @param self 要更新的单个头寸
    /// @param liquidityDelta 由于头寸更新而导致的池流动性的变化
    /// @param feeGrowthInside0X128 每单位流动性的token0的总费用增长，在头寸的tick边界内
    /// @param feeGrowthInside1X128 每单位流动性的token1的总费用增长，在头寸的tick边界内
    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        Info memory _self = self; // 节约gas费

        uint128 liquidityNext;
        if (liquidityDelta == 0) { // 如果流动性不增不减
            require(_self.liquidity > 0, 'NP'); // disallow pokes for 0 liquidity positions
            liquidityNext = _self.liquidity;
        } else {
            liquidityNext = LiquidityMath.addDelta(_self.liquidity, liquidityDelta); // 增加或减少流动性
        }

        // calculate accumulated fees
        // 计算累积的手续费
        // 新积累的token0手续费 = （feeGrowthInside0X128 - feeGrowthInside0LastX128）× 原来的liquidity
        // 之所以乘以原来的liquidity，是因为截至到当前为止，手续费都是原来的流动性挣的，和这次新增/减少的流动性没有关系
        uint128 tokensOwed0 =
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside0X128 - _self.feeGrowthInside0LastX128,
                    _self.liquidity,
                    FixedPoint128.Q128
                )
            );
        // 新积累的token1手续费 = （feeGrowthInside1X128 - feeGrowthInside1LastX128）× 原来的liquidity
        uint128 tokensOwed1 =
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside1X128 - _self.feeGrowthInside1LastX128,
                    _self.liquidity,
                    FixedPoint128.Q128
                )
            );

        // update the position
        // 更新头寸
        if (liquidityDelta != 0) self.liquidity = liquidityNext; // 如果流动性增量不等于0,就更新storage position的流动性
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            // overflow is acceptable, have to withdraw before you hit type(uint128).max fees
            // 溢出是可以接受的，在手续费达到type(uint128).max之前必须移除流动性
            self.tokensOwed0 += tokensOwed0;
            self.tokensOwed1 += tokensOwed1;
        }
    }
}

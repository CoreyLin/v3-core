// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title An interface for a contract that is capable of deploying Uniswap V3 Pools
/// @notice A contract that constructs a pool must implement this to pass arguments to the pool
/// @dev This is used to avoid having constructor arguments in the pool contract, which results in the init code hash
/// of the pool being constant allowing the CREATE2 address of the pool to be cheaply computed on-chain

/// @title 一个能够部署Uniswap V3 Pools的合约接口
/// @notice 构造一个池的合约必须实现这个接口来将参数传递给池。所以pool必须由合约部署，而不能由EOA部署。
/// @dev 这是用来避免在池合约中有构造函数参数，这导致池的init code hash是常量，允许池的CREATE2地址在链上被廉价计算
interface IUniswapV3PoolDeployer {
    /// @notice Get the parameters to be used in constructing the pool, set transiently during pool creation.
    /// @dev Called by the pool constructor to fetch the parameters of the pool
    /// Returns factory The factory address
    /// Returns token0 The first token of the pool by address sort order
    /// Returns token1 The second token of the pool by address sort order
    /// Returns fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// Returns tickSpacing The minimum number of ticks between initialized ticks

    /// @notice 获取用于构建池的参数，在创建池时临时设置。
    /// @dev 由池的构造函数调用此方法来获取池的参数
    /// 返回工厂合约地址
    /// 返回token0地址
    /// 返回token1地址
    /// 返回在池中每次swap时收取的费用，以百分之一bip为单位
    /// 返回tickSpacing 初始化的ticks之间的最小ticks数，即两个初始化的tick之间最少相隔几个tick
    function parameters()
        external
        view
        returns (
            address factory,
            address token0,
            address token1,
            uint24 fee,
            int24 tickSpacing
        );
}

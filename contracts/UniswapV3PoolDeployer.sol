// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3PoolDeployer.sol';

import './UniswapV3Pool.sol';

contract UniswapV3PoolDeployer is IUniswapV3PoolDeployer {
    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @inheritdoc IUniswapV3PoolDeployer
    Parameters public override parameters; // 状态变量

    /// @dev Deploys a pool with the given parameters by transiently setting the parameters storage slot and then
    /// clearing it after deploying the pool.
    /// 通过临时设置参数存储槽位，然后在部署池后清除该存储槽位，部署具有给定参数的池。
    /// @param factory The contract address of the Uniswap V3 factory
    /// @param token0 The first token of the pool by address sort order
    /// @param token1 The second token of the pool by address sort order
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip 池中每一次swap所收取的费用，以百分之一bip为单位
    /// @param tickSpacing The spacing between usable ticks 可用ticks之间的间隔
    function deploy(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (address pool) {
        // 给状态变量赋值，UniswapV3Pool的构造函数会反向查询 UniswapV3Factory 中的 parameters 值来进行初始变量的赋值
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing});
        // 使用new部署合约，然后返回地址。注意salt是固定的，和token0, token1, fee的哈希有关
        // new的底层实际上使用的create2，只要合约的bytecode及salt不变，那么部署后的地址也不变，可以在链下计算出已经创建的交易池的地址，具体计算方法，参考：
        // https://github.com/Uniswap/v3-periphery/blob/3514c56ccf84a2d32b623004e7c119494ac729cc/contracts/libraries/PoolAddress.sol#L15-L38
        // 为什么不直接使用参数传递来对新合约的状态变量赋值呢。这是因为 CREATE2 会将合约的 initcode 和 salt 一起用来计算创建出的合约地址。
        // 而 initcode 是包含 contructor code 和其参数的，如果合约的 constructor 函数包含了参数，那么其 initcode 将因为其传入参数不同而不同。在 off-chain 计算合约地址时，也需要通过这些参数来查询对应的 initcode。为了让合约地址的计算更简单，这里的 constructor 不包含参数（这样合约的 initcode 将时唯一的），而是使用动态 call 的方式来获取其创建参数。
        pool = address(new UniswapV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}());
        delete parameters; // 这一步对节省gas费很重要，清除结构体的每个属性，释放未使用的存储空间，可以因释放未使用的存储空间而获得 gas 退款，黄皮书中记载“当存储值从非零设置为零时给予退款”
    }
}

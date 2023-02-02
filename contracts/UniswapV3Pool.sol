// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3Pool.sol';

import './NoDelegateCall.sol';

import './libraries/LowGasSafeMath.sol';
import './libraries/SafeCast.sol';
import './libraries/Tick.sol';
import './libraries/TickBitmap.sol';
import './libraries/Position.sol';
import './libraries/Oracle.sol';

import './libraries/FullMath.sol';
import './libraries/FixedPoint128.sol';
import './libraries/TransferHelper.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/SqrtPriceMath.sol';
import './libraries/SwapMath.sol';

import './interfaces/IUniswapV3PoolDeployer.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/callback/IUniswapV3MintCallback.sol';
import './interfaces/callback/IUniswapV3SwapCallback.sol';
import './interfaces/callback/IUniswapV3FlashCallback.sol';

contract UniswapV3Pool is IUniswapV3Pool, NoDelegateCall {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override factory;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override token0;
    /// @inheritdoc IUniswapV3PoolImmutables
    address public immutable override token1;
    /// @inheritdoc IUniswapV3PoolImmutables
    uint24 public immutable override fee;

    /// @inheritdoc IUniswapV3PoolImmutables
    int24 public immutable override tickSpacing;

    /// @inheritdoc IUniswapV3PoolImmutables
    uint128 public immutable override maxLiquidityPerTick;

    struct Slot0 {
        // the current price
        // 当前价格
        uint160 sqrtPriceX96;
        // the current tick
        // 当前的tick
        int24 tick;
        // the most-recently updated index of the observations array
        // observations数组最近更新的索引
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        // 当前被存储的最大observations数量
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        // 下一个要存储的最大observations数量，在observations.write中触发
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        // 当前协议费用占提取时swap手续费的百分比，表示为整数分母(1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        // 池是否被锁定
        bool unlocked;
    }
    /// @inheritdoc IUniswapV3PoolState
    Slot0 public override slot0;

    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal1X128;

    // accumulated protocol fees in token0/token1 units
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    /// @inheritdoc IUniswapV3PoolState
    ProtocolFees public override protocolFees;

    /// @inheritdoc IUniswapV3PoolState
    /// @notice The currently in range liquidity available to the pool
    /// 可用于池的当前范围内的流动性
    /// @dev This value has no relationship to the total liquidity across all ticks
    /// 这个值与所有ticks的总流动性没有关系
    uint128 public override liquidity;

    /// @inheritdoc IUniswapV3PoolState
    mapping(int24 => Tick.Info) public override ticks;
    /// @inheritdoc IUniswapV3PoolState
    mapping(int16 => uint256) public override tickBitmap;
    /// @inheritdoc IUniswapV3PoolState
    mapping(bytes32 => Position.Info) public override positions;
    /// @inheritdoc IUniswapV3PoolState
    // Observation数组，长度为65535
    Oracle.Observation[65535] public override observations;

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock() {
        require(slot0.unlocked, 'LOK');
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    /// @dev Prevents calling a function from anyone except the address returned by IUniswapV3Factory#owner()
    modifier onlyFactoryOwner() {
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

    constructor() {
        int24 _tickSpacing;
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters(); // 反向查询 UniswapV3Factory 中的 parameters 值来进行初始变量的赋值
        // tickSpacing是在factory合约里写死的，分为三个梯度
        // 1.手续费0.05%：tickSpacing为10
        // 2.手续费0.3%：tickSpacing为60
        // 3.手续费0.1%：tickSpacing为200
        // 手续费越高，tickSpacing越大。因为手续费越低的pool，往往资产价格越稳定，价格波动不大，所以tickSpacing就需要小一些，而手续费越高的pool，资产价格波动大，所以tickSpacing可以大一些
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    /// @dev Common checks for valid tick inputs.
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, 'TLU'); // tickLower必须小于tickUpper
        require(tickLower >= TickMath.MIN_TICK, 'TLM');
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');
    }

    /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
    /// 返回截断为32位的区块时间戳，即mod 2**32。
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    /// @dev 获取pool的token0的余额
    /// @dev 这个函数是gas优化的，以避免除了returndatasize检查之外的多余的extcodesize检查
    function balance0() private view returns (uint256) {
        // The staticcall is a security improvement, as it allows a contract to call another contract (or itself) without modifying the state.
        // If you try to call something in another contract with staticcall, and that contract attempts to change state then an exception gets thrown and the call fails.
        // staticcall works in a similar way as a normal call (without any value (sending eth) as this would change state). But when staticcall is used, the EVM has a STATIC flag set to true. Then, if any state modification is attempted, an exception is thrown. Once the staticcall returns, the flag is turned off.
        // [success, returnData] = aContratAddress.staticcall(bytesToSend)
        // 详细参考 https://cryptoguide.dev/post/guide-to-solidity's-staticcall-and-how-to-use-it/
        // 此处为什么要用staticcall: https://ethereum.stackexchange.com/questions/135922/what-is-need-to-use-staticcall-and-encodewithselector-for-fetching-the-balance
        (bool success, bytes memory data) =
            token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        // bytes转uint256的方法：abi.decode
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) =
            token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external
        view
        override
        noDelegateCall
        returns (
            int56 tickCumulativeInside,
            uint160 secondsPerLiquidityInsideX128,
            uint32 secondsInside
        )
    {
        checkTicks(tickLower, tickUpper);

        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        {
            Tick.Info storage lower = ticks[tickLower];
            Tick.Info storage upper = ticks[tickUpper];
            bool initializedLower;
            (tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = (
                lower.tickCumulativeOutside,
                lower.secondsPerLiquidityOutsideX128,
                lower.secondsOutside,
                lower.initialized
            );
            require(initializedLower);

            bool initializedUpper;
            (tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = (
                upper.tickCumulativeOutside,
                upper.secondsPerLiquidityOutsideX128,
                upper.secondsOutside,
                upper.initialized
            );
            require(initializedUpper);
        }

        Slot0 memory _slot0 = slot0;

        if (_slot0.tick < tickLower) {
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } else if (_slot0.tick < tickUpper) {
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    _slot0.tick,
                    _slot0.observationIndex,
                    liquidity,
                    _slot0.observationCardinality
                );
            return (
                tickCumulative - tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 -
                    secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                time - secondsOutsideLower - secondsOutsideUpper
            );
        } else {
            return (
                tickCumulativeUpper - tickCumulativeLower,
                secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128,
                secondsOutsideUpper - secondsOutsideLower
            );
        }
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        noDelegateCall
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
    }

    /// @inheritdoc IUniswapV3PoolActions
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext)
        external
        override
        lock
        noDelegateCall
    {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew =
            observations.grow(observationCardinalityNextOld, observationCardinalityNext);
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev not locked because it initializes unlocked
    function initialize(uint160 sqrtPriceX96) external override {
        require(slot0.sqrtPriceX96 == 0, 'AI'); // 如果不为0,则已经调用过initialize进行过初始化了，初始化只能进行一次

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96); // 计算最大的tick值，使getRatioAtTick(tick) <= ratio

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96, // 初始价格
            tick: tick, // 初始价格对应的tick
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true // 未锁定
        });

        emit Initialize(sqrtPriceX96, tick);
    }

    struct ModifyPositionParams {
        // the address that owns the position 拥有该头寸的地址
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity 流动性变化
        int128 liquidityDelta;
    }

    /// @dev Effect some changes to a position
    /// 对一个头寸进行一些改变
    /// @param params the position details and the change to the position's liquidity to effect
    /// 头寸细节和头寸流动性变化的影响
    /// @return position a storage pointer referencing the position with the given owner and tick range
    /// 一个存储指针，它引用具有给定所有者和tick范围的头寸。所有者通常就是NonfungiblePositionManager
    /// @return amount0 the amount of token0 owed to the pool, negative if the pool should pay the recipient
    /// LP欠池token0的金额，如果池应该支付给接收者，则为负数
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    /// LP欠池token0的金额，如果池应该支付给接收者，则为负数
    function _modifyPosition(ModifyPositionParams memory params)
        private
        noDelegateCall // 判断不是delegatecall，即状态变量的变化应该作用于UniswapV3Pool自己的存储槽，而不是外层调用合约
        returns (
            Position.Info storage position, // 注意，返回的position是storage修饰的
            int256 amount0,
            int256 amount1
        )
    {
        checkTicks(params.tickLower, params.tickUpper); // 校验tick的合法性

        Slot0 memory _slot0 = slot0; // SLOAD for gas optimization 节约gas费

        // 获取头寸并用给定流动性增量（减量）更新它
        position = _updatePosition(
            params.owner, // 此处的owner是NonfungiblePositionManager合约
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta, // 增加或者移除的流动性数量，可为正，可为负
            _slot0.tick
        );

        // 如果有流动性的增减
        if (params.liquidityDelta != 0) {
            // 当前价格小于tickLower，注意：统一以token0价格为准，P=reserve1/reserve0，token0是横坐标，token1是纵坐标
            if (_slot0.tick < params.tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ token0 (it's becoming more valuable) so user must provide it
                // 当前tick低于position的范围;流动性只能通过从左到右交叉进入范围，当我们需要_more_ token0时(它变得更有价值)，所以用户必须提供它
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            // Pa<=P<Pb，Pa是价格下限，P是当前价格，Pb是价格上限
            } else if (_slot0.tick < params.tickUpper) {
                // current tick is inside the passed range
                uint128 liquidityBefore = liquidity; // SLOAD for gas optimization

                // write an oracle entry
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96, // 当前价格P
                    TickMath.getSqrtRatioAtTick(params.tickUpper), // 价格上限Pb
                    params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower), // 价格下限Pa
                    _slot0.sqrtPriceX96, // 当前价格P
                    params.liquidityDelta
                );

                // pool的liquidity属性代表“The currently in range liquidity available to the pool”
                // 如果Pa<=P<Pb，说明此position的流动性在范围内，是当前可用的流动性，所以会引起池子当前总的可用的流动性的增减
                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ token1 (it's becoming more valuable) so user must provide it
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev Gets and updates a position with the given liquidity delta
    /// 获取头寸并用给定流动性增量（减量）更新它
    /// @param owner the owner of the position
    /// 头寸的owner，通常是NonfungiblePositionManager
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    /// @param tick the current tick, passed to avoid sloads
    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta, // 当新增流动性时，liquidityDelta为正数；当减少流动性时，liquidityDelta为负数
        int24 tick // 池子当前的价格
    ) private returns (Position.Info storage position) { // 注意：返回的position是storage修饰的
        // 给定头寸的所有者和头寸边界，返回头寸的Info结构体
        position = positions.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128; // SLOAD for gas optimization
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128; // SLOAD for gas optimization

        // if we need to update the ticks, do it
        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) { // liquidityDelta为非0,意味着流动性有增加或者减少
            uint32 time = _blockTimestamp(); // 获取当前区块时间
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                // 如果在所需的观察时间戳或之前的observation不存在，则回滚。0可以作为secondsAgo传递，以返回当前的累积值。
                // 如果使用位于两个观察之间的时间戳调用，则返回恰好位于两个观察之间的时间戳处的反事实累加器值。
                observations.observeSingle( // Observation数组，长度为65535
                    time, // 当前区块的时间戳
                    0,
                    slot0.tick, // 当前的tick
                    slot0.observationIndex, // observations数组最近更新的索引
                    liquidity, // 当前in-range的池的流动性
                    slot0.observationCardinality // 当前被存储的最大observations数量，即oracle数组中被填充元素的数量
                );

            // flippedLower和flippedUpper代表是否将tick从初始化转换为未初始化，或反之亦然
            // 更新lower tick，如果该tick从初始化翻转到未初始化则返回true，反之亦然
            flippedLower = ticks.update(
                tickLower, // 将被更新的tick，此处是头寸的lower tick
                tick, // 当前tick
                liquidityDelta, // 当tick从左到右(从右到左)交叉时，增加(减去)一个新的流动性量
                _feeGrowthGlobal0X128, // 每单位流动性的全部时间全局费用增长，以token0为单位
                _feeGrowthGlobal1X128, // 每单位流动性的全部时间全局费用增长，以token1为单位
                secondsPerLiquidityCumulativeX128, // 在observeSingle里已经更新
                tickCumulative, // 在observeSingle里已经更新
                time, // 当前区块时间戳，转换为uint32
                false, // 更新头寸的lower tick为false
                maxLiquidityPerTick // 当前每tick的最大in range流动性数量
            );
            // 更新upper tick，如果该tick从初始化翻转到未初始化则返回true，反之亦然
            flippedUpper = ticks.update(
                tickUpper, // 将被更新的tick，此处是头寸的upper tick
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true, // 更新头寸的lower tick为false
                maxLiquidityPerTick
            );

            if (flippedLower) {
                // 将给定tick的初始化状态从false翻转为true，反之亦然
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                // 将给定tick的初始化状态从false翻转为true，反之亦然
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        // 获取tickLower和tickUpper之间每单位流动性手续费增长数据
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        // 累积手续费到一个用户的头寸
        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        // clear any tick data that is no longer needed
        // 清除不再需要的tick数据
        // 当新增流动性时，liquidityDelta为正数；当减少流动性时，liquidityDelta为负数。此处指的是减少流动性的场景，减少流动性可能引起tickLower和tickUpper的总流动性变为0.
        if (liquidityDelta < 0) {
            if (flippedLower) { // tickLower的总流动性从有到无
                ticks.clear(tickLower); // 清除tick数据
            }
            if (flippedUpper) { // tickUpper的总流动性从有到无
                ticks.clear(tickUpper);
            }
        }
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    /// 为指定的recipient/tickLower/tickUpper position增加流动性
    /// 在core pool中，所有的positions的recipient都是NonfungiblePositionManager合约，由NonfungiblePositionManager合约统一管理LP的仓位
    /// 此方法被LiquidityManagement.sol的addLiquidity方法调用
    function mint(
        address recipient, // NonfungiblePositionManager合约
        int24 tickLower, // 价格下限
        int24 tickUpper, // 价格上限
        uint128 amount, // 要铸造的流动性数量
        bytes calldata data // 传的abi.encode(MintCallbackData({poolKey: poolKey, payer: msg.sender})) 用abi.encode对struct MintCallbackData进行编码，编码为bytes，然后传给pool，pool用于回调
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0); // 流动性数量必须大于0
        // amount0Int是LP欠池token0的金额，如果池应该支付给接收者，则为负数。此处是增加流动性，一定为正数。
        // amount1Int是LP欠池token1的金额，如果池应该支付给接收者，则为负数。此处是增加流动性，一定为正数。
        (, int256 amount0Int, int256 amount1Int) =
            _modifyPosition( // 对一个头寸进行一些改变
                ModifyPositionParams({
                    owner: recipient, // NonfungiblePositionManager合约
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(amount).toInt128() // uint128-->int256-->int128 此处liquidityDelta一定是正数，因为是增加流动性
                })
            );

        // amount0,amount1是LP应该付出的金额，一定是正数，所以把int256转为uint256
        amount0 = uint256(amount0Int); // int256-->uint256
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        // 回调，LP把amount0和amount1转给pool
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        // 转了之后再取一次balance，确保至少转了amount0,amount1，即转的token是足够的
        if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), 'M0');
        if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), 'M1');

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
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
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        // we don't need to checkTicks here, because invalid positions will never have non-zero tokensOwed{0,1}
        // 我们不需要在这里checkTicks，因为无效的头寸永远不会有非零的tokensOwed{0,1}
        // 根据头寸的所有者，tickLower，tickUpper获取storage position
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        // 获取实际收取的token0和token1的数量
        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0; // 头寸的tokensOwed0相应减少，因为amount0要被转给position所有者或者其他人
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
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
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(amount).toInt128() // 移除流动性，liquidityDelta就需要为负数
                })
            );

        amount0 = uint256(-amount0Int); // amount0Int为LP欠池token0的金额，如果池应该支付给接收者，则为负数。此处负负得正，然后int256-->uint256
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = ( // 更新token0/token1中欠头寸所有者即NonfungiblePositionManager的金额（本金+手续费），金额增加了
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    struct SwapCache {
        // the protocol fee for the input token 输入token的协议费
        uint8 feeProtocol;
        // liquidity at the beginning of the swap 交换开始前的流动性
        uint128 liquidityStart;
        // the timestamp of the current block 当前区块的时间戳
        uint32 blockTimestamp;
        // the current value of the tick accumulator, computed only if we cross an initialized tick
        // tick累加器的当前值，仅在经过初始化的tick时计算
        int56 tickCumulative;
        // the current value of seconds per liquidity accumulator, computed only if we cross an initialized tick
        // 每单位流动性累加器的秒的当前值，只在经过初始化的tick时计算
        uint160 secondsPerLiquidityCumulativeX128;
        // whether we've computed and cached the above two accumulators
        // 我们是否计算并缓存了上述两个累加器
        bool computedLatestObservation;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    // 交换的顶层状态，其结果最后被记录在storage中
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        // 在输入/输出资产中进行交换的剩余金额，即剩余还未交换的量
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        // 输出/输入资产已经交换出/入的数量，即已经交换的量
        int256 amountCalculated;
        // current sqrt(price)
        // 当前平方根价格
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        // 与当前价格相关的tick
        int24 tick;
        // the global fee growth of the input token
        // input token的全局手续费增长
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        // 作为协议费用已支付的输入token的数量。注意：fee都是用input token计算
        uint128 protocolFee;
        // the current liquidity in range
        // 在区间内的当前流动性
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        // step刚开始的价格
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        // 在交换方向上要交换到的下一个tick
        int24 tickNext;
        // whether tickNext is initialized or not
        // tickNext是否初始化
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        // 下一个tick的根号价格
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        // 这一步的amountIn
        uint256 amountIn;
        // how much is being swapped out
        // 这一步的amountOut
        uint256 amountOut;
        // how much fee is being paid in
        // 要付多少fee
        uint256 feeAmount;
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// 用token0换token1，或用token1换token0
    // TODO 好好看看swap，是核心逻辑，关注各个状态变量是如何更新的
    function swap(
        address recipient, // 受益人是谁
        bool zeroForOne, // 是否是token0换token1
        int256 amountSpecified, // 交换的数量，它隐式地将交换配置为精确输入(正数)或精确输出(负数)。为正，则为精确输入；为负，则为精确输出。
        uint160 sqrtPriceLimitX96, // 交换后的token0的价格限制
        bytes calldata data
    ) external override noDelegateCall returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, 'AS'); // 交换的数量不能为0

        Slot0 memory slot0Start = slot0; // 将交易前的元数据保存在内存中，后续的访问通过 `MLOAD` 完成，节省 gas

        require(slot0Start.unlocked, 'LOK'); // 处于非锁定状态，防止可重入攻击，防止交易过程中回调到合约中其他的函数中修改状态变量
        require(
            zeroForOne
                // 如果token0换token1，则交换后token0会贬值，sqrtPriceLimitX96是交换后的价格，所以sqrtPriceLimitX96应该小于池子的当前价格slot0Start.sqrtPriceX96。注意：以token0计价。
                // TickMath.MIN_SQRT_RATIO是从#getSqrtRatioAtTick返回的最小值。等价于getSqrtRatioAtTick(MIN_TICK)
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                // 如果token1换token0，则交换后token0会升值，sqrtPriceLimitX96是交换后的价格，所以sqrtPriceLimitX96应该大于池子的当前价格slot0Start.sqrtPriceX96。注意：以token0计价。
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            'SPL'
        );

        slot0.unlocked = false; // 加锁，防止可重入攻击

        // 缓存交易前的数据，节省gas
        SwapCache memory cache =
            SwapCache({
                liquidityStart: liquidity, // liquidity是状态变量，代表可用于池的当前范围内的流动性，这个值与所有ticks的总流动性没有关系
                blockTimestamp: _blockTimestamp(), // 32位的区块时间戳
                // feeProtocol表示当前协议费用占提取时swap手续费的百分比，表示为整数分母(1/x)%
                feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),//TODO 这一步不懂
                secondsPerLiquidityCumulativeX128: 0, // 每单位流动性累加器的秒的当前值，只在经过初始化的tick时计算
                tickCumulative: 0, // tick累加器的当前值，仅在经过初始化的tick时计算
                computedLatestObservation: false // 我们是否计算并缓存了上述两个累加器
            });

        bool exactInput = amountSpecified > 0; // 为正，则为精确输入，exactInput为true；为负，则为精确输出，exactInput为false

        // 保存交易过程中计算所需的中间变量，这些值在交易的步骤中可能会发生变化
        SwapState memory state =
            SwapState({
                amountSpecifiedRemaining: amountSpecified, // 在输入/输出资产中进行交换的剩余金额，即剩余还未交换的量
                amountCalculated: 0, // 输出/输入资产已经交换出/入的数量，即已经交换的量。初始化为0
                sqrtPriceX96: slot0Start.sqrtPriceX96, // 当前平方根价格，即池子的当前价格
                tick: slot0Start.tick, // 与当前价格相关的tick
                feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128, // input token的全局手续费增长。在本次swap发生前已经积累了一些。
                protocolFee: 0, // 作为协议费用已支付的输入token的数量。注意：fee都是用input token计算，比如token0换token1,那输入token就是token0
                liquidity: cache.liquidityStart // 可用于池的当前范围内的流动性，这个值与所有ticks的总流动性没有关系
            });
        // 上述代码都是交易前的准备工作

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        // 只要我们没有使用完所有输入/输出，并且没有达到价格限制，就继续交换
        // sqrtPriceLimitX96是交换后的token0的价格限制
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) { // 只要交换的金额还没用完，以及池子的价格还没达到指定的价格限制
            // 每个while循环就新初始化一个StepComputations，代表一个计算步骤。有可能一个swap会包含多个计算步骤。
            StepComputations memory step;

            // 把SwapState的当前价格赋给这个step的开始价格，由于SwapState初始化的时候，sqrtPriceX96是池子的当前价格，所以，第一次while循环的时候，step.sqrtPriceStartX96就是池子的当前价格
            // 后续随着while循环的进行，state.sqrtPriceX96就会发生变化，不再是池子的当前价格，会发生偏离
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            // tickBitmap就是pool的一个状态变量
            // mapping(int16 => uint256) public override tickBitmap;
            // nextInitializedTickWithinOneWord返回与给定tick的左边(小于或等于)或右边(大于)的tick包含在同一个word(或相邻word)中的下一个初始化的tick，注意：返回的可能是已经初始化的tick，也可能是还没有初始化的tick
            // 详细的可以直接看nextInitializedTickWithinOneWord方法的注释
            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick, // SwapState的当前tick，随着循环的进行，在进行变化，初始值为池子的当前tick
                tickSpacing, // 是一个不可变状态变量，pool初始化的时候就确定了。1.手续费0.05%：tickSpacing为10 2.手续费0.3%：tickSpacing为60 3.手续费0.1%：tickSpacing为200
                zeroForOne // 如果是token0换token1，意味着token0价格下降，那么我们要找的就是给定tick左边的tick，即价格更低的tick
            );

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            // 确保我们没有超过最小/最大tick，因为tick bitmap不知道这些界限
            if (step.tickNext < TickMath.MIN_TICK) { // MIN_TICK=-887272
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) { // MAX_TICK=887272
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            // 获取下一个tick对应的根号价格，即sqrt(1.0001^tick) * 2^96，是一个Q64.96 number
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            // 计算得到这一次swap step对应的：
            // 1.sqrtRatioNextX96 交换amountin/amountout后的价格，不超过目标价格sqrtRatioTargetX96。把这个值赋给state.sqrtPriceX96，适用于多次循环。
            // 2.amountIn 根据交换方向，token0或token1的swapped in数量
            // 3.amountOut 根据交换方向，trader接收到的token0或token1的数量
            // 4.feeAmount 将被作为手续费的amountin
            // 2,3,4都被赋给本次swap step，只适用于本次循环
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96, // SwapState初始化的时候，sqrtPriceX96是池子的当前价格，后续随着while循环的进行，state.sqrtPriceX96就会发生变化，不再是池子的当前价格，会发生偏离
                // sqrtPriceLimitX96是输入参数，代表交换后的token0的价格限制
                // 如果zeroForOne为true，那么token0降价；反之token0涨价
                // token0降价时，如果低于sqrtPriceLimitX96，那么就使用sqrtPriceLimitX96
                // token0涨价时，如果高于sqrtPriceLimitX96，那么就使用sqrtPriceLimitX96
                // 总之，就是使得next price不超过价格下限/上限
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity, // 可用于池的当前范围内的流动性，这个值与所有ticks的总流动性没有关系
                state.amountSpecifiedRemaining, // 在输入/输出资产中进行交换的剩余金额，即剩余还未交换的量
                fee // 只可能是0.05%,0.3%,0.1%
            );

            // 更新state的amountSpecifiedRemaining和amountCalculated，即amountin和amountout或者amountout和amountin
            if (exactInput) { // 精确输入的场景
                // 更新state变量的amountSpecifiedRemaining，减去这次swap step的amountIn和手续费。有可能为0,也有可能还有剩。
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                // state.amountCalculated的初始值是0,每一次循环都要进行累积
                // 如果是精准输入，那么每次累积step.amountOut，注意，每次都是减，累积之后是负数，越累加，负得越多，说明总的amountOut越多
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
                // 总结：精确输入的场景，amountSpecifiedRemaining由正向0靠拢，amountCalculated负得越来越多
            } else { // 精确输出的场景
                // state.amountSpecifiedRemaining初始化是负数，step.amountOut是正数，那么每次循环都加step.amountOut，state.amountSpecifiedRemaining就负得越少，剩余的amountout就越少
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                // state.amountCalculated的初始值是0,每一次循环都要进行累积
                // 如果是精准输出，那么每次累积step.amountIn + step.feeAmount，注意，每次都是加，累积之后是正数，越累加，正得越多，说明总的amountIn越多
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
                // 总结：精确输出的场景，amountSpecifiedRemaining由负向0靠拢，amountCalculated正得越来越多
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            // 如果协议费用是打开的，计算欠多少，减feeAmount，增加protocolFee，即从feeAmount中划一部分到protocolFee
            // cache的类型是SwapCache，缓存的swap之前的数据,feeProtocol来自于状态变量slot0Start.feeProtocol
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol; // 协议费
                step.feeAmount -= delta; // 手续费扣除协议费
                state.protocolFee += uint128(delta); // 协议费累积
            }

            // update global fee tracker
            if (state.liquidity > 0)//TODO
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    // check for the placeholder value, which we replace with the actual value the first time the swap
                    // crosses an initialized tick
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    int128 liquidityNet =
                        ticks.cross(
                            step.tickNext,
                            (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                            (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
                            cache.secondsPerLiquidityCumulativeX128,
                            cache.tickCumulative,
                            cache.blockTimestamp
                        );
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    if (zeroForOne) liquidityNet = -liquidityNet;

                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        } // 这里是while循环的结束

        // update tick and write an oracle entry if the tick change
        if (state.tick != slot0Start.tick) {
            (uint16 observationIndex, uint16 observationCardinality) =
                observations.write(
                    slot0Start.observationIndex,
                    cache.blockTimestamp,
                    slot0Start.tick,
                    cache.liquidityStart,
                    slot0Start.observationCardinality,
                    slot0Start.observationCardinalityNext
                );
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // otherwise just update the price
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // update fee growth global and, if necessary, protocol fees
        // overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // do the transfers and collect payment
        if (zeroForOne) {
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
        } else {
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
        }

        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        slot0.unlocked = true;
    }

    /// @inheritdoc IUniswapV3PoolActions
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override lock noDelegateCall {
        uint128 _liquidity = liquidity;
        require(_liquidity > 0, 'L');

        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        require(balance0Before.add(fee0) <= balance0After, 'F0');
        require(balance1Before.add(fee1) <= balance1After, 'F1');

        // sub is safe because we know balanceAfter is gt balanceBefore by at least fee
        uint256 paid0 = balance0After - balance0Before;
        uint256 paid1 = balance1After - balance1Before;

        if (paid0 > 0) {
            uint8 feeProtocol0 = slot0.feeProtocol % 16;
            uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;
            if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0);
            feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - fees0, FixedPoint128.Q128, _liquidity);
        }
        if (paid1 > 0) {
            uint8 feeProtocol1 = slot0.feeProtocol >> 4;
            uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;
            if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);
            feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - fees1, FixedPoint128.Q128, _liquidity);
        }

        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner {
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10)) &&
                (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );
        uint8 feeProtocolOld = slot0.feeProtocol;
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock onlyFactoryOwner returns (uint128 amount0, uint128 amount1) {
        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        if (amount0 > 0) {
            if (amount0 == protocolFees.token0) amount0--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            if (amount1 == protocolFees.token1) amount1--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}

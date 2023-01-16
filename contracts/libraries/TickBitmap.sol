// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './BitMath.sol';

/// @title Packed tick initialized state library
/// @notice Stores a packed mapping of tick index to its initialized state
/// @dev The mapping uses int16 for keys since ticks are represented as int24 and there are 256 (2^8) values per word.
library TickBitmap {
    /// @notice Computes the position in the mapping where the initialized bit for a tick lives
    /// @param tick The tick for which to compute the position
    /// @return wordPos The key in the mapping containing the word in which the bit is stored
    /// @return bitPos The bit position in the word where the flag is stored
    /// @notice 计算一个tick在第几个word，以及在这个word中的具体位置
    /// @param tick 需要计算位置的tick，通常传进来的是根据tickSpacing压缩后的tick，比如tick是50,tickSpacing是10,那么compressed就是5
    /// @return wordPos 映射中包含存储位的word的键
    /// @return bitPos flag在word中存储的位位置(position)
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        // 右移一位就相当于除以2,那右移8位就相当于除以256
        // wordPos就是tick除以256的值，比如tick在0到255之间，那么wordPos为0；tick在256到511之间，那么wordPos为1；以此类推
        // 之所以用位右移操作，原因是比直接除256更加节省gas费
        // 此处可以看出来，一个word包含256个数，wordPos表示tick在第几个word，bitPos表示tick在某个word中的第几位，换句话说，就是tick在某个word中排在第几个位置
        wordPos = int16(tick >> 8);
        bitPos = uint8(tick % 256);
    }

    /// @notice Flips the initialized state for a given tick from false to true, or vice versa
    /// @param self The mapping in which to flip the tick
    /// @param tick The tick to flip
    /// @param tickSpacing The spacing between usable ticks

    /// @notice 将给定tick的初始化状态从false翻转为true，反之亦然
    /// @param self 要翻转tick的映射
    /// @param tick 要翻转的tick
    /// @param tickSpacing 可用tick之间的间隔
    function flipTick(//TODO: 逻辑还没细看
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing
    ) internal {
        require(tick % tickSpacing == 0); // ensure that the tick is spaced
        (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        uint256 mask = 1 << bitPos;
        self[wordPos] ^= mask;
    }

    /// @notice Returns the next initialized tick contained in the same word (or adjacent word) as the tick that is either
    /// to the left (less than or equal to) or right (greater than) of the given tick
    /// @param self The mapping in which to compute the next initialized tick
    /// @param tick The starting tick
    /// @param tickSpacing The spacing between usable ticks
    /// @param lte Whether to search for the next initialized tick to the left (less than or equal to the starting tick)
    /// @return next The next initialized or uninitialized tick up to 256 ticks away from the current tick
    /// @return initialized Whether the next tick is initialized, as the function only searches within up to 256 ticks

    /// @notice 返回与给定tick的左边(小于或等于)或右边(大于)的tick包含在同一个word(或相邻word)中的下一个初始化的tick，注意：返回的可以是已经初始化的tick，也可以是还没有初始化的tick
    /// @param self 用于计算下一个已初始化tick的映射，即mapping
    /// @param tick 开始的tick
    /// @param tickSpacing 可用tick之间的间距
    /// @param lte 是否搜索下一个已初始化的左边tick(小于或等于起始tick)，如果搜索左边tick，则为true，如果搜索右边tick，则为false
    /// @return next 下一个初始化或未初始化的tick，距当前tick最多256个tick
    /// @return initialized 是否下一个tick已经初始化了，因为函数只搜索最多256个ticks
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        // 假设tickSpacing是10（手续费为0.05%的场景）
        // 1.tick为正数，比如50,那么compressed就是5，价格P是1.0001的50次方，就是1.00501...
        // 2.tick为负数，比如-55,那么compressed就是-5，价格P是1.0001的-55次方，就是0.994515...
        // 可以把compressed理解为经过了压缩之后的tick，打个比方，如果tick是50到59之间的任何一个数，那么compressed都是5
        int24 compressed = tick / tickSpacing;
        // 比如tick是-55, tick % tickSpacing就不等于0, 有余数，那么compressed就是-5，然后再减1,就是-6，向负无穷大舍入
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity

        if (lte) {
            // 如果是搜索下一个已初始化的左边tick(小于或等于起始tick)
            // 注意，此处传入的是compressed，即压缩后的tick
            // 计算压缩后的tick在第几个word，以及在这个word中的具体位置，也就是对compressed进行精准定位
            // 打个比方，如果compressed是258,那么wordPos是1,bitPos是2
            // 如果compressed是256,那么wordPos是1,bitPos是0
            // bitPos的值在0到255之间，刚好可以对应uint256的256个二进制位，相当于256个插槽
            (int16 wordPos, uint8 bitPos) = position(compressed);
            // all the 1s at or to the right of the current bitPos
            // 假设bitPos为2,那么1 << bitPos为4,mask为7，换算成二进制就是111, bitPos 2刚好对应最左边那个1的插槽
            // 假设bitPos为3,那么1 << bitPos为8,mask为15，换算成二进制就是1111, bitPos 3刚好对应最左边那个1的插槽
            // 所以，mask就是把bitPos对应的插槽的右边全部填充1
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            uint256 masked = self[wordPos] & mask;//TODO

            // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            next = initialized
                ? (compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing
                : (compressed - int24(bitPos)) * tickSpacing;
        } else {
            // start from the word of the next tick, since the current tick state doesn't matter
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            // all the 1s at or to the left of the bitPos
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = self[wordPos] & mask;

            // if there are no initialized ticks to the left of the current tick, return leftmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            next = initialized
                ? (compressed + 1 + int24(BitMath.leastSignificantBit(masked) - bitPos)) * tickSpacing
                : (compressed + 1 + int24(type(uint8).max - bitPos)) * tickSpacing;
        }
    }
}

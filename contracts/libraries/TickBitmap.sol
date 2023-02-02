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
    /// @param self 用于计算下一个已初始化tick的映射，即mapping，键代表经过了压缩之后的tick，即compressed，打个比方，如果tick是50到59之间的任何一个数，那么compressed都是5
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

        if (lte) { // 找小于或等于tick的next tick
            // 如果是搜索下一个已初始化的左边tick(小于或等于起始tick)
            // 注意，此处传入的是compressed，即压缩后的tick
            // 计算压缩后的tick在第几个word，以及在这个word中的具体位置，也就是对compressed进行精准定位
            // 打个比方，如果compressed是258,那么wordPos是1,bitPos是2
            // 如果compressed是256,那么wordPos是1,bitPos是0
            // bitPos的值在0到255之间，刚好可以对应uint256的256个二进制位，相当于256个插槽
            // 举例：
            // tick=260-->compressed=26-->wordPos=0,bitPos=26-->mask为27个1组成的二进制
            // tick=258-->compressed=25-->wordPos=0,bitPos=25-->mask为26个1组成的二进制
            // tick=50-->compressed=5-->wordPos=0,bitPos=5-->mask为6个1组成的二进制，即111111
            // tick=10-->compressed=1-->wordPos=0,bitPos=1-->mask为2个1组成的二进制，即11
            (int16 wordPos, uint8 bitPos) = position(compressed);
            // all the 1s at or to the right of the current bitPos
            // 假设bitPos为2,那么1 << bitPos为4,mask为7，换算成二进制就是111, bitPos 2刚好对应最左边那个1的插槽
            // 假设bitPos为3,那么1 << bitPos为8,mask为15，换算成二进制就是1111, bitPos 3刚好对应最左边那个1的插槽
            // 所以，mask就是把bitPos对应的插槽的右边全部填充1
            // 注意：mask的类型是uint256，有256位
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            // &是位与操作，如果bitPos为2,那么mask就是111,就用self[wordPos]和111做位与操作
            // 如果self[wordPos]最低三位为000,那么位与操作的结果就是0，那么initialized为false，未初始化
            // 如果self[wordPos]最低三位只要有一位为1,那么位与操作的结果就是非0,那么initialized为true，已初始化
            uint256 masked = self[wordPos] & mask;

            // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            // 第一个例子
            // 如果已初始化，以tick为258举个例子，bitPos为25,mask为26个1组成的二进制,如果self[wordPos]的最低26位是00..001，那么masked=1，那么masked的最高位索引为0,那么(compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing = (25-(25-0))*10=0,和tick相差258
            // 如果self[wordPos]的最低26位是00..011，那么masked=11，那么masked的最高位索引为1,那么(compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing = (25-(25-1))*10=10
            // 如果self[wordPos]的最低26位是00..111，那么masked=111，那么masked的最高位索引为2,那么(compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing = (25-(25-2))*10=20
            // 如果self[wordPos]的最低26位是11..111，那么masked=26个1，那么masked的最高位索引为25,那么(compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing = (25-(25-25))*10=250
            // tick 250的next tick的可能值就是0,10,20,30,40,...240,250
            // 第二个例子
            // 如果已初始化，以tick为260举个例子，compressed为26,bitPos为26,mask为27个1组成的二进制，如果self[wordPos]的最低27位是00..001，那么masked=1，那么masked的最高位索引为0,那么(compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing = (26-(26-0))*10=0,和tick相差260
            // 如果self[wordPos]的最低27位是00..011，那么masked=11，那么masked的最高位索引为1,那么(compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing = (26-(26-1))*10=10,和tick相差250
            // 如果self[wordPos]的最低27位是00..111，那么masked=111，那么masked的最高位索引为2,那么(compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing = (26-(26-2))*10=20,和tick相差240
            // 如果self[wordPos]的最低27位是00..1111，那么masked=1111，那么masked的最高位索引为3,那么(compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing = (26-(26-3))*10=30,和tick相差230
            // 如果self[wordPos]的最低27位全是1，那么masked=27个1，那么masked的最高位索引为26,那么(compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing = (26-(26-26))*10=260,和tick相差0,即相等
            // 可以看出来，self[wordPos]的最低27位，左边有几个0,那么next tick就和传入tick相差几十，如果最左边是1,那么next tick就和传入tick是一个tick，即小于等于tick
            // tick 260的next tick的可能值就是0,10,20,30,40,...,250,260
            // 第三个例子
            // 如果已初始化，以tick为10举个例子，compressed为1,bitPos为1,mask为11，如果self[wordPos]的最低2位是01，那么masked=1，那么masked的最高位索引为0,那么(compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing = (1-(1-0))*10=0,和tick相差10
            // 如果self[wordPos]的最低2位是11，那么masked=11，那么masked的最高位索引为1,那么(compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing = (1-(1-1))*10=10,和tick相差0
            // tick 10的next tick的可能值就是0,10
            // 如果没有初始化，举三个例子：
            // 如果tick为50,tickSpacing为10,compressed为5,wordPos为0,bitPoS为5,那么(compressed - int24(bitPos)) * tickSpacing = (5-5)*10=0，即下一个tick是0
            // 如果tick为258,tickSpacing为10,compressed为25,wordPos为0,bitPoS为25,那么(compressed - int24(bitPos)) * tickSpacing = (25-25)*10=0，即下一个tick是0
            // 如果tick为260,tickSpacing为10,compressed为26,wordPos为0,bitPoS为26,那么(compressed - int24(bitPos)) * tickSpacing = (26-26)*10=0，即下一个tick是0
            // 如果tick为2600,tickSpacing为10,compressed=260,wordPos=1,bitPos=4,那么(compressed - int24(bitPos)) * tickSpacing = (260-4)*10=2560，即下一个tick是2560
            next = initialized
                ? (compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing
                : (compressed - int24(bitPos)) * tickSpacing;
        } else { // 找大于或等于tick的next tick
            // start from the word of the next tick, since the current tick state doesn't matter
            // 从下一个tick的word开始，因为当前的tick状态并不重要
            // tick=260-->compressed=26-->compressed + 1=27-->wordPos=0,bitPos=27-->mask为28个1组成的二进制-->masked有可能在00..000到28个1之间，index在0到27之间
            // 如果index是27,(compressed + 1 + int24(BitMath.leastSignificantBit(masked) - bitPos)) * tickSpacing=(27+(27-27))*10=270
            // 如果index是26,(compressed + 1 + int24(BitMath.leastSignificantBit(masked) - bitPos)) * tickSpacing=(27+(26-27))*10=260
            // 如果index是0,(compressed + 1 + int24(BitMath.leastSignificantBit(masked) - bitPos)) * tickSpacing=(27+(0-27))*10=0
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            // all the 1s at or to the left of the bitPos
            // ~就是每位取反，bitPos=27，1 << bitPos就是1后面跟27个0,100..000，再减1,就是27个1,再用~取反，就是256-27个1,即229个1,加上27个0,即1111111..11100..000
            // 那么masked的leastSignificantBit可能是0,也可能是27,28,29,30,...,254,255
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = self[wordPos] & mask;

            // if there are no initialized ticks to the left of the current tick, return leftmost in the word
            // 如果在当前tick的左边没有初始化的tick，则返回word中的最左边
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            // 如果已经初始化，masked的leastSignificantBit可能是0,也可能是27,28,29,30,...,254,255
            // 如果是27,(26 + 1 + (27-27)) * 10=270
            // 如果是28,(26 + 1 + (28-27)) * 10=280
            // 如果是29,(26 + 1 + (29-27)) * 10=290
            // 如果是255,(26 + 1 + (255-27)) * 10=2550
            // 如果没有初始化,type(uint8).max为255,(compressed + 1 + int24(type(uint8).max - bitPos)) * tickSpacing=(26 + 1 + (255-27)) * 10=2550
            // 总结：tick 260的next tick可能是270,280,290,...,2530,2540,2550
            next = initialized
                ? (compressed + 1 + int24(BitMath.leastSignificantBit(masked) - bitPos)) * tickSpacing
                : (compressed + 1 + int24(type(uint8).max - bitPos)) * tickSpacing;
        }
    }
}

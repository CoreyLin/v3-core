// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

/// @title Prevents delegatecall to a contract
/// @notice Base contract that provides a modifier for preventing delegatecall to methods in a child contract
abstract contract NoDelegateCall {
    /// @dev The original address of this contract
    address private immutable original; // 注意：是immutable的

    constructor() {
        // Immutables are computed in the init code of the contract, and then inlined into the deployed bytecode.
        // In other words, this variable won't change when it's checked at runtime.
        // 不可变变量在合约的初始化代码中计算，然后内联到部署的字节码中。换句话说，这个变量在运行时不会改变。
        original = address(this);
    }

    /// @dev Private method is used instead of inlining into modifier because modifiers are copied into each method,
    ///     and the use of immutable means the address bytes are copied in every place the modifier is used.
    /// 使用Private方法而不是内联到修饰符中，因为修饰符被复制到每个方法中，如果把require(address(this) == original)内联到修饰符中，
    /// 意味着immutable original地址字节会被复制到修饰符使用的每一个地方，造成代码冗余以及代码过大。
    function checkNotDelegateCall() private view {
        require(address(this) == original); // 判断当前地址是否是original（即合约地址），如果是delegatecall，address(this)就是外部调用的合约地址，而不是本合约地址
    }

    /// @notice Prevents delegatecall into the modified method
    /// 防止委托调用修改后的方法
    /// // 判断当前地址是否是original（即合约地址），如果是delegatecall，address(this)就是外部调用的合约地址，而不是本合约地址
    modifier noDelegateCall() {
        checkNotDelegateCall();
        _;
    }
}

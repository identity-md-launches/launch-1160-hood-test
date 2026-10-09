// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Hood Test (HOODT)
/// @notice A fixed-supply ERC-20 for an ordinary token launch on Robinhood Chain.
/// @dev The whole supply, 1,000,000,000 HOODT with 18 decimals (1e27 minor units), is minted once to
/// the deployer in the constructor. The deployer is the launch factory, which distributes the supply:
/// the swarm's share goes through the Merkle distributor, the pool share seeds the Uniswap v4 pool and
/// the remainder is forwarded. This contract never subtracts any allocation itself.
///
/// There is no owner, no admin, no minting after construction, no pause, no blacklist, no fee or tax
/// on transfer, no proxy, no delegatecall and no selfdestruct. Every parameter is a compile-time
/// constant. The contract is self-contained: it imports nothing.
contract HOODTToken {
    /// @notice Emitted on every transfer, including the single constructor mint (from the zero address).
    event Transfer(address indexed from, address indexed to, uint256 value);
    /// @notice Emitted whenever an allowance is set.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice A transfer or approval named the zero address as the counterparty.
    error ZeroAddress();
    /// @notice The sender's balance is smaller than the amount it tried to move.
    error InsufficientBalance(address from, uint256 balance, uint256 needed);
    /// @notice The spender's allowance is smaller than the amount it tried to move.
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    string public constant name = "Hood Test";
    string public constant symbol = "HOODT";
    uint8 public constant decimals = 18;

    /// @notice The fixed supply in minor units: 1,000,000,000 * 10 ** 18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    /// @dev Mints the entire supply to the deployer. No outside contract is called, so the
    /// constructor runs on an empty chain exactly as it runs on the real one.
    constructor() {
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    /// @notice The supply, fixed forever at `TOTAL_SUPPLY`.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @notice Moves `amount` from the caller to `to` with no fee, tax or limit.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to `amount`.
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves `amount` from `from` to `to` within the caller's allowance. An allowance of
    /// `type(uint256).max` is treated as infinite and is not decremented.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 current = allowance[from][msg.sender];
        if (current != type(uint256).max) {
            if (current < amount) revert InsufficientAllowance(msg.sender, current, amount);
            unchecked {
                allowance[from][msg.sender] = current - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            balanceOf[from] = fromBalance - amount;
            // The supply is fixed and every balance is bounded by it, so the sum cannot overflow.
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (spender == address(0)) revert ZeroAddress();
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

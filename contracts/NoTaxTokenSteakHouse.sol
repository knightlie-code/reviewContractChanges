// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
//  🥩 STEAKHOUSE — Clean. Curve. Contracts.

   SteakHouse Finance | NoTax Token Contract
   📲 dapp:      https://steakhouse.finance
   ✖️ x:         https://x.com/steakhouse_fi
   📤 telegram:  https://t.me/steakhouse_fi
   🔒 locker:    https://locker.steakhouse.finance
   📈 curve:     https://app.steakhouse.finance/token/[token]

   This contract is deployed by SteakHouse Finance.
   Contains no tax or ownership logic.
   All minting and LP actions are done via the Graduation Controller.
*/

contract NoTaxToken {
    // --- ERC20 basics ---
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public immutable maxSupply; // hard cap
    uint256 public totalSupply;         // minted so far

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable minter;

    // --- Events ---
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // --- Modifiers ---
    modifier onlyMinter() {
        require(msg.sender == minter, "Only minter");
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _maxSupply
    ) {

    // --- input validation ---
    require(bytes(_name).length > 0 && bytes(_symbol).length > 0, "Invalid name/symbol");
    require(_maxSupply > 1e18 && _maxSupply <= 1_000_000_000_000 * 1e18, "Invalid supply");

    // Initialize token metadata and record deployer as `minter`.
    // This contract intentionally contains no tax or privileged transfer logic.
    name = _name;
    symbol = _symbol;
    maxSupply = _maxSupply;
    minter = msg.sender;
    }

    // --- Minting (Factory/Graduation via Deployer) ---
    function mint(address to, uint256 amount) external onlyMinter {
    // Mint helper used by the deployer during graduation; enforces maxSupply cap.
    require(to != address(0), "zero addr");
    uint256 newTotal = totalSupply + amount;
    require(newTotal <= maxSupply, "Exceeds maxSupply");
    totalSupply = newTotal;
    balanceOf[to] += amount;
    emit Transfer(address(0), to, amount);
    }

    // --- ERC20 ---
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        unchecked { allowance[from][msg.sender] = allowed - amount; }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        // Minimal ERC20 transfer implementation — mirrors `NoTaxToken`.
        require(to != address(0), "zero addr");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "balance");
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}

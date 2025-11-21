// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { TaxToken as TaxTokenSteakHouseImpl } from "./TaxTokenSteakHouse.sol";
import { NoTaxToken as NoTaxTokenSteakHouseImpl } from "./NoTaxTokenSteakHouse.sol";
import "./TaxToken.sol";
import "./NoTaxToken.sol";
import "./KitchenTimelock.sol";

interface ITaxOrNoTaxMint { function mint(address to, uint256 amount) external; }

error NotOwner();
error NotFactory();
error FinalTaxTooHigh();
error HeaderlessFeeTooLow();
error FinalTaxMustBeZero();

// --- Governance Events ---
event RouterUpdated(address indexed oldRouter, address indexed newRouter);
event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
event FactoryUpdated(address indexed oldFactory, address indexed newFactory);
event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
event EmergencyWithdraw(address indexed to, uint256 amount);


contract KitchenDeployer is KitchenTimelock {
    address public owner;
    address public router;
    address public steakhouseTreasury;
    address public factory;

    uint256 public constant FEE_HEADERLESS = 0.003 ether;

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyFactory() { if (msg.sender != factory) revert NotFactory(); _; }

    constructor(address _router, address _treasury) {
        owner = msg.sender;
        router = _router;
        steakhouseTreasury = _treasury;
    }

function setRouter(address _router)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_ROUTER"))
{
    address old = router;
    router = _router;
    emit RouterUpdated(old, _router);
}

function setTreasury(address _treasury)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_TREASURY"))
{
    address old = steakhouseTreasury;
    steakhouseTreasury = _treasury;
    emit TreasuryUpdated(old, _treasury);
}

function setFactory(address _factory)
    external
    onlyOwner
    timelocked(keccak256("UPDATE_FACTORY"))
{
    address old = factory;
    factory = _factory;
    emit FactoryUpdated(old, _factory);
}

function transferOwnership(address newOwner)
    external
    onlyOwner
    timelocked(keccak256("TRANSFER_OWNERSHIP"))
{
    require(newOwner != address(0), "Zero address");
    address old = owner;
    owner = newOwner;
    emit OwnershipTransferred(old, newOwner);
}

    // ---- Only handles headered/headerless ----
    function deployToken(
        string memory name,
        string memory symbol,
        address creator,
        // --- NEW MULTI-WALLET TAX SUPPORT ---
        address[4] calldata taxWallets,
        uint8[4] calldata taxSplits,
        bool isTax,
        bool removeHeader,
        uint256 finalTaxRate,
        uint256 maxSupply
    ) external payable onlyFactory returns (address tokenAddress) {
        // Enforce tax invariants independent of isTax flag.
        // If final ERC20 is NO_TAX, finalTaxRate must be exactly 0.
        // If ERC20 is TAX, finalTaxRate must be <= 5.
        if (finalTaxRate > 5) revert FinalTaxTooHigh();
        if (!isTax && finalTaxRate != 0) revert FinalTaxMustBeZero();


        if (removeHeader) {
            if (msg.value < FEE_HEADERLESS) revert HeaderlessFeeTooLow();
            (bool ok, ) = payable(steakhouseTreasury).call{value: msg.value}("");
            require(ok, "headerless fee xfer failed");

            tokenAddress = isTax
                ? address(new TaxToken(name, symbol, maxSupply, finalTaxRate, steakhouseTreasury, router, taxWallets,  taxSplits))
                : address(new NoTaxToken(name, symbol, maxSupply));
        } else {
            tokenAddress = isTax
                ? address(new TaxTokenSteakHouseImpl(name, symbol, maxSupply, finalTaxRate, steakhouseTreasury, router, taxWallets,  taxSplits))
                : address(new NoTaxTokenSteakHouseImpl(name, symbol, maxSupply));
        }
        return tokenAddress;
    }

    function mintRealToken(address token, address to, uint256 amount) external onlyFactory {
        ITaxOrNoTaxMint(token).mint(to, amount);
    }

function getConfig() external view returns (
    address _router,
    address _treasury,
    address _factory,
    address _owner
) {
    return (
        router,
        steakhouseTreasury,
        factory,
        owner
    );
}

function emergencyWithdraw(address payable to)
    external
    onlyOwner
    timelocked(keccak256("EMERGENCY_WITHDRAW"))
{
    require(to != address(0), "Zero address");
    uint256 amt = address(this).balance;
    require(amt > 0, "No balance");
    (bool ok, ) = to.call{value: amt}("");
    require(ok, "Withdraw failed");
    emit EmergencyWithdraw(to, amt);
}


    receive() external payable {}
}

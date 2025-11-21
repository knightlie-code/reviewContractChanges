// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { TaxToken as TaxTokenSteakHouseImpl } from "./TaxTokenSteakHouse.sol";
import { NoTaxToken as NoTaxTokenSteakHouseImpl } from "./NoTaxTokenSteakHouse.sol";
import "./TaxToken.sol";
import "./NoTaxToken.sol";

interface ITaxOrNoTaxMint { function mint(address to, uint256 amount) external; }

error NotOwner();
error NotFactory();
error FinalTaxTooHigh();
error HeaderlessFeeTooLow();

contract KitchenDeployer {
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

    function setRouter(address _router) external onlyOwner { router = _router; }
    function setTreasury(address _treasury) external onlyOwner { steakhouseTreasury = _treasury; }
    function setFactory(address _factory) external onlyOwner { factory = _factory; }
    function transferOwnership(address newOwner) external onlyOwner { owner = newOwner; }

    // ---- Only handles headered/headerless ----
    function deployToken(
        string memory name,
        string memory symbol,
        address creator,
        address taxWallet,
        bool isTax,
        bool removeHeader,
        uint256 finalTaxRate,
        uint256 maxSupply
    ) external payable onlyFactory returns (address tokenAddress) {
        if (isTax && finalTaxRate > 5) revert FinalTaxTooHigh();

        if (removeHeader) {
            if (msg.value < FEE_HEADERLESS) revert HeaderlessFeeTooLow();
            (bool ok, ) = payable(steakhouseTreasury).call{value: msg.value}("");
            require(ok, "headerless fee xfer failed");

            tokenAddress = isTax
                ? address(new TaxToken(name, symbol, maxSupply, finalTaxRate, taxWallet, steakhouseTreasury, router))
                : address(new NoTaxToken(name, symbol, maxSupply));
        } else {
            tokenAddress = isTax
                ? address(new TaxTokenSteakHouseImpl(name, symbol, maxSupply, finalTaxRate, taxWallet, steakhouseTreasury, router))
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



    receive() external payable {}
}

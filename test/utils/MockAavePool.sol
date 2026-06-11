// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockAToken is ERC20 {
    address public underlyingAsset;
    uint256 public constant RAY = 1e27;

    constructor(string memory name, string memory symbol, address _underlying) ERC20(name, symbol) {
        underlyingAsset = _underlying;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockAavePool {
    mapping(address => MockAToken) public aTokens;
    mapping(address => mapping(address => uint256)) public balances; // user => asset => amount
    uint256 public constant RAY = 1e27;

    constructor() {}

    function createAToken(address underlying) external {
        require(address(aTokens[underlying]) == address(0), "aToken already exists");
        MockAToken aToken = new MockAToken("aToken", "aToken", underlying);
        aTokens[underlying] = aToken;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(address(aTokens[asset]) != address(0), "aToken not created");

        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        balances[onBehalfOf][asset] += amount;

        // Mint aTokens 1:1
        aTokens[asset].mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(address(aTokens[asset]) != address(0), "aToken not created");

        uint256 bal = balances[msg.sender][asset];
        uint256 toWithdraw = amount > bal ? bal : amount;

        balances[msg.sender][asset] -= toWithdraw;
        IERC20(asset).transfer(to, toWithdraw);

        // Burn aTokens 1:1
        aTokens[asset].burn(msg.sender, toWithdraw);

        return toWithdraw;
    }

    function getBalance(address user, address asset) external view returns (uint256) {
        return balances[user][asset];
    }

    function getAToken(address underlying) external view returns (address) {
        return address(aTokens[underlying]);
    }

    function getReserveData(address asset)
        external
        view
        returns (uint256 currentVariableBorrowRate, uint256 currentLiquidityRate)
    {
        return (RAY * 3 / 100, RAY * 2 / 100); // 3% borrow, 2% supply
    }
}
